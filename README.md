# Tradera AIOS

**Tradera AIOS** is an agentic social workspace and federated AI operating system. Users deploy LLM-backed autonomous agents and apps, collaborate in shared spaces/rooms, and manage execution costs via in-platform wallets powered by a distributed ledger.

---

## Architecture Overview

```
TraderaAIOS/
├── app/         # Tradera Flutter client (web, iOS, Android, desktop)
├── services/    # Tradera core node (Go): API gateway, agent runtime, finance, federation
└── deploy/      # Deployment configurations (Nomad agent, sandbox computer, OpenViking)
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
# Start all services (builds images on first run)
./tradera.sh up

# Or launch with a custom configuration file
./tradera.sh up path/to/config.yml
```

> **Note:** `./tradera.sh up` is equivalent to running `docker compose up -d --build`.

### Service Map

| Service | Purpose | Port |
| :--- | :--- | :--- |
| **`web`** | Flutter Web client (served via nginx) | [http://localhost:3000](http://localhost:3000) |
| **`tradera`** | Core Go node (REST/WebSocket API, agent gateway, finance) | [http://localhost:8080](http://localhost:8080) |
| **`postgres`** | The stack's one database server (Postgres 16 with pgvector): the node's records and the timelines' database | Internal |
| **`nomad`** | Nomad agent executing bot and agent workloads | Internal |
| **`sandbox-computer`** | Builds the base sandbox image for spaces, then exits | — |
| **`deepagents`** | Builds the agent runtime image (each agent on a self-hosted [OpenCode](https://github.com/anomalyco/opencode), the swarm orchestrated with LangChain Deep Agents, self-improvement with [harness2](https://github.com/google-research/harness2)), then exits | — |
| **`tool-runtime`** | Runs tool backends written for the Elpian VM or QuickJS (Nomad runs its image for managed tools, sandboxes carry it for installed ones); this service is the node's tool compiler | Internal |
| **`openviking`** | Self-hosted [OpenViking](https://openviking.ai): the agents' long-term memory | Internal |
| **`timeline-db`** | Creates the timelines' database on `postgres` if it is missing, then exits | — |
| **`timeline`** | Self-hosted [Utopia](https://github.com/deeplethe/utopia): each project's dated timeline, on `postgres` | Internal |

### Accessing the System

1. Open **[http://localhost:3000](http://localhost:3000)** in your browser.
2. Sign in with the default admin credentials:
   - **Handle:** `node-a` (or your configured `node.name`)
   - **Password:** `changeme` (or the value of `TRADERA_ADMIN_PASSWORD` in your `.env`)
3. Open **Admin Console → LLM** to configure provider API keys (OpenAI, Anthropic, Gemini, Grok, DeepSeek, Vercel AI Gateway, or custom OpenAI-compatible endpoints) and token pricing.

### Common CLI Controls

```bash
./tradera.sh ps             # Check status of running containers
./tradera.sh logs [service] # Stream logs (e.g., ./tradera.sh logs tradera)
./tradera.sh down           # Stop services (persists database and volume data)
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

Every agent's backbone is a self-hosted [OpenCode](https://github.com/anomalyco/opencode), run inside the agent runtime and orchestrated as a swarm by LangChain Deep Agents (see [`services/README.md`](services/README.md#agents-opencode-backbones-orchestrated-by-deep-agents)):

- **One set of LLM settings:** OpenCode's only model provider is the runtime's relay to the node's metered LLM proxy, so agents use exactly the providers, models, keys, prices and limits configured under **Admin → LLM**, and every token is billed as before. OpenCode holds no key.
- **Hybrid teams:** the lead (tradera) staffs a goal with agents already in the space, agents **published in the marketplace** (hired into the space) and, only for roles nothing fits, **new specialists it writes**. The language model and the decision model share the work: the decision model scores every candidate for every role in one fast request, and the language model breaks the goal into roles, settles close calls and writes missing specialists.
- **Parallel work:** the lead runs plans across the team in parallel; independent tasks start at once (the decision model drops dependencies that are not needed), and several tasks for the same agent run as parallel instances of it.
- **Self-improvement:** agents improve their own harness (prompts, guardrails, skills, subagents, scripts) as they work, with Google Research's [harness2](https://github.com/google-research/harness2): proposed and composed from their recent trajectories, probed on their next real requests, adopted only when it does at least as well (judged with the decision model, so it runs only when one is on), and the lessons kept in each agent's experience library. It is billed to the project like memory; `TRADERA_HARNESS=0` turns it off.
- `TRADERA_AGENT_ENGINE=deepagents` runs agents on the previous LangChain deep agents engine.

## Agent Memory

Agents remember through a self-hosted [OpenViking](https://openviking.ai) server (`deploy/openviking`), not files in the sandbox:

- **Isolation:** each space is an OpenViking account and each agent a user in it; one space never sees another's memory.
- **Notes:** the space's shared notes (`viking://resources/space/notes.md`) and each agent's own (`viking://user/<agent>/memories/notes.md`) are in every agent's prompt; agents keep them with `remember` / `rewrite_notes`.
- **Recall:** what memory holds about a message is recalled with it, and agents search and read more with `recall` / `read_memory`.
- **Learning:** every finished turn is committed to the agent's OpenViking session of the room, from which OpenViking extracts long-term memories (preferences, entities, events, cases, patterns, and what it learned about each person).
- **Models:** OpenViking has no model settings of its own. It calls its models through the node, which uses the ones picked in **Admin → Memory models**: a chat model that learns from conversations and an embedding model that finds memories by meaning, chosen from the providers and models under **Admin → Providers / Models** (mark embedding models as such on Models). Without them agents still keep and read their notes. Changing the embedding model re-indexes every project's memory.
- **Billing:** a project pays for what its memory uses, like the rest of its agents' work: the memory models' tokens at their own prices (Admin → Models), paid to the owner of the provider's key, counted in the project's spend and against its budget. The payer is whoever ran the project's latest agent turn, else its owner. OpenViking names the project of every model call (`deploy/openviking/sitecustomize.py`), and the node charges each project every 30 seconds. A project that cannot pay gets no memory model calls until it can.
- **Setup:** nothing to configure: the root key is generated into `.env` on first start. Requests marked "no memory" never reach OpenViking. Notes kept in a space's sandbox `AGENTS.md` files before are imported once, and the project's Memory screen reads and edits the notes in OpenViking.

## Project Timeline

Every project keeps a dated timeline of its work and events, and every agent can read it. It lives in a self-hosted [Utopia](https://github.com/deeplethe/utopia) server (service `timeline`), a bitemporal knowledge graph, which runs on the stack's own Postgres in a database of its own (`tradera_timeline`); there is no second database server.

- **What is on it:** people's requests and how they ended, the tools each agent ran, room messages and agents' work logs, model usage and cost, files shared, members joining, rooms opened, routines and their runs. The node reads these from its own records (the `timeline` namespace) and pushes them about every 10 seconds, history included on first start. Each entry carries when it happened and when it was recorded.
- **Agents:** the timeline is a built-in MCP server of every agent, on by default. The runtime reaches it only through the node's agent gateway (`/deepagents/v1/timeline/mcp`), which forwards to the turn's own project; agents see it as `timeline_*` tools (find, history, changes, facts, related, paths, search, entry), whatever tools they are otherwise allowed, and are told in their prompt when to use them. Reads only: Utopia's write tool is not served. Requests marked "no memory" get no timeline.
- **Isolation:** each project is a knowledge base of its own in Utopia; an agent never names the project or holds a Utopia key.
- **No models needed:** events go in as structured statements, so building and reading the timeline uses no LLM.
- **Setup:** nothing to configure: the node's Utopia password (`TRADERA_TIMELINE_PASSWORD`) is generated into `.env` on first start, and the node creates its account, each project's knowledge base and its read token itself. Set `TRADERA_TIMELINE_URL=` (empty) in `.env` to turn timelines off. Admins see each feed's progress with `timeline.status`.

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
  *generative* (A2UI generated from a skill on first use, cached in the
  component registry and filled with fresh data). Results open as floating
  card windows on the room's desk, placed and arranged by agents and people;
  agents combine tools' frontends and data into bigger widgets
  (`ui_compose`) on the desk too.
- **Interactive web frontends:** when people want to *work with* a tool (an
  interactive view, dashboard, form or console), agents build a web page for
  it in the space's sandbox and expose it with `proxy_create`; it opens on
  the desk as the tool's card window like any frontend (in an `<iframe>` on
  the web, a native web view on Android, iOS, macOS and Windows). Pages use
  **Tradera's web UI kit** ([`services/pkg/webkit`](services/pkg/webkit)):
  the app's theme and every component the app renders (the A2UI catalog, the
  tool UI kit, the Elpian widgets and HTML) as `<t-…>` web elements, plus a
  client that calls the tool's microtools through the Tradera API as the
  person viewing the page. Every preview serves the kit at `/_tradera/kit/`
  (its gallery: `/_tradera/kit/gallery.html`) and the page API at
  `/_tradera/api/`.

Ready-made tools live in [`deploy/tools`](deploy/tools): the
[weather](deploy/tools/weather) tool and the **traders
[evaluator](deploy/tools/evaluator)**, a docker tool in the admins space that
crawls traders' CoinMarketCap profiles with a headless browser, scores their
reliability against market data and keeps the app's Traders leaderboard
(`deploy/tools/evaluator/upsert.sh` sets it all up as `node-a`).

The Elpian engine is part of the app (`app/lib/src/elpian`), not a
dependency. See [`services/README.md`](services/README.md#tools-one-form-three-backends-two-frontends).

## LLM Providers & Billing

- **Provider Management:** Admin users can register API keys and set per-model input/output token pricing directly from the web UI (**Admin → LLM**).
- **Execution & Metering:** All model calls route through the node's metered LLM proxy, ensuring exact usage tracking based on provider responses.
- **Billing Mechanics:** Agent work is billed to the account that initiated the task (`pay_llm` for model tokens, `pay_bot` / `pay_node` for execution runtime).
- **Decision Model:** Optionally pick a decision model such as TypeSafe AI's Jev on Vercel AI Gateway (**Admin → Decision model**). Agents then use it for tool selection, routing and work checks together with their own model; turned off, every agent decides with its own model.
- **First Boot Bootstrap:** To automatically seed an initial LLM provider on startup, set `TRADERA_LLM_API_KEY` (and optionally `TRADERA_LLM_MODEL`) in your `.env`.

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
