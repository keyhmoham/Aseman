# Aseman

**Aseman** is a federated, decentralized VM platform. Users deploy VMs (known as **bots**) on a mesh of federation nodes, interact with them through spaces/rooms/messaging, and pay for their live execution from in-platform wallets backed by a distributed ledger.

The system is built with **hexagonal architecture** and is fully **plugin-driven**: database, cache, network, filesystem and VMM providers are swappable at runtime; every feature (action) is a plugin grouped into a namespace; and an admin CLI can load/unload/reprogram all of it while the node runs.

```
┌──────────────────────────────────────────────────────────────────┐
│ DRIVING ADAPTERS                        cmd/aseman (CLI)      │
│                                        plugins/adapters/network/gateway         │
│              network plugins (http/tcp/ws) → action router       │
├──────────────────────────────────────────────────────────────────┤
│ APPLICATION  namespaces (plugins):                               │
│   admin · auth · users · spaces · bots · finance · federation    │
├──────────────────────────────────────────────────────────────────┤
│ DOMAIN       accounts, spaces, rooms, memberships, permissions,  │
│              metadata (JSON trees + public paths), messages,     │
│              files, wallets, ledger, bots, KV, universal IDs     │
├──────────────────────────────────────────────────────────────────┤
│ PORTS        database · cache · filesystem · network · vmm       │
│              (interfaces only; providers are plugins)            │
├──────────────────────────────────────────────────────────────────┤
│ ADAPTERS     postgres/mysql/mongo/memory · local/redis ·         │
│              local/s3 · http/tcp/ws · nomad/docker/wasm/modal/   │
│              harness                                              │
└──────────────────────────────────────────────────────────────────┘
```

## Universal IDs

Every persisted entity is addressed by a **universal ID**: two fixed 64-bit parts
rendered as hex and concatenated.

```
<node id (16 hex)> + <entity id (16 hex)>   →   32 hex characters
0000000000000001abcdefabcdefabcd
```

The node part tells any node *where* the entity lives. Requests touching entities
owned by another node are transparently proxied to the owning node through the
`federation` namespace.

## Node identity & the mesh

Node ids are **allocated by the central node** on a node's first run, generated
from the **timestamp of the allocation moment** (high bits = unix milliseconds,
low bits = random entropy) — never a counter. A node with no `node.id` configured
requests one from the central node (`node.central_url`) on first start; the
central node registers it, returns its own info, and the peer auto-registers the
central node back. The allocated id and keypair are persisted (`data/node-id`,
`data/node-<id>.key`) and reused on later runs. The central node itself
self-allocates its id the same (timestamp-derived) way when its id is empty.

```
node (first run, no id) ──POST /v1/federation/node_allocate──▶ central
                          ◀── { node_id: <timestamp-id>, central: {...} }
node persists id + key, registers central as a peer
```

## Identity & request signing

Every account (and every node) has an **Ed25519 keypair**.

- **Users**: a keypair is generated at registration; the private key is stored
  encrypted (scrypt + AES-256-GCM, keyed by the account password) and returned
  once to the client. The CLI stores it and **signs every authenticated request**
  (Ed25519 over `method\npath\nnonce\ntimestamp\nsha256(body)`). The gateway
  verifies the signature against the account's public key and rejects replays
  via a nonce guard and a freshness window. Requests without a signature are
  rejected.
- **Nodes**: each node holds a private key persisted at `data/node-<id>.key`.
  Inter-node requests (proxying, ledger replication) are signed with it and
  verified by the receiving node against the sender's public key from its node
  registry. Peers are mutually registered through `federation.node_register`.

```
                   signed request (Ed25519 + nonce)
  CLI/client ──────────────────────────────────────▶ /v1/{ns}/{action}
                                                    verify(user.public_key)

  node A ──(node-key signed)──▶ node B  /fed/dispatch   → proxied action
  node A ──(node-key signed)──▶ node B  /fed/ledger      → ledger replica
```

## Ledger replication

The central node mints credits and appends entries to its ledger with a global
monotonic `seq`. Every new entry is **broadcast to all peer nodes** (signed with
the node key). Replicas accept entries only in strict `seq` order, so every node
converges on the same deterministic ledger. Google sign-in performs real RS256
verification against Google's JWKS (issuer/audience/expiry checks).

## Getting started

```bash
# build
make daemon cli            # or: go build ./cmd/asemand ./cmd/aseman

# run a node (defaults: in-memory DB, local cache/fs, HTTP on :8080)
./bin/asemand -config configs/config.yml -admin-password changeme

# interact
./bin/aseman login node-a changeme            # admin bootstrap account
./bin/aseman whoami
./bin/aseman actions                          # list namespaces/actions
./bin/aseman plugins                          # plugin registry & states
./bin/aseman wiring                           # active adapter per category
./bin/aseman telemetry
```

A quick end-to-end session:

```bash
./bin/aseman call auth.register handle=alice email=alice@x.com password=secret1234
./bin/aseman login alice secret1234          # stores session token + identity key
./bin/aseman call auth.whoami                 # request is auto-signed with the key

# finance (central node mints)
./bin/aseman login node-a changeme
./bin/aseman call finance.wallet_mint target=<alice-id> amount=1000
./bin/aseman login alice secret1234
./bin/aseman call finance.wallet_get

# spaces
./bin/aseman call spaces.space_create name="team alpha"
./bin/aseman call spaces.metadata_patch space=<id> 'patch=[{"op":"set","path":"/owner","value":{"email":"a@x.com"}}]'
./bin/aseman call spaces.metadata_public space=<id> paths=owner
./bin/aseman call spaces.message_send space=<id> room=<room-id> body="hello"

# bots (VMs): load the wasm provider and rewire the VMM adapter at runtime
./bin/aseman login node-a changeme
./bin/aseman call admin.plugins_load name=wasm
./bin/aseman call admin.plugins_set_active category=vmm plugin=wasm
./bin/aseman login alice secret1234
./bin/aseman call bots.bot_create name=helper vm_type=wasm image_ref=hello.wasm
./bin/aseman call bots.bot_usage bot=<bot-id>        # live metering
./bin/aseman call bots.bot_resize bot=<bot-id> cpu=1 memory_mb=256   # live resize
./bin/aseman call bots.bot_lifecycle bot=<bot-id> op=pause
```

### Running a two-node mesh

```bash
# node B (peer)
cp configs/config.yml configs/config.peer.yml   # change node.id, node.name, url, http.addr
./bin/asemand -config configs/config.peer.yml -admin-password changeme

# each node registers the other (public keys come from federation.node_info)
./bin/aseman login node-a changeme
./bin/aseman call federation.node_register id=<B-id> url=http://localhost:8081 public_key=<B-pubkey>
./bin/aseman call users.account_get account=<b-on-node-B>   # transparently proxied & verified
```

Every ledger entry on the central node is broadcast to peers and replicated in
`seq` order on all nodes.

## Runtime reprogramming (admin)

All wiring is live:

| command | effect |
|---|---|
| `admin.plugins_list` | every plugin, its state, error, capabilities |
| `admin.plugins_load <name>` | init + start a registered plugin |
| `admin.plugins_unload <name>` | stop + unload |
| `admin.plugins_update <name> config={...}` | hot config update |
| `admin.plugins_set_active category=<cat> plugin=<name>` | switch the active adapter for a category (database/cache/network/filesystem/vmm) |
| `admin.models_register` / `admin.models_unregister` | define/remove database schemas |
| `admin.tables_list` / `admin.table_get` / `admin.table_query` | inspect data |
| `admin.workflow_create` / `admin.workflow_run` | define & run workflows of action calls |
| `admin.telemetry` / `admin.logs` | node health + live logs |

External plugins can be compiled as Go plugins (`-buildmode=plugin`) and loaded
through `internal/plugins/host`; see [runtime plugin architecture](plugins/README.md),
`plugins/adapters/example` and `plugins/actions/greeter`.

## Adapters

| category | providers | default |
|---|---|---|
| database | postgres, mysql, mongodb, memory | memory |
| cache | local-cache, redis | local-cache |
| filesystem | local, s3 | local (s3 when `ASEMAN_S3_BUCKET` is set: Cloudflare R2, AWS S3, MinIO) |
| network | http, tcp (JSON frames), websocket | http |
| vmm | nomad (docker, plus elpian/quickjs tool backends), docker, wasm (wazero), modal, harness, mcp (external and installed tools) | nomad |

VMM providers implement a common interface (images, create/start/stop/pause/
resume/resize/delete, live `Usage` metering). `ResizeVM` applies new resource
limits to a running VM (bots.bot_resize). Nomad is the default and is used to
run docker/wasm drivers; the wasm provider runs modules in-process via
**wazero**; docker talks directly to the engine API; modal wraps remote
sandboxes; and the **harness** provider treats each agent as a VM — an
agent's definition (instructions, skills, model) is its image, its turns run on
the DeepSeek Harness runtime, and token consumption is metered as execution
cost (see [Agents](#agents-the-deepseek-harness-runtime) and
`configs/vmm/vm.example.yml`).

## Pricing

What execution costs is node policy, `settings.pricing` (admin → Settings →
Pricing), in credits (ledger units, 1,000,000 = $1; the app shows credits, 100 = $1) per running minute: a flat rate plus a
rate per vCPU, GB of RAM and GB of disk the VM has. Everything is metered per
second and rounded up to whole credits (a 2 s command is not a minute).

| What | Billed as | Paid to |
|---|---|---|
| **Sandbox** (a space's shared computer) | the platform's sandbox rate × the seconds a command or agent used it | the node |
| **Agent** | the agent's own per-minute rate (else the platform's agent rate) × the seconds of the turn — time only; its machine is the sandbox, billed apart | the agent's owner and the node |
| **Model tokens** | input / output tokens × the model's prices per 1M (set per model on its LLM provider) | the provider's owner |
| **App** (a tool) | its time (its own rates, else the platform's app rates, × its resources) **plus** its flat price per call (`cost.per_call`, set by its owner or an admin in its price form) | the tool's owner and the node, half each |

The bots namespace resolves all of it in one place (`costFor`). Every agent
turn is billed once, where it runs, to the person who started it (including the
work agents hand to each other); a message that answers no question is not a
turn and costs nothing.

### Per-space usage and the budget

Every charge made inside a space (an agent turn, a sandbox command, a tool
call, a model call, a mention or a DM to an agent) carries the space in its
execution scope, and `finance.ChargeLines` records one `settlement` per charge
with its split (`agent_minor`, `llm_minor`, `compute_minor`, `tool_minor`).
`usage.projects` is built from those records, so the space's usage page and its
spend always agree: agents = agent time + model tokens, tools, computer.

`finance.budget_set` sets the space's one cap; 0 or blank means no limit. Spend
is counted whether or not a cap is set. The cap is enforced at gates, before
work starts: a turn (reserving a minute of the agent's time), each sandbox or
tool call, and each model call a running agent makes. Settling work already
done is never refused, so a run can finish at most one step past the cap.

## Namespaces

- **admin** — node administration, plugin/model/table management, wiring and
  reprogramming, workflows, telemetry, logs.
- **federation** — the mesh entry point; proxies requests to the node owning an
  entity and hosts the node registry.
- **finance** — wallets, distributed ledger (central node mints + broadcasts in
  deterministic `seq` order), token pools for VM execution, transfers and bot/
  node payments.
- **auth** — register, login, logout, sessions, Google sign-in. Every user
  account is provisioned with a default **home workspace** (`home` flag) linked
  to the account.
- **spaces** — spaces, rooms, memberships, invitations, the modular permission
  system, metadata, messages, files and per-bot isolated key-value storage.
- **users** — accounts, JSON-tree metadata with public/private paths, files,
  direct messaging, and the personal Aseman brain (`dm_*`, `voice_config`,
  `voice_speak`, `voice_turn`). Live voice is mic audio → node STT
  (`llm.Transcribe` / Parakeet V3) → brain agent → TTS (`llm.Speak` /
  Kokoro-class) → reply audio; enable roles under Admin → AI → Voice, or run
  the compact OpenAI-compatible sidecar in `deploy/voice`.
- **bots** — VM lifecycle, bot metadata (`kind` agent or tool — an app), the
  elpian `frontend` bundle of an app (`frontend_set`/`frontend_get`), bot host
  functions (global KV, network ops) and direct bot messaging.
- **message** — the universal packet transport between users and bots:
  - `message.send` — a fire-and-forget packet to a user or bot.
  - `message.ask` — a request to a user or bot that expects a response. When
    the target is a bot the ask is routed synchronously to its VM (an agent's
    reply, or a wasm app backend's `ask` host function); when the
    target is a user the ask is stored and answered via `message.respond`.
  - `message.respond`, `message.get`, `message.list`, `message.requests`.
- **posts** — the social feed: `post_create` (or, with `forward`, share a
  post into the global or a workspace feed, naming its original author),
  `post_get`, `post_update` (edit my post), `post_delete`, `post_report`,
  `post_feed` (global or following via shared workspace memberships),
  `post_user_posts`, `post_like`, `post_unlike`, `post_comment`,
  `post_comments`; admins review reports with `admin_post_reports` and
  `admin_post_report_resolve`.
- **timeline** — each space's dated timeline, kept in the node's own
  database (`timeline_entries`). Its worker reads the other namespaces'
  records in time order (requests, tool runs, messages and work logs, usage,
  files, members, rooms, routines and their runs) and writes each as a dated
  entry. Its service serves the agents' searches (through the harness
  gateway's `/timeline/search` and `/timeline/entry`, for the turn's own space)
  and `timeline.status` shows the admin each feed's cursor.
  `ASEMAN_TIMELINE=off` turns it off.
- **Code Mode** — Cloudflare's search-and-execute pattern for external MCP
  clients: the tools namespace builds one OpenAPI document of
  `POST /apps/{slug}/{function}` (and `/ask`), `POST /platform/{tool}` (files,
  proxies, routines, desk, UI, database, …), the shared computer and the
  space's agents, and runs model-written JavaScript in an isolated sandbox.
  HTTP for external hosts (including `deploy/codemode` Cloudflare Workers):
  `/tools/v1/codemode/{openapi,request,mcp}`. (Agents on the runtime call the
  same capabilities as native tools.)
- **market** — publish, discover and install agents and apps:
  `publish`, `unpublish`, `list`, `get`, `install`, `my_listings`.
- **governance** — every agent action passes one gate: the harness
  gateway, Code Mode, platform tools, app calls and sandbox commands are
  normalized to a request (tool, kind, effect, target, initiator) and decided
  by CEL rules, deny then ask then allow, failing closed (`policy_get`,
  `policy_set`, `policy_test`). The default policy asks before sending, paying,
  signing or deleting and lets proactive work only read. Asks become approvals
  (Allow once, Always allow, Refuse: `approval_*`, `grant_list`,
  `grant_revoke`) answered in the app, Slack, Teams or SMS. Every decision is
  audited with who started it (`audit_list`, `audit_export` as CSV). Agents ask
  for credentials with a masked box (`secret_request`; `secret_*`) and use them
  as `{{secret:name}}`; outbound content is checked for credentials and card
  numbers; outside content reaches models in an untrusted envelope. An app
  function is judged by what it does (`gmail_search` reads, `gmail_send`
  sends), read from the call's body. A project's
  computer follows its network policy (`egress_get`, `egress_set`; the
  `aseman-egress` sidecar), and a person can take it over (`computer_help`,
  `control_take`, `control_release`). See [`docs/openduet-parity-plan.md`](../docs/openduet-parity-plan.md).
- **google** — Gmail and Calendar as an app: turned on (`admin_set`), it lists
  a **Google** app in the Apps catalog whose MCP server is this namespace
  (`/google/v1/mcp`, called with the app's key and the person each call is
  for). Each person connects their own Google account (OAuth with PKCE:
  `status`, `connect_start`, `disconnect`); connecting adds the app to their
  home project. Its functions: `gmail_search`, `gmail_read`, `gmail_draft`,
  `gmail_send`, `calendar_events`, `calendar_create`.
- **proactive** — Tasks (suggested, working, needs input, ready for review),
  inbox triage, the morning brief, background research (read-only, as
  initiator `proactive`), the first-day greeting and the setup checklist
  (`tasks_list`, `task_*`, `brief_*`, `triage`, `first_day`, `settings_*`,
  `research_now`, `setup_check`).
- **responsibilities** — standing instructions an agent runs, as the person,
  when a trigger fires. The triggers are one catalog (`triggers`): signed
  hooks from GitHub, GitLab, Slack, Microsoft Teams, SMS (Twilio), Stripe,
  Linear, Jira, Shopify and generic webhooks at
  `/hooks/v1/responsibilities/{id}`; polls of Gmail, Google Calendar, RSS/Atom
  feeds, any HTTP API (a change of its answer or one JSON value) and an app's
  read-only function; and schedules (an interval, or daily at a time). Feeds
  and APIs are fetched from public addresses only
  (`ASEMAN_RESPONSIBILITIES_ALLOW_PRIVATE=1` lifts that). `create`, `list`,
  `pause`, `resume`, `delete`, `test`.
- **channels** — Slack, Microsoft Teams and SMS (Twilio): people link their
  accounts with a code, talk to their agents, answer approvals with buttons and
  get their brief there (`status`, `link_code`, `unlink`, `binding_set`,
  `admin_get`, `admin_set`).
- **apps as connectors** — Composio and Arcade are listed as apps from
  presets (`tools.broker_presets`, `tools.broker_add`), each person connecting
  their own accounts at the broker. `tools.commands_list` reports such
  connector apps (and Google) as `auth: "account"` with how to connect them,
  so every app is added and connected through the same Apps flow.
- **apps are bots** — every app, these included, is a bot with its own
  account: added to projects and rooms, given to agents as functions, asked
  with `spaces.ask` / `message.ask`, and messaged directly or named in a
  room by an agent. People use apps in their projects: they neither mention
  an app in chat nor message one directly (`users.dm_send` and
  `spaces.direct_open` refuse it). Plain
  words reach an app without an `ask` function of its own: the node's model
  turns them into one of its functions, as the person, and when an agent is
  behind them that call is decided by the gate. The node's own apps (Google)
  are called on its internal address; every other app's address must be
  public.
- **enterprise** — OpenID Connect single sign-on (optionally required per
  domain), SCIM 2.0 provisioning at `/scim/v2`, organizations by email domain,
  offboarding, and SPIFFE workload identity for the agent runtime.
- **hostaccess** — shared folders. A person shares a folder of one of their
  project computers with their own agents in every project (`folders`,
  `folder_share`, `folder_set`, `folder_unshare`; agent tools `folder_list`,
  `folder_read`, `folder_write`); the files stay on that computer. Agents on
  people's **own** computers (the desktop app: `register`, `next`, `result`;
  tools `host_*`) is a node setting an administrator turns on (`admin_set`),
  off by default.

### Agents & apps

Every agent is a **bot** managed through the VMM layer; agents run on the
harness VM (skills/instructions YAML as the image, token usage metered as
cost). Every app is a bot too, of kind `tool` (see below). There is one kind
of app: the retired `miniapp` kind (a wasm backend with an elpian frontend)
is migrated to `tool` when the node starts, bots and market listings alike.

A static app frontend talks to its backend through two actions:
`message.ask` (request/response — used by wasm backends and chat agents)
and `message.send` (fire-and-forget). Every such call is signed by the user,
so the backend always sees the caller's identity.

### A turn is the team's

A room turn (`spaces.turn_submit`) runs as one **run** whose id is the turn's
(`vmm.Execution.RunID`). Everything the turn's agents start joins it: agents
they bring in by mentioning them (`spaces.message_send`) or messaging them
(`users.dm_send`), and so on down the chain, and every command they run in the
project computer, which carries the run's mark (`ASEMAN_RUN`) into every
process it starts. The turn stays `running` until every member is done, so it
can be stopped for as long as anyone works on it. `spaces.turn_cancel` stops
the whole run: the turn's agents, the agents they brought in (their runtime
requests are dropped, which cancels them in the runtime), and the processes
marked with the run in the project computer, backgrounded ones included. A
stopped run refuses new work for a while (a message bringing in another
agent, a command), so calls already on their way cannot restart it. A worker
on another node sees the cancelled status at its next lease renewal (15 s).

## Tools: one form, three backends, two frontends

A tool is created from one form (`tools.tool_create`) with two halves.

**Backend** — always an MCP server, so agents and frontends use every mode
the same way:

| Mode | Runs | Reached |
|---|---|---|
| `external` | an MCP server someone else runs | its URL, with shared or per-person credentials |
| `managed` | this node, as a Nomad service of its own (`vm_type` `elpian`, `quickjs` or `docker`) serving every space the tool is added to | `http://tool-<key>:<port>/mcp` on the stack's network |
| `installed` | inside the sandbox of each space that adds it, serving only that space (`vm_type` `installed`) | the space's gateway proxy to the tool's sandbox port |

Elpian VM (Dart or the Elpian JS subset) and QuickJS backends run in the
**tool runtime** (`deploy/tool-runtime`): Nomad runs its image for managed
tools, the sandbox computer image carries it for installed ones. A docker
backend is the author's own image (an installed one runs as a sidecar in the
sandbox's network namespace). The node calls a managed or installed backend
with the tool's runtime credential and the call's **execution scope** —
who asks (`X-Aseman-Actor`), on whose behalf an agent asks
(`X-Aseman-Agent`), from which space and room — plus a signed scope token
the backend hands back to act in that scope through the tool gateway
(`/tools/v1/runtime/host`: `spaces.message_send`, `spaces.ask`,
`spaces.message_list`, `bots.kv_*`, …), as the tool's account. A backend
acts only in the space it was called from.

**Frontend**:

| Mode | What it is |
|---|---|
| `static` | an Elpian program on the Elpian VM (compiled to bytecode by the node's tool compiler, or uploaded compiled) or QuickJS, run by the app; it calls microtools with `tool.call`, and on phones may publish its compact widget's summary with `tool.compact` (`tool.context().display` says how it is shown) |
| *(empty)* | no dedicated frontend; interactive UIs are authored via `appui_create` |

**Presentation.** Classify once — prefer the lightest surface; never duplicate
the same UI in chat and on the desk.

- **In-chat AG-UI** (`ui_present` / `ask_user`, `placement=chat`): low-complexity
  structured data and human-in-the-loop. Flutter mounts the `agui` fence in the
  message bubble.
- **Desk AG-UI window** (`ui_present`, `placement=desk` / `complexity=high`):
  large or multi-panel **non-interactive** visualizations using the same AG-UI
  components on the room desk.
- **DeskWeb App UI** (`appui_create`, then `appui_publish` when the agents
  build): interactive + complex + live APIs / lasting apps. The space's agents
  build fullstack
  software (an Elpian frontend by default; optional OpenUI agent islands via
  `_aseman/kit/openui`).
- **`proxy_create`**: only to expose an already-running sandbox HTTP service.

Agents get every tool's microtools as tools (`spaces.tools_list`, through
`spaces.ask`). Interactive UIs and previews open as card windows on the room's
**desk** (`spaces/desk.go`, `desktop/<room>`). `desk_state`, `desk_arrange` and
`desk_close` lay the desk out; each turn's note describes it (size, usable
area, open windows).

**Web pages on the desk.** A page an agent builds in the sandbox and exposes
with `proxy_create` (or via `appui_create`) is a desk window of kind `web`
(`args: {"page": "/v1/proxy/<id>/…"}`), the frontend of the tool it names
(`tool`) or of none (dock entry `pages`); creation opens it itself.
Under every preview's prefix the gateway answers the page's Aseman API itself
(`plugins/adapters/network/gateway/proxy_page.go`), authorized like the
preview (the person's session, membership of its space, same-origin writes):

| Path | |
|---|---|
| `_aseman/api/context` | who views the page, in which space and room |
| `_aseman/api/tools` · `microtools {tool}` | the space's tools and their microtools |
| `_aseman/api/call {tool, microtool, args}` | calls a microtool as the person (`tools.invoke`) |
| `_aseman/api/frontend` | static frontend program, or mode metadata when empty/unknown |
| `_aseman/api/show {tool, microtool, args}` | opens a tool result window on the desk, next to the page |
| `_aseman/api/file/<id>` | a stored file the person may read |

Interactive tool UIs use `appui_create` (DeskWeb), not a preview kit path.

| Action | |
|---|---|
| `tools.tool_create` / `tool_update` / `tool_get` / `tool_delete` | the tool |
| `tools.tool_microtools` | what its backend offers, asked live |
| `tools.invoke` | call a microtool as the signed-in person in a space |
| `tools.frontend_get` | static program, or mode metadata when empty/unknown |

Configuration: `ASEMAN_TOOL_RUNTIME_IMAGE`, `ASEMAN_TOOL_RUNTIME_NETWORK`,
`ASEMAN_TOOL_NODE_URL` (the node as backends reach it) and
`ASEMAN_TOOL_COMPILER_URL` (compose sets them all).

## Agents: the DeepSeek Harness runtime

Every agent — the built-in **aseman** lead of each space and every
specialist — and every person's own Aseman runs on
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`).
The engine is a modular VMM adapter, `plugins/adapters/vmm/harness`:

- the **Go adapter** registers agents as VMs (`vm_type: harness`; records of
  older engines are read as it), runs the runtime as a Nomad service, mints a
  token for every turn and serves the turn's **gateway** (`/harness/v1`):
  platform actions under one policy (`/call`, `/catalog`, `policy.go`), the
  metered model (`/llm`), the agents' memory (`/memory/*`, `memory.go`) and
  the project timeline (`/timeline/*`);
- the **runtime** (`plugins/adapters/vmm/harness/runtime`, Node) is one
  long-lived dsh host running the `aseman` profile with Aseman's own Cordis
  plugins: the node-facing API and turn driver, the LLM route's per-turn
  token, and agent-scoped tools (the space's computer, messaging and
  `ask_user`, the space's apps and platform builtins, the whole Aseman API,
  team hand-offs, memory, timeline). See its
  [README](plugins/adapters/vmm/harness/runtime/README.md).

Each agent keeps one dsh Session per room thread (the person's Aseman one per
personal chat), resumed from disk after a restart; a deleted thread's
Sessions are deleted. A question (`ask_user`) ends the turn and waits in the
runtime's store; the person's answer resumes the same Session.

### Image model

Agents make images with their `image_generate` tool, never with their own chat
model, so an agent can run on any model and still make images. The tool always
uses the node's **image model** (Admin → AI → Image model, `llm.llm_image_get` /
`llm_image_set`): one model of an enabled provider marked *Image* on the Models
page. It is charged at that model's prices there: per image (`units.image`), per
token (the input and output tokens the provider reports for the image, as
Gemini image models bill), or both. Gemini image models (`gemini-…-image`) on
Vertex AI or Google Gemini are called through Google's `generateContent`; every
other provider through its OpenAI-compatible `/images/generations`. Until the
setting is first saved, a provider's own `image_model` field is used at its
flat `image_price`, as before. The tool runs only when the person's message asks
for an image (the request's intent, set when a turn starts).

### Decision model

The node admin can turn on a **decision model** (Admin → AI → Decision model):
one model of an enabled provider marked as a decision model, answering typed
questions (yes/no, choice, score) with probabilities instead of text. A
person's own Aseman uses it to decide, before anything else, whether a note
is kept or answered. Models carry `capabilities` (`chat`, `decision`):
decision models are never offered as an agent's backbone (`llm.llm_models`).
Admin actions: `llm.llm_decision_get` / `llm.llm_decision_set`.

A person's mention starts an agent, and so does an agent's: hand-offs are
ordinary room messages, bounded by `vmm.MaxAgentAskDepth` (`message_send`
refuses a hand-off past it). People can message any agent directly — in a room
or by DM (a DM runs in the space the person and the agent share).

```bash
# give the space's lead a task (or post a message that mentions it)
./bin/aseman lead run space=<space-id> body="Build a landing page"
# what the space's agents are waiting on, and answering one
./bin/aseman lead questions space=<space-id>
./bin/aseman lead answer space=<space-id> bot=<bot-id> question_id=<id> answer="yes"
```

Configuration (all optional; compose sets them): `ASEMAN_AGENT_RUNTIME_IMAGE`,
`ASEMAN_AGENT_NODE_URL` (the node as the runtime reaches it),
`ASEMAN_AGENT_RUNTIME_NETWORK`, or `ASEMAN_AGENT_RUNTIME_URL` to run the
runtime yourself. Provider calls default to a five-minute total limit, two
minutes to the first streamed event and 45 seconds between events; tune them
with `ASEMAN_LLM_CALL_TIMEOUT`, `ASEMAN_LLM_FIRST_EVENT_TIMEOUT` and
`ASEMAN_LLM_STREAM_IDLE_TIMEOUT` (Go duration strings). The runtime's own
tests (unit, and the real launcher and dsh against a fake node gateway):

```bash
cd plugins/adapters/vmm/harness/runtime && npm ci && npm test
```

### Shared space sandbox

Every space owns a **shared sandbox** — itself a bot (kind `tool`) provisioned
lazily and joined to the space as a member. Its backbone is selected by one
config variable, `sandbox.backend`: a **docker container** (VM type `container`,
the default) or a **Modal remote sandbox** (VM type `modal`). Agents, apps
and users all talk to it (and to each other) through `spaces.ask`. The sandbox
is **started on agent activity** and **stopped after an idle window** (2
minutes) — never deleted, restarted on the next activity. A docker sandbox
whose image tag was rebuilt or pulled since it was created is recreated on
the current image when it next wakes (same name, VM id and named `/workspace`
volume; what was installed outside the volumes comes from the new image), so
upgrades reach existing projects; `ASEMAN_DOCKER_REFRESH_IMAGES=0` turns this
off. An app tool that finds an awake sandbox still on an older image restarts
it once.

The default image (`deploy/sandbox-computer`) includes `aseman-appui` and the
Elpian toolchain (`aseman-elpian`), so every new space can generate on-demand
fullstack App UIs, built by the space's agents: `appui_create` runs
`aseman-appui prepare` and answers with the build task (`TASK.md`); the agent
builds, tests and drives the app end to end, then `appui_publish` runs
`aseman-appui verify` and opens it, or answers with the problem
(`REPAIR.md`). `appui_status` reads a project's state.

When an agent takes a turn in a space, the runtime reads the space's tools
(`spaces.tools_list`) — every app installed in the space **plus the
sandbox** — and exposes them to the model. Calling any of them
routes back through `spaces.ask`:

| tool | backend | routing |
|---|---|---|
| `execute` and the file tools | shared docker/container or modal sandbox VM | `spaces.ask` (`raw`) → docker/modal exec (`Send`) |
| `ask_<app>` | wasm app VM | `spaces.ask` → wasm `ask` host fn |
| platform tools (`file_send`, `image_generate`, `proxy_*`, `appui_*`, `routine_*`) | the spaces namespace | `spaces.ask` (`tool` + `args`) |

```bash
# list the tools an agent sees in a space
./bin/aseman call spaces.tools_list space=<space-id>
# run a shell command in the shared sandbox
./bin/aseman call spaces.sandbox_exec space=<space-id> command="ls /"
# ask an agent (it may call sandbox + apps)
./bin/aseman call spaces.ask space=<space-id> bot=<agent-bot> body="..."
```

## Configuration

`configs/config.yml` declares the node identity (id, URL, optional Ed25519
`private_key` — auto-generated and persisted per node otherwise), which
adapters/actions to boot, each adapter's settings, and the per-plugin log
directory (`logger.dir`, e.g. `data/logs/<plugin>.log`). Nodes form a mesh by
registering each other through `federation.node_register`. The **central node**
(the platform owner) holds the primary financial ledger; other nodes hold
replicas fed by signed broadcasts.

## Project layout

```
cmd/asemand            node daemon
cmd/aseman             CLI client (auto-signs requests with the identity key)
plugins/adapters/network/gateway         HTTP driving adapter (protocol → actions)
plugins/actions/federation/gateway          node-authenticated inter-node surface (/fed/*)
internal/plugins/signing      shared Ed25519 request signing + replay guard
internal/app              composition root (kernel + plugin wiring)
plugins/actions/*/models namespace-owned entities
internal/plugins/identity shared universal ID contract
plugins/adapters/*/ports provider-neutral contracts by category
internal/kernel           capability wiring + host maintenance
internal/routing          protocol-neutral action routing
plugins/actions/support   shared action persistence/helpers
internal/plugins          plugin contract, registry, lifecycle manager, host
plugins/config          configuration
plugins/actions/*/schema namespace-owned schema descriptors
pkg/                      errs, logger (with per-plugin files), jsonpatch, crypto
configs/                  configuration and SQL schema reference
plugins/adapters          provider modules and sample custom adapter
plugins/actions           internally wired namespace modules
```

## Tests

```bash
make test          # or: go test ./...
make vet           # or: go vet ./...
```


## Routines

Scheduled occurrences have stable IDs and target/task snapshots. Scheduler nodes
claim execution only after acquiring capacity. Committed occurrences advance after
a restart without redispatch; uncertain occurrences pause for inspection. Safe
unavailable dispatches retry twice with one- and two-minute backoff. Periodic
routines continue after failure, coalesce missed occurrences into one execution,
and schedule their next occurrence from completion. Resuming a paused routine
starts a new occurrence after the operator has inspected previous side effects.
An omitted target routes to the space's lead agent, in the routine's room, using
the retained creator identity.

### Module boundaries

Keep each module's implementation, actions, internal mechanisms, and internal
wiring together. Cross-module calls use small consumer-owned interfaces and shared
domain values. Provider code implements ports; business logic does not select SQL,
NoSQL, or network protocols. The composition root only connects concrete modules
and starts their lifecycle; execution logic lives in its owning namespaces and
the agent engine in its VMM adapter.

Database conditional updates have one provider-neutral contract, negotiated by the
repository module. Memory, PostgreSQL, MySQL, and MongoDB implement it. A replacement
provider needs atomic conditional writes for durable turns and scheduling;
providers without that capability return an explicit feature error while basic
CRUD remains available. Platform actions use normalized requests, independent of
the selected network adapter.

For native build, bootstrap, runtime replacement, bridge contracts and model ownership, see [plugins/README.md](plugins/README.md).
