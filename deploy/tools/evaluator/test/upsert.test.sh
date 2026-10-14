#!/usr/bin/env bash
# Exercises upsert.sh against a stub `tradera` CLI (and a stub `docker`) that
# record every call and answer from the scenario in $STUB_SCENARIO:
#   fresh     nothing yet            → space, admins space, build, tool, add, routine
#   again     everything exists      → kept: tool restarted, routine updated
#   other     "evaluator" runs another image → refused without --replace
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/tradera" <<'STUB'
#!/usr/bin/env bash
# tradera login --server URL HANDLE PASSWORD | tradera call --server URL --json BODY ns.action
if [ "$1" = login ]; then printf 'login\t%s %s\n' "$4" "$5" >>"$STUB_LOG"; exit 0; fi
[ "$1" = call ] || { echo "unexpected: $*" >&2; exit 1; }
body="$5"; action="$6"
case "$action" in
  tools.invoke) printf '%s\t%s\n' "$action:$(jq -r .function <<<"$body")" "$body" >>"$STUB_LOG" ;;
  *) printf '%s\t%s\n' "$action" "$body" >>"$STUB_LOG" ;;
esac
case "$action" in
  spaces.space_list)
    if [ "$STUB_SCENARIO" = fresh ]; then echo '{"spaces":[{"id":"home-1","name":"Home","role":"owner"}]}'
    else echo '{"spaces":[{"id":"sp-admins","name":"Admins Space","role":"owner"}]}'; fi ;;
  spaces.space_create) echo '{"space_id":"sp-new","room_id":"room-new"}' ;;
  spaces.room_list) echo '{"rooms":[{"id":"room-late"},{"id":"room-general"}]}' ;;
  bots.bot_list)
    if [ "$STUB_SCENARIO" = fresh ]; then echo '{"bots":[]}'
    else echo '{"bots":[{"id":"bot-ev","name":"evaluator","kind":"tool"}]}'; fi ;;
  tools.tool_get)
    if [ "$STUB_SCENARIO" = again ]; then echo '{"bot_id":"bot-ev","mode":"managed","runtime":"docker","image":"tradera/evaluator-tool:latest"}'
    else echo '{"bot_id":"bot-ev","mode":"managed","runtime":"docker","image":"acme/other:1"}'; fi ;;
  tools.tool_create) echo '{"bot_id":"bot-new"}' ;;
  spaces.bots_list)
    if [ "$STUB_SCENARIO" = again ]; then echo '{"bots":[{"id":"bot-ev"}]}'; else echo '{"bots":[]}'; fi ;;
  routines.list)
    if [ "$STUB_SCENARIO" = again ]; then echo '{"routines":[{"id":"rt-1","name":"evaluator heartbeat"}]}'; else echo '{"routines":[]}'; fi ;;
  tools.invoke) echo '{"result":{"isError":false,"structuredContent":{"cookies":3,"logged_in":true}}}' ;;
  *) echo '{"ok":true}' ;;
esac
STUB
cat >"$WORK/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker\t%s\n' "$*" >>"$STUB_LOG"
STUB
chmod +x "$WORK/tradera" "$WORK/docker"
echo '{"cookies":[{"name":"Authorization","value":"x"}],"origins":[]}' >"$WORK/session.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
run() { # scenario [args] → prints the actions called, one per line
  local scenario="$1"; shift
  export STUB_SCENARIO="$scenario" STUB_LOG="$WORK/$scenario.log"
  : >"$STUB_LOG"
  PATH="$WORK:$PATH" "$HERE/../upsert.sh" --cli "$WORK/tradera" --server http://node.test "$@" >"$WORK/$scenario.out" 2>"$WORK/$scenario.err" || return 1
  cut -f1 "$STUB_LOG" | tr '\n' ' '
}
body() { grep "^$2	" "$WORK/$1.log" | head -1 | cut -f2; }

got="$(run fresh --cmc-session "$WORK/session.json" --trader https://coinmarketcap.com/community/profile/daniel_crypto365/ --eval-hours 6)"
want="login spaces.space_list spaces.space_create spaces.admins_space_set docker bots.bot_list tools.tool_create spaces.bots_list spaces.bot_add routines.list routines.create tools.invoke:status tools.invoke:configure tools.invoke:set_session tools.invoke:trader_add tools.invoke:tick "
[ "$got" = "$want" ] || fail "fresh: $got"
grep -q $'^login\tnode-a changeme$' "$WORK/fresh.log" || fail "signs in as node-a"
[ "$(body fresh spaces.space_create | jq -r .name)" = "admins space" ] || fail "space name"
[ "$(body fresh spaces.admins_space_set | jq -r .space)" = sp-new ] || fail "admins space set"
grep -q $'^docker\tbuild -t tradera/evaluator-tool:latest ' "$WORK/fresh.log" || fail "image build"
create="$(body fresh tools.tool_create)"
[ "$(jq -r '.name + " " + .backend.mode + "/" + .backend.runtime + " " + .backend.image + " " + .backend.path' <<<"$create")" = "evaluator managed/docker tradera/evaluator-tool:latest /mcp" ] || fail "create: $create"
jq -e '.frontend.mode == "generative" and (.frontend.skill | contains("trader_add"))' <<<"$create" >/dev/null || fail "frontend"
[ "$(body fresh spaces.bot_add | jq -r '.bot + "@" + .space')" = bot-new@sp-new ] || fail "added to space"
routine="$(body fresh routines.create)"
[ "$(jq -r '.space + " " + .room + " " + .type + " " + .target + " " + (.interval_sec|tostring)' <<<"$routine")" = "sp-new room-new periodic bot-new 600" ] || fail "routine: $routine"
[ "$(jq -r .task <<<"$routine" | jq -r .function)" = tick ] || fail "routine task"
[ "$(body fresh tools.invoke:configure | jq -c .payload)" = '{"interval_hours":6}' ] || fail "configure"
[ "$(body fresh tools.invoke:set_session | jq -r '.payload.storage_state.cookies[0].name + "@" + .space')" = Authorization@sp-new ] || fail "session"
[ "$(body fresh tools.invoke:trader_add | jq -r .payload.profile_link)" = https://coinmarketcap.com/community/profile/daniel_crypto365/ ] || fail "trader"
[ "$(cat "$WORK/fresh.out")" = bot-new ] || fail "fresh printed $(cat "$WORK/fresh.out")"

got="$(TRADERA_HANDLE=root TRADERA_PASSWORD=pw run again --no-build --interval 300)"
want="login spaces.space_list spaces.room_list spaces.admins_space_set bots.bot_list tools.tool_get tools.tool_update bots.bot_lifecycle bots.bot_lifecycle spaces.bots_list routines.list routines.update tools.invoke:status tools.invoke:tick "
[ "$got" = "$want" ] || fail "again: $got"
grep -q $'^login\troot pw$' "$WORK/again.log" || fail "handle override"
[ "$(body again spaces.admins_space_set | jq -r .space)" = sp-admins ] || fail "found the existing space (case-insensitively)"
[ "$(grep '^bots.bot_lifecycle' "$WORK/again.log" | cut -f2 | jq -r .op | tr '\n' ' ')" = "stop start " ] || fail "restart"
[ "$(body again routines.list | jq -r .room)" = room-general ] || fail "general room is the oldest"
[ "$(body again routines.update | jq -r '.routine + " " + .target + " " + (.interval_sec|tostring)')" = "rt-1 bot-ev 300" ] || fail "routine update"

if run other >/dev/null; then fail "other: replaced a tool running another image without --replace"; fi
grep -q -- "--replace" "$WORK/other.err" || fail "other: no hint"
got="$(run other --replace)"
case "$got" in *"tools.tool_delete tools.tool_create"*) ;; *) fail "replace: $got" ;; esac

echo "ok: fresh install, re-run in place and replace"
