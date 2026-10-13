#!/usr/bin/env bash
# Exercises upsert.sh's decisions against a stub `tradera` CLI that records
# every call and answers from the scenario in $STUB_SCENARIO:
#   none      no "weather" tool yet          → tool_create
#   managed   a managed QuickJS one exists   → tool_update in place
#   external  one deployed another way       → tool_delete, then tool_create
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/tradera" <<'STUB'
#!/usr/bin/env bash
# tradera call --server URL --json BODY ns.action
[ "$1" = call ] || { echo "unexpected: $*" >&2; exit 1; }
body="$5"; action="$6"
printf '%s\t%s\n' "$action" "$body" >>"$STUB_LOG"
case "$action" in
  bots.bot_list)
    if [ "$STUB_SCENARIO" = none ]; then echo '{"bots":[{"id":"agent-1","name":"weather","kind":"agent"}]}'
    else echo '{"bots":[{"id":"bot-w","name":"weather","kind":"tool"},{"id":"bot-x","name":"other","kind":"tool"}]}'; fi ;;
  tools.tool_get)
    if [ "$STUB_SCENARIO" = managed ]; then echo '{"bot_id":"bot-w","mode":"managed","runtime":"quickjs"}'
    else echo '{"bot_id":"bot-w","mode":"external","runtime":""}'; fi ;;
  tools.tool_create) echo '{"bot_id":"bot-new","mode":"managed","runtime":"quickjs"}' ;;
  *) echo '{"ok":true}' ;;
esac
STUB
chmod +x "$WORK/tradera"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() { # scenario → prints the actions called, one per line
  export STUB_SCENARIO="$1" STUB_LOG="$WORK/$1.log"
  : >"$STUB_LOG"
  out="$("$HERE/../upsert.sh" --cli "$WORK/tradera" --server http://node.test --space space-1 --city Lisbon 2>/dev/null)"
  printf '%s\n' "$out" >"$WORK/$1.out"
  cut -f1 "$STUB_LOG" | tr '\n' ' '
}

[ "$(run none)" = "bots.bot_list tools.tool_create spaces.bot_add " ] || fail "none: $(run none)"
[ "$(cat "$WORK/none.out")" = bot-new ] || fail "none: printed $(cat "$WORK/none.out")"
create="$(grep '^tools.tool_create' "$WORK/none.log" | cut -f2)"
[ "$(jq -r '.backend.mode + "/" + .backend.runtime' <<<"$create")" = managed/quickjs ] || fail "create backend"
[ "$(jq -r '.frontend.mode' <<<"$create")" = generative ] || fail "create frontend"
jq -e '.backend.source | contains("function weather_report")' <<<"$create" >/dev/null || fail "create program"
jq -e '.frontend.skill | contains("{\"city\": \"Lisbon\"}")' <<<"$create" >/dev/null || fail "default city in the skill"
[ "$(grep '^spaces.bot_add' "$WORK/none.log" | cut -f2 | jq -r '.bot + "@" + .space')" = bot-new@space-1 ] || fail "added to space"

[ "$(run managed)" = "bots.bot_list tools.tool_get tools.tool_update spaces.bot_add " ] || fail "managed: $(run managed)"
update="$(grep '^tools.tool_update' "$WORK/managed.log" | cut -f2)"
[ "$(jq -r '.bot' <<<"$update")" = bot-w ] || fail "updated the wrong tool"
jq -e '(.source | contains("function weather_report")) and .frontend.mode == "generative"' <<<"$update" >/dev/null || fail "update body"
[ "$(cat "$WORK/managed.out")" = bot-w ] || fail "managed: printed $(cat "$WORK/managed.out")"

[ "$(run external)" = "bots.bot_list tools.tool_get tools.tool_delete tools.tool_create spaces.bot_add " ] || fail "external: $(run external)"
[ "$(grep '^tools.tool_delete' "$WORK/external.log" | cut -f2 | jq -r .bot)" = bot-w ] || fail "deleted the wrong tool"

echo "ok: create, update in place and replace"
