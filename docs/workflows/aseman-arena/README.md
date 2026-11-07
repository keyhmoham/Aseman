# Aseman Arena — a 3D gaming platform, as one workflow

[`../aseman-arena.json`](../aseman-arena.json) brings up **Aseman Arena** on an
Aseman node: an organization with its platform, a project whose agents build
games with the players, two official Godot games built from source, and the
platform's server and native Elpian frontend — published as the platform's
frontend with an Android app of its own.

What a player gets:

- **A 3D home of their own** — a workshop garage or a research lab, drawn by
  the Godot engine embedded in the Aseman client (`Scene3D`), furnished with
  Poly Haven's CC0 models (roller door, the covered project car, tool chest,
  the gaming corner, a trophy shelf that fills with achievements, arcade
  cabinets for the store's games) and their own robot avatar.
- **Rooms** — a grid of 3D rooms to join, or one of their own: each room is
  **bound to one game of the store** and has a venue in 3D (neon arena,
  rooftop, lab, garage, lounge) where the members stand around the game's
  stage; chat, members, invitations, the room's own board, and **Play**,
  which mounts the game itself in the room's `Scene3D`.
- **Games against AI opponents** — every game is single-player against AI
  participants. A match gets a one-time token; the game reports its result
  through the engine; the server checks it is believable and rates it.
- **Leaderboards, profiles, communication** — Elo ratings per game (against
  the AI's level), best scores, weekly boards, experience and levels,
  thirteen achievements, profiles with records and trophies, friends,
  direct messages, notifications, reviews in the store, reports.
- **The Game Forge** — describe a game, chat with the Forge agent, and it
  builds it (Godot 4.3, AI opponents, CC0 models), tests it, exports it and
  submits it; the player play-tests it (also in a private room) and
  publishes it to the store, where anyone can host it in a room.

## The official games

| | |
| --- | --- |
| **Arena Chess** ([`games/chess`](games/chess)) | The complete Laws of Chess in GDScript — legal moves, castling with every condition, en passant, promotion, check, checkmate, stalemate, the fifty- and seventy-five-move rules, threefold and fivefold repetition, insufficient material, FEN and SAN — checked by **perft** against five published positions. The AI: iterative-deepening principal-variation search with a transposition table, null-move pruning, late-move reductions, quiescence, MVV-LVA/killer/history ordering and a tapered PeSTO evaluation, on a worker thread; five levels from forgiving to club strength. Poly Haven's marble Staunton set (turned pieces of its own when offline), tap-to-move with the legal squares, animated moves and captures, promotion picker, clocks, take-back, draw claims and offers, resignation, the PGN. |
| **City Strike** ([`games/city-strike`](games/city-strike)) | A third-person shooter in a generated city: Kenney's roads, shops and trucks, Poly Haven's street props and covered car, glass towers with lit facades, traffic circling the plaza. Quaternius' robot characters carry Kenney's blaster. AI squads see (field of view, line of sight), hear shots and call each other; they patrol, engage with human reaction time and aim error, strafe, break for cover behind cars and street furniture, heal and peek back out, and hunt the last place they saw you — on an A* navigation grid built from the city. Waves, supply drops, radar, kill feed, hit markers, damage direction, keyboard/mouse, gamepad and touch controls. |

Both run three ways: as a **Web export** (practice in any browser), mounted
from their **resource pack** inside the Aseman client's `Scene3D` (the
`pack` node: `arena_start(params)` in, `arena_event(json)` out), and
**headless** in their tests (`tests/run_tests.gd`).

All 3D models are **CC0**, pinned in [`games/assets.json`](games/assets.json)
and fetched at build time by [`games/fetch_assets.py`](games/fetch_assets.py)
(Poly Haven's glTF, packed into single `.glb` files where the client loads
them at run time); every build writes `LICENSES.md` beside the models.
[`games/godot_setup.py`](games/godot_setup.py) installs the Godot 4.3 editor
(the engine the client embeds) and reads only the two Web templates it needs
out of the 1 GB template archive with HTTP range requests.
[`games/build.sh`](games/build.sh) fetches, imports, tests and exports.

## What the workflow makes

| Step | What |
| --- | --- |
| `org`, `team`, `platform` | the platform's organization, its developers, the platform (its players have their own accounts) |
| `server_key`, `server_secrets` | a developer key for the server (`platform: write`), `ensure`d and sensitive, and an internal token, written once to `/workspace/secrets/<slug>/server.env` |
| `space`, `forge_room`, `team_room` | the project; each Forge project talks in its own thread of **Forge** |
| `forge` | **the Game Forge agent**: designs and builds games with the players and submits them with `tools/arena_forge.py` |
| `helpers` | the **Steward** (community, reports, weekly highlights) and the **QA** tester (tests games against the contract) |
| `app_files` | the server and the Elpian frontend written to `/workspace/apps/<slug>`, its 19 tests run |
| `games` | the garage models fetched, both games fetched, imported, tested headless, exported as packs and Web builds, and checked against the game contract |
| `install`, `healthy` | the Elpian bundle built, the platform served on the port, until it answers with its two games |
| `store_check` | **proof**: `tools/arena_smoke.py` opens a garage, a room, plays and rates a match, as a system player kept off the boards |
| `elpian_app` | `appui_publish`: the platform runs the frontend on QuickJS against the server and replays its end-to-end scenarios |
| `frontend` | `platform_publish`: it becomes the platform's frontend, and its Android app is built (with the Godot engine: `godot_in_app`) |
| `forge_proof` | optional (`forge_demo`): the Forge agent builds a small game from a brief through the running platform |

Inputs: `product`, `slug`, `developer_api_url` (the developer API as the
space's computer reaches it), `public_url` (the node as players' devices
reach it: models and packs download from
`<public_url>/v1/platforms/<slug>/app/`), `agent_model`, `team`, `port`,
`web_builds`, `publish_frontend`, `android_app`, `godot_in_app`,
`forge_demo`.

## Install or update: `deploy.sh`

```bash
docs/workflows/aseman-arena/deploy.sh --server https://aseman.example.com
```

It bundles the source into the workflow, runs the server's tests, checks
both games against the contract (`--games` also runs their headless tests),
runs the Elpian frontend on QuickJS with its end-to-end scenarios against a
fresh server, signs in when there is no session, validates on the node,
shows the plan, asks, runs and follows the workflow, and keeps the run so a
failed one resumes (`--resume`). `--public` is the node as players reach it
(default `--server`); `--dev-api` the developer API as the project's
computer reaches it (in the Docker stack: `http://aseman:8080/dev/v1`).

By hand, from the console door (it creates an organization and a key):

```bash
aseman workflow run docs/workflows/aseman-arena.json developer_api_url=https://aseman.example.com/dev/v1 public_url=https://aseman.example.com
```

## The server (`app/`)

Standard library Python and SQLite (`/workspace/data/<slug>/arena.db`, kept
across reinstalls).

- `arena.py` — the rules: Elo against the AI's level (provisional players
  move faster), experience and levels, achievements, what a believable
  result looks like (outcome, score bounds, no win faster than the game
  allows, no more time than has passed), room themes, the store manifest's
  contract (single-player, AI declared, a `res://` scene, Godot 4.3), chat
  hygiene.
- `store.py` — people and garages, games and reviews, rooms, members and
  chat, matches, ratings and weekly scores, achievements, friends, direct
  messages, notifications, Forge projects and their conversations, reports.
- `server.py` — the API (people, garage, rooms, matches and results,
  leaderboards, friends, messages, notifications, store and reviews, the
  Forge, internal routes for builds), the files (the Elpian bundle, garage
  models, packs and Web builds), the web hub (`public/`). People are known
  by the platform's gateway (`X-Aseman-User`); what one player sees of
  others carries handles, never platform ids. Visitors read the store,
  rooms and boards.
- `forge.py` — the Forge agent's brief and the developer API door
  (`/platform/spaces/ask`, in the project's own thread when the node opens
  one).
- `tools/arena_forge.py` — the agent's `check` and `submit`: the contract,
  the headless tests, the pack and Web exports, the hand-over.
- `tools/arena_smoke.py` — the end-to-end proof the workflow runs.
- `data/garages.json` — the garage and lab layouts.
- `elpian/` — the native frontend: `scenes.js` (garage, room venues and the
  game mount as Scene3D scenes), `garage.js`, `rooms.js`, `play.js`,
  `store.js`, `ranks.js` (leaderboards and profiles), `social.js`,
  `forge.js`, `main.js` (navigation, live updates, the phone widget);
  `e2e/*.json` are the journeys the platform replays before it opens the
  app.

Locally (no Aseman needed):

```bash
cd docs/workflows/aseman-arena
python3 games/fetch_assets.py garage --out app/public/assets/models
games/build.sh all --out /tmp/arena-games          # fetch, test, export both games
cd app && python3 test_app.py
GAMES_DIR=/tmp/arena-games ASSET_BASE=http://127.0.0.1:8080/ python3 server.py
```

The Elpian frontend, with the kit in `deploy/sandbox-computer/appui/elpian`
(QuickJS from `cd deploy/tool-runtime && npm ci`):

```bash
KIT=../../../../deploy/sandbox-computer/appui/elpian
node $KIT/bundle.mjs .
node $KIT/check.mjs elpian/app.js --server http://127.0.0.1:8080
node $KIT/drive.mjs run elpian/e2e --dir . --bundle elpian/app.js --server http://127.0.0.1:8080
```

After changing anything under `app/` or `games/`, refresh the workflow's
assets: `python3 docs/workflows/aseman-arena/bundle.py`.

## The engine pieces it needs

The Elpian scene DSL gained two nodes for this platform
(`app/lib/src/elpian/godot/scene_assets.dart`): **`model`** loads a glTF by
address into the `Scene3D` (fetched with an `HTTPRequest` node into the
device's cache, built with `GLTFDocument`), and **`pack`** mounts a Godot
resource pack and instances one of its scenes — a whole game — reporting
its events to the program as `gameevent`. A hand-built app's `READY.json`
can say `"audience": "platform"`.
