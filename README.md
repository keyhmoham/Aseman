# Aseman AIOS

**Aseman AIOS** is an agentic social workspace and federated AI operating system. Users deploy LLM-backed autonomous agents and apps, collaborate in shared spaces/rooms, and manage execution costs via in-platform wallets powered by a distributed ledger.

**Full platform documentation** (architecture, modular philosophy, product surfaces, developer API, sub-platforms, deploy): [`docs/PLATFORM.md`](docs/PLATFORM.md).

---

## Architecture Overview

```
AsemanAIOS/
├── app/         # Aseman Flutter client (web, iOS, Android, desktop)
├── services/    # Aseman core node (Go): API gateway, agent runtime, finance, federation
└── deploy/      # Deployment configurations (Nomad agent, sandbox computer, Helm, …)
```

| Component | Tech Stack | Role |
| :--- | :--- | :--- |
| **`app/`** | Flutter, Dart | Unified UI (Web, iOS, Android and desktop) for chat, projects, agent work, social features, billing and administration. |
| **`services/`** | Go (Hexagonal architecture) | Core node managing accounts, spaces, wallets, LLM proxy, and node-to-node federation. |
| **`deploy/`** | Docker, Nomad | Nomad bot scheduler, per-space sandbox container definitions and the agents' memory server. |

---

## Quickstart (Docker)

Run the entire platform with a single command. Docker with the Compose plugin is the only prerequisite.

```bash
# Start all services. The Flutter app is served in debug mode and hot-reloads
# when files under app/ change.
./aseman.sh up

# Serve the release web image instead of the debug server
./aseman.sh up --no-hot-reload

# Or launch with a custom configuration file
./aseman.sh up path/to/config.yml
```

> **Note:** `./aseman.sh up` starts the stack with the Flutter client in debug mode (`docker-compose.hotreload.yml`). `./aseman.sh up --no-hot-reload` is the release image, equivalent to `docker compose up -d --build`.

### Service Map

| Service | Purpose | Port |
| :--- | :--- | :--- |
| **`web`** | Flutter web client. Debug mode with hot reload by default; `--no-hot-reload` serves the release build | [http://localhost:3000](http://localhost:3000) |
| **`aseman`** | Core Go node (REST/WebSocket API, agent gateway, finance) | [http://localhost:8080](http://localhost:8080) |
| **`postgres`** | The stack's one database server (Postgres 16 with pgvector): the node's records, the agents' memory and the project timelines | Internal |
| **`nomad`** | Nomad agent executing bot and agent workloads | Internal |
| **`sandbox-computer`** | Builds the base sandbox image for spaces, then exits | — |
| **`harness`** | Builds the agent runtime image (DeepSeek Harness with Aseman's plugins), then exits | — |
| **`tool-runtime`** | Runs tool backends written for the Elpian VM or QuickJS (Nomad runs its image for managed tools, sandboxes carry it for installed ones); this service is the node's tool compiler | Internal |

### Accessing the System

1. Open **[http://localhost:3000](http://localhost:3000)** in your browser.
2. Sign in with the default admin credentials:
   - **Handle:** `node-a` (or your configured `node.name`)
   - **Password:** `changeme` (or the value of `ASEMAN_ADMIN_PASSWORD` in your `.env`)
3. Open **Admin Console → LLM** to configure provider API keys (OpenAI, Anthropic, Gemini, Grok, DeepSeek, Vercel AI Gateway, or custom OpenAI-compatible endpoints) and token pricing.

### Common CLI Controls

```bash
./aseman.sh ps             # Check status of running containers
./aseman.sh logs [service] # Stream logs (e.g., ./aseman.sh logs aseman)
./aseman.sh down           # Stop services (persists database and volume data)
```

---

## Configuration

Configuration values specific to your node live in `services/configs/config.yml` (fallback: `services/configs/config.example.yml`):

```yaml
node:
  name: "node-a"              # Node name and handle of the admin account
  oauth_client_id: ""         # Optional: Google OAuth client ID

sandbox:                      # Shared per-space sandbox backbone
  backend: "docker"           # "docker" (local per-space container) or "modal" (remote Modal sandbox)

modal:                        # Required only when sandbox.backend is "modal"
  token_id: "ak-..."
  token_secret: "as-..."
```

Additional environment-level overrides (database credentials, transactional email via Resend/SMTP, RevenueCat backend secrets, ports, public URLs, admin password) can be set via `.env`. See [`.env.example`](.env.example) for all available options.

The Flutter client reads the Google web/server client ID from the node at runtime. For an iOS build, also set the `GOOGLE_REVERSED_CLIENT_ID` Xcode build setting to the reversed iOS OAuth client ID and pass that client ID with `--dart-define=GOOGLE_IOS_CLIENT_ID=...`. The iOS target already includes Sign in with Apple and APNs entitlements; signing profiles must enable both capabilities.

---

## Agents

Every agent runs on **[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)** (`dsh`): one long-lived harness host with Aseman's own plugins, which the node runs as its agent runtime (see [`services/plugins/adapters/vmm/harness/runtime`](services/plugins/adapters/vmm/harness/runtime/README.md)). Each agent keeps one dsh Session per room thread (and the person's Aseman one per personal chat), resumed across turns and restarts. The harness brings the agent loop, compaction, todos, goals, workflows, subagents and Agent Teams; Aseman's plugins bring the platform:

- **The metered model:** every model call goes to the node's LLM gateway as the turn it belongs to (the agent's own provider and model, billed to the turn); provider keys never leave the node.
- **The space's computer** is each agent's shell and files (`bash`, `read_file`, `write_file`, `edit_file`, `glob`, `grep`, `read_image`); the harness's local shell and files are off.
- **The platform:** the space's apps and the platform's tools (files, desk, AG-UI, app building, routines, images, proxies, …) are generated per turn; the whole Aseman API (spaces, rooms and threads, people, agents, files and media, routines, market, themes, posts, …) is reachable with `aseman_api_search` / `aseman_api_call`, under one policy: a room agent stays in its space; the person's own Aseman acts across their account. Administration, credentials and money movement are never served.
- **People:** `post_message`, direct messages, and `ask_user`, which pauses the conversation until a person answers.

- **Hybrid teams:** the lead (aseman) hands work to the space's agents (`delegate_task`), hires agents **published in the marketplace** (`hire_agent`) and, only for roles nothing fits, writes **new specialists** (`recruit_agent`). For parallel work of its own it spawns teammates (dsh Agent Teams: a shared task board and mailbox).
- **Theme packs:** people publish and install **UI themes** from the Store (Themes tab). A pack is versioned JSON (`aseman.theme/v1`) that restyles Material tokens, glass/surfaces, shapes, typography, motion, graphics, and shell layout (which features appear as tabs/sections and in what order) through a trusted Flutter runtime — no arbitrary Dart from the Store. Theme Studio and Aseman (`create_theme` / `install_theme`) generate packs from a design brief; Settings → Appearance switches builtins (Sky, High contrast, Compact) or opens the Store.
- **Parallel work:** several delegations run at once, teammates and subagents work in parallel, and `workflow` scripts orchestrate fixed fan-outs.

## Room Threads

A room's conversation can be split into **threads**. The chat header's
threads button lists the room's main thread (the room itself) and its other
threads, opens new ones, and renames or deletes them; switching thread
switches the chat to that thread's own history.

- **Isolation:** each thread has its own messages and its own context for
  every agent (the agents' LangGraph conversations, catch-up and memory
  sessions are per thread), so a thread starts clean of the room's history.
- **Shared:** the room's desk, members, grants and files belong to all of its
  threads. Threads never show up as rooms in listings.
- **Temporary threads:** when a generated app asks an agent
  (`_aseman/api/ask`), the agent works in a temporary thread opened for that
  one ask and deleted as soon as it answers — its messages and the agents'
  runtime checkpoints included. A sweep removes any left behind after an hour.
- **API:** `spaces.thread_list`, `thread_create`, `thread_rename`,
  `thread_delete`; message actions take a thread's id as `room`.
  `spaces.ask` takes `thread` (run in a thread) or `temp_thread: true`.

## Agent Memory

Agents remember in three layers, all kept by the node and scoped by the turn:

- **Notes:** the space's shared notes and each agent's own (in personal chat, the person's notes with their Aseman) are always in the agent's context; agents keep them with `rewrite_notes`. The project's Memory screen reads and corrects the same notes.
- **Long-term memories:** facts, preferences, decisions, procedures and what is known about people, stored in Postgres with **pgvector** and recalled by meaning. Agents keep them (`remember`, `shared=true` for the whole team) and look them up (`recall`); what memory holds about each message comes with it. After every turn the node learns new memories from it with the memory chat model, skipping what it already knows. A room agent recalls its own and its space's memories, never another space's; a person's memory is theirs alone.
- **Earlier conversations:** dsh's full-text session search (`session_*` tools) over the space's earlier sessions.
- **Models:** pick a chat and an embedding model under **Admin → Memory models**. Without an embedding model, memories are recalled by words; without a chat model, nothing is learned from turns. Notes always work. Changing the embedding model needs no reindex: memories of another dimension are never compared.
- **Billing:** a project pays for what its memory uses of the memory models (its owner's provider prices), counted in its spend and budget; a person's own memory is billed to the person. A project that cannot pay gets no memory model calls until it can. Requests marked "no memory" read and learn nothing.

## Project Timeline

Every project keeps a dated timeline of its work and events in the node's own database (`timeline_entries`): people's requests and how they ended, the tools each agent ran, room messages and work logs, model usage, files shared, members joining, rooms opened, routines and their runs. The node reads these from its own records about every 10 seconds, history included on first start. Agents search it with `timeline_search` and `timeline_entry`, for their own project only. No model is involved. `ASEMAN_TIMELINE=off` turns it off; admins see each feed's progress with `timeline.status`.

## Tools

Users create tools in the Tools panel from one form with a **backend** and a
**frontend**:

- **Backend:** *external* (an MCP server), *managed* (an Elpian VM, QuickJS or
  docker backend the node runs as a Nomad service, aware of which person or
  agent calls it from which space and room) or *installed* (installed into the
  sandbox of each space that adds it, serving only that space, wired through
  the sandbox proxy). Every backend's microtools are agents' tools and the
  frontend's API alike.
- **Frontend:** *static* (an Elpian program on the Elpian VM or QuickJS) or
  empty (no dedicated frontend). Interactive UIs open as floating card
  windows on the room's desk, placed and arranged by agents and people.
- **On-demand apps:** when people want an app, dashboard or custom tool UI,
  agents start it with `appui_create` (fullstack in the sandbox), and the
  space's agents build it (see *Who builds* below). The
  frontend is an **Elpian app** by default: JavaScript the client runs on
  its Elpian QuickJS runtime and draws natively with the UI kit and the
  person's theme, with the OpenUI collection and agent islands ported to
  Elpian ([`appui/elpian`](deploy/sandbox-computer/appui/elpian)). A web
  frontend (Material 3 Expressive / `@material/web`) is built only when the
  person explicitly asks for web technology. Mix Aseman OpenUI agent islands
  with programmed UI; tools via
  `/_aseman/api/call`, agents via `/_aseman/api/ask`, each ask in a
  temporary thread). App servers use agents and apps too: as the person
  using the app (a token the gateway sends with each request) or, for
  background work, as the person who asked for the app (the app's key);
  either way it is charged to that person's wallet like their own ask.
  The builder gets the space's apps (with microtool argument
  schemas) and agents, the page API contract and a client SDK; the platform
  then starts the app and checks it (an Elpian frontend on QuickJS against
  the live server, its end-to-end scenarios replayed) before it opens.
  Passing an existing app's `dir` changes it in place.
  See [`deploy/sandbox-computer/appui`](deploy/sandbox-computer/appui).
- **Who builds:** the space's own agents. `appui_create` lays the project
  out and answers with the build task (`TASK.md`); the agent (or a developer
  specialist the lead staffs) plans, builds, tests, validates the Elpian views
  and drives the app end to end with `aseman-elpian` (the Elpian validator and
  headless driver, sessions kept between commands), then calls
  `appui_publish`: the platform verifies it and opens it, or answers with what
  to repair. Other coding happens directly in the sandbox. `appui_status`
  reads a project's state.
  Use `proxy_create` to expose an already-running sandbox HTTP service as a
  DeskWeb card. Previews serve the page API at `/_aseman/api/` (context,
  tools, microtool calls).

Ready-made tools live in [`deploy/tools`](deploy/tools), such as the
[weather](deploy/tools/weather) tool.

The Elpian engine is part of the app (`app/lib/src/elpian`), not a
dependency. See [`services/README.md`](services/README.md#tools-one-form-three-backends-two-frontends).

## LLM Providers & Billing

- **Provider Management:** Admin users can register API keys and set per-model input/output token pricing directly from the web UI (**Admin → LLM**).
- **Execution & Metering:** All model calls route through the node's metered LLM proxy, ensuring exact usage tracking based on provider responses.
- **Billing Mechanics:** Agent work is billed to the account that initiated the task (`pay_llm` for model tokens, `pay_bot` / `pay_node` for execution runtime).
- **Decision Model:** Optionally pick a fast decision model (**Admin → Decision model**). Your personal Aseman uses it to decide, before anything else, whether a note is kept or answered.
- **First Boot Bootstrap:** To automatically seed an initial LLM provider on startup, set `ASEMAN_LLM_API_KEY` (and optionally `ASEMAN_LLM_MODEL`) in your `.env`.

## Personal Aseman, calls and social

- **Aseman chat is your home:** the former Saved Messages self-chat is also
  your home workspace — one space for notes answered by your personal Aseman,
  your computer (shared with your other direct chats' agents), your lead and
  team, and universal floating App UI gadgets. Your Aseman acts for you on DeepSeek Harness with
  your access across the app (your own memory, room access, `ask_user` before
  anything that cannot be undone). Long work stays in this same home; live
  voice is under Admin → Agents. There is no separate home project or Aseman
  assistant Direct — opening the built-in assistant or lead out of space lands
  here. Mentions of `@aseman` in other personal chats still use the chat
  assistant; room agents stay mentionable in projects, scoped to whoever
  prompts them.
- **Voice and video calls** between people (WebRTC; media never hits the node).
  Configure TURN with `ASEMAN_TURN_*`. Privacy settings control who may message,
  call or invite you; notification prefs mute kinds of push.
- **Push:** APNs (iOS) and FCM (Android, `ASEMAN_FCM_SERVICE_ACCOUNT`).
- **Credits:** people can apply for complimentary credits; admins resolve them
  and edit transactional email templates (Admin → Emails).
- **Orbit:** project workspaces show agents, people and tools in an orbit strip.

## Governance, proactive work and connections

- **Every agent action is decided and recorded.** A CEL policy (Admin →
  Governance → Policy, or a project's Agents settings) denies, asks or allows
  each action; asks become approvals with Allow once, Always allow and Refuse,
  in the app, Slack, Teams or SMS. The audit trail records who started each
  action and exports as CSV.
- **Secrets stay out of the conversation**: agents ask with a masked box and
  use credentials by name; outbound content is checked; outside content is
  marked untrusted. Project computers follow a network policy through the
  egress proxy, optionally under gVisor (`ASEMAN_SANDBOX_RUNTIME=runsc`), and a
  person can take one over.
- **Your assistant works on its own, read-only**: Tasks, the morning brief,
  inbox triage and background research, with the Google app connected.
  Responsibilities react to services (GitHub, GitLab, Slack, Teams, SMS,
  Stripe, Linear, Jira, Shopify, webhooks), polls (mail, calendar, feeds, any
  API, an app's answer) and schedules; demonstrations turn something you
  showed into a skill.
- **Apps are the connectors**: Google (Gmail and Calendar), Composio and Arcade
  are apps in the catalog, added to projects and connected per person like
  any other app.
- **Reach it anywhere**: Slack, Microsoft Teams and SMS; voice dictation.
  People share folders of their project computers with their agents
  everywhere; agents on people's own computers (desktop app) is an admin
  switch, off by default.
- **Enterprise**: OIDC single sign-on, SCIM provisioning, organizations, SPIFFE
  workload identity (`docker compose --profile spire up`).
- **Operations**: Admin → Health checks the real thing; `deploy/helm/aseman`
  for Kubernetes; `evals/` for triage and reply-chip quality; the node sends no
  telemetry ([`docs/telemetry.md`](docs/telemetry.md)); see
  [`CHANGELOG.md`](CHANGELOG.md) when upgrading.

---

## Local Development

### Backend (`services/`)
- Built with Go. See [`services/README.md`](services/README.md) for architecture details, plugin systems, and unit test execution (`make build`, `make test`).
- When run directly without Docker variables, the node operates in-memory with local cache.

### Client (`app/`)
- Built with Flutter.
- Start dev server:
  ```bash
  cd app
  flutter pub get
  flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
  ```
- Code checks:
  ```bash
  flutter analyze
  flutter test
  ```
- Refer to [`app/README.md`](app/README.md) for client architecture and backend wiring.
