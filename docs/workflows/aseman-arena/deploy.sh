#!/usr/bin/env bash
# Installs Aseman Arena on an Aseman node, or updates it in place.
#
# The workflow converges: on a node without the platform it creates the
# organization, platform, key, project, agents, games and the platform's
# server and frontend; on a node that has it, it changes only what differs
# (new code, changed instructions, inputs) and leaves the rest — and the
# players' data — as it is. This script
# checks everything locally first, shows the plan (what would be created,
# updated or left unchanged), asks, runs it, follows it, and remembers the
# run so a failed one can be resumed.
#
#   docs/workflows/aseman-arena/deploy.sh [options] [input=value ...]
#
# Options:
#   --server URL       the node (default $ASEMAN_SERVER or http://localhost:8080)
#   --dev-api URL      the developer API as the space's computer reaches it
#                      (default $ASEMAN_SANDBOX_DEV_API, else <server>/dev/v1;
#                      inside the Docker stack: http://aseman:8080/dev/v1)
#   --handle NAME      sign in as NAME when there is no session (password from
#                      $ASEMAN_PASSWORD, else asked)
#   --plan             only show the plan; change nothing
#   --yes              do not ask before running
#   --resume           resume the last failed run on this node (only what it did not finish)
#   --public URL       the node's public address for players' devices (default
#                      the server's address); the workflow's public_url
#   --skip-tests       do not run the local checks
#   --games            also run the games' headless tests locally (downloads
#                      the Godot 4.3 editor once)
#   -h, --help         this text
#
# Any input of the workflow can follow as name=value, e.g.
# product="Aseman Arena" slug=aseman-arena agent_model=gpt-5-mini
# godot_in_app=true android_app=true web_builds=true forge_demo=false port=8080.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DOC="$REPO/docs/workflows/aseman-arena.json"
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
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  warn "Inside the Docker stack pass --dev-api http://aseman:8080/dev/v1; otherwise the node's public address."
fi

# ---------------------------------------------------------------- tools
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is needed: $2"; }
need python3 "the app's tests and this script's JSON handling"

ASEMAN=()
if command -v aseman >/dev/null 2>&1; then
  ASEMAN=(aseman)
elif command -v go >/dev/null 2>&1; then
  mkdir -p "$STATE_DIR/bin"
  if [[ ! -x "$STATE_DIR/bin/aseman" || "$REPO/services/cmd/aseman/workflow.go" -nt "$STATE_DIR/bin/aseman" ]]; then
    say "building the aseman CLI (services/cmd/aseman)"
    (cd "$REPO/services" && go build -o "$STATE_DIR/bin/aseman" ./cmd/aseman) || die "could not build the aseman CLI"
  fi
  ASEMAN=("$STATE_DIR/bin/aseman")
else
  die "the aseman CLI is needed: put it on PATH, or install Go to build it from services/cmd/aseman"
fi
cli() { "${ASEMAN[@]}" "$@"; }

json_get() { # json_get <file> <python expression on d>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print("" if v is None else (v if isinstance(v,str) else json.dumps(v, ensure_ascii=False)))' "$1" "$2"
}

# ---------------------------------------------------------------- 1. local checks
say "bundling the platform's source (server, frontend, games) into the workflow"
find "$HERE" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
python3 "$HERE/bundle.py" >/dev/null
ok "$(python3 "$HERE/bundle.py" --check)"

mkdir -p "$STATE_DIR"
if [[ $SKIP_TESTS -eq 0 ]]; then
  say "running the server's tests (rules, rooms, matches, ratings, social, store, Forge)"
  (cd "$APP" && python3 test_app.py >"$STATE_DIR/test.log" 2>&1) || { cat "$STATE_DIR/test.log"; die "the server's tests fail"; }
  ok "$(tail -n 1 "$STATE_DIR/test.log")"
  python3 "$APP/tools/arena_forge.py" check --dir "$HERE/games/chess" >/dev/null || die "Arena Chess breaks the game contract"
  python3 "$APP/tools/arena_forge.py" check --dir "$HERE/games/city-strike" >/dev/null || die "City Strike breaks the game contract"
  ok "both games follow the game contract"
  if [[ $GAMES -eq 1 ]]; then
    say "the games' headless tests (Godot 4.3, offline models)"
    TMP_GAMES="$(mktemp -d)"
    cp -r "$HERE/games" "$TMP_GAMES/" && rm -rf "$TMP_GAMES"/games/*/arena/*/models "$TMP_GAMES"/games/*/.godot
    (cd "$TMP_GAMES/games" && ./build.sh all --offline --no-web --out "$TMP_GAMES/build" >"$STATE_DIR/games.log" 2>&1) || { tail -n 40 "$STATE_DIR/games.log"; die "the games' tests fail"; }
    ok "$(grep -c '^built ' "$STATE_DIR/games.log") games pass their tests and export"
    rm -rf "$TMP_GAMES"
  fi
  if command -v node >/dev/null 2>&1; then
    say "checking the Elpian frontend (bundle, QuickJS, end-to-end scenarios)"
    if [[ -d "$REPO/deploy/tool-runtime/node_modules/quickjs-emscripten" ]]; then
      PORT_CHECK=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
      TMP_DATA="$(mktemp -d)"
      mkdir -p "$TMP_DATA/games"
      for g in chess city-strike; do
        slug=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['slug'])" "$HERE/games/$g/game.json")
        mkdir -p "$TMP_DATA/games/$slug" && cp "$HERE/games/$g/game.json" "$TMP_DATA/games/$slug/" && printf 'GDPC' >"$TMP_DATA/games/$slug/$slug.pck"
      done
      (cd "$APP" && node "$KIT/bundle.mjs" . >/dev/null)
      (cd "$APP" && ARENA_QUIET=1 PORT="$PORT_CHECK" DATA_DIR="$TMP_DATA/data" GAMES_DIR="$TMP_DATA/games" ASSET_BASE="http://127.0.0.1:$PORT_CHECK/" exec python3 server.py >"$TMP_DATA/server.log" 2>&1) &
      SRV=$!
      trap 'kill $SRV 2>/dev/null || true; rm -rf "$TMP_DATA"' EXIT
      for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$PORT_CHECK/healthz" >/dev/null 2>&1 && break; sleep 0.3; done
      echo '{"apps":[],"agents":[]}' >"$TMP_DATA/APPS.json"
      (cd "$APP" && node "$KIT/check.mjs" elpian/app.js --apps "$TMP_DATA/APPS.json" --server "http://127.0.0.1:$PORT_CHECK" >"$TMP_DATA/check.log" 2>&1) \
        || { tail -n 30 "$TMP_DATA/check.log"; die "the Elpian program fails on QuickJS"; }
      (cd "$APP" && node "$KIT/drive.mjs" run elpian/e2e --dir . --bundle elpian/app.js --server "http://127.0.0.1:$PORT_CHECK" >"$TMP_DATA/e2e.log" 2>&1) \
        || { grep -v 'seen after' "$TMP_DATA/e2e.log" | tail -n 40; die "the Elpian end-to-end scenarios fail"; }
      ok "Elpian: $(grep -c '^✓' "$TMP_DATA/e2e.log") scenarios pass on QuickJS"
      kill $SRV 2>/dev/null || true
    else
      warn "QuickJS is not installed (cd deploy/tool-runtime && npm ci): the Elpian program is checked on the node instead"
    fi
  else
    warn "node is not installed: the Elpian frontend is checked on the node instead"
  fi
fi

# ---------------------------------------------------------------- 2. the node
say "the node: $SERVER"
if ! cli whoami --server "$SERVER" >/dev/null 2>&1; then
  [[ -n "$HANDLE" ]] || read -r -p "Aseman handle: " HANDLE
  PASS="${ASEMAN_PASSWORD:-}"
  [[ -n "$PASS" ]] || { read -r -s -p "password for $HANDLE: " PASS; echo; }
  cli login --server "$SERVER" "$HANDLE" "$PASS" >/dev/null || die "could not sign in as $HANDLE"
fi
ok "signed in as $(cli whoami --server "$SERVER" 2>/dev/null | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin); print(d.get("handle") or d.get("account",{}).get("handle") or d.get("id") or "?")
except Exception: print("?")')"

say "validating the workflow on the node"
cli workflow validate "$DOC" --server "$SERVER" >/dev/null || { cli workflow validate "$DOC" --server "$SERVER"; die "the node refuses the workflow"; }
ok "valid"

ARGS=(developer_api_url="$DEV_API" public_url="$PUBLIC")
for kv in "${INPUTS[@]:-}"; do [[ -n "$kv" && "$kv" != developer_api_url=* && "$kv" != public_url=* ]] && ARGS+=("$kv"); done

mkdir -p "$STATE_DIR"
HOST_KEY="$(printf '%s' "$SERVER" | sed 's#^[a-z]*://##; s#[^A-Za-z0-9._-]#_#g')"
STATE="$STATE_DIR/$HOST_KEY.json"

# ---------------------------------------------------------------- 3. the plan
say "planning (a dry run: what would change)"
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
fresh = any(p in ("space", "forge.agent") for p in ops.get("would_create", []))
print("   mode: " + ("first install" if fresh else "update of an existing install"))
PY
[[ $PLAN_ONLY -eq 1 ]] && { ok "plan only: nothing changed"; exit 0; }

RUN_ARGS=()
if [[ $RESUME -eq 1 ]]; then
  [[ -f "$STATE" ]] || die "no earlier run on this node to resume"
  LAST_ID="$(json_get "$STATE" 'd.get("id")')"
  LAST_STATUS="$(json_get "$STATE" 'd.get("status")')"
  [[ "$LAST_STATUS" == "succeeded" ]] && die "the last run ($LAST_ID) succeeded: run without --resume to update"
  RUN_ARGS+=(--resume "$LAST_ID")
  say "resuming run $LAST_ID (it ended $LAST_STATUS)"
fi

if [[ $YES -eq 0 ]]; then
  read -r -p "Apply this to $SERVER? [y/N] " ans
  [[ "$ans" == y || "$ans" == Y || "$ans" == yes ]] || { warn "nothing changed"; exit 1; }
fi

# ---------------------------------------------------------------- 4. the run
say "running (this can take a while: the games are built from source, then the frontend is verified and published)"
set +e
cli workflow run "$DOC" "${ARGS[@]}" ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} --server "$SERVER" --async 2>&1 | tee "$STATE_DIR/run.log"
CODE=${PIPESTATUS[0]}
set -e
# "run <id> is going; following …" while it runs, "aseman-arena <id> — <status>" at the end.
RUN_ID="$(sed -nE 's/^run ([^ ]+) is going.*/\1/p; s/^aseman-arena ([^ ]+) — .*/\1/p' "$STATE_DIR/run.log" | tail -n 1)"
if [[ -n "$RUN_ID" ]]; then
  cli workflow get "$RUN_ID" --server "$SERVER" --json >"$STATE" 2>/dev/null || true
fi
if [[ $CODE -ne 0 ]]; then
  warn "the run did not succeed. Read the failing step above; after fixing it, resume with:"
  warn "  $0 --server $SERVER --resume ${INPUTS[*]:-}"
  exit $CODE
fi
ok "done"
if [[ -f "$STATE" ]]; then
  python3 - "$STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = (d.get("report") or {}).get("outputs") or {}
print("   players open:   " + str(out.get("players_open")))
if out.get("android_app"):
    print("   Android app:    " + str(out["android_app"]))
print("   server:         " + str(out.get("server")))
print("   project:        " + str(out.get("space")))
print("   Forge agent:    " + str(out.get("forge_agent")))
PY
fi
