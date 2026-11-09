#!/usr/bin/env bash
# Installs Persian Rails Empire (امپراتوری راه‌آهن پارس) on an Aseman node.
#
#   docs/workflows/persian-rails-empire/deploy.sh [options] [input=value ...]
#
# Options:
#   --server URL       the node (default $ASEMAN_SERVER or http://localhost:8080)
#   --dev-api URL      developer API as the space's computer reaches it
#                      (Docker stack: http://aseman:8080/dev/v1)
#   --public URL       public address for players (default --server)
#   --handle NAME      sign in when there is no session
#   --plan             only show the plan
#   --yes              do not ask
#   --resume           resume last failed run
#   --skip-tests       skip local checks
#   --games            also run Godot headless tests locally
#   -h, --help
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DOC="$REPO/docs/workflows/persian-rails-empire.json"
APP="$HERE/app"
KIT="$REPO/deploy/sandbox-computer/appui/elpian"
STATE_DIR="$HERE/.deploy"

SERVER="${ASEMAN_SERVER:-http://localhost:8080}"
DEV_API="${ASEMAN_SANDBOX_DEV_API:-}"
HANDLE="${ASEMAN_HANDLE:-}"
PUBLIC=""
PLAN_ONLY=0 YES=0 RESUME=0 SKIP_TESTS=0 GAMES=0
INPUTS=()

say()  { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --dev-api) DEV_API="$2"; shift 2 ;;
    --handle) HANDLE="$2"; shift 2 ;;
    --plan) PLAN_ONLY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --resume) RESUME=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --public) PUBLIC="$2"; shift 2 ;;
    --games) GAMES=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *=*) INPUTS+=("$1"); shift ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
SERVER="${SERVER%/}"
[[ -n "$DEV_API" ]] || DEV_API="$SERVER/dev/v1"
for kv in "${INPUTS[@]:-}"; do [[ "$kv" == developer_api_url=* ]] && DEV_API="${kv#developer_api_url=}"; [[ "$kv" == public_url=* ]] && PUBLIC="${kv#public_url=}"; done
[[ -n "$PUBLIC" ]] || PUBLIC="$SERVER"
PUBLIC="${PUBLIC%/}"
if [[ "$DEV_API" == *localhost* || "$DEV_API" == *127.0.0.1* ]]; then
  warn "developer_api_url is $DEV_API: the project's computer cannot reach the node's localhost."
  warn "Inside the Docker stack pass --dev-api http://aseman:8080/dev/v1"
fi

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is needed: $2"; }
need python3 "the app's tests and this script's JSON handling"

ASEMAN=()
pick_cli() {
  local c="$1"
  [[ -x "$c" ]] || return 1
  "$c" workflow help >/dev/null 2>&1
}
mkdir -p "$STATE_DIR/bin"
if pick_cli "$STATE_DIR/bin/aseman"; then
  ASEMAN=("$STATE_DIR/bin/aseman")
elif pick_cli "$REPO/docs/workflows/aseman-arena/.deploy/bin/aseman"; then
  ASEMAN=("$REPO/docs/workflows/aseman-arena/.deploy/bin/aseman")
elif command -v aseman >/dev/null 2>&1 && aseman workflow help >/dev/null 2>&1; then
  ASEMAN=(aseman)
elif command -v go >/dev/null 2>&1; then
  say "building the aseman CLI with workflow support"
  (cd "$REPO/services" && go build -o "$STATE_DIR/bin/aseman" ./cmd/aseman) || die "could not build the aseman CLI"
  ASEMAN=("$STATE_DIR/bin/aseman")
else
  die "the aseman CLI with workflow support is needed"
fi
cli() { "${ASEMAN[@]}" "$@"; }

json_get() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print("" if v is None else (v if isinstance(v,str) else json.dumps(v, ensure_ascii=False)))' "$1" "$2"
}

say "bundling source into the workflow"
find "$HERE" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
python3 "$HERE/bundle.py" >/dev/null
ok "$(python3 "$HERE/bundle.py" --check)"

mkdir -p "$STATE_DIR"
if [[ $SKIP_TESTS -eq 0 ]]; then
  say "running the server's tests"
  (cd "$APP" && python3 test_app.py >"$STATE_DIR/test.log" 2>&1) || { cat "$STATE_DIR/test.log"; die "the server's tests fail"; }
  ok "$(tail -n 1 "$STATE_DIR/test.log")"
  python3 "$APP/tools/rails_forge.py" check --dir "$HERE/games/persian-rails" >/dev/null || die "the Godot game breaks the contract"
  ok "persian-rails follows the game contract"
  if [[ $GAMES -eq 1 ]]; then
    say "Godot headless tests (downloads editor once)"
    TMP_GAMES="$(mktemp -d)"
    cp -r "$HERE/games" "$TMP_GAMES/" && rm -rf "$TMP_GAMES"/games/*/arena/*/models "$TMP_GAMES"/games/*/.godot
    (cd "$TMP_GAMES/games" && ./build.sh persian-rails --offline --no-web --out "$TMP_GAMES/build" >"$STATE_DIR/games.log" 2>&1) || { tail -n 40 "$STATE_DIR/games.log"; die "the game's tests fail"; }
    ok "game tests passed"
    rm -rf "$TMP_GAMES"
  fi
  if command -v node >/dev/null 2>&1; then
    say "checking thin Godot Scene3D host"
    if [[ -d "$REPO/deploy/tool-runtime/node_modules/quickjs-emscripten" ]]; then
      PORT_CHECK=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
      TMP_DATA="$(mktemp -d)"
      mkdir -p "$TMP_DATA/games/persian-rails"
      cp "$HERE/games/persian-rails/game.json" "$TMP_DATA/games/persian-rails/"
      printf 'GDPC' >"$TMP_DATA/games/persian-rails/persian-rails.pck"
      (cd "$APP" && node "$KIT/bundle.mjs" . >/dev/null)
      (cd "$APP" && RAILS_QUIET=1 PORT="$PORT_CHECK" DATA_DIR="$TMP_DATA/data" GAMES_DIR="$TMP_DATA/games" ASSET_BASE="http://127.0.0.1:$PORT_CHECK/" exec python3 server.py >"$TMP_DATA/server.log" 2>&1) &
      SRV=$!
      trap 'kill $SRV 2>/dev/null || true; rm -rf "$TMP_DATA"' EXIT
      for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$PORT_CHECK/healthz" >/dev/null 2>&1 && break; sleep 0.3; done
      echo '{"apps":[],"agents":[]}' >"$TMP_DATA/APPS.json"
      (cd "$APP" && node "$KIT/check.mjs" elpian/app.js --apps "$TMP_DATA/APPS.json" --server "http://127.0.0.1:$PORT_CHECK" >"$TMP_DATA/check.log" 2>&1) \
        || { tail -n 30 "$TMP_DATA/check.log"; die "Elpian fails on QuickJS"; }
      (cd "$APP" && node "$KIT/drive.mjs" run elpian/e2e --dir . --bundle elpian/app.js --server "http://127.0.0.1:$PORT_CHECK" >"$TMP_DATA/e2e.log" 2>&1) \
        || { grep -v 'seen after' "$TMP_DATA/e2e.log" | tail -n 40; die "Elpian e2e failed"; }
      ok "Elpian: $(grep -c '^✓' "$TMP_DATA/e2e.log") scenarios pass"
      kill $SRV 2>/dev/null || true
      trap - EXIT
      rm -rf "$TMP_DATA"
    else
      warn "QuickJS not installed; Elpian checked on the node instead"
    fi
  fi
fi

say "the node: $SERVER"
if ! cli whoami --server "$SERVER" >/dev/null 2>&1; then
  [[ -n "$HANDLE" ]] || read -r -p "Aseman handle: " HANDLE
  PASS="${ASEMAN_PASSWORD:-}"
  [[ -n "$PASS" ]] || { read -r -s -p "password for $HANDLE: " PASS; echo; }
  cli login --server "$SERVER" "$HANDLE" "$PASS" >/dev/null || die "could not sign in"
fi
ok "signed in as $(cli whoami --server "$SERVER" 2>/dev/null | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print(d.get("handle") or d.get("account",{}).get("handle") or d.get("id") or "?")
except Exception: print("?")')"

say "validating the workflow"
cli workflow validate "$DOC" --server "$SERVER" >/dev/null || { cli workflow validate "$DOC" --server "$SERVER"; die "invalid workflow"; }
ok "valid"

ARGS=(developer_api_url="$DEV_API" public_url="$PUBLIC")
for kv in "${INPUTS[@]:-}"; do [[ -n "$kv" && "$kv" != developer_api_url=* && "$kv" != public_url=* ]] && ARGS+=("$kv"); done

mkdir -p "$STATE_DIR"
HOST_KEY="$(printf '%s' "$SERVER" | sed 's#^[a-z]*://##; s#[^A-Za-z0-9._-]#_#g')"
STATE="$STATE_DIR/$HOST_KEY.json"

say "planning"
cli workflow plan "$DOC" "${ARGS[@]}" --server "$SERVER" --json >"$STATE_DIR/plan.json" || { cat "$STATE_DIR/plan.json"; die "the plan failed"; }
python3 - "$STATE_DIR/plan.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rep = d.get("report") or {}
ops = {}
for s in rep.get("steps", []):
    op = s.get("operation") or ""
    if op:
        ops.setdefault(op, []).append(s.get("path"))
labels = {"would_create": "would create", "would_update": "would update", "unchanged": "unchanged", "create_or_update": "create or update (decided when it runs)"}
for op in ("would_create", "would_update", "create_or_update", "unchanged"):
    if op in ops:
        print("   %-40s %s" % (labels[op] + ":", ", ".join(ops[op])))
fresh = any(p in ("space", "steward.agent", "platform") for p in ops.get("would_create", []))
print("   mode: " + ("first install" if fresh else "update of an existing install"))
PY
[[ $PLAN_ONLY -eq 1 ]] && { ok "plan only: nothing changed"; exit 0; }

RUN_ARGS=()
if [[ $RESUME -eq 1 ]]; then
  [[ -f "$STATE" ]] || die "no earlier run to resume"
  LAST_ID="$(json_get "$STATE" 'd.get("id")')"
  LAST_STATUS="$(json_get "$STATE" 'd.get("status")')"
  [[ "$LAST_STATUS" == "succeeded" ]] && die "last run succeeded; run without --resume"
  RUN_ARGS+=(--resume "$LAST_ID")
  say "resuming run $LAST_ID"
fi

if [[ $YES -eq 0 ]]; then
  read -r -p "Apply this to $SERVER? [y/N] " ans
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]] || { warn "nothing changed"; exit 1; }
fi

say "running (Godot build + publish can take a while)"
set +e
cli workflow run "$DOC" "${ARGS[@]}" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} --server "$SERVER" --async 2>&1 | tee "$STATE_DIR/run.log"
CODE=${PIPESTATUS[0]}
set -e
RUN_ID="$(sed -nE 's/^run ([^ ]+) is going.*/\1/p; s/^persian-rails-empire ([^ ]+) — .*/\1/p' "$STATE_DIR/run.log" | tail -n 1)"
if [[ -n "$RUN_ID" ]]; then
  cli workflow get "$RUN_ID" --server "$SERVER" --json >"$STATE" 2>/dev/null || true
fi
if [[ $CODE -ne 0 ]]; then
  warn "run failed; resume with: $0 --server $SERVER --resume"
  exit $CODE
fi
ok "done"
if [[ -f "$STATE" ]]; then
  python3 - "$STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = (d.get("report") or {}).get("outputs") or {}
print("   players open:   " + str(out.get("players_open")))
print("   server:         " + str(out.get("server")))
print("   platform:       " + str(out.get("platform")))
print("   project:        " + str(out.get("space")))
print("   Steward:        " + str(out.get("steward_agent")))
if out.get("android_app"):
    print("   Android app:    " + str(out["android_app"]))
PY
fi
