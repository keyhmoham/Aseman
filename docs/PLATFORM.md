# Aseman — Platform Documentation

> **Brief:** Aseman is a federated AI operating system and agentic social workspace. People collaborate in spaces, run LLM-backed agents and apps, share a desk and a computer per project, pay from in-platform wallets, and optionally expose the same product surface through a developer API — including isolated platforms built on one node.
>
> **This document** is the full map: philosophy, architecture, product surfaces, identity, tenancy, agents, money, deploy, and how the pieces fit. Paths are relative to the repository root.

---

## 1. In one page

| Layer | What it is | Where it lives |
| --- | --- | --- |
| **Client** | Flutter app (web, iOS, Android, desktop) | `app/` |
| **Node** | Go daemon: actions, adapters, finance, federation, agent gateway | `services/` |
| **Deploy** | Caddy edge, sandbox/harness images, Nomad/Helm/SPIRE, ship scripts | `deploy/` |

**How a request moves**

```
Flutter / CLI / partner
        │  Bearer session + Ed25519 signature
        ▼
Network adapter (http | tcp | websocket)
        ▼
Gateway  POST /v1/{namespace}/{action}
        ▼
Action router  →  namespace plugin  →  domain models / adapters
```

**What “modular” means here**

1. **Fixed foundation** — kernel, routing, plugin host, signing, universal IDs (`services/internal/`). Not product logic.
2. **Adapters** — swappable providers for database, cache, filesystem, network, VMM (`services/plugins/adapters/`).
3. **Actions** — every product feature is a namespace plugin (`services/plugins/actions/<ns>/`). Namespaces never import each other’s service implementations; they talk through a **bridge**.

**Three audiences**

| Audience | Door |
| --- | --- |
| People (main Aseman app) | Node host `/v1/{ns}/{action}` |
| External developers / OpenAI clients | Developer host `/v1/...` (API keys `dk_live_…`) |
| Agents inside a turn | Harness `/harness/v1/...` + Code Mode `/tools/v1/codemode/...` |

---

## 2. Repository map

```
Aseman/
├── app/                 Flutter client + Elpian engine + AG-UI
├── services/            Go node (cmd/, internal/, plugins/, pkg/)
├── deploy/              Edge, images, Nomad, Helm, SPIRE, voice, codemode
├── docs/                Platform docs (this file), telemetry, plans
├── evals/               Quality evals (triage, reply chips, …)
├── bin/                 Wrapper binaries
├── aseman.sh            Local compose entry
├── docker-compose.yml   Stack definition
└── CHANGELOG.md
```

### `services/` ownership

| Path | Role |
| --- | --- |
| `cmd/asemand` | Node process |
| `cmd/aseman` | Signed CLI client |
| `cmd/aseman-egress` | Egress proxy for sandboxes |
| `internal/app` | Composition root: boot, load plugins, bind gateway |
| `internal/kernel` | Capabilities, active adapters, route bindings |
| `internal/routing` | Namespace → action dispatch |
| `internal/plugins` | Plugin API, bridge, host, registry, signing, identity |
| `plugins/adapters/*` | Ports + providers (postgres, http, harness, …) |
| `plugins/actions/*` | Product namespaces |
| `plugins/config` | Node manifest + env overlay |
| `pkg/*` | Shared libraries (`errs`, `tenancy`, `agentpolicy`, `agui`, …) |

### Compose services (local)

| Service | Purpose |
| --- | --- |
| `web` | Flutter web (hot-reload debug by default) |
| `aseman` | Go node API |
| `postgres` | Postgres 16 + pgvector (records, agent memory, timelines) |
| `nomad` | Schedules bots / agents / tool jobs |
| `sandbox-computer` | Builds the per-space computer image |
| `harness` | Builds the DeepSeek Harness agent runtime image |
| `tool-runtime` | Compiles/runs Elpian & QuickJS tool backends |
| `egress-proxy` | Outbound network control for sandboxes |

---

## 3. Modular philosophy (detail)

### 3.1 Hexagonal core

Driving adapters (HTTP, WebSocket, TCP, CLI) call into an **action router**. Domain logic lives in **action namespaces**. Driven adapters implement **ports** (database, cache, filesystem, network, VMM). Providers behind a port can be swapped at runtime (`admin.plugins_set_active` / CLI `plugins-active`).

```
┌─────────────────────────────────────────────────────────────┐
│ Driving:  Flutter · CLI · webhooks · federation peers       │
├─────────────────────────────────────────────────────────────┤
│ Application:  namespaces (auth, spaces, bots, finance, …)   │
├─────────────────────────────────────────────────────────────┤
│ Domain:  accounts, spaces, rooms, bots, wallets, ledger, …  │
├─────────────────────────────────────────────────────────────┤
│ Ports:  database · cache · filesystem · network · vmm       │
├─────────────────────────────────────────────────────────────┤
│ Adapters: postgres/mysql/mongo/memory · redis · s3 ·        │
│           http/tcp/ws · nomad/docker/wasm/modal/harness/mcp │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Rules namespaces must obey

- **Own your models.** Accounts belong to `auth`; spaces/rooms/memberships to `spaces`; wallets/ledger to `finance`; bots to `bots`; etc. Schemas register with the active database when the namespace starts.
- **Bridge, don’t import.** Cross-namespace calls use `bridge.Invoke(ctx, kernel, "spaces", "Method", args, &out)`. Consumers declare a **narrow interface** they need; the bridge resolves `service/<ns>` and calls by reflection. Sibling DTO/model packages may be imported; sibling **service implementations** must not.
- **Actions are the public API.** Each action is `namespace.action` with a JSON body. HTTP is `POST /v1/{namespace}/{action}`. The Flutter client and CLI share this contract (`app/lib/src/data/services/backend_capabilities.dart` inventories client-used actions).
- **Live reprogramming.** Native Go plugins (`.so`) can be built, loaded, replaced, stopped, and unloaded while the node runs. Unload removes routes and drains work; mapped code stays until process exit (Go plugin limitation).

### 3.3 Adapter categories

| Category | Providers (typical) | Default |
| --- | --- | --- |
| **database** | postgres, mysql, mongodb, memory | memory (compose uses postgres) |
| **cache** | local-cache, redis | local-cache |
| **filesystem** | local, s3 | local (S3 when `ASEMAN_S3_BUCKET`) |
| **network** | http, tcp, websocket | http |
| **vmm** | nomad, docker, wasm, modal, harness, mcp, … | nomad |

### 3.4 Universal IDs & federation

Every entity ID is **32 hex characters**: 16 hex node id + 16 hex entity id. The node prefix tells *where* the record lives. Requests that touch foreign-node entities are proxied through the `federation` namespace. Node IDs are allocated by the central node on first run (timestamp-derived, not a counter). Peers register mutually; ledger sequences replicate.

### 3.5 Request identity

Every **user** and **node** has an Ed25519 keypair.

- At registration, the client receives the private key once (encrypted at rest with the password).
- Authenticated product calls send: Bearer session token + signature over `method\npath\nnonce\ntimestamp\nsha256(body)`.
- The gateway verifies the signature against the account public key and rejects replays (nonce + freshness window).
- Inter-node traffic is signed with the node key.

---

## 4. Network surfaces

### 4.1 Node host (people & the Flutter app)

| Path | Role |
| --- | --- |
| `POST /v1/{namespace}/{action}` | Product API |
| `GET /v1/files/{id}/content` | Raw file bytes |
| `GET|POST|… /v1/proxy/{id}/*` | Reverse-proxy into a space’s sandbox preview |
| `/appapi/v1/*` | App-server API for sandboxed App UIs |
| `/healthz` | Health probe |

### 4.2 Developer host (API keys)

Configured with `ASEMAN_DEVELOPER_HOST` / `DEVELOPER_DOMAIN`. On that host only:

- External `/v1/...` maps to internal `/dev/v1/...`
- Ordinary `/v1/{ns}/{action}` is **not** served (404)

**Auth:** `Authorization: Bearer dk_live_…` (hashed secrets in `dev_keys`).

**Surfaces include**

| Family | Examples |
| --- | --- |
| OpenAI-shaped models | `/v1/models`, `/chat/completions`, `/embeddings`, `/images/generations`, `/videos/*`, `/audio/*`, `/rerank`, `/decisions` |
| Org metering | `/balance`, `/organization`, `/usage` |
| Computers & storage | `/computers`, `/files`, … |
| **Platform collection** | `GET /v1/platform`, `POST /v1/platform/{namespace}/{action}` |
| **Workflow installer** | `POST /v1/workflows/{validate,plan,runs}`, `GET /v1/workflows/runs[/{id}]`, `…/cancel`, `GET /v1/workflows/reference` |

The **workflow installer** runs one JSON document that brings up a whole
product through those same actions, in order — organization, platform, keys
(from the console), spaces, agents, apps, the full source of an app written,
built and served on a space's computer — validated, planned (dry run) and
idempotent, with retries, loops, templates and rollback. See
[`WORKFLOWS.md`](WORKFLOWS.md).

The platform collection exposes every registered **non-admin** product action (excludes `admin`, `developer`, and `admin_*`). Calls act as the **person who created the key**. If that key’s organization owns a platform, new entities are stamped with that platform id.

### 4.3 Agent & tool surfaces

| Path | Role |
| --- | --- |
| `/harness/v1/call`, `/catalog`, `/llm/*`, `/memory/*`, `/timeline/*` | Turn-scoped agent gateway (policy-bound) |
| `/tools/v1/codemode/{openapi,request,mcp}` | Code Mode: search/execute against a generated OpenAPI of space capabilities |
| `/tools/v1/runtime/host` | Managed/installed tool backends calling back into the platform |
| `/v1/proxy/{id}/*` | An app's preview (space members); its page API at `_aseman/api/*` |
| `/appapi/v1/{op}` | An app's server using its space's agents and apps (user token or app key) |
| `/v1/platforms/{slug}/app/*` | A platform's published frontend (§8.3); `_aseman/wake` wakes its computer for anyone |
| `/v1/platforms/{slug}/client/android.apk` | A platform's own Android app, for anyone to install (§8.3) |

### 4.4 Other HTTP doors

| Path | Owner |
| --- | --- |
| `/fed/dispatch`, `/fed/ledger` | Federation peers |
| `/sso/v1/callback`, `/scim/v2` | Enterprise SSO / SCIM |
| `/google/v1/mcp` | Google connector |
| Channel webhooks, talent partner API, responsibility hooks | Respective namespaces |

### 4.5 Edge domains (production)

| Env | Serves |
| --- | --- |
| `APP_DOMAIN` | Flutter web |
| `API_DOMAIN` | Node API |
| `DEVELOPER_DOMAIN` | Developer API only (optional) |

See `deploy/README.md` and `deploy/caddy/Caddyfile`.

---

## 5. Action namespaces (catalog)

Under `services/plugins/actions/`:

| Namespace | Owns / does |
| --- | --- |
| `auth` | Register, login, sessions, OAuth (Google/Apple), profile, platform-scoped accounts |
| `users` | Profiles, DMs, notifications, personal files/storage, voice, search, hireable |
| `spaces` | Spaces, rooms/threads, memberships, messages, turns, desk, sandbox, files, proxies, App UI |
| `bots` | Agents, apps (tools), themes as bots; lifecycle, frontends, KV, samples |
| `tools` | MCP, OAuth connections, invoke, commands, App UI gadgets, Code Mode |
| `message` | Packet ask/send between accounts/bots |
| `posts` | Social feed |
| `market` | Catalog of agents/apps/themes; publish/approve |
| `themes` | Theme pack records / studio support |
| `finance` | Wallets, ledger, purchases, payouts, grants, budgets |
| `usage` | Metering aggregates |
| `llm` | Provider/model catalog, decision/image/voice/memory model picks (admin-gated writes) |
| `routines` | Scheduled / recurring automation in a space |
| `responsibilities` | Assigned ongoing duties + hooks |
| `proactive` | Tasks, approvals, outbound work |
| `governance` | Policies, gates, secrets, audit, computer takeover |
| `channels` | External chat channel bindings |
| `google` | Google workspace connector |
| `hostaccess` | Shared folders / host FS grants |
| `enterprise` | Orgs, OIDC SSO, SCIM, SPIFFE |
| `talent` | Human collaboration offers + partner keys |
| `federation` | Node mesh, proxy, ledger replication |
| `timeline` | Dated project history tools |
| `settings` | Node settings, email templates |
| `admin` | Node administration |
| `developer` | Developer orgs, keys, computers, files, platforms, playground; HTTP developer door |
| `support/` | Shared helpers (repo, authorization, metasvc) — not a product namespace |
| `greeter` | Sample plugin |

**Agent policy** (`services/pkg/agentpolicy`) further restricts what model-written code may call (denies admin/auth/developer/llm keys/settings/… and money-moving finance actions).

---

## 6. Product features (what people use)

**Live shell** (`features/navigation/presentation/app_shell.dart`): after login the root is **Pulse** — `SearchFeedScreen` with phone tabs **Chats / Explore / You**. Opening a workspace **pushes** `WorkspaceScreen` (rooms, desk, computer, bots); Home pops back to the feed. Wallet, Admin, Agents, Developer, and settings open from profile / workspace affordances — not a permanent multi-destination rail.

### 6.1 Spaces & home

- A **space** is a workspace: members, rooms, files, bots, desk, optional sandbox computer.
- Every person has one **home / Aseman** space: personal chat with their lead agent, notes, and personal computer (self-direct + `home` flag).
- **Direct** spaces are 1:1 chats (person↔person or person↔agent).
- **Projects** are ordinary multi-member spaces (created private by default).
- **Rooms** hold conversation; **threads** are child rooms (`parent_id`) with their own message context.

Client: `app/lib/src/features/home/`, `features/rooms/`.  
Backend: `spaces.*`.

### 6.2 Messenger & presence

Inbox of chats, typing, seen, reports, pin/clear, DMs via `users.dm_*` and space directs. Live updates through `spaces.live`.

Client: `features/messenger/`.

### 6.3 Desk

Floating windows for apps, previews, files, and work surfaces inside a space. Arrange / pin / close via desk actions. App UIs in **gadget mode** also float as **compact frameless widgets** over desk, chat, rail, or as pages.

Client: `features/desk/`, `features/gadgets/`.

### 6.4 Agents

LLM-backed assistants. Every agent runs on the **DeepSeek Harness** runtime (VMM type `harness`). Agents join spaces, take **turns** (runs with logs, cancel/resume, questions for the person), use tools, memory, timeline, and the shared sandbox.

Client: `features/agents/`, `features/rooms/`.  
Runtime: `services/plugins/adapters/vmm/harness/` (+ `runtime/`).

### 6.5 Apps (tools) & App UI

An **app** is a bot of kind `tool`: MCP backend, Elpian/QuickJS program, installed sandbox binary, wasm, etc., plus an optional frontend. Frontends are built with the **Elpian / web App UI** pipeline (`appui_create` / `appui_publish`) and hosted in **window mode** (framed desk card) or **gadget mode** (compact frameless widget).

Client: `features/tools/`, `features/gadgets/`.  
Images: `deploy/sandbox-computer/appui/`, `deploy/tool-runtime/`.

### 6.6 App UI gadget mode

Same App UI creation path with `kind: "gadget"` (see `deploy/sandbox-computer/appui/elpian/GADGETS.md`). Placement: `chat` | `rail` | `desk` | `page`. Account-wide when built in home; space-scoped when built in a project. **First rule:** compact like a mobile home-screen widget — no window frame, small footprint, only necessary information. Person removes them (agents cannot).

### 6.7 Computer / sandbox

Each project can have a Linux sandbox (Docker container or Modal). Agents and people use it for shell, files, and previews (`/v1/proxy/{id}`). Idle stop; starts on activity. Image from `deploy/sandbox-computer`.

Client: `features/computer/`.

### 6.8 Market & themes

Publish and install agents, apps, and **theme packs**. Theme Studio + Settings Appearance use `aseman.theme/v1` packs (Sky and builtins in-app; store packs via bots of kind `theme`). Themes reshape Material chrome, glass, shapes, type, motion, and shell feature slots (`SoftCard`, `ThemeChrome`, `FeatureSlots`).

Client: `features/market/`, `core/theme/`.

### 6.9 Finance & wallet

In-platform **wallets** and a **distributed ledger**. Spend on LLM use, bot runtime, storage, developer API, etc. Credits, purchases, payouts, budgets. Display mapping: ledger units with \$1 = 1e6 units (see billing helpers).

Client: Wallet destination + account hub. Backend: `finance.*`, `usage.*`.

### 6.10 Social / explore / talent

Posts feed, explore, hireable profiles, talent collaboration offers and partner keys.

### 6.11 Talk, voice, calls

Speech/transcription models (Admin → AI → Voice) power Talk. WebRTC calls use node signaling and optional TURN (`ASEMAN_TURN_*`). Voice sidecar: `deploy/voice/`.

### 6.12 Assistant / proactive / governance

Tasks, approvals, connections, shared folders, CEL policy gates, secrets, computer takeover — for controlled autonomous work.

### 6.13 Admin console

Node operators manage providers, models, voice, finance ops, users, market moderation, enterprise SSO/SCIM, developer orgs/platforms, plugins, health, email templates.

Client: `features/admin/`. Requires node admin (`Role == "admin"` or configured `admin_handle`).

### 6.14 Developer console

Profile → **Developer API**: orgs, API keys, usage, logs, models playground, computers, storage, **platform**, and the live **platform action collection**. Styled with the app’s theme chrome (SoftCard, glass nav, SegmentedTabBar).

Client: `features/developer/`.

---

## 7. Identity, auth & enterprise

### 7.1 Accounts

- Kind: `user` | `bot`
- Handle + email unique **per platform** (`platform_id` empty = main Aseman)
- Password (bcrypt), Ed25519 identity keys, optional recovery key tied to node master
- Metadata tree with public paths (profile visibility)

### 7.2 Sign-in methods (shared system)

| Method | Action | Notes |
| --- | --- | --- |
| Password | `auth.register`, `auth.login` | Optional `platform` slug/id |
| Google | `auth.oauth_google` | Same `platform` field |
| Apple | `auth.oauth_apple` | Same |
| Enterprise OIDC | `enterprise` + `/sso/v1/callback` | Domain can require SSO |
| SCIM | `/scim/v2` | Directory sync / deprovision |

Platform clients use the **same APIs**; pass `"platform": "acme"` so the account is local to that environment. The same Google email can exist on main Aseman and on `acme` as **separate** accounts.

### 7.3 Sessions & third-party OAuth

Sessions are bearer tokens (hashed at rest). Apps that need “each person connects” use PKCE OAuth (`tools.oauth_*`) with redirect to `/oauth.html` or in-app WebView.

### 7.4 Enterprise extras

Organizations by email domain, SSO providers, SCIM people/groups, SPIFFE/SVID for workload identity (`deploy/spire`). Enterprise “admin groups” elevate to **node** admin — they are not platform tenants.

---

## 8. Platforms & isolation

### 8.1 Model

A **developer organization** may create **any number of** `Platform`s (`dev_platforms`): each with a node-unique slug, a name and `main_access`. Org-scoped platform actions name the one they act on with `platform` (its id or slug); it may be omitted while the organization has only one.

| Concept | Behavior |
| --- | --- |
| **Platform-local account** | `accounts.platform_id = <platform>` |
| **Stamped product rows** | `spaces.platform_id`, `bots.platform_id` (set on create from caller or developer API stamp) |
| **Default** | Isolated — environments never see each other |
| **`main_access`** | Node-admin boolean bridge: that platform ↔ **main Aseman** both ways. Still not to other platforms |

Visibility rules: `services/pkg/tenancy` (`Sees`). Helpers: `plugins/actions/support/helper/tenancy.go`.

Product discovery applies `SeesEntity`: user search / hireable, bot search, space list/search, market list/catalog/install, posts feeds, message send/ask/list-by-peer. **Node-admin** directories (`users.accounts_list`, finance ops, …) stay **global** on purpose.

**API keys and platforms.** A developer key may be bound to one of its
organization's platforms (`key_create` / `key_update` with
`input.platform`). What the key makes through the developer host's platform
collection joins that platform. An unbound key uses the organization's only
platform; with several, it must be bound to one (the call is refused
otherwise).

### 8.2 Who manages what

| Role | APIs |
| --- | --- |
| Org owner/admin | `developer.platforms_list`, `developer.platform_create|get|rename|delete|stats|users` (each takes `platform`) |
| Node admin | `developer.admin_platforms`, `developer.admin_platform_access` |
| End users of a platform | Same product actions as the main app, scoped by their `platform_id` |

### 8.3 A platform's frontend

An organization owner or admin can publish an **app the agents of a space
built** (an Elpian or web App UI with its own backend) as the platform's
**frontend** — what the platform's people open:

1. In a space they belong to, the person asks its agents for the app.
   Agents call `appui_create` with `audience: "platform"`: the project gets
   `PLATFORM.md` (signed-out visitors, the platform's people, who pays) next to
   `APPS.json`, the space's agents and apps the software is wired to.
2. The agents build, test and `appui_publish` it. `aseman-appui verify`
   refuses an app whose code names an agent, app or microtool that
   `APPS.json` does not list, or that serves its own `_aseman/…` routes in
   place of the gateway (`aseman-wiring-check`): wiring is real, never
   imitated. The published app records its wiring with its key.
3. **Developer API → Platforms → (a platform) → Frontend → Publish** picks the app
   (`developer.platform_frontend_apps`, `platform_frontend_publish`,
   `platform_frontend_unpublish`; public `platform_frontend {platform}`).

**Agents can do all of it for the person.** Three tools of the spaces
namespace act as the person whose request the turn serves (never as the
agent), through the developer namespace's own role checks; the developer
namespace itself stays closed to agents:

| Tool | Does |
| --- | --- |
| `platform_setup {name, slug, org_name?, org?}` | makes (or reuses) a team organization by name, or uses `org` / the personal one, and a platform in it: reused when the organization has one with that slug, else made (an organization may have several) |
| `app_developer_access {dir, platform?, org?, platform_api?}` | a developer key of that organization, bound to the platform (`platform`, or the person's only one) (models: read, chat: write, platform collection: write) written into the app's `.aseman/server.env` (`ASEMAN_DEVELOPER_KEY`, `ASEMAN_DEVELOPER_API_URL` = node `/dev/v1`, `ASEMAN_PLATFORM`); the agent never sees it; calling again revokes and replaces it; rebuilds keep it |
| `platform_publish {dir, platform?, org?, android?}` | publishes the app `appui_publish` verified as the platform's frontend and answers its address; for an Elpian frontend it also starts the platform's Android app (below) unless `android` is false |
| `platform_client_build {platform?, org?, name?, app_id?, version?, accent?, node_url?}` | builds the platform's Android app again (a new version, name, accent or app id) |
| `platform_client_status {platform?, org?}` | how that build stands (`building` with its step, `done` with the download address, `failed` with the error and the build's last output) |

The server SDKs' `Aseman.developer()` uses the key (`models`, `chat`,
`platform(namespace, action, body)`, `catalog`); `DEVELOPER.md` in the project
says when (a model call no agent is meant for, the platform's own product
surface) and the wiring check refuses the key in page code or written into
source. Governance classifies `platform_publish` and `platform_client_build`
as sends, `platform_setup` and `app_developer_access` as writes and
`platform_client_status` as a read, so a space's approval rules apply.

**End to end.** `internal/plugins/host/testdata/platform` boots a whole node
from the native plugins and proves the flow: a person's Builder agent, through
the real agent gateway, sets up the organization and platform, starts the app
with `appui_create`, gives it developer access, writes it on the space's
computer, passes `appui_publish` (the real kit: wiring check, widget on QuickJS,
start), and `platform_publish`es it. Then a visitor and a signed-in person of
the platform use it: the app's server asks the space's Advisor agent and calls
its Pricing app (a real MCP server) for them, uses the developer API, and an
agent the app is not wired to is refused. Run it after `make plugins`, as root
on a throwaway machine (the space's computer is that machine):
`ASEMAN_PLATFORM_E2E=1 go test ./internal/plugins/host -run PlatformE2E`.

The gateway serves it at **`/v1/platforms/{slug}/app/`**:

| | |
| --- | --- |
| Visitors (signed out) | see its pages; no person headers, no page API |
| Signing in | `_aseman/auth/login`, `register`, `logout`, `GET _aseman/auth/me` — platform-local accounts; the session stays in the frontend's HttpOnly cookie |
| Who may use it | the platform's accounts, the organization's members, and main Aseman when bridged (`main_access`) |
| Its server | gets `X-Aseman-Platform*` and, for a signed-in person, a **platform user token** (`X-Aseman-User-Token`) |
| Agents and apps | page and server calls run as — and are billed to — **the person who published the frontend**, name the platform's person on the usage record (`via`), and reach **only the wired** agents, apps and microtools; desk windows and space files are not served |
| Asleep | woken for whoever opens it, from anywhere, as the publisher (who pays for the computer): see *Waking* below |

**Waking.** A platform's frontend runs on a space's computer, and the
computer sleeps when idle. Waking it is not a space mechanism: the
platform's people (and visitors who have not signed in) are not the space's,
and they open the frontend from any device. So the gateway wakes it for
anyone (`spaces/platform_wake.go`):

| | |
| --- | --- |
| `GET`/`POST _aseman/wake` | no sign-in: starts a wake unless the app answers, and reports `{state: ready \| waking \| failed, ready, error, retry_after_ms}`; `?wait=<s>` (≤ 25) waits for it. The platform's clients call it when opened and when brought back |
| A request that finds the app down | starts the wake (or joins the one under way) and waits up to 25 s; a browser opening a page gets a *waking up* page after 3 s that asks `_aseman/wake` and reloads when the app answers; anything else a `503` with `Retry-After` |
| One wake at a time | per frontend, shared by everyone who arrives meanwhile; a failed wake (say, the publisher's wallet cannot pay for the computer) is reported for 15 s instead of retried by each visitor |
| Kept awake | each request the frontend serves renews the computer's lease (at most every 20 s), so it does not fall asleep under its people |

An Elpian program's host (`ElpianAppHost.onAsleep`) wakes the computer and
sends a request again when the app answers 503 mid-session.

**A platform's own Android app.** An Elpian frontend gets a lightweight app
of its own: `app/platform_client`, the Elpian engine, the UI kit and the
Elpian host the Aseman client runs frontends with (264 files of the app,
listed in `app/platform_client/tool/shared.txt` and copied in by
`tool/assemble.sh` — the engine is the app's own, never a fork), plus
sign-in to the platform's accounts and the wake above; nothing else of
Aseman (no workspace, no Elpian VM native library, no Godot). Its
`assets/client.json` names the frontend's address — the platform's door to
the Elpian app's proxy, `<ASEMAN_PUBLIC_URL>/v1/platforms/<slug>/app/`.

1. `platform_publish` (by an agent) or **Frontend → Publish** (in the
   console) starts the build for an Elpian frontend;
   `platform_client_build`, or **Android app → Build** in the console, builds
   it again.
2. It runs on the frontend space's computer, detached (it takes minutes,
   and the computer runs one command at a time for everyone):
   `aseman-platform-client build` (`deploy/sandbox-computer/platform-client`)
   copies the client kit the sandbox image carries
   (`/opt/aseman-platform-client`), writes the platform's address, name,
   accent and Android application id (default `io.aseman.platform.<slug>`,
   kept across builds), and signs with the platform's own key
   (`/workspace/.aseman/platform-clients/<slug>/`, made on the first build),
   so every version installs over the one before. The first build on a
   computer downloads Flutter and the Android SDK into `/opt/aseman-toolchain`;
   `--build-arg WITH_ANDROID_TOOLCHAIN=1` bakes them into the image. The
   computer's network must reach pub.dev, Google's Maven and Maven Central
   (`ASEMAN_MAVEN_MIRROR` names a mirror of it), and, without a baked
   toolchain, storage.googleapis.com and dl.google.com. A build wants about
   4 GB of memory and, with the toolchain, 6 GB of disk on the computer
   (`sandbox.memory_mb`, `sandbox.disk_mb`); the APK (arm and arm64) is
   about 48 MB, within the 64 MB a stored file may be.
3. The node looks at the build every 15 s (which keeps the computer awake for
   it), then stores the APK as a file of the space, records it on the
   platform (`dev_platforms.client_*`) and, when an agent asked, posts it in
   the room with its download address.
4. Anyone downloads it at **`/v1/platforms/<slug>/client/android.apk`**, signed
   in or not, while the computer sleeps too. The public `platform_frontend`
   names it (`client.android`) and the wake door (`frontend.wake`).

Opening the app (or bringing it back) wakes the platform's computer; people
sign in to and up on the platform's own accounts in it, and the frontend
runs full screen as them. A web frontend needs no app: its people open its
address in any browser, which wakes the computer the same way. The node
needs `ASEMAN_PUBLIC_URL` (a phone must reach it); an agent may name another
address with `node_url`.

**A platform's own client.** Build the Aseman client for one platform with
`--dart-define=ASEMAN_PLATFORM=<slug>` (the web image: `docker build
--build-arg ASEMAN_PLATFORM=<slug> app`), or open a web build with
`?platform=<slug>`. Its sign-in screen carries the platform's name and signs
people in to — and up on — the platform's own accounts (password, Google,
Apple, password reset and email verification all pass `platform`; enterprise
SSO stays main Aseman's). Home is the published frontend, full screen: an
Elpian frontend runs natively (`ElpianAppView` on the platform path), a web
one in the in-app web view. A menu reaches the regular workspace and signs
out. A platform with no frontend yet opens the workspace. The console's
**Open** button runs the frontend for the owner.

Password reset and email verification look the account up within its
environment: an email is unique per platform, so the same address on main
Aseman and on a platform are two accounts.

### 8.4 Building a product on Aseman

1. Create a developer org + API keys (Platform permission).
2. Create a platform (`slug`).
3. Point your client at the node API; register/login with `platform: "<slug>"`.
4. Optionally use the developer host for models/computers and `POST /v1/platform/{ns}/{action}` for automation as the key creator.
5. Or skip writing a client: have a space's agents build the frontend and publish it (§8.3). An Elpian frontend gets the platform's own Android app, downloadable at `/v1/platforms/<slug>/client/android.apk`.
6. Or describe the whole product as one workflow installer document and run it (`docs/WORKFLOWS.md`): every step above, repeatable.
7. Ask the node admin to **Bridge to Aseman** only if you want shared discovery with the main app.

---

## 9. Agents, harness & sandboxes (detail)

### 9.1 Bot kinds

| Kind | Meaning |
| --- | --- |
| `agent` | LLM assistant on harness |
| `tool` | App / backend (MCP, Elpian, QuickJS, installed, wasm, docker, …) |
| `theme` | Installable UI theme pack (no VM) |

### 9.2 Turn lifecycle

Person or system starts work → `spaces.turn_*` / `spaces.ask` → harness session for agent×room → tools, LLM, memory, timeline under turn token → results stream to the room; cancel/resume supported. Billing meters runtime + tokens via finance pools/charge lines.

### 9.3 What agents may call

Outer bound: `agentpolicy` (account vs space scope). Inner bound: each action’s own authorization. Code Mode exposes a **capability OpenAPI** per space (apps, platform tools, timeline, sandbox ops) so models search/execute instead of loading every tool schema.

### 9.4 Isolation of compute

- Sandboxes can use gVisor (`ASEMAN_SANDBOX_RUNTIME=runsc`)
- Outbound via `aseman-egress`
- Governance can gate or take over computers

---

## 10. Finance (brief but complete)

- **Wallet** per account (and per developer org id for API billing).
- **Ledger** with global sequence on the central node; peers replicate.
- Charges for LLM, bot minutes (CPU/RAM/disk dimensions), storage, developer API usage, etc.
- Restricted/complimentary credits cannot always move to the developer API or peer transfers.
- Node admin: mint, reconcile, purchases, payouts, provider costs.

---

## 11. Client architecture

```
app/lib/src/
  app.dart / app_dependencies.dart
  core/          network, theme, settings, formatting
  data/          AsemanService, ApiClient, models, capabilities
  domain/        shared domain models (room, message, …)
  features/      one folder per product area (see below)
  shared/        SoftCard, glass, overlays, inputs, skeletons
  elpian/        in-tree Elpian VM engine
  agui/          AG-UI fence rendering
```

Feature folders in use: `account`, `admin`, `agents`, `assistant`, `auth`, `brain`, `calls`, `computer`, `desk`, `developer`, `explore`, `files`, `gadgets`, `home`, `market`, `marketing`, `messenger`, `navigation`, `rooms`, `search_feed`, `settings`, `talent`, `tools`.

Large presentation hubs are split with Dart `part` files so private helpers stay shared:

- `developer_console` → pages / platform  
- `workspace_screen` → explore / profile / library / desk / social  
- `admin_page_content` → people / catalog / finance / AI / ops / editors

- **ApiClient** posts signed calls to `/v1/{ns}/{action}`.
- **Theme packs** (`aseman.theme/v1`) drive `AsemanTokens`, `ThemeChrome`, shell slots, SoftCard recipes. Packs may contribute **islands** (Elpian UI sections), not App UI gadgets.
- **Elpian** hosts App UI window and gadget frontends; native packages for VM/Godot where needed.

---

## 12. Deploy & operations

Documented in depth in `deploy/README.md`. Highlights:

- **Caddy** terminates TLS for `APP_DOMAIN`, `API_DOMAIN`, optional `DEVELOPER_DOMAIN`.
- **Credentials:** LLM keys and sensitive secrets encrypted with material derived from the node identity — back up `data/node-*.key` with the database.
- **Images:** sandbox-computer, harness, tool-runtime built in CI/compose; Nomad runs jobs.
- **Env groups:** admin password, Postgres, sandbox backend, Modal, OAuth, push (APNs/FCM), TURN, email, RevenueCat, LLM bootstrap, developer host, SPIRE, timeline toggles.
- **Health:** `/healthz`; Admin → health / plugins / wiring.
- **Telemetry policy:** see `docs/telemetry.md`.

---

## 13. Extending the node

1. **New namespace:** copy the greeter sample under `plugins/actions/`, implement `NewPlugin` + `BuildActions`, register models, bridge only outward.
2. **New adapter provider:** implement the category port under `plugins/adapters/<category>/<name>/`.
3. **Build:** `make plugins` (CGO, `-buildmode=plugin`); load via Admin/CLI.
4. **Replace live:** `plugins-replace` validates, drains, starts; rolls back on failure.
5. **Respect agentpolicy** if agents should call you; never put node-admin power on agent-reachable paths without gates.

---

## 14. Glossary

| Term | Meaning |
| --- | --- |
| **Node** | One Aseman daemon instance (and its id on the federation mesh) |
| **Namespace** | Action plugin owning a product area (`spaces`, `bots`, …) |
| **Action** | Single callable `ns.name` with JSON body |
| **Bridge** | Reflective cross-namespace service call |
| **Adapter / port** | Swappable infrastructure behind a category interface |
| **Space** | Workspace (home, project, or direct) |
| **Room / thread** | Conversation container; thread = child room |
| **Bot** | Agent, app, or theme record (often backed by a VM) |
| **Harness** | Agent runtime (DeepSeek Harness + Aseman Cordis plugins). Legacy VMM name `deepagents` remaps to harness. |
| **Sandbox** | Per-space Linux computer |
| **Desk** | Floating window surface inside a space |
| **Gadget** | Compact frameless App UI widget (gadget mode) over chat/rail/desk/page |
| **Turn** | One agent work unit in a room |
| **Developer org** | Team (or personal) owner of API keys, computers, optional platform |
| **Platform** | Isolated product environment on one node (`dev_platforms`) |
| **Main Aseman** | Empty `platform_id` — the shared app environment |
| **Main access** | Admin boolean bridge between one platform and main |
| **Universal ID** | `node(16hex)+entity(16hex)` address |

---

## 15. Further reading

| Doc | Topic |
| --- | --- |
| `README.md` | Quickstart, compose, first admin login |
| `services/README.md` | Node architecture, IDs, signing, federation |
| `services/plugins/README.md` | Plugin layers, build, replace, bridge rules |
| `deploy/README.md` | Domains, env, Caddy, shipping |
| `app/README.md` | Flutter run defines, OAuth for apps |
| `CHANGELOG.md` | Recent product changes (gadgets, harness, themes, developer/platforms) |
| `deploy/sandbox-computer/appui/elpian/GADGETS.md` | App UI gadget mode |
| `services/plugins/adapters/vmm/harness/runtime/README.md` | Agent runtime internals |
| `docs/telemetry.md` | Telemetry policy |

---

*Aseman’s modular bet: a fixed kernel, swappable infrastructure, and product features as loadable namespaces — so the same node can host the social AI workspace, an OpenAI-compatible developer door, and isolated platforms without forking the stack.*
