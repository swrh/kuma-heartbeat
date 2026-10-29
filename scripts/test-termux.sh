#!/usr/bin/env bash
# Install, smoke-test, and uninstall the Termux kuma-heartbeat .deb inside a
# termux/termux-docker container (real Termux userland, dpkg and apt).
#
# Usage: test-termux.sh <kuma-heartbeat-termux-deb> <expected-version>
# Run as the container's default user ("system"), from the repository root.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <kuma-heartbeat-termux-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
prefix=/data/data/com.termux/files/usr
conf="$prefix/etc/kuma-heartbeat/kuma-heartbeat.conf"
svc="$prefix/var/service/kuma-heartbeat"
token=SECRETTOKEN0123456789abcdef
port=18080
reqlog="$HOME/stub-requests.log"
out="$HOME/out"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

echo "==> Inspecting package contents"
arch="$(dpkg --print-architecture)"
[[ "$(dpkg-deb -f "$deb_path" Architecture)" == "$arch" ]] \
  || fail "package architecture $(dpkg-deb -f "$deb_path" Architecture) != $arch"
paths="$(dpkg-deb -c "$deb_path" | awk '{print $6}' | grep -v '^\./$')"
bad="$(echo "$paths" | grep -vE '^\./data/data/com\.termux/files/usr(/|$)|^\./data(/|/data|/data/com\.termux|/data/com\.termux/files)/?$' || true)"
[[ -z "$bad" ]] || fail "paths outside the Termux prefix: $bad"
echo "$paths" | grep -q '/down$' && fail "package must not ship the service down file"
echo "$paths" | grep -qiE 'systemd|^\./(usr|etc|lib)/' && fail "systemd or non-Termux paths in package"

echo "==> Installing dependencies and $deb_path"
apt-get update -qq || fail "apt-get update"
# python only provides the stub server; the package itself needs just
# curl and termux-services (installed by dpkg's dependency resolution below).
apt-get install -y python >/dev/null || fail "apt-get install python"
apt-get install -y "./${deb_path}" || fail "apt-get install deb"

hash -r
command -v kuma-heartbeat >/dev/null || fail "kuma-heartbeat not on PATH"
version_out="$(kuma-heartbeat --version)"
[[ "$version_out" == "kuma-heartbeat ${expected_version}-"* ]] || fail "--version printed '$version_out'"
[[ "$(stat -c %a "$conf")" == 600 ]] || fail "$conf mode is not 600"
[[ -x "$svc/run" && -x "$svc/log/run" ]] || fail "service scripts missing"
[[ -e "$svc/down" ]] || fail "postinst should create the down file on a fresh install"
dpkg -s kuma-heartbeat | grep -q "^Status: install ok installed" || fail "dpkg status not installed"

echo "==> Functional test against a stub Uptime Kuma"
: > "$reqlog"
python3 "$repo_root/scripts/stub-server.py" "$port" "$reqlog" "$token" &
stub_pid=$!
trap 'kill $stub_pid 2>/dev/null || true' EXIT
sleep 2

printf 'KUMA_HOST="http://127.0.0.1:%s"\nKUMA_TOKEN="%s"\nKUMA_INTERVAL=10\n' "$port" "$token" > "$conf"
chmod 600 "$conf"
kuma-heartbeat >"$out" 2>&1 || { cat "$out"; fail "one-shot push failed"; }
grep -q "$token" "$out" && fail "token leaked in output"

echo "==> Running it as a supervised runit service"
export SVDIR="$prefix/var/service" # set by Termux login shells
runsvdir "$prefix/var/service" >"$HOME/runsvdir.log" 2>&1 &
runsvdir_pid=$!
sleep 3
sv-enable kuma-heartbeat >/dev/null 2>&1 || fail "sv-enable"
sleep 3
sv status kuma-heartbeat | grep -q '^run:' || { sv status kuma-heartbeat || true; fail "service not running"; }
: > "$reqlog"
sleep 13
[[ "$(wc -l < "$reqlog")" -ge 1 ]] || fail "service sent no heartbeat within 13 s"
grep -q "ping=" "$reqlog" || echo "(note: no ping value seen yet)"

echo "==> Upgrading while enabled (stays enabled, service restarted)"
old_pid="$(sv status kuma-heartbeat | sed -n 's/^run: [^:]*: (pid \([0-9]*\)).*/\1/p')"
apt-get install -y --reinstall "./${deb_path}" >/dev/null || fail "apt-get reinstall"
sleep 3
[[ ! -e "$svc/down" ]] || fail "upgrade re-created the down file"
sv status kuma-heartbeat | grep -q '^run:' || { sv status kuma-heartbeat || true; fail "service not running after upgrade"; }
new_pid="$(sv status kuma-heartbeat | sed -n 's/^run: [^:]*: (pid \([0-9]*\)).*/\1/p')"
[[ -n "$old_pid" && "$old_pid" != "$new_pid" ]] || fail "service not restarted by upgrade ($old_pid -> $new_pid)"

sv-disable kuma-heartbeat >/dev/null 2>&1 || true
kill "$runsvdir_pid" 2>/dev/null || true
kill "$stub_pid" 2>/dev/null || true
trap - EXIT

echo "==> Removing (config must be kept)"
apt-get remove -y kuma-heartbeat || fail "apt-get remove"
hash -r
command -v kuma-heartbeat >/dev/null && fail "kuma-heartbeat still on PATH"
[[ -f "$conf" ]] || fail "config removed by 'remove'"

echo "==> Purging"
apt-get purge -y kuma-heartbeat || fail "apt-get purge"
[[ ! -e "$conf" ]] || fail "config left behind after purge"
[[ ! -e "$svc" ]] || fail "service directory left behind"

echo "PASS: all checks succeeded"
