#!/usr/bin/env bash
# Sets up the traders evaluator on a Tradera node, as the node administrator
# (node-a by default):
#
#   1. upserts a project named "admins space" owned by node-a
#   2. makes it the platform's admins space (spaces.admins_space_set)
#   3. builds the evaluator's docker image (deploy/tools/evaluator)
#   4. upserts a tool named "evaluator": a managed docker backend (an MCP
#      server with a headless browser) with a generative admin frontend
#   5. adds the tool to the admins space
#   6. upserts the admins space routine that calls the evaluator's `tick`
#      every few minutes (the scope its background worker acts in)
#   7. optionally uploads the CoinMarketCap browser session, LLM settings and
#      traders to evaluate
#
# The evaluator keeps the traders and their scores in its own bot KV store;
# everyone signed in reads them through tools.traders_leaderboard and
# tools.trader_profile (the app's Traders leaderboard).
#
# A tool named "evaluator" node-a owns is kept (and with it its KV store: the
# traders and their scores): a new build of the same image tag restarts it.
# One running another image is left alone unless --replace is given, which
# deletes it and its store and creates it again.
#
# Usage:
#   deploy/tools/evaluator/upsert.sh [options]
#
#   --server URL         the node (default $TRADERA_SERVER or http://localhost:8080)
#   --handle NAME        the admin account (default $TRADERA_HANDLE or node-a)
#   --password PW        its password (default $TRADERA_PASSWORD, $TRADERA_ADMIN_PASSWORD, else changeme)
#   --space-name NAME    the admins space's name (default "admins space")
#   --image REF          the backend image (default tradera/evaluator-tool:latest)
#   --no-build           use --image as it is (e.g. pulled from a registry)
#   --replace            replace an "evaluator" tool that runs another image
#   --interval SEC       how often the routine calls tick (default 600)
#   --cmc-session FILE   CoinMarketCap session: a Playwright storage_state
#                        (decifi's capture_cmc_session.py) or a cookie jar
#                        (decifi's cmc_cookiejar.json)
#   --trader URL         a trader's CoinMarketCap community profile link to add
#                        (repeatable)
#   --eval-hours N       re-evaluate each trader every N hours
#   --llm-base-url URL   OpenAI-compatible endpoint (else the space's lead agent analyses)
#   --llm-api-key KEY    its key (default $EVALUATOR_LLM_API_KEY)
#   --llm-model NAME     its model
#   --proxy URL          HTTP proxy for the browser (CoinMarketCap geo-blocks)
#   --cli PATH           the tradera CLI (default: `tradera` on PATH, else built from services/)
#   --dry-run            print what would be sent; call nothing
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

NAME="evaluator"
DESCRIPTION="Traders evaluator: crawls each trader's CoinMarketCap community profile with a headless browser, measures their posts against market data and scores their reliability with decifi's analyst-reliability prompt. Microtools: leaderboard, trader_get, traders_list, status, trader_add, trader_remove, evaluate_now, configure, set_session."
ROUTINE="evaluator heartbeat"
SERVER="${TRADERA_SERVER:-http://localhost:8080}"
HANDLE="${TRADERA_HANDLE:-node-a}"
PASSWORD="${TRADERA_PASSWORD:-${TRADERA_ADMIN_PASSWORD:-changeme}}"
SPACE_NAME="${EVALUATOR_SPACE_NAME:-admins space}"
IMAGE="${EVALUATOR_IMAGE:-tradera/evaluator-tool:latest}"
BUILD=1
REPLACE=""
INTERVAL=600
CMC_SESSION=""
TRADERS=()
EVAL_HOURS=""
LLM_BASE_URL=""
LLM_API_KEY="${EVALUATOR_LLM_API_KEY:-}"
LLM_MODEL=""
PROXY=""
CLI="${TRADERA_CLI:-}"
DRY_RUN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --handle) HANDLE="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --space-name) SPACE_NAME="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --no-build) BUILD=""; shift ;;
    --replace) REPLACE=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --cmc-session) CMC_SESSION="$2"; shift 2 ;;
    --trader) TRADERS+=("$2"); shift 2 ;;
    --eval-hours) EVAL_HOURS="$2"; shift 2 ;;
    --llm-base-url) LLM_BASE_URL="$2"; shift 2 ;;
    --llm-api-key) LLM_API_KEY="$2"; shift 2 ;;
    --llm-model) LLM_MODEL="$2"; shift 2 ;;
    --proxy) PROXY="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
if [ -n "$CMC_SESSION" ] && ! jq -e 'type == "object" or type == "array"' "$CMC_SESSION" >/dev/null 2>&1; then
  echo "--cmc-session: $CMC_SESSION is not a JSON storage_state or cookie list" >&2
  exit 1
fi

say() { printf '==> %s\n' "$*" >&2; }

# --- the CLI ---------------------------------------------------------------------

if [ -z "$DRY_RUN" ] && [ -z "$CLI" ]; then
  if command -v tradera >/dev/null; then
    CLI="tradera"
  elif [ -x "$ROOT/services/bin/tradera" ]; then
    CLI="$ROOT/services/bin/tradera"
  else
    command -v go >/dev/null || { echo "no tradera CLI: install it, pass --cli, or install Go to build it" >&2; exit 1; }
    say "building the tradera CLI"
    (cd "$ROOT/services" && go build -o bin/tradera ./cmd/tradera)
    CLI="$ROOT/services/bin/tradera"
  fi
fi

# call <ns.action> <json body>: prints the response body.
call() {
  if [ -n "$DRY_RUN" ]; then
    # Secrets and sessions are elided; everything else is shown as it would be sent.
    jq --arg action "$1" '{call: $action, body: (
        (if .frontend.skill then .frontend.skill = "<frontend-skill.md: \(.frontend.skill | length) chars>" else . end)
      | (if .payload.storage_state then .payload.storage_state = "<CoinMarketCap session>" else . end)
      | (if .payload.llm_api_key then .payload.llm_api_key = "<secret>" else . end))}' <<<"$2" >&2
    echo '{}'
    return
  fi
  "$CLI" call --server "$SERVER" --json "$2" "$1"
}

# invoke <microtool> <payload json>: runs one of the evaluator's microtools in the admins space.
invoke() {
  local out
  out="$(call tools.invoke "$(jq -nc --arg bot "${bot:-<evaluator>}" --arg space "${space:-<admins-space>}" --arg fn "$1" --argjson payload "$2" \
    '{bot: $bot, space: $space, function: $fn, payload: $payload}')")"
  if [ -z "$DRY_RUN" ] && [ "$(jq -r '.result.isError // false' <<<"$out")" = "true" ]; then
    echo "evaluator $1 failed: $(jq -r '[.result.content[]?.text] | join(" ")' <<<"$out")" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

if [ -z "$DRY_RUN" ]; then
  say "signing in as $HANDLE"
  "$CLI" login --server "$SERVER" "$HANDLE" "$PASSWORD" >/dev/null
fi

# --- 1. the admins space ---------------------------------------------------------

space=""
room=""
if [ -z "$DRY_RUN" ]; then
  space="$(call spaces.space_list '{"limit":200}' | jq -r --arg name "$SPACE_NAME" \
    '[.spaces[]? | select((.name | ascii_downcase) == ($name | ascii_downcase) and (.role == "owner" or .role == "admin"))][0].id // empty')"
fi
if [ -n "$space" ]; then
  say "found \"$SPACE_NAME\" ($space)"
else
  say "creating \"$SPACE_NAME\""
  created="$(call spaces.space_create "$(jq -nc --arg name "$SPACE_NAME" \
    '{name: $name, description: "The platform administrators project: the traders evaluator lives here."}')")"
  space="$(jq -r '.space_id // empty' <<<"$created")"
  room="$(jq -r '.room_id // empty' <<<"$created")"
  if [ -z "$space" ] && [ -z "$DRY_RUN" ]; then
    echo "the node did not return the new space's id" >&2
    exit 1
  fi
fi
if [ -z "$room" ] && [ -z "$DRY_RUN" ]; then
  # The general room: the oldest one (room_list is newest first).
  room="$(call spaces.room_list "$(jq -nc --arg space "$space" '{space: $space, limit: 200}')" | jq -r '.rooms[-1].id // empty')"
fi

# --- 2. the platform's admins space ----------------------------------------------

say "making \"$SPACE_NAME\" the platform's admins space"
call spaces.admins_space_set "$(jq -nc --arg space "${space:-<admins-space>}" '{space: $space}')" >/dev/null

# --- 3. the image -----------------------------------------------------------------

if [ -n "$BUILD" ]; then
  if [ -n "$DRY_RUN" ]; then
    say "would build $IMAGE from $HERE"
  else
    command -v docker >/dev/null || { echo "docker is required to build $IMAGE (or pass --no-build with a pulled --image)" >&2; exit 1; }
    say "building $IMAGE (the node's Nomad runs it from this docker host)"
    docker build -t "$IMAGE" "$HERE" >&2
  fi
fi

# --- 4. the tool ------------------------------------------------------------------

skill="$(cat "$HERE/frontend-skill.md")"
create_body="$(jq -nc --arg name "$NAME" --arg description "$DESCRIPTION" --arg image "$IMAGE" --arg skill "$skill" '{
  name: $name,
  description: $description,
  backend: {
    mode: "managed",
    runtime: "docker",
    image: $image,
    port: 8080,
    path: "/mcp",
    resources: { cpu: 1, memory: 2048, disk: 4096 }
  },
  frontend: { mode: "generative", skill: $skill }
}')"

bot=""
if [ -z "$DRY_RUN" ]; then
  bot="$(call bots.bot_list '{"limit":200}' | jq -r --arg name "$NAME" '[.bots[]? | select(.name == $name and .kind == "tool")][0].id // empty')"
fi

if [ -n "$bot" ]; then
  info="$(call tools.tool_get "$(jq -nc --arg bot "$bot" '{bot: $bot}')" || echo '{}')"
  mode="$(jq -r '.mode // ""' <<<"$info")"
  runtime="$(jq -r '.runtime // ""' <<<"$info")"
  image="$(jq -r '.image // ""' <<<"$info")"
  if [ "$mode" = "managed" ] && [ "$runtime" = "docker" ] && [ "$image" = "$IMAGE" ]; then
    say "updating $NAME ($bot): new frontend skill; restarting it on the new build of $IMAGE"
    call tools.tool_update "$(jq -nc --arg bot "$bot" --arg skill "$skill" '{bot: $bot, frontend: {mode: "generative", skill: $skill}}')" >/dev/null
    call bots.bot_lifecycle "$(jq -nc --arg bot "$bot" '{bot: $bot, op: "stop"}')" >/dev/null || true
    call bots.bot_lifecycle "$(jq -nc --arg bot "$bot" '{bot: $bot, op: "start"}')" >/dev/null
  elif [ -n "$REPLACE" ]; then
    say "replacing $NAME ($bot): it runs ${mode:-?}/${runtime:-?} ${image:-}; its stored traders and scores go with it"
    call tools.tool_delete "$(jq -nc --arg bot "$bot" '{bot: $bot}')" >/dev/null
    bot=""
  else
    echo "a tool named $NAME ($bot) runs ${mode:-?}/${runtime:-?} ${image:-}, not $IMAGE." >&2
    echo "Pass --image $image --no-build to keep it, or --replace to recreate it (its stored traders and scores are lost)." >&2
    exit 1
  fi
fi

if [ -z "$bot" ]; then
  say "creating $NAME: managed docker backend ($IMAGE), generative frontend"
  bot="$(call tools.tool_create "$create_body" | jq -r '.bot_id // empty')"
  if [ -z "$bot" ] && [ -z "$DRY_RUN" ]; then
    echo "the node did not return the new tool's id" >&2
    exit 1
  fi
fi

# --- 5. in the admins space -------------------------------------------------------

in_space=""
if [ -z "$DRY_RUN" ]; then
  in_space="$(call spaces.bots_list "$(jq -nc --arg space "$space" '{space: $space}')" | jq -r --arg bot "$bot" '[.bots[]? | select(.id == $bot)][0].id // empty')"
fi
if [ -z "$in_space" ]; then
  say "adding $NAME to \"$SPACE_NAME\""
  call spaces.bot_add "$(jq -nc --arg space "${space:-<admins-space>}" --arg bot "${bot:-<evaluator>}" '{space: $space, bot: $bot}')" >/dev/null
fi

# --- 6. the heartbeat routine -----------------------------------------------------

task='{"function":"tick","payload":{}}'
routine=""
if [ -z "$DRY_RUN" ]; then
  routine="$(call routines.list "$(jq -nc --arg space "$space" --arg room "$room" '{space: $space, room: $room}')" \
    | jq -r --arg name "$ROUTINE" '[.routines[]? | select(.name == $name)][0].id // empty')"
fi
if [ -n "$routine" ]; then
  say "updating the \"$ROUTINE\" routine ($routine): tick every ${INTERVAL}s"
  call routines.update "$(jq -nc --arg id "$routine" --arg bot "$bot" --arg task "$task" --argjson every "$INTERVAL" \
    '{routine: $id, target: $bot, task: $task, interval_sec: $every}')" >/dev/null
else
  say "creating the \"$ROUTINE\" routine: tick every ${INTERVAL}s"
  call routines.create "$(jq -nc --arg space "${space:-<admins-space>}" --arg room "${room:-<general-room>}" --arg name "$ROUTINE" \
    --arg bot "${bot:-<evaluator>}" --arg task "$task" --argjson every "$INTERVAL" \
    '{space: $space, room: $room, name: $name, type: "periodic", target: $bot, task: $task, interval_sec: $every}')" >/dev/null
fi

# --- 7. settings, session, traders ------------------------------------------------

if [ -z "$DRY_RUN" ]; then
  # A new backend takes a moment to start serving.
  for _ in $(seq 1 60); do
    invoke status '{}' >/dev/null 2>&1 && break
    sleep 3
  done
fi

config="$(jq -nc --arg hours "$EVAL_HOURS" --arg base "$LLM_BASE_URL" --arg key "$LLM_API_KEY" --arg model "$LLM_MODEL" --arg proxy "$PROXY" '
  {} + (if $hours != "" then {interval_hours: ($hours | tonumber)} else {} end)
     + (if $base != "" then {llm_base_url: $base} else {} end)
     + (if $key != "" then {llm_api_key: $key} else {} end)
     + (if $model != "" then {llm_model: $model} else {} end)
     + (if $proxy != "" then {proxy: $proxy} else {} end)')"
if [ "$config" != "{}" ]; then
  say "configuring the evaluator"
  invoke configure "$config" >/dev/null
fi

if [ -n "$CMC_SESSION" ]; then
  say "uploading the CoinMarketCap browser session from $CMC_SESSION"
  invoke set_session "$(jq -c 'if type == "array" then {cookies: .} else {storage_state: .} end' "$CMC_SESSION")" \
    | jq -r '.result.structuredContent // {} | "    \(.cookies // 0) cookies, logged in: \(.logged_in // false), expires: \(.authorization_expires // "unknown")"' >&2
fi

for link in "${TRADERS[@]+"${TRADERS[@]}"}"; do
  say "adding trader $link"
  invoke trader_add "$(jq -nc --arg link "$link" '{profile_link: $link}')" >/dev/null
done

if [ -z "$DRY_RUN" ]; then
  invoke tick '{}' >/dev/null || true
fi

if [ -n "$DRY_RUN" ]; then
  say "dry run: nothing was sent"
else
  say "done: \"$SPACE_NAME\" is space $space (the admins space); $NAME is bot $bot"
  printf '%s\n' "$bot"
fi
