# Tradera

**Tradera** is a federated, decentralized VM platform. Users deploy VMs (known as **bots**) on a mesh of federation nodes, interact with them through spaces/rooms/messaging, and pay for their live execution from in-platform wallets backed by a distributed ledger.

The system is built with **hexagonal architecture** and is fully **plugin-driven**: database, cache, network, filesystem and VMM providers are swappable at runtime; every feature (action) is a plugin grouped into a namespace; and an admin CLI can load/unload/reprogram all of it while the node runs.

```
┌──────────────────────────────────────────────────────────────────┐
│ DRIVING ADAPTERS                        cmd/tradera (CLI)      │
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
│              deepagents                                           │
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
make daemon cli            # or: go build ./cmd/traderad ./cmd/tradera

# run a node (defaults: in-memory DB, local cache/fs, HTTP on :8080)
./bin/traderad -config configs/config.yml -admin-password changeme

# interact
./bin/tradera login node-a changeme            # admin bootstrap account
./bin/tradera whoami
./bin/tradera actions                          # list namespaces/actions
./bin/tradera plugins                          # plugin registry & states
./bin/tradera wiring                           # active adapter per category
./bin/tradera telemetry
```

A quick end-to-end session:

```bash
./bin/tradera call auth.register handle=alice email=alice@x.com password=secret1234
./bin/tradera login alice secret1234          # stores session token + identity key
./bin/tradera call auth.whoami                 # request is auto-signed with the key

# finance (central node mints)
./bin/tradera login node-a changeme
./bin/tradera call finance.wallet_mint target=<alice-id> amount=1000
./bin/tradera login alice secret1234
./bin/tradera call finance.wallet_get

# spaces
./bin/tradera call spaces.space_create name="team alpha"
./bin/tradera call spaces.metadata_patch space=<id> 'patch=[{"op":"set","path":"/owner","value":{"email":"a@x.com"}}]'
./bin/tradera call spaces.metadata_public space=<id> paths=owner
./bin/tradera call spaces.message_send space=<id> room=<room-id> body="hello"

# bots (VMs): load the wasm provider and rewire the VMM adapter at runtime
./bin/tradera login node-a changeme
./bin/tradera call admin.plugins_load name=wasm
./bin/tradera call admin.plugins_set_active category=vmm plugin=wasm
./bin/tradera login alice secret1234
./bin/tradera call bots.bot_create name=helper vm_type=wasm image_ref=hello.wasm
./bin/tradera call bots.bot_usage bot=<bot-id>        # live metering
./bin/tradera call bots.bot_resize bot=<bot-id> cpu=1 memory_mb=256   # live resize
./bin/tradera call bots.bot_lifecycle bot=<bot-id> op=pause
```

### Running a two-node mesh

```bash
# node B (peer)
cp configs/config.yml configs/config.peer.yml   # change node.id, node.name, url, http.addr
./bin/traderad -config configs/config.peer.yml -admin-password changeme

# each node registers the other (public keys come from federation.node_info)
./bin/tradera login node-a changeme
./bin/tradera call federation.node_register id=<B-id> url=http://localhost:8081 public_key=<B-pubkey>
./bin/tradera call users.account_get account=<b-on-node-B>   # transparently proxied & verified
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
| filesystem | local, s3 | local |
| network | http, tcp (JSON frames), websocket | http |
| vmm | nomad (docker, plus elpian/quickjs tool backends), docker, wasm (wazero), modal, deepagents, mcp (external and installed tools) | nomad |

VMM providers implement a common interface (images, create/start/stop/pause/
resume/resize/delete, live `Usage` metering). `ResizeVM` applies new resource
limits to a running VM (bots.bot_resize). Nomad is the default and is used to
run docker/wasm drivers; the wasm provider runs modules in-process via
**wazero**; docker talks directly to the engine API; modal wraps remote
sandboxes; and the **deepagents** provider treats each agent as a VM — an
agent's definition (instructions, skills, model) is its image, its turns run on
the deep agents runtime, and token consumption is metered as execution cost
(see [Agents](#agents-the-deep-agents-runtime) and `configs/vmm/vm.example.yml`).

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
| **Tool or miniapp** | its time (its own rates, else the platform's tool rates, × its resources) **plus** its flat price per call (`cost.per_call`, set by its owner or an admin in its price form) | the tool's owner and the node, half each |

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
  direct messaging.
- **bots** — VM lifecycle, bot metadata (`kind` agent/miniapp/tool), the elpian
  `frontend` bundle for miniapps (`frontend_set`/`frontend_get`), bot host
  functions (global KV, network ops) and direct bot messaging.
- **message** — the universal packet transport between users and bots:
  - `message.send` — a fire-and-forget packet to a user or bot.
  - `message.ask` — a request to a user or bot that expects a response. When
    the target is a bot the ask is routed synchronously to its VM (an agent's
    reply, or a wasm miniapp backend's `ask` host function); when the
    target is a user the ask is stored and answered via `message.respond`.
  - `message.respond`, `message.get`, `message.list`, `message.requests`.
- **posts** — the social feed: `post_create`, `post_get`, `post_delete`,
  `post_feed` (global or following via shared workspace memberships),
  `post_user_posts`, `post_like`, `post_unlike`, `post_comment`,
  `post_comments`.
- **timeline** — each space's dated timeline, kept in the node's Utopia
  server (a bitemporal knowledge graph on the node's Postgres). Its worker
  reads the other namespaces' records in time order (requests, tool runs,
  messages and work logs, usage, files, members, rooms, routines and their
  runs), turns each into dated statements and pushes them to the space's
  knowledge base, one per space, created on first use. Its service serves the
  agents' reads (`MCP`, through the deepagents gateway's `/timeline/mcp`) and
  `timeline.status` shows the admin each feed's cursor. Configured by
  `TRADERA_TIMELINE_URL` / `_EMAIL` / `_PASSWORD`; off without the URL.
- **market** — publish, discover and install agents and miniapps:
  `publish`, `unpublish`, `list`, `get`, `install`, `my_listings`.

### Agents & miniapps

Every agent is a **bot** managed through the VMM layer; agents run on the
deepagents VM (skills/instructions YAML as the image, token usage metered as
cost). Every miniapp is also a **bot**: its backend is a wasm VM that exports
an `ask` host function (see `plugins/adapters/vmm/wasm`), and its frontend is
an **elpian** bundle served by the bot and rendered inside the client's elpian
sandbox. In the client UI miniapps surface as **tools**.

A miniapp frontend talks to its backend through two actions:
`message.ask` (request/response — used by miniapp backends and chat agents)
and `message.send` (fire-and-forget). Every such call is signed by the user,
so the backend always sees the caller's identity.

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
who asks (`X-Tradera-Actor`), on whose behalf an agent asks
(`X-Tradera-Agent`), from which space and room — plus a signed scope token
the backend hands back to act in that scope through the tool gateway
(`/tools/v1/runtime/host`: `spaces.message_send`, `spaces.ask`,
`spaces.message_list`, `bots.kv_*`, …), as the tool's account. A backend
acts only in the space it was called from.

**Frontend**:

| Mode | What it is |
|---|---|
| `static` | an Elpian miniapp: a program on the Elpian VM (compiled to bytecode by the node's tool compiler, or uploaded compiled) or QuickJS, run by the app; it calls microtools with `tool.call` |
| `generative` | A2UI generated from the deployer's skill the first time anyone opens it, kept in the **component registry** (`tool_components`, keyed by the skill's version and the backend's microtools) and served from there afterwards, filled with fresh microtool data per request; its buttons map to microtools |

A tool without a generative frontend still gets an interface where one is
needed, designed for the request at hand rather than for the tool: when an
agent shows a result (`frontend_show` with the person's `request`), or a
person opens such a tool on the desk, the node designs a template for that
request around the actual result (`tools.GenerateWindowFrontend`) and keeps
it with that one desk window; nothing is cached for the tool, and another
request gets its own. `tools.frontend_get` / `frontend_action` fill and run
a window's own template. Opening a tool itself runs its static frontend or
serves its generative one (from the component registry, generated the
first time).

Agents get every tool's microtools as tools (`spaces.tools_list`, through
`spaces.ask`). Tools' interfaces never go into the chat: they open as card
windows on the room's **desk** (`spaces/desk.go`, kept in the space's
metadata under `desktop/<room>`; `spaces.desktop_get` / `desktop_update`).
`frontend_show` opens a tool's generative frontend on a result,
`ui_compose` a widget built from A2UI, microtool data and tools' own
frontends (`ToolFrontend` components), and `desk_state`, `desk_arrange`
and `desk_close` let agents lay the desk out; each turn's note describes it
(size, usable area, open windows).

| Action | |
|---|---|
| `tools.tool_create` / `tool_update` / `tool_get` / `tool_delete` | the tool |
| `tools.tool_microtools` | what its backend offers, asked live |
| `tools.invoke` | call a microtool as the signed-in person in a space |
| `tools.frontend_get` / `frontend_action` | its frontend, and a generated frontend's actions |
| `tools.components_list` | the generated frontends the registry holds |
| `tools.traders_leaderboard` / `trader_profile` | the traders leaderboard the admins space's `evaluator` tool keeps ([`deploy/tools/evaluator`](../deploy/tools/evaluator)), read by anyone signed in |

Configuration: `TRADERA_TOOL_RUNTIME_IMAGE`, `TRADERA_TOOL_RUNTIME_NETWORK`,
`TRADERA_TOOL_NODE_URL` (the node as backends reach it) and
`TRADERA_TOOL_COMPILER_URL` (compose sets them all).

## Agents: the deep agents runtime

Every agent — the built-in **tradera** lead of each space and every
specialist — runs on [LangChain Deep Agents](https://github.com/langchain-ai/deepagents)
(on LangGraph). The engine is a modular VMM adapter,
`plugins/adapters/vmm/deepagents`:

- the **Go adapter** registers agents as VMs (`vm_type: deepagents`), runs the
  **Python runtime** (`deepagents/runtime`, image `tradera/deepagents:v1`) as
  a Nomad service on the stack's network, and hands it one turn at a time;
- each turn carries a **turn token**. The runtime reaches the platform only
  through the adapter's gateway (`/deepagents/v1/call`), which dispatches real
  actions *as the agent's account* inside the turn's execution scope (who
  started it and pays, the space, room and run), and through the metered
  OpenAI-compatible LLM proxy (`/deepagents/v1/llm`), so provider keys never
  leave the node and every token is billed to the turn.

The platform's own APIs are the agents' transport:

| what | transport |
|---|---|
| people ↔ agents | room messages (`spaces.message_send` / `message_list`) and direct chats: a one-room space per pair (`spaces.direct_open`, listed with project rooms by `spaces.chat_list`); `users.dm_send` / `dm_list` still work and mirror into that room |
| lead ↔ subagents (and any agent ↔ agent) | room messages: the delegating agent mentions the agent it hands work to; the agent's answer is a message whose `reply_to` is the hand-off |
| agents → tools | `spaces.ask`: the shared sandbox (`raw` shell commands), tool and miniapp bots, and platform tools (`tool` + `args`: files, images, previews, routines) |
| work logs and live status | `spaces.agent_log` (log messages in the room + the room's live activity) |
| questions to people | `spaces.agent_questions` / `spaces.agent_answer`, or a plain reply in the room |
| recruiting specialists | `spaces.agent_recruit` |

Every deep agents feature is on, mapped onto the platform:

- **planning** — `write_todos`; the plan is written to the work log;
- **filesystem and shell** — `ls`, `read_file`, `write_file`, `edit_file`,
  `glob`, `grep` and `execute` run on the space's shared sandbox, so the lead
  and every specialist work on the same machine and files (`/workspace`);
- **subagents** — the `task` tool hands a task to an agent of the space over
  room messaging and returns its answer; `general-purpose` is the space's
  generalist, recruited on first use. `start_task` / `check_tasks` /
  `wait_tasks` run several agents in parallel in the background;
- **skills** — each agent's skills (and the space's shared ones) are `SKILL.md`
  files in the sandbox (`/workspace/.tradera/...`), loaded progressively;
- **memory** — `/workspace/AGENTS.md` (the space's) and each agent's own
  `AGENTS.md`, read every turn and kept current by the agents;
- **human in the loop** — `ask_user`, and any tool listed in an agent's
  `interrupt_on`, pause the agent's thread on a question people answer;
- **summarization, prompt caching and tool-call repair** — the harness defaults;
- **durable threads** — one LangGraph thread per agent per room, checkpointed
  on the runtime's volume, so conversations and pending questions survive
  restarts.

### Decision model

The node admin can turn on a **decision model** (Admin → AI → Decision model):
one model of an enabled provider marked as a decision model — e.g. TypeSafe
AI's **Jev** (`typesafe-ai/jev`) on Vercel AI Gateway, which answers typed
questions (yes/no, choice, score) with probabilities instead of text. On, the
runtime's `decision` module (`deepagents/runtime/tradera_agents/decision`)
uses it together with each agent's own model:

- **tool selection** — once per turn, the app, bot and platform tools the
  request needs are shortlisted, so every model call carries fewer tool schemas
  (the sandbox, file, planning, messaging and delegation tools are never
  hidden, every tool still runs when called, and the list stays stable through
  the turn for the provider's prompt cache);
- **routing** — the agent that fits a task best (a lead's hint; a hand-off
  addressed by role);
- **progress** and **completion** checks — a long run that goes nowhere is told
  to change approach, and a final answer that does not deliver the request
  sends the agent back once;
- **approvals** (opt-in: *auto-approve*) — low-risk calls of `interrupt_on`
  tools run without waiting on a person; each is written to the work log.

Off — or whenever the decision model is unusable or a decision fails — the
agent's own model decides everything, as before. Decisions go through the
gateway (`/deepagents/v1/decision/evaluate`, the provider's `/evaluate`
endpoint, key kept on the node) and are billed to the turn at the decision
model's own token prices. Models carry `capabilities` (`chat`, `decision`):
decision models are never offered as an agent's backbone (`llm.llm_models`).
Admin actions: `llm.llm_decision_get` / `llm.llm_decision_set`.

A person's mention starts an agent, and so does an agent's: hand-offs are
ordinary room messages, bounded by `vmm.MaxAgentAskDepth` (`message_send`
refuses a hand-off past it). People can message any agent directly — in a room
or by DM (a DM runs in the space the person and the agent share).

```bash
# give the space's lead a task (or post a message that mentions it)
./bin/tradera lead run space=<space-id> body="Build a landing page"
# what the space's agents are waiting on, and answering one
./bin/tradera lead questions space=<space-id>
./bin/tradera lead answer space=<space-id> bot=<bot-id> question_id=<id> answer="yes"
```

Configuration (all optional; compose sets them): `TRADERA_AGENT_RUNTIME_IMAGE`,
`TRADERA_AGENT_NODE_URL` (the node as the runtime reaches it),
`TRADERA_AGENT_RUNTIME_NETWORK`, or `TRADERA_AGENT_RUNTIME_URL` to run the
runtime yourself. The runtime's own tests: `cd plugins/adapters/vmm/deepagents/runtime
&& pip install -r requirements-dev.txt && pytest`.

### Shared space sandbox

Every space owns a **shared sandbox** — itself a bot (kind `tool`) provisioned
lazily and joined to the space as a member. Its backbone is selected by one
config variable, `sandbox.backend`: a **docker container** (VM type `container`,
the default) or a **Modal remote sandbox** (VM type `modal`). Agents, miniapps
and users all talk to it (and to each other) through `spaces.ask`. The sandbox
is **started on agent activity** and **stopped after an idle window** (2
minutes) — never deleted, restarted on the next activity.

When an agent takes a turn in a space, the runtime reads the space's tools
(`spaces.tools_list`) — every miniapp/tool installed in the space **plus the
sandbox** — and exposes them to the model. Calling any of them routes back
through `spaces.ask`:

| tool | backend | routing |
|---|---|---|
| `execute` and the file tools | shared docker/container or modal sandbox VM | `spaces.ask` (`raw`) → docker/modal exec (`Send`) |
| `ask_<miniapp>` | wasm miniapp VM | `spaces.ask` → wasm `ask` host fn |
| platform tools (`file_send`, `image_generate`, `proxy_*`, `routine_*`) | the spaces namespace | `spaces.ask` (`tool` + `args`) |

```bash
# list the tools an agent sees in a space
./bin/tradera call spaces.tools_list space=<space-id>
# run a shell command in the shared sandbox
./bin/tradera call spaces.sandbox_exec space=<space-id> command="ls /"
# ask an agent (it may call sandbox + miniapp tools)
./bin/tradera call spaces.ask space=<space-id> bot=<agent-bot> body="..."
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
cmd/traderad            node daemon
cmd/tradera             CLI client (auto-signs requests with the identity key)
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
