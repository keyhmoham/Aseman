# Aseman agent runtime (DeepSeek Harness)

Every Aseman agent — each space's **aseman** lead, every specialist, and
every person's own Aseman — runs here: one long-lived
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`)
host with Aseman's own Cordis plugins. The node's harness VMM adapter
(`..`, Go) schedules it on Nomad, sends it turns, and serves every turn's
gateway; the runtime holds no platform credential of its own.

```
node (Go, vmm/harness)                          runtime (this package, Node)
  POST /v1/turns, /v1/answers, /v1/chat  ───▶  aseman-host  ── drives ──▶ dsh Agents/Sessions
  GET  /v1/questions, POST /v1/rooms/forget                    │
                                                               ▼
  /harness/v1/llm  ◀── every model call (X-Aseman-Turn) ── dsh pi-ai route "aseman" (aseman-llm)
  /harness/v1/call, /catalog, /memory/*, /timeline/*  ◀── Aseman tools (turn token)
```

## The `aseman` profile

`bin/aseman-harness.js` creates the `aseman` dsh profile from dsh's shipped
`sdk` template once, writes the patch layer `lib/profile.js` builds, and runs
`dsh --profile aseman --patch <layer>`. The layer:

- turns off the SDK's stdio JSON-RPC server (Aseman's host plugin serves the
  node instead), dsh's local shell, file and working-directory tools (the
  runtime's machine is not the space's computer), plan mode (no reviewer in a
  room), disk skills, session titles and DeepSeek-key web search;
- routes models to the node: the `aseman` route on dsh's own pi-ai adapter,
  one model name per context-window class (`aseman-16k` … `aseman-1m`), with
  compaction headroom scaled per class;
- mounts dsh's Agent Teams (in place of plain subagents) and FTS5 session
  search (`session_*` tools);
- loads `aseman-llm` and `aseman-host` (`lib/plugins`).

## Turns

One dsh Session per agent per room thread (`aseman-room-…`) and one per
personal chat thread (`aseman-personal-…`): created on the first turn,
resumed from disk after a restart, kept live while used (idle ones are
disposed and resume later). Each turn:

1. binds the Session to the turn (`lib/bindings.js`): the node's fresh token,
   the agent's definition, the space, room and flags — children of the
   Session (teammates, subagents, forks) resolve to the same binding;
2. loads the agent's notes into a scoped prompt context, and recalls what
   memory holds about the message;
3. registers the turn's tools on the agent's own scope (`lib/turns.js`);
4. sends the message and drives the agent and its children to quiescence;
5. answers with the final text — or, when the agent asked a person
   (`ask_user`, which concludes the turn), with the question, which waits in
   `aseman-runtime.json` until the node sends the answer to `/v1/answers`;
6. reports a short transcript, which the node learns memories from.

A cancelled room turn (the node drops the request) cancels the agent.

## Tools (agent-scoped, `lib/tools`)

| Group | Tools | Through |
|---|---|---|
| The space's computer | `bash`, `read_file`, `write_file`, `edit_file`, `list_files`, `glob`, `grep`, `read_image` | `spaces.ask` (raw) and `spaces.sandbox_files` |
| People | `post_message`, `read_messages`, `search_messages`, `send_dm`, `read_dm`, `ask_user` | messaging actions; the runtime's question store |
| The space's apps and platform builtins | generated per turn from `spaces.tools_list` (files, desk, AG-UI, `appui_*`, routines, images, proxies, connected apps…) | `spaces.ask` (tool / bot) |
| The whole Aseman API | `aseman_api_search`, `aseman_api_call` | `/catalog`, `/call` |
| Team (lead) | `list_team`, `delegate_task`, `recruit_agent`, `hire_agent` | room hand-offs, `agent_recruit`, `agent_hire`, `market.catalog` |
| Memory | `remember`, `recall`, `rewrite_notes` | `/memory/*` |
| Timeline | `timeline_search`, `timeline_entry` | `/timeline/*` |
| Skills | `load_skill` | the agent's own definition |

Plus dsh's own: `todo_write`, goals, `workflow`, Agent Teams
(`spawn_teammate`, `send_message`, `wait_agent`, `team_task_*`), and
`session_*` search. App and API results reach the model in the untrusted
envelope (`lib/untrusted.js`).

## Scoping

The node decides what a token may do (`../policy.go`): a room agent acts as
its own account and only inside its turn's space; a person's Aseman acts as
the person across their account. Administration, authentication, the plugin
host, federation, model providers and money movement are never served.

## Develop

```bash
npm ci
npm test            # unit tests, and the real launcher and dsh against a fake node gateway
node bin/aseman-harness.js   # needs ASEMAN_GATEWAY_URL and ASEMAN_RUNTIME_SECRET
```

Environment: `ASEMAN_GATEWAY_URL`, `ASEMAN_RUNTIME_SECRET`,
`ASEMAN_RUNTIME_PORT` (8000), `ASEMAN_DATA_DIR` (`/data`),
`ASEMAN_DEFAULT_CONTEXT_WINDOW`, `ASEMAN_TURN_TIMEOUT`,
`ASEMAN_GATEWAY_CALL_TIMEOUT`, `ASEMAN_TOOL_RESULT_MAX_CHARS`,
`ASEMAN_SVID_FILE`.
