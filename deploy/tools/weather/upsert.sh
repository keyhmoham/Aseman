#!/usr/bin/env bash
# Upserts the "weather" tool on an Aseman node:
#
#   backend   managed, QuickJS — backend.js run by the node as a Nomad service
#             of the tool runtime image (Open-Meteo data, no API key)
#   frontend  generative — Fixed Schema Surface Bundle compiled from
#             frontend-skill.md (archetype analytics_console) once, then
#             bind-only from the component registry on every open
#
# A tool named "weather" that you own is updated in place (new program, new
# skill: the frontend is generated again on next use); one deployed some other
# way (not managed QuickJS) is replaced; otherwise a new one is created.
#
# Usage:
#   deploy/tools/weather/upsert.sh [options]
#
#   --server URL     the node (default $ASEMAN_SERVER or http://localhost:8080)
#   --space ID       also add the tool to this space (default $ASEMAN_SPACE)
#   --city NAME      the place the frontend opens on (default $WEATHER_CITY or London)
#   --cli PATH       the aseman CLI (default: `aseman` on PATH, else built from services/)
#   --dry-run        print what would be sent; call nothing
#
# Signs in with $ASEMAN_HANDLE / $ASEMAN_PASSWORD when both are set;
# otherwise uses the session `aseman login` stored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

NAME="weather"
DESCRIPTION="Weather anywhere: current conditions, the next hours and a 7-day forecast (Open-Meteo). Microtools: weather_report, current_weather, daily_forecast, hourly_forecast, search_places."
SERVER="${ASEMAN_SERVER:-http://localhost:8080}"
SPACE="${ASEMAN_SPACE:-}"
CITY="${WEATHER_CITY:-London}"
CLI="${ASEMAN_CLI:-}"
DRY_RUN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --space) SPACE="$2"; shift 2 ;;
    --city) CITY="$2"; shift 2 ;;
    --cli) CLI="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

say() { printf '==> %s\n' "$*" >&2; }

# --- the tool --------------------------------------------------------------------

backend="$(cat "$HERE/backend.js")"
skill="$(sed "s/{{DEFAULT_CITY}}/$(printf '%s' "$CITY" | sed 's/[\/&]/\\&/g')/g" "$HERE/frontend-skill.md")"

create_body="$(jq -nc --arg name "$NAME" --arg description "$DESCRIPTION" --arg source "$backend" --arg skill "$skill" '{
  name: $name,
  description: $description,
  backend: {
    mode: "managed",
    runtime: "quickjs",
    language: "js",
    source: $source,
    resources: { cpu: 0.5, memory: 256, disk: 256 }
  },
  frontend: { mode: "generative", skill: $skill }
}')"

# --- the CLI ---------------------------------------------------------------------

if [ -z "$DRY_RUN" ] && [ -z "$CLI" ]; then
  if command -v aseman >/dev/null; then
    CLI="aseman"
  elif [ -x "$ROOT/services/bin/aseman" ]; then
    CLI="$ROOT/services/bin/aseman"
  else
    command -v go >/dev/null || { echo "no aseman CLI: install it, pass --cli, or install Go to build it" >&2; exit 1; }
    say "building the aseman CLI"
    (cd "$ROOT/services" && go build -o bin/aseman ./cmd/aseman)
    CLI="$ROOT/services/bin/aseman"
  fi
fi

# call <ns.action> <json body>: prints the response body.
call() {
  if [ -n "$DRY_RUN" ]; then
    # Long programs are elided; everything else is shown as it would be sent.
    jq --arg action "$1" '{call: $action, body: (
        (if .backend.source then .backend.source = "<backend.js: \(.backend.source | length) chars>" else . end)
      | (if .source then .source = "<backend.js: \(.source | length) chars>" else . end)
      | (if .frontend.skill then .frontend.skill = "<frontend-skill.md: \(.frontend.skill | length) chars>" else . end))}' <<<"$2" >&2
    echo '{}'
    return
  fi
  "$CLI" call --server "$SERVER" --json "$2" "$1"
}

if [ -z "$DRY_RUN" ] && [ -n "${ASEMAN_HANDLE:-}" ] && [ -n "${ASEMAN_PASSWORD:-}" ]; then
  say "signing in as $ASEMAN_HANDLE"
  "$CLI" login --server "$SERVER" "$ASEMAN_HANDLE" "$ASEMAN_PASSWORD" >/dev/null
fi

# --- upsert ----------------------------------------------------------------------

existing=""
if [ -z "$DRY_RUN" ]; then
  existing="$(call bots.bot_list '{"limit":200}' | jq -r --arg name "$NAME" '[.bots[]? | select(.name == $name and .kind == "tool")][0].id // empty')"
fi

if [ -n "$existing" ]; then
  info="$(call tools.tool_get "$(jq -nc --arg bot "$existing" '{bot: $bot}')" || echo '{}')"
  mode="$(jq -r '.mode // ""' <<<"$info")"
  runtime="$(jq -r '.runtime // ""' <<<"$info")"
  if [ "$mode" = "managed" ] && [ "$runtime" = "quickjs" ]; then
    say "updating $NAME ($existing): new program and frontend skill"
    call tools.tool_update "$(jq -nc --arg bot "$existing" --arg source "$backend" --arg skill "$skill" \
      '{bot: $bot, source: $source, frontend: {mode: "generative", skill: $skill}}')" >/dev/null
    bot="$existing"
  else
    say "replacing $NAME ($existing): it runs as ${mode:-unknown}/${runtime:-unknown}, not managed/quickjs"
    call tools.tool_delete "$(jq -nc --arg bot "$existing" '{bot: $bot}')" >/dev/null
    existing=""
  fi
fi

if [ -z "$existing" ]; then
  say "creating $NAME: managed QuickJS backend, generative frontend"
  bot="$(call tools.tool_create "$create_body" | jq -r '.bot_id // empty')"
  if [ -z "$bot" ] && [ -z "$DRY_RUN" ]; then
    echo "the node did not return the new tool's id" >&2
    exit 1
  fi
fi

if [ -n "$SPACE" ]; then
  say "adding $NAME to space $SPACE"
  call spaces.bot_add "$(jq -nc --arg space "$SPACE" --arg bot "${bot:-<new-tool>}" '{space: $space, bot: $bot}')" >/dev/null
fi

if [ -n "$DRY_RUN" ]; then
  say "dry run: nothing was sent"
else
  say "done: $NAME is bot ${bot}"
  printf '%s\n' "$bot"
fi
