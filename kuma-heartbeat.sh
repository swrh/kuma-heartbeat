#!/bin/sh
# kuma-heartbeat: send a heartbeat to an Uptime Kuma "Push" monitor.
#
# Exit codes: 0 ok, 1 push failed, 2 configuration problem / bad usage.

# Rewritten by scripts/build-deb.sh for the Termux package.
PKG_PREFIX=""
# Replaced by scripts/build-deb.sh; "dev" when run from a checkout.
VERSION="__VERSION__"
case $VERSION in __*) VERSION=dev ;; esac

conf="${KUMA_HEARTBEAT_CONF:-$PKG_PREFIX/etc/kuma-heartbeat/kuma-heartbeat.conf}"
# Under the systemd service the root-only config arrives as a credential
# (the %d unit specifier would need systemd >= 250; Ubuntu 22.04 has 249).
if [ -z "${KUMA_HEARTBEAT_CONF:-}" ] && [ -r "${CREDENTIALS_DIRECTORY:-}/conf" ]; then
  conf="$CREDENTIALS_DIRECTORY/conf"
fi
state_dir="${KUMA_HEARTBEAT_STATE:-${STATE_DIRECTORY:-}}"

usage() {
  cat <<USAGE
Usage: kuma-heartbeat [options]

Send one heartbeat to an Uptime Kuma Push monitor:
  GET <KUMA_HOST>/api/push/<KUMA_TOKEN>?status=up&msg=OK&ping=<ms>

Options:
  -c, --config FILE  configuration file (default: $conf)
      --tick         periodic run (used by the systemd service): do nothing
                     if less than KUMA_INTERVAL - 15 s passed since the last
                     run
      --loop         run forever, one heartbeat every KUMA_INTERVAL seconds
                     (used by the Termux runit service)
      --check-config validate the configuration and exit
  -h, --help         show this help
  -V, --version      show the version

Configuration (shell syntax, see kuma-heartbeat.conf.example):
  KUMA_HOST      base URL of Uptime Kuma, e.g. https://kuma.example.com
  KUMA_TOKEN     push token of the monitor
  KUMA_STATUS    up (default) or down
  KUMA_MSG       message sent with the heartbeat (default: OK)
  KUMA_TIMEOUT   per-request timeout in seconds (default: 10)
  KUMA_INTERVAL  seconds between heartbeats, minimum 10 (default: 60)

Exit codes: 0 ok, 1 push failed, 2 configuration problem.
USAGE
}

nl='
'
# While BUFFERING is set (loop mode) messages are kept in BUF instead of
# printed, so run_loop can drop repeats without using temporary files.
info() {
  if [ -n "$BUFFERING" ]; then BUF="${BUF}kuma-heartbeat: $*$nl"; else printf 'kuma-heartbeat: %s\n' "$*"; fi
}
err() {
  if [ -n "$BUFFERING" ]; then BUF="${BUF}kuma-heartbeat: $*$nl"; else printf 'kuma-heartbeat: %s\n' "$*" >&2; fi
}

is_uint() {
  case $1 in
    '' | *[!0-9]*) return 1 ;;
  esac
}

urlencode() {
  printf '%s' "$1" | tr -d '\n\r' | sed \
    -e 's/%/%25/g' -e 's/ /%20/g' -e 's/&/%26/g' -e 's/+/%2B/g' \
    -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/=/%3D/g' -e 's/"/%22/g' \
    -e 's/\\/%5C/g'
}

# Loads and validates $conf into KUMA_*. Returns 2 on any problem.
load_config() {
  KUMA_HOST="" KUMA_TOKEN="" KUMA_STATUS="" KUMA_MSG="" KUMA_TIMEOUT="" KUMA_INTERVAL=""
  if [ ! -r "$conf" ]; then
    err "cannot read config file: $conf"
    return 2
  fi
  # A syntax error inside "." would abort a POSIX shell, so probe first.
  # shellcheck disable=SC1090
  if ! (. "$conf") >/dev/null 2>&1; then
    err "config file has errors: $conf"
    return 2
  fi
  # shellcheck disable=SC1090
  . "$conf"
  if [ -z "$KUMA_HOST" ] || [ -z "$KUMA_TOKEN" ]; then
    err "KUMA_HOST and KUMA_TOKEN must be set in $conf"
    return 2
  fi
  while :; do
    case $KUMA_HOST in
      */) KUMA_HOST=${KUMA_HOST%/} ;;
      *) break ;;
    esac
  done
  case $KUMA_HOST in
    http://?* | https://?*) ;;
    *) err "KUMA_HOST must start with http:// or https://"; return 2 ;;
  esac
  case $KUMA_TOKEN in
    *[!A-Za-z0-9_-]*) err "KUMA_TOKEN contains invalid characters"; return 2 ;;
  esac
  : "${KUMA_STATUS:=up}" "${KUMA_MSG:=OK}" "${KUMA_TIMEOUT:=10}" "${KUMA_INTERVAL:=60}"
  case $KUMA_STATUS in
    up | down) ;;
    *) err "KUMA_STATUS must be 'up' or 'down'"; return 2 ;;
  esac
  if ! is_uint "$KUMA_TIMEOUT" || [ "$KUMA_TIMEOUT" -lt 1 ]; then
    err "KUMA_TIMEOUT must be an integer >= 1"
    return 2
  fi
  if ! is_uint "$KUMA_INTERVAL" || [ "$KUMA_INTERVAL" -lt 10 ]; then
    err "KUMA_INTERVAL must be an integer >= 10"
    return 2
  fi
}

# Sends one heartbeat. LAST_PING (ms of the previous push round trip, may be
# empty) is sent as the "ping" value; it is updated on success.
push() {
  url="$KUMA_HOST/api/push/$KUMA_TOKEN?status=$KUMA_STATUS&msg=$(urlencode "$KUMA_MSG")"
  if [ -n "$LAST_PING" ]; then
    url="$url&ping=$LAST_PING"
  fi
  # The URL goes through stdin so the token never shows up in "ps".
  # stdout carries the timing (marked), stderr the error text; both are
  # captured in memory.
  out=$(printf 'url = "%s"\n' "$url" |
    curl -K - -fsS -m "$KUMA_TIMEOUT" --retry 2 -o /dev/null -w '\nKUMA_TIME=%{time_total}\n' 2>&1)
  rc=$?
  secs=$(printf '%s\n' "$out" | sed -n 's/^KUMA_TIME=//p' | tail -n 1)
  if [ "$rc" -eq 0 ] && [ -n "$secs" ]; then
    LAST_PING=$(printf '%s' "$secs" | awk '{ printf "%d", $1 * 1000 + 0.5 }')
    info "push ok (status=$KUMA_STATUS, round trip ${LAST_PING} ms)"
    return 0
  fi
  err "push to $KUMA_HOST failed: $(printf '%s\n' "$out" | sed -e '/^KUMA_TIME=/d' -e '/^$/d' -e "s/$KUMA_TOKEN/***/g" | tr '\n' ' ')"
  return 1
}

run_once() {
  load_config || return 2
  push
}

run_tick() {
  load_config || return 2
  now=$(date +%s)
  last_ts="" last_ping=""
  if [ -n "$state_dir" ] && [ -r "$state_dir/state" ]; then
    read -r last_ts last_ping <"$state_dir/state" || :
  fi
  if is_uint "$last_ts" && [ "$((now - last_ts))" -lt "$((KUMA_INTERVAL - 15))" ]; then
    return 0
  fi
  is_uint "$last_ping" && LAST_PING=$last_ping
  push
  rc=$?
  if [ -n "$state_dir" ]; then
    echo "$now $LAST_PING" >"$state_dir/state" 2>/dev/null || err "cannot write $state_dir/state"
  fi
  return $rc
}

run_loop() {
  last_rc=-1 sleeper=""
  trap '[ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; exit 0' TERM INT
  info "$VERSION started, config $conf"
  while :; do
    BUFFERING=1 BUF=""
    run_once
    rc=$?
    BUFFERING=""
    # Only report state changes, so an outage does not flood the log.
    if [ "$rc" != "$last_rc" ]; then
      if [ "$rc" -eq 0 ]; then printf '%s' "$BUF"; else printf '%s' "$BUF" >&2; fi
    fi
    last_rc=$rc
    interval=$KUMA_INTERVAL
    [ "$rc" -eq 2 ] && interval=60
    sleep "$interval" &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
  done
}

mode=once
while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -V | --version) echo "kuma-heartbeat $VERSION"; exit 0 ;;
    -c | --config)
      if [ $# -lt 2 ]; then err "$1 needs an argument"; exit 2; fi
      conf=$2
      shift
      ;;
    --config=*) conf=${1#--config=} ;;
    --tick) mode=tick ;;
    --loop) mode=loop ;;
    --check-config) mode=check ;;
    *) err "unknown option: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

BUFFERING="" BUF=""
LAST_PING=""

case $mode in
  check) load_config; exit $? ;;
  once) run_once; exit $? ;;
  tick) run_tick; exit $? ;;
  loop) run_loop ;;
esac
