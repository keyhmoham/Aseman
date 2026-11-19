# Aseman Flutter client

The Flutter client for the **Aseman** federated super app. Every screen is
connected to a Decillion node's gateway (by default
`https://preview.decillionai.com`, or a self-hosted one; see `../aseman.sh`
and `../render.yaml`): a federated, decentralized VM platform where users
publish posts, build workspaces (each account gets a home workspace), deploy
and chat with **agents**, and add **apps** — a backend (an MCP server, an
Elpian VM, QuickJS or docker program, or one installed into the space's
sandbox) and the frontend it is used through. On the wire an app is a bot of
kind `tool`, served by the `tools` namespace.

## Run

```bash
flutter pub get
# point the app at your Aseman node:
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
# android emulator default: http://10.0.2.2:8080 (set in app_dependencies.dart)
# optional: where the developer API answers, shown in Profile → Developer API
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080 \
  --dart-define=DEVELOPER_API_BASE=https://api.example.com/v1
```

## Finding and signing in to apps

Apps are found in the **MCP directory** (Glama), read by the node with its own
key: Add an app (workspace Apps library, a project's Apps, a chat) searches it,
filters it by sign-in, shows each server's tools and adds one in a tap
(`features/tools/connect/mcp_directory_view.dart`, `tools.glama_*` /
`mcp_install`). Glama's licence asks for its credit on the screen and a link to
each listing; both are shown. Without a key on the node the directory says so
and an app can still be added by its address.

An app registered with "each person connects" (`auth: user`) asks for the
person's own account, once: at its own provider, never through Glama. The node
runs the sign-in (OAuth 2.1 with PKCE, `tools.mcp_connect_start` /
`mcp_connect_finish`): the app only opens the provider's page and brings the
code back, so no token ever reaches it. On the web the page opens in a popup
that returns to `/oauth.html`; on Android, iOS, macOS and Windows in an in-app
web view that stops at the redirect; elsewhere in the browser, with the
returned address pasted back. A provider that will not register Aseman needs an
OAuth client: a person can enter one in the connect dialog, or an admin saves
one per server (Admin → Apps → Sign-in client), created with the redirect
address shown there. Override that address with
`--dart-define=OAUTH_REDIRECT_URI=…`. An app with no sign-in page takes a key
or a login (`mcp_connect_token`), checked with the app before it is kept. One
sign-in serves every space the app is added to.

**Agents add apps as the work needs them** (`mcp_find`, `mcp_add`, `mcp_use`,
`mcp_list`, `mcp_remove`, served by the node). Whatever needs the person's
sign-in arrives as a **login card** in the chat: an AG-UI `Connect` surface in
a room (`agui/governance_cards.dart`, drawn by
`features/tools/connect/mcp_login_card.dart`) and a `connect` card above the
composer of the personal chat (`brain_proposals.dart`). The card asks the node
whether the person is signed in and says so wherever it is read.

## How the client talks to the server

Every action is an HTTP `POST /v1/{namespace}/{action}` carrying a JSON body.
Authenticated requests are **Ed25519-signed** with the account's identity key
(`core/network/signing.dart`) over the canonical payload
`method\npath\nnonce\ntimestamp\nsha256(body)` and carry the session bearer
token. This is what lets an app's frontend call its backend "as the user":
the backend always sees the signed-in user's identity.

## Elpian frontends

The Elpian engine is part of the app, not a dependency: its Flutter host is
copied into `lib/src/elpian` (rendering engine, Elpian VM and QuickJS
runtimes, app host, the Godot `Scene3D` widget — see its README), its native
VM library into `packages/elpian_vm_native`, the embedded Godot engine into
`packages/elpian_godot_native`, and its web runtimes into `assets/elpian`.
An app's static frontend is a `{ manifest, source }` bundle in its bot's
`frontend` field. The `AppFrontendScreen` runs the bundle inside an
`ElpianVmWidget` (QuickJS runtime) with host handlers wired by
`features/tools/elpian/app_bridge.dart`:

| host API        | backend action                      |
|-----------------|-------------------------------------|
| `server.call`   | `message.ask` → wasm backend reply   |
| `host.request`  | `message.ask` (alias)                |
| `host.send`     | `message.send` (fire-and-forget)     |
| `ctx.user`      | the signed-in user context           |

A platform's published Elpian frontend also gets an Android app of its own:
`platform_client/`, a separate Flutter package with only this engine, the UI
kit and the Elpian host (shared from `lib/`, listed in
`platform_client/tool/shared.txt`) plus sign-in to the platform's accounts.
See its README and `docs/PLATFORM.md` §8.3.

## Apps

Apps are created from one form (`features/tools/presentation/tool_create_form.dart`,
"My bots → Create → App") with a **backend** — external (an MCP server),
managed (an Elpian VM, QuickJS or docker backend the node runs) or installed
(into each space's sandbox) — and a **frontend**:

* **static** — an Elpian program the app runs on the Elpian VM (bytecode) or
  QuickJS, with `ToolFrontendHost` as its host: `tool.call(microtool, args)`,
  `tool.microtools()`, `tool.context()` (with `display`: `full`, `compact`
  or `sheet`), `tool.compact(summary)` (its phone widget) and
  `tool.expand()`.

Tools open as card windows on the room's desk (`features/desk`): a
floating, scrollable desk of windows people and agents open, move, resize,
pin and close (all animated), with a dock of the open tools pinned to its
bottom and a pinned desk of shortcuts. Sandbox web pages are desk windows;
tool UIs do not go into the chat.

On phones (narrower than 600 px) the desk is a board of **compact
widgets** instead (`CompactDesk`): each window shows a compact summary — a
static program's `tool.compact` summary, or a live miniature — in one of
five shapes (card, squircle, pill, circle, leaf) and three sizes.
Long-press drags a widget to a new place; tapping opens the full frontend,
phone-wide, in a bottom sheet. The board arrangement is kept on the node
with each window (`compact`, the desk's `arrange` op).

## Architecture

```text
lib/
├── main.dart                       # Process entry point
└── src/
    ├── app.dart                    # Material application (auth-gated)
    ├── app_dependencies.dart       # Composition root / dependency injection
    ├── core/
    │   ├── network/                # Signing, session store, API client
    │   ├── settings/ theme/ utils/ # Theme, breakpoints, shared utilities
    ├── data/
    │   ├── models/                 # Server-aligned entities (space, bot, post...)
    │   ├── services/               # AsemanService (real) + Mock (tests)
    │   └── repositories/           # Sources of truth and caching
    ├── shared/widgets/             # Reusable design-system components
    └── features/
        ├── auth/                   # Login / register + auth gate
        ├── navigation/             # AppShell: Pulse feed root, push workspace
        ├── search_feed/            # Pulse home (Chats / Explore / You)
        ├── home/                   # Workspace desk, rooms, bots, facilities
        ├── messenger/              # DMs and chat surfaces
        ├── desk/                   # Floating framed windows in a space
        ├── gadgets/                # Compact frameless App UI widgets
        ├── computer/               # Sandbox preview / computer host
        ├── rooms/                  # Room chat, turns, orbit strip
        ├── tools/                  # Apps, App UI, MCP, Elpian frontends
        ├── agents/                 # Bot list, create, lifecycle
        ├── market/                 # Publish / browse / install agents+apps+themes
        ├── files/ admin/ developer/ explore/ settings/ …
```

`AppShell` keeps Pulse (`SearchFeedScreen`) as the navigator root and **pushes**
`WorkspaceScreen` for a project; it does not use a permanent side-rail of
destinations. View models own mutable UI state and commands; repositories own
data; the service isolates the remote (signed) infrastructure. Offline/mock
mode falls back to bundled showcase data so the UI stays testable without a
node.

## Agent work in a room

A room shows its agents' work in one place each (`features/rooms`, driven by
`RoomWorkController` over `spaces.turn_log`, the `spaces.live` long poll and
`spaces.agent_questions`):

* **in the thread** — below the last message, who is working and on what, or
  the answer being written as it comes, and how many requests wait;
* **the composer** — its send button becomes Stop while agents work (it stops
  the room's running and waiting requests); a leading `/` offers the `/btw`,
  `/ask` and `/fresh` prompt commands;
* **above the composer, only when needed** — the answers to an agent's question
  (its question is its message in the thread), or Retry / Run again for work
  that did not finish;
* **Work** (header) — what runs and waits now (drop a waiting request) and what
  ran, with its time, outcome and error.

```bash
flutter analyze lib test
flutter test
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin
```
