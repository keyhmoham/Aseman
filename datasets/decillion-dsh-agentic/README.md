# Decillion dsh agentic dataset

A supervised fine-tuning dataset that teaches a small model (built for Qwen 3.5 4B) to work as a
**Decillion agent on the dsh runtime** (DeepSeek Harness, `services/plugins/adapters/vmm/harness/runtime`
in DecillionAIOS): the space lead `decillion`, its specialists, and the person's own Decillion.

Every sample is one dsh Session as the model really sees it: the exact system prompt, the composed turn
message (`<where_you_are>`, `<now>`, `<from_your_memory>`, `<attachments>`, `Sender: …`), dsh's own runtime
messages, tool calls validated against the exact tool schemas, and tool results in the exact text the
runtime and the node return.

## Size

**68,339 samples** (66,918 train / 1,421 validation, a 2% hash split): about 2,300 single-turn samples
across 60 scenario families, plus 58,769 multi-turn room sessions and 5,869 multi-turn personal-chat
sessions that recombine them (deduplicated on the conversation itself: names, ids, digits and the room
context are normalized before comparing). Built with the default options the train split is about 1 GB
gzipped, so only the compact data and the validation split are committed; `scripts/build.py` produces the
rest in about 3 minutes.

## What is in it

| Path | What |
|---|---|
| `data/samples.jsonl.gz` | The dataset, compact (system prompt and tool schemas by reference). |
| `dist/validation.jsonl.gz`, `dist/stats.json` | A built validation split, ready for training tools. |
| `assets/tools/dsh_tools.json` | All 132 tools the runtime offers, captured from a real dsh boot (schemas, origin, who gets them, which to avoid). |
| `assets/api/catalog.json` | The 281 platform actions `decillion_api_search`/`decillion_api_call` can reach, with body schemas and the agent policy (room agent vs personal). |
| `assets/system/` | dsh prefix/suffix, Decillion persona sections, runtime-context and time messages, and reference personas for parity tests. |
| `assets/agents.json` | The built-in lead and the 12 sample agents (exact instructions). |
| `assets/appui/` | Real `decillion-appui prepare` TASK.md texts and the real `verify` "not ready" output. |
| `extract/` | The scripts that captured all of the above from DecillionAIOS (rerun them when it changes). |
| `scripts/` | `generate.py` (samples), `build.py` (training rows), `validate.py` (checks), the scenario modules. |

## Coverage

Scenario families (`category`), all grounded in the runtime's code:

- **Shared computer**: `bash`, `read_file` (numbered, offset/limit), `write_file`, `edit_file` (incl. the real
  "not found" / "occurs N times" errors and `replace_all`), `list_files`, `glob`, `grep`; bug fixes with tests,
  scripts that deliver files with `file_send`, long logs, the computer disabled for a request.
- **Previews**: `proxy_list` → `proxy_create` with a `start` command (real success and "did not answer" texts).
- **People**: `post_message` progress, `read_messages`, `search_messages`, `send_dm`, `ask_user` (the turn
  concludes; the answer resumes as `Answer to your question …`), stale questions, `interrupt_on` approvals
  (approved → same call again; refused → do not run, ask), reply chips `<replies>…</replies>`.
- **Team**: `list_team`, parallel `delegate_task`, `hire_agent` (marketplace) and `recruit_agent` (lead only),
  delegating to yourself, dsh Agent Teams (`spawn_teammate`, background closing messages), `team_task_*`,
  `create_goal`, `workflow` (only when explicitly asked), `todo_write`.
- **Memory**: `remember` (own vs shared), `recall`, memory already in context, `rewrite_notes`, memory off,
  `timeline_search`, `session_search`.
- **Presenting**: `show_card` (stats, list, facts, table, steps, links, callout), `show_chart`,
  `ui_present` (chat), `desk_show`, `desk_close`/`desk_arrange`, `board_add`, `board_mindmap` — the final
  answer is the takeaway, not a repeat of the card.
- **Apps**: generated app tools (`weather__forecast`, `exa__web_search_exa`, plain-words `translator`), app
  output in the `<untrusted_data>` envelope (including prompt-injection that must be ignored), `mcp_list` →
  `mcp_find` → `mcp_add`, daily `routine_create` with the person's timezone, `image_generate`, the
  file-intent permission error.
- **App UI**: `appui_create` / `create_gadget` with the real TASK.md, build, `appui_publish` "not ready"
  repair, READY.json, publish result (desk window or gadget); answer first and offer a UI.
- **Decillion API**: `decillion_api_search` (exact ranking of the node's catalog) → `decillion_api_call`;
  policy refusals (admin, money, auth) and the own-space confinement error.
- **Safety**: `secret_request` + `{{secret:name}}`, `computer_help` at login walls and two-factor checks.
- **Personal Decillion**: `list_rooms` → `show_rooms`, `wallet_balance`, `remind_me` (ISO with offset, asks
  for the timezone when unknown), `hand_to_workspace`, `connect_channel`, retrying a tool that failed before.
- **Sessions**: 2–4 turns in one room thread (or personal chat), mixing the families above — how dsh
  Sessions actually persist per agent per thread.

## Use

```bash
python3 scripts/build.py                 # dist/train.jsonl.gz + dist/validation.jsonl.gz + stats.json
python3 scripts/build.py --tools full    # every tool the agent really gets (≈130 schemas per row)
python3 scripts/build.py --no-reasoning  # drop reasoning_content
python3 scripts/validate.py              # all checks; exit 1 on any problem
python3 scripts/generate.py --seed 7     # regenerate data/samples.jsonl.gz (deterministic)
```

A built row is `{"id", "category", "language", "tools": [OpenAI function specs], "messages": [...]}` with
roles `system`, `user`, `assistant` (`content`, optional `reasoning_content`, `tool_calls`) and `tool`
(`tool_call_id`, `name`, `content`). It goes straight into `tokenizer.apply_chat_template(messages,
tools=tools)` for Qwen chat templates (TRL `SFTTrainer` with assistant-only loss works as is).

`--tools relevant` (default) gives each row its scenario's tools plus the core tools of its mode and a few
random distractors, so the model learns to choose; `--tools full` matches production exactly but makes rows
about 30k tokens. A mix (mostly relevant, some full) is a good start for a 4B model.

## How it was made, and what is verified

Nothing in the tool layer is written by hand from memory:

- The tool list and schemas come from booting the real runtime (`bin/decillion-harness.js`, dsh
  0.2.2-alpha.3) against the repo's fake gateway and recording the model request (`extract/capture.mjs`).
- The system prompt is dsh's prefix + `persona.js` + dsh's suffix; `validate.py` checks the Python persona
  builder against personas the real `persona.js` produced.
- Result texts were read from the code that produces them (sandbox.js, messaging.js, team.js, memory.js,
  api.js, spaces/*.go, users/brain_tools.go, governance, tools/agent_tools.go) or captured from dsh itself
  (todo, goals, teams, workflow, session search, tool errors as `Error: …`).
- The API catalog is every routed action filtered through `pkg/agentpolicy`, with `action_schemas.json`.
- `validate.py`: schema-valid arguments (`additionalProperties: false`) for every call, calls only to tools
  offered in that row, API actions allowed in the row's scope, exact `decillion_api_search` output, app and
  API results enveloped, matching call ids, turns that end after `ask_user`/approvals, valid endings.

## Known limits (read before training)

- **Faithful quirks.** Two runtime outputs are reproduced as they really are today: `read_messages`
  prints the sender as `[object Object]` (the node sends `sender` as an object; `messaging.js` expects
  `sender_name`), and `timeline_search` lines start with `undefined` (timeline items have no `at`). If you fix
  these in DecillionAIOS, update `dshlib.format_room_messages` and `scen_memory.timeline` and regenerate.
- **Example apps.** Connected apps differ per space; `assets/tools/example_apps.json` holds illustrative
  apps (GitHub, Exa, Weather, Shop, Translator, Invoice Maker). Their tool *names, descriptions and
  envelopes* follow `tools/space.js` exactly; their replies are illustrative.
- **Window geometry and ids** (desk window x/y/w/h, random ids) are plausible values, not node-computed.
- **Notes placement.** Agent notes are appended at the end of the system prompt; dsh adds them as a
  dynamic context section whose exact position was not captured.
- **Time messages.** dsh's runtime-context and time messages are added for the first turn only (later
  turns' "elapsed" text was not captured).
- **Balance.** Multi-turn sessions are the bulk (they recombine the single-turn families); the single-turn
  families are listed with counts in `dist/stats.json`. Most text is English, with some Persian.
- No screenshot/vision samples: `read_image` returns pixels this text dataset cannot carry.
