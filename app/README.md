# Aseman Flutter client

The Flutter client for the **Aseman** federated super app. Every screen is
connected to the Aseman Go gateway (`services/`): a federated, decentralized
VM platform where users publish posts, build workspaces (each account gets a
home workspace), deploy and chat with **agents**, and add **apps** — a
backend (an MCP server, an Elpian VM, QuickJS or docker program, or one
installed into the space's sandbox) and the frontend it is used through. On
the wire an app is a bot of kind `tool`, served by the `tools` namespace.

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

## Signing in to apps

An app registered with "each person connects" (`auth: user`) asks for the
person's own account where it is used: when it is added with "Add an app"
(workspace Apps library or Project → Apps), on its screen, and under
Project → Apps. Sign-in is OAuth with PKCE run by the
node (`tools.oauth_prepare` / `oauth_exchange`): the app only opens the
provider's page and brings the code back, then stores the connection from the
sign-in (`tools.connection_set` with its `grant`) so the node renews it. On
the web the page opens in a popup that returns to `/oauth.html`; on Android,
iOS, macOS and Windows in an in-app web view that stops at the redirect;
elsewhere in the browser, with the returned address pasted back. A provider
that will not register Aseman needs an OAuth client: a person can enter one
in the connect dialog, or an admin saves one per server (Admin → Apps →
Sign-in client), created with the redirect address shown there. Override that
address with `--dart-define=OAUTH_REDIRECT_URI=…`. A pasted access token works
too, without renewal.

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
runtimes, app host, A2UI renderer, the Godot `Scene3D` widget — see its
README), its native VM library into `packages/elpian_vm_native`, the
embedded Godot engine into `packages/elpian_godot_native`, and its web
runtimes into `assets/elpian`. An app's static frontend is a
`{ manifest, source }` bundle in its bot's `frontend` field. The
`AppFrontendScreen` runs the bundle inside an `ElpianVmWidget` (QuickJS
runtime) with host handlers wired by `features/tools/elpian/app_bridge.dart`:

| host API        | backend action                      |
|-----------------|-------------------------------------|
| `server.call`   | `message.ask` → wasm backend reply   |
| `host.request`  | `message.ask` (alias)                |
| `host.send`     | `message.send` (fire-and-forget)     |
| `ctx.user`      | the signed-in user context           |

## Apps

Apps are created from one form (`features/tools/presentation/tool_create_form.dart`,
"My bots → Create → App") with a **backend** — external (an MCP server),
managed (an Elpian VM, QuickJS or docker backend the node runs) or installed
(into each space's sandbox) — and a **frontend**:

* **static** — an Elpian program the app runs on the Elpian VM (bytecode) or
  QuickJS, with `ToolFrontendHost` as its host: `tool.call(microtool, args)`,
  `tool.microtools()`, `tool.context()` (with `display`: `full`, `compact`
  or `sheet`), `tool.compact(summary)` (its phone widget) and
  `tool.expand()`;
* **generative** — A2UI the node generated from the deployer's skill (cached
  in its component registry) rendered with Flutter's genui by `GenUiView`
  (`lib/src/genui`: Aseman's catalog in the app's design language), its
  buttons running microtools through `tools.frontend_action`.

Tools open as card windows on the room's desk (`features/desk`): a
floating, scrollable desk of windows people and agents open, move, resize,
pin and close (all animated), with a dock of the open tools pinned to its
bottom and a pinned desk of shortcuts. Agents' composed widgets are desk
windows too, their `ToolFrontend` components embedding tools' own
frontends; nothing of a tool's interface goes into the chat.

On phones (narrower than 600 px) the desk is a board of **compact
widgets** instead (`CompactDesk`): each window shows the minimal information
about its data — an A2UI surface's own `compact` component, or a summary
derived from its components; a static program's `tool.compact` summary, or
a live miniature — in one of five shapes (card, squircle, pill, circle,
leaf) and three sizes. Long-press drags a widget to a new place; tapping
opens the full frontend, phone-wide, in a bottom sheet. Every frontend reads
how it is shown from `FrontendPresentation` (`lib/src/genui`), and the board
arrangement is kept on the node with each window (`compact`, the desk's
`arrange` op).

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
        ├── search_feed/            # Post feed + search (server-backed)
        ├── home/                   # The workspace desk + room library
        ├── agents/                 # Bot list, create, lifecycle, chat
        ├── workflows/              # Room tasks, verification, recovery, delivered files
        ├── market/                 # Publish / browse / install agents+miniapps
        ├── miniapps/               # elpian sandbox + host bridge
        ├── wallet/ chats/ explore/ admin/ settings/
        └── navigation/             # Super-app shell (rail + destinations)
```

View models own mutable UI state and commands; repositories own data; the
service isolates the remote (signed) infrastructure. Offline/mock mode falls
back to bundled showcase data so the UI stays testable without a node.

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
