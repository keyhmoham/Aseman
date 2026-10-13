# Tradera Flutter client

The Flutter client for the **Tradera** federated super app. Every screen is
connected to the Tradera Go gateway (`services/`): a federated, decentralized
VM platform where users publish posts, build workspaces (each account gets a
home workspace), deploy and chat with **agents** (langchain bots), and run
**miniapps** — wasm-backed bots whose **elpian** frontends render inside the
client's sandbox and surface as *tools*.

## Run

```bash
flutter pub get
# point the app at your Tradera node:
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080
# android emulator default: http://10.0.2.2:8080 (set in app_dependencies.dart)
```

## How the client talks to the server

Every action is an HTTP `POST /v1/{namespace}/{action}` carrying a JSON body.
Authenticated requests are **Ed25519-signed** with the account's identity key
(`core/network/signing.dart`) over the canonical payload
`method\npath\nnonce\ntimestamp\nsha256(body)` and carry the session bearer
token. This is what lets a miniapp frontend call its backend "as the user":
the backend always sees the signed-in user's identity.

## Elpian miniapps

The Elpian engine is part of the app, not a dependency: its Flutter host is
copied into `lib/src/elpian` (rendering engine, Elpian VM and QuickJS
runtimes, miniapp host, A2UI renderer — see its README), its native VM
library into `packages/elpian_vm_native`, and its web runtimes into
`assets/elpian`. A miniapp is a
bot whose `frontend` field holds a `{ manifest, source }` bundle. The
`MiniappSandboxScreen` runs the bundle inside an `ElpianVmWidget` (QuickJS
runtime) with host handlers wired by `features/miniapps/elpian/miniapp_bridge.dart`:

| host API        | backend action                      |
|-----------------|-------------------------------------|
| `server.call`   | `message.ask` → wasm backend reply   |
| `host.request`  | `message.ask` (alias)                |
| `host.send`     | `message.send` (fire-and-forget)     |
| `ctx.user`      | the signed-in user context           |

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
    │   ├── services/               # TraderaService (real) + Mock (tests)
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

## Agent task compatibility

Open a room and select **Agent tasks** to track Tradera's stages and outcome.
The panel supports partial completion, budget exhaustion, interruption,
question-bound answers, cancellation, execution review and delivered artifacts.
Report attachment links use authenticated file cards; preview links use the
configured gateway. Runtime instructions and skill selection stay on the server.
See the [workflow feature](lib/src/features/workflows/README.md) for its boundaries
and regression coverage.

```bash
flutter analyze lib test
flutter test
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=same-origin
```
