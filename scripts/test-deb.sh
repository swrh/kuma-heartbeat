#!/usr/bin/env bash
# Install, smoke-test, and uninstall a built kuma-heartbeat .deb inside a
# Debian/Ubuntu container.
#
# Usage: test-deb.sh <kuma-heartbeat-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container, from the
# repository root (it uses scripts/stub-server.py).

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <kuma-heartbeat-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

export DEBIAN_FRONTEND=noninteractive
conf=/etc/kuma-heartbeat/kuma-heartbeat.conf
token=SECRETTOKEN0123456789abcdef
port=18080
reqlog=/tmp/stub-requests.log

rm -f /etc/dpkg/dpkg.cfg.d/excludes
apt-get update -qq || fail "apt-get update"

if apt-cache show kuma-heartbeat >/dev/null 2>&1; then
  echo "==> Stock 'kuma-heartbeat' package found; installing it first"
  apt-get install -y kuma-heartbeat || fail "apt-get install (stock kuma-heartbeat)"
fi

echo "==> Installing $deb_path"
apt-get install -y -o Dpkg::Options::=--force-confold "./${deb_path}" || fail "apt-get install"

echo "==> Verifying installation"
hash -r
command -v kuma-heartbeat >/dev/null 2>&1 || fail "kuma-heartbeat not found on PATH after install"
kuma-heartbeat --help >/dev/null || fail "--help failed"
version_out="$(kuma-heartbeat --version)"
[[ "$version_out" == "kuma-heartbeat ${expected_version}-"* ]] \
  || fail "--version printed '$version_out', expected '${expected_version}-*'"

[[ -f "$conf" ]] || fail "$conf missing"
[[ "$(stat -c %a "$conf")" == 600 ]] || fail "$conf mode is $(stat -c %a "$conf"), expected 600"
[[ -f /usr/share/doc/kuma-heartbeat/kuma-heartbeat.conf.example ]] || fail "conf example missing"
for u in service timer; do
  [[ -f /lib/systemd/system/kuma-heartbeat.$u || -f /usr/lib/systemd/system/kuma-heartbeat.$u ]] \
    || fail "kuma-heartbeat.$u not installed"
done
dpkg -s kuma-heartbeat | grep -q "^Status: install ok installed" || fail "dpkg status is not 'install ok installed'"

# Not configured yet: the maintainer script must not have enabled the timer.
if command -v deb-systemd-helper >/dev/null 2>&1 \
   && deb-systemd-helper --quiet is-enabled kuma-heartbeat.timer; then
  fail "timer was enabled although the config is empty"
fi

echo "==> Validating systemd units"
apt-get install -y systemd >/dev/null || fail "apt-get install systemd"
systemd-analyze verify /lib/systemd/system/kuma-heartbeat.service /lib/systemd/system/kuma-heartbeat.timer \
  || fail "systemd-analyze verify"

echo "==> Functional tests against a stub Uptime Kuma"
apt-get install -y python3 >/dev/null || fail "apt-get install python3"
: > "$reqlog"
python3 "$repo_root/scripts/stub-server.py" "$port" "$reqlog" "$token" &
stub_pid=$!
trap 'kill $stub_pid 2>/dev/null || true' EXIT
for _ in $(seq 20); do
  python3 -c "import socket; socket.create_connection(('127.0.0.1', $port), 1)" 2>/dev/null && break
  sleep 0.25
done

write_conf() { # host token [extra lines]
  printf 'KUMA_HOST="%s"\nKUMA_TOKEN="%s"\n%s\n' "$1" "$2" "${3:-}" > "$conf"
  chmod 600 "$conf"
}
requests() { wc -l < "$reqlog" | tr -d ' '; }
no_token_leak() { # file
  if grep -q "$token" "$1"; then
    cat "$1" >&2
    fail "token leaked in output"
  fi
}

# 1. Success.
write_conf "http://127.0.0.1:$port/" "$token"
kuma-heartbeat >/tmp/out 2>&1 || { cat /tmp/out; fail "push against stub failed"; }
no_token_leak /tmp/out
grep -q "^/api/push/$token?status=up&msg=OK" "$reqlog" || { cat "$reqlog"; fail "stub did not get the expected request"; }

# 2. Unreachable host: exit 1, no token in output.
write_conf "http://127.0.0.1:1" "$token" 'KUMA_TIMEOUT=2'
rc=0; kuma-heartbeat >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "unreachable host: exit $rc, expected 1"
no_token_leak /tmp/out

# 3. Wrong token (stub answers 404): exit 1, no token in output.
write_conf "http://127.0.0.1:$port" "WRONGTOKEN" 'KUMA_TIMEOUT=2'
rc=0; kuma-heartbeat >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 1 ]] || fail "wrong token: exit $rc, expected 1"

# 4. Empty / missing / bad config: exit 2.
write_conf "" ""
rc=0; kuma-heartbeat >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "empty config: exit $rc, expected 2"
rc=0; kuma-heartbeat --config /nonexistent >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "missing config: exit $rc, expected 2"
write_conf "http://127.0.0.1:$port" "$token" 'KUMA_INTERVAL=abc'
rc=0; kuma-heartbeat >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "KUMA_INTERVAL=abc: exit $rc, expected 2"
write_conf "http://127.0.0.1:$port" "$token" 'KUMA_INTERVAL=5'
rc=0; kuma-heartbeat >/tmp/out 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "KUMA_INTERVAL=5: exit $rc, expected 2"

# 5. --config overrides the default path.
cp "$conf" /tmp/other.conf
write_conf "" ""
printf 'KUMA_HOST="http://127.0.0.1:%s"\nKUMA_TOKEN="%s"\n' "$port" "$token" > /tmp/other.conf
kuma-heartbeat --config /tmp/other.conf >/tmp/out 2>&1 || { cat /tmp/out; fail "--config run failed"; }

# 6. --tick gating (state dir as the systemd service has it).
write_conf "http://127.0.0.1:$port" "$token" 'KUMA_INTERVAL=60'
export KUMA_HEARTBEAT_STATE=/tmp/kh-state
rm -rf "$KUMA_HEARTBEAT_STATE"; mkdir -p "$KUMA_HEARTBEAT_STATE"
: > "$reqlog"
kuma-heartbeat --tick >/tmp/out 2>&1 || fail "first --tick failed"
[[ "$(requests)" == 1 ]] || fail "first --tick should push once (got $(requests))"
kuma-heartbeat --tick >/tmp/out 2>&1 || fail "second --tick failed"
[[ "$(requests)" == 1 ]] || fail "second immediate --tick should not push (got $(requests))"
kuma-heartbeat >/tmp/out 2>&1 || fail "manual run failed"
[[ "$(requests)" == 2 ]] || fail "manual run should always push (got $(requests))"
unset KUMA_HEARTBEAT_STATE

# 6b. Under systemd the config comes from $CREDENTIALS_DIRECTORY/conf.
mkdir -p /tmp/creds
printf 'KUMA_HOST="http://127.0.0.1:%s"\nKUMA_TOKEN="%s"\n' "$port" "$token" > /tmp/creds/conf
write_conf "" ""
: > "$reqlog"
CREDENTIALS_DIRECTORY=/tmp/creds kuma-heartbeat >/tmp/out 2>&1 || { cat /tmp/out; fail "run via CREDENTIALS_DIRECTORY failed"; }
[[ "$(requests)" == 1 ]] || fail "CREDENTIALS_DIRECTORY config was not used"

# 7. --loop pushes at the configured interval and stops on SIGTERM.
write_conf "http://127.0.0.1:$port" "$token" 'KUMA_INTERVAL=10'
: > "$reqlog"
kuma-heartbeat --loop >/tmp/loop.out 2>&1 &
loop_pid=$!
sleep 12
kill "$loop_pid"
wait "$loop_pid" || true
[[ "$(requests)" -ge 2 ]] || fail "--loop should push at least twice in 12 s (got $(requests))"
grep -q "ping=" "$reqlog" || fail "--loop never sent a ping value"
no_token_leak /tmp/loop.out

kill "$stub_pid" 2>/dev/null || true
trap - EXIT

echo "==> Removing (config must be kept)"
apt-get remove -y kuma-heartbeat || fail "apt-get remove"
hash -r
command -v kuma-heartbeat >/dev/null 2>&1 && fail "kuma-heartbeat still present after removal"
[[ -f "$conf" ]] || fail "config removed by 'remove' (should only go on purge)"
[[ ! -f /lib/systemd/system/kuma-heartbeat.timer ]] || fail "timer unit left behind"

echo "==> Purging"
apt-get purge -y kuma-heartbeat || fail "apt-get purge"
[[ ! -e /etc/kuma-heartbeat ]] || fail "/etc/kuma-heartbeat left behind after purge"
if dpkg -s kuma-heartbeat 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "still reports as installed after purge"
fi

echo "PASS: all checks succeeded"
