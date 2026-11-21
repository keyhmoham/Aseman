#!/bin/sh
# Runs Peyda's whole install in the background and reports on it, because one
# command on a project's computer may run only a few minutes (the node's
# command_timeout_sec, 300 s by default) and the first install takes far longer:
#   run_install.sh start    begin (or join the install already running)
#   run_install.sh status   print PEYDA_INSTALL=running|ok|failed|lost and the log's tail; always exits 0
# Steps, in order, each of which must print what it should:
#   netcheck.py · install.sh (with the Google Maps engine) · the test suite · check_services.py · smoke_engine.py
cd "$(dirname "$0")/.."
APP="$(pwd)"
VENV="${PEYDA_VENV:-/workspace/.venvs/peyda}"
STATE=/workspace/data/peyda/install
LOG="$STATE/install.log"
mkdir -p "$STATE"

alive() { [ -s "$STATE/pid" ] && kill -0 "$(cat "$STATE/pid")" 2>/dev/null; }

step() { # step <expected output> <command...>
  expect=$1; shift
  echo "\$ $*" >>"$LOG"
  from=$(wc -c <"$LOG")
  "$@" >>"$LOG" 2>&1 || { echo "exit $? from: $*" >>"$LOG"; return 1; }
  tail -c +"$((from + 1))" "$LOG" | grep -q "$expect" || { echo "did not print \"$expect\": $*" >>"$LOG"; return 1; }
}

job() {
  echo $$ >"$STATE/pid"
  cd "$APP" || exit 1
  # Settings the workflow wrote (PEYDA_GMAPS, HF_ENDPOINT, …), for the network check too.
  if [ -f .peyda/env ]; then set -a; . ./.peyda/env; set +a; fi
  [ -n "${HF_ENDPOINT:-}" ] || unset HF_ENDPOINT
  if [ -s .peyda/gmaps_proxy ]; then PEYDA_GMAPS_PROXY="$(cat .peyda/gmaps_proxy)"; export PEYDA_GMAPS_PROXY; fi
  step "network check: ok" python3 scripts/netcheck.py &&
  step "peyda environment ready" sh scripts/install.sh &&
  step "passed" "$VENV/bin/python" -m pytest -q -p no:cacheprovider &&
  step "start and offer every tool" "$VENV/bin/python" scripts/check_services.py &&
  step "peyda smoke: ok" "$VENV/bin/python" scripts/smoke_engine.py
  echo $? >"$STATE/exit"
}

case "${1:-status}" in
  start)
    if alive; then echo "peyda install already running (pid $(cat "$STATE/pid"))"; exit 0; fi
    rm -f "$STATE/exit"; : >"$LOG"
    date +%s >"$STATE/started"
    if command -v setsid >/dev/null 2>&1; then
      setsid sh "$APP/scripts/run_install.sh" job </dev/null >/dev/null 2>&1 &
    else
      nohup sh "$APP/scripts/run_install.sh" job </dev/null >/dev/null 2>&1 &
    fi
    echo $! >"$STATE/pid"
    echo "peyda install started (pid $!)"
    ;;
  job) job ;;
  status)
    if [ -s "$STATE/exit" ]; then
      [ "$(cat "$STATE/exit")" = 0 ] && echo "PEYDA_INSTALL=ok" || echo "PEYDA_INSTALL=failed"
    elif alive || [ $(( $(date +%s) - $(cat "$STATE/started" 2>/dev/null || echo 0) )) -lt 20 ]; then echo "PEYDA_INSTALL=running"
    else echo "PEYDA_INSTALL=lost"; fi
    echo "--- log tail"; tail -n 25 "$LOG" 2>/dev/null
    exit 0 ;;
  *) echo "usage: run_install.sh start|status"; exit 2 ;;
esac
