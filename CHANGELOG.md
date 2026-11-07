# Changelog

## Unreleased: the workflow installer

- **Aseman Arena: a 3D gaming platform, brought up by one workflow.**
  `docs/workflows/aseman-arena.json` creates the organization, its
  platform and server key, a project with the **Game Forge** agent (players
  chat with it to build Godot games against AI opponents, which it tests,
  exports and submits with `tools/arena_forge.py`), a Steward and a QA
  tester; builds the two official games from source (`games/build.sh`:
  CC0 models from `games/assets.json`, the Godot 4.3 editor and only the
  Web templates, headless tests, resource packs and Web exports); installs
  the platform's server (rooms bound to games, matches with one-time tokens
  and plausibility checks, Elo ratings, levels, achievements, weekly
  boards, friends, direct messages, the store with reviews, the Forge) and
  proves it end to end (`tools/arena_smoke.py`); and publishes its native
  Elpian frontend — each player's 3D garage or lab, the rooms grid, room
  venues in 3D, the games mounted in `Scene3D` — as the platform's
  frontend with its Android app (Godot on). **Arena Chess**: the complete
  Laws of Chess (perft-checked) and a PVS/alpha-beta AI with five levels on
  Poly Haven's marble set. **City Strike**: a third-person shooter in a
  generated city against AI squads that see, hear, talk, take cover and
  hunt. `deploy.sh` installs or updates it; CI runs the server's tests, the
  games' headless tests and the frontend's end-to-end scenarios.
- **Scene3D loads models and whole games by address.** The scene DSL's new
  `model` node loads a glTF (cached on the device under its address and
  version) and `pack` mounts a Godot resource pack, instances its scene,
  starts it with `arena_start(params)` and reports its `arena_event` to the
  Elpian program as `gameevent` (`assetprogress`, `assetload`,
  `asseterror` too). A `Scene3D` that goes away stops its games; the
  embedded engine leaves a world with its own camera alone.
  Where there is no engine (the web client), a `pack` node with `web` — the
  game's browser build — runs that build in the `Scene3D` as an embedded
  page instead of the placeholder, and the page's `postMessage({arena: …})`
  events arrive as the same `gameevent`; the loader no longer tries to
  fetch packs or models without an engine.
- **Big files stream through app previews and platform doors.** The
  gateway read every proxied response whole and refused anything past
  32 MiB, so a game's engine (`index.wasm`, ~35 MB) or a large pack never
  arrived. What it does not rewrite (binaries, media, models, wasm) now
  streams through as it comes, with its length and caching headers and no
  whole-request time limit; pages, scripts and styles are read and rewritten
  as before.
- **An Elpian app knows its own address.** `Aseman.env().appUrl` is the
  app's address as this client reaches it, so a program builds the
  addresses the 3D engine downloads from on it instead of on a configured
  host name (`localhost` on a phone reaches the phone).
- **A hand-built app can be a platform's frontend.** `READY.json` (or
  `JOB.json`) may say `"audience": "platform"`, and `appui_publish` now
  gives an app written without `appui_create` its app key (and
  `.aseman/server.env`) for the person publishing it, as `appui_create`
  would have: the key is the app's record, so `platform_publish` finds it
  instead of answering "the app … is not published yet".

- **A platform's Android app in seconds: prebuilt, then post-processed.**
  The sandbox image now carries the platform client already built
  (`/opt/aseman-platform-client-apk/template.apk`, built with Flutter once,
  in the image's amd64 `platform-client-apk` stage), so publishing a
  platform's app no longer runs a Flutter build: `aseman-platform-client
  build` writes the platform into a copy (`apkpatch.py`: `client.json` with
  the frontend's address, name and accent; the binary manifest's
  application id — with the authorities and permissions named after it —
  label, version and cleartext flag; the resource table's package name; the
  asked ABIs), aligns it as `zipalign -P 16 4` does, signs it with the
  platform's key with `apksigner` and verifies it (certificate, manifest and
  `client.json` read back). About 3 s instead of minutes; the result is the
  same app a Flutter build of that platform makes (every entry byte for byte
  but the manifest, whose decoded tree is identical). Godot builds, `--full`
  and images without the template still build with Flutter.
  `--build-arg PREBUILD_PLATFORM_CLIENT=0` leaves the template out;
  `ASEMAN_MAVEN_MIRROR` works as a build arg. App ids are now at most 127
  characters (the resource table's limit).
- **A platform's own Android app, and waking from anywhere.** Publishing an
  Elpian app as a platform's frontend now also builds the platform an app of
  its own: the lightweight Elpian client (`app/platform_client`: the Elpian
  engine, the UI kit and the Elpian host — 264 files of the app, listed in
  `tool/shared.txt` and copied in when it is assembled, never forked — plus
  sign-in to the platform's accounts and nothing else of Aseman), with the
  frontend's address (the platform's door to the Elpian app's proxy) in it.
  `aseman-platform-client` builds it on the frontend space's computer,
  detached (Flutter and the Android SDK are fetched on the first build, or
  baked with `--build-arg WITH_ANDROID_TOOLCHAIN=1`); the node watches the
  build — which keeps the computer awake for it — stores the APK as a file
  of the space, records it on the platform and posts it in the room. Anyone
  downloads it at `/v1/platforms/<slug>/client/android.apk`, also while the
  computer sleeps. One signing key per platform (kept in the project's
  files) signs every version, so updates install over the last. Agents:
  `platform_publish` starts the build (`android: false` skips it),
  `platform_client_build` builds again (name, app id, version, accent),
  `platform_client_status` follows it. Console: an **Android app** card on
  the platform with Build and the download; `developer.platform_client_build`
  / `platform_client_status`; publishing an Elpian frontend from the console
  starts a build too. The public `platform_frontend` names the client and the
  wake door.
- **Godot in a platform's app: off by default, on when asked.** The
  lightweight client carries no Godot engine unless the build turns it on:
  a `Scene3D` shows its placeholder. `godot: true` on `platform_publish` /
  `platform_client_build`, the console's **3D scenes (Godot engine)**
  switch, or `aseman-platform-client --godot` adds the Godot plugin and the
  engine's artifacts (`embed.pck`, the GDExtension; from
  `/workspace/.aseman/godot` or the image's `aseman-godot` context) and
  builds for arm64; a rebuild keeps the last choice, and the platform
  records it.
  The app's native libraries are now compressed and limited to the ABIs the
  build is for (Flutter's own filter let a plugin's every ABI in): the
  default APK went from 48 MB to 23 MB, and a Godot one is 32 MB.
- **A platform app finds the node's public address.** The build no longer
  needs `ASEMAN_PUBLIC_URL` in the node's own environment (compose passes it
  as `ASEMAN_NODE_URL`): it takes `node_url`, `ASEMAN_PUBLIC_URL`, the node's
  `node.url`, or the address the person building opens Aseman at (noted per
  person by the gateway from the forwarded host or Origin), and passes over
  addresses a phone cannot reach (localhost, private networks, container
  names) instead of building an app that points at them.
- **A sleeping platform wakes for whoever opens it.** Waking is no longer a
  side effect inside the space: `/v1/platforms/<slug>/app/_aseman/wake`
  (GET or POST, no sign-in, `?wait=` up to 25 s) wakes the frontend's
  computer as its publisher and reports `{state, ready, error,
  retry_after_ms}`. One wake per frontend at a time, shared by everyone who
  arrives meanwhile, and a failed wake is reported for 15 s instead of
  retried by each visitor. A browser opening a sleeping web frontend gets a
  "waking up" page that reloads itself when the app answers; other requests
  get a 503 with `Retry-After`. Traffic through the platform's door renews
  the computer's lease, so it no longer falls asleep under the platform's
  people two minutes after it woke. The lightweight client and the Aseman
  client's platform home wake it when opened and when brought back to the
  foreground, and an Elpian program's request that meets a 503 wakes it and
  is sent again (`ElpianAppHost.onAsleep`).
- **Platforms, not sub-platforms; several per organization.** "Sub-platform"
  is gone as a term: it was the same thing as a platform. An organization
  may now own any number of platforms (each with a node-unique slug).
  `developer.platforms_list` lists them, and `platform_get`, `rename`,
  `delete`, `stats`, `users` and `frontend_publish` / `unpublish` take
  `platform` (id or slug; optional while the organization has one). A
  developer key can be bound to one platform (`input.platform`): what it
  makes through the platform collection joins that platform, and an unbound
  key of an organization with several platforms is refused there. Workflows
  find the `platform` resource by slug and stamp the platform
  `options.platform` names. The agents' `platform_setup` reuses a platform
  by slug and otherwise makes another; `app_developer_access` and
  `platform_publish` take `platform`. The console's **Platforms** page
  switches between an organization's platforms, makes, renames and deletes
  them, and the key dialog binds a key to one.
- **An agentic product as a workflow: آسمان‌درس.** `docs/workflows/study-planner.json`
  brings up a study planner for Iranian school students: organization,
  sub-platform and server key, a project with a custom **Planner** agent
  (plus a Curator for the official curriculum and a Counselor), and the web
  app installed, tested and served. The app's wizard takes the grade (and
  field from grade 10), confirms the official course list (chap.sch.ir),
  the goals, evidence-based difficulties (ADHD, test anxiety, sleep, …) and
  the free hours; the Planner agent writes the plan and counsel through
  `POST /v1/platform/spaces/ask`, the app checks it against the rules and
  asks the agent to repair what breaks one, then files every session into a
  Jalali calendar shown day by day on the home page. The run ends by having
  the agent make a real plan. Source in `docs/workflows/study-planner/app`,
  bundled by `bundle.py`; CI runs its tests and checks the bundle.
- **آسمان‌درس: one command to install or update, and a native Elpian
  frontend.** `docs/workflows/study-planner/deploy.sh` checks the app
  locally, signs in, validates, shows the plan (first install or update,
  what would change), runs and follows the workflow and resumes a failed
  run. The product also ships as an Elpian program with the web app's
  steps, screens, palette and features (wizard, today from the calendar, a
  Jalali calendar computed without `Intl`, the plan's table and charts, a
  phone widget); the workflow opens it on the project's desk with
  `appui_publish`, after the platform's QuickJS check and end-to-end
  scenarios. The server serves `GET /elpian/app.js` and names the Aseman
  person `me`.
- **One document brings up a whole product.** The developer API runs a JSON
  workflow (`aseman_workflow: "1"`) that calls the platform's actions in
  order: upsert the organization, its members, sub-platform and keys (from
  the console), spaces, rooms, agents and apps and install them in spaces,
  write a full-stack app's source onto a space's computer, run its build and
  tests (a non-zero exit fails the step), serve it, wait until it answers,
  call models, and publish the platform's frontend. `docs/WORKFLOWS.md`;
  example `docs/workflows/fullstack-product.json`.
- **Doors.** `POST /v1/workflows/validate|plan|runs`, `GET /v1/workflows/runs[/{id}]`,
  `POST /v1/workflows/runs/{id}/cancel`, `GET /v1/workflows/reference` with a
  key (platform permission; acts as the key's person, stamped with the
  org's platform, held to the key's permissions); console actions
  `developer.workflow_*` as the signed-in person.
- **The format.** Typed inputs, secrets (never stored), vars, assets,
  templates with params, `${{ }}` expressions with ~90 functions and
  lambdas, `if`, `for_each` (with concurrency), parallel groups, `wait`,
  `assert`, retries with backoff, timeouts, `continue_on_error`, `on_error`,
  `on_failure`, `finally`, and rollback (`compensate`, and deleting what
  upserts created). Twelve built-in upsert resources, or `define` your own.
- **Tooling.** A JSON Schema (`docs/workflows/workflow.schema.json`,
  `GET /v1/workflows/schema`), `aseman workflow …` in the CLI (either door,
  secrets from the environment, `--assets` ships a local source tree, live
  follow), and **Developer API → Build → Workflows** in the app.
- **A guide for models.** `docs/workflows/AUTHORING.md` — how to write a
  rich, professional workflow: what to decide first, the phases, the rules
  the engine enforces, patterns, a complete example, how to read a failed
  run, and a checklist. Served as `GET /v1/workflows/guide`
  (`developer.workflow_guide`, `aseman workflow guide`, the console's
  Writing guide); a test keeps its examples valid.
- **Proven on a node.** `ASEMAN_WORKFLOW_E2E=1 go test ./internal/plugins/host -run WorkflowE2E`
  runs the example end to end on a whole node.
- **Several nodes.** Runs keep a heartbeat, are counted and cancelled
  through the store, and read `interrupted` when their node stops.
- **Safe to run again.** Upserts find before they create and skip unchanged
  updates; plans dry-run with real reads; `resume_from` continues a failed
  run with the same document and inputs. Runs are stored
  (`dev_workflow_runs`) with redacted reports; the request log never holds a
  workflow's body. A synchronous call answers `202` before a proxy would
  give up.
- **Fix:** calls through `POST /v1/platform/{namespace}/{action}` now carry
  the acting person in the context, as every in-process caller does.

## Unreleased: agent-built platform frontends, wired to the space for real

- **A platform's frontend.** An organization owner or admin publishes an app
  the agents of a space built (Elpian or web, with its backend) as the
  sub-platform's frontend: Developer API → Platform → Frontend
  (`developer.platform_frontend_apps` / `_publish` / `_unpublish`, public
  `platform_frontend`). The gateway serves it at `/v1/platforms/<slug>/app/`
  to the platform's people (and the organization; main Aseman when bridged),
  and to signed-out visitors without any agent access. Web frontends sign
  people in to the platform through `_aseman/auth/*` (HttpOnly cookie; the
  page never holds a token). An asleep computer is woken as the publisher.
- **Backends use the space's agents and apps for the platform's people.** A
  platform user token (`X-Aseman-User-Token`) and the page API run as, and
  bill, the person who published the frontend, name the platform's person on
  usage (`via`), and reach only the agents, apps and microtools the app is
  wired to (its `APPS.json`, recorded at `appui_publish`).
- **Builder agents know.** `appui_create` takes `audience: "platform"`; the
  project gets `PLATFORM.md`; the persona, the tool's usage, `AGENTS.md`,
  `ASEMAN_API.md` and `TASK.md` say to wire the space's real agents and apps
  from the page and the server, never imitate one.
- **Wiring is checked.** `aseman-appui verify` runs `aseman-wiring-check`:
  an agent, app or microtool missing from `APPS.json`, or a server route at
  `_aseman/…` standing in for the gateway, and the app is not ready.
- **Fix:** the production gateway's bridge never implemented the app-server
  access methods, so apps got no `X-Aseman-User-Token` and `/appapi/v1`
  answered "app API unavailable": app backends could not reach their space's
  agents and apps at all. It now does (checked at compile time).
- **Agents set the whole product up for the person.** New agent tools
  `platform_setup` (organization + platform, made or reused),
  `app_developer_access` (an organization developer key in one app's server
  settings only; `Aseman.developer()` in the server SDKs; `DEVELOPER.md`)
  and `platform_publish` (the verified app as the platform's frontend, with
  its address). They act as the person, never the agent; the developer
  namespace stays closed to agents. The wiring check refuses a developer or
  app key in page code or written into source.
- **End-to-end test on a whole node** (`testdata/platform`,
  `ASEMAN_PLATFORM_E2E=1`): agent → organization, platform, fullstack app
  wired to the space's agent and MCP app, developer API, published; the
  platform's people then use it.
- **Fixes the end-to-end run found:** `appui_publish` hid the platform's
  "not ready, here is what to fix" answer behind "sandbox command exited with
  status 1"; an agent working in a room did not see the apps added to the
  whole space (so App UIs built there were wired to none); and
  `appui_create` dropped an app named the way people see it ("Pricing" for
  `tool_pricing`). `APPS.json` now carries each app's `display_name`.
- **A platform's own client.** `--dart-define=ASEMAN_PLATFORM=<slug>` (web:
  `--build-arg ASEMAN_PLATFORM`, or `?platform=<slug>`) builds the Aseman
  client for one sub-platform: sign-in on its own accounts under its name,
  home on its published frontend (Elpian natively, web in the in-app view),
  a menu to the workspace and sign-out. Sessions remember their platform.
- **Fix:** password reset and email verification looked accounts up by email
  across every environment, so the same address on main Aseman and on a
  platform could reset the wrong account. They take `platform` and stay in it.
- Server SDKs expose the platform (`req.asemanPlatform`, `client.platform`,
  `Aseman.platform_of`); the page SDK works under the platform path and has
  `me` / `signIn` / `signUp` / `signOut`.

## Unreleased: developer API platform collection

- **Developer console redesign.** Profile → Developer API uses the app's
  theme chrome: SoftCard sections, Sky headers, glass side navigation on
  wide layouts, and SegmentedTabBar on compact — shaped by the selected
  theme pack like Settings and Admin.
- **Platform API.** Bearer keys with Platform access can call every
  non-admin product action through `GET/POST /v1/platform` and
  `POST /v1/platform/{namespace}/{action}` (spaces, bots, tools, desk,
  messenger, finance, themes, market, posts, routines, …). Node
  administration (`admin.*`, `admin_*`, and the developer console
  namespace) stays off this door. Acts as the person who created the key.
- **Sub-platforms.** A developer organization can create one isolated
  product environment (`dev_platforms`). Spaces, bots and accounts carry
  `platform_id`. Auth (password, Google, Apple) is the shared system with
  an optional `platform` slug — accounts stay local to that environment.
  Platforms never see each other. Node admin can set `main_access` so one
  platform and main Aseman see each other both ways. Org owners get
  `platform_*` admin actions; node admin gets `admin_platforms` /
  `admin_platform_access`.

## Unreleased: App UI window + gadget modes (plugins product purged)

- **One App UI system, two hosts.** Elpian / web apps use `appui_create` /
  `appui_publish`. `kind: "app"` (default) opens a framed desk window;
  `kind: "gadget"` registers a compact frameless free-position widget
  (`placement` chat / rail / desk / page). Built in the person's Aseman
  (home) gadgets are account-wide / platform; built in a space they stay
  on that space's surfaces. Agents use `create_gadget` (shorthand) or
  `appui_create` with `kind: "gadget"`; `list_gadgets` / `tools.gadget_*`.
  Only the person removes gadgets from the right-edge handle.
- **Gadget first rule.** Generated gadgets must be compact like mobile
  home-screen widgets: no window frame, small footprint, only necessary
  information — not full windows.
- **Purged product “plugins” naming.** Former `kind: "plugin"`,
  `create_plugin`, `tools.plugin_*`, Flutter `features/plugins`, and
  `PLUGINS.md` are replaced by gadget mode (`features/gadgets`,
  `elpian/GADGETS.md`). Legacy `kind: "plugin"` still maps to gadget.

## Unreleased: Aseman chat is home

- **One personal space.** The Aseman self-chat (former Saved Messages) is also
  the user's home workspace and personal computer — same space id for notes,
  the assistant, the lead/team, and the sandbox. Legacy `{handle}'s Home`
  projects collapse into that Aseman chat; the inbox shows a single Aseman row.

## Unreleased: every agent on DeepSeek Harness

- **One agentic engine.** Every agent turn and every personal Aseman answer
  runs on [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
  `0.2.2-alpha.3`: one long-lived dsh host (the `aseman` profile, dsh's `sdk`
  template plus Aseman's patch layer) with Aseman's own Cordis plugins,
  replacing the LangChain Deep Agents runtime and the OpenCode and headless
  dsh engines. The node's VMM plugin is `harness` (gateway `/harness/v1`);
  agents recorded on older engines are served by it unchanged.
- **Removed:** the Python runtime (LangGraph, GEPA self-improvement, the
  swarm planner), the Admin → Agentic engine and Admin → OpenCode switches,
  the OpenCode builtins and sandbox install, the self-hosted OpenViking
  memory server and the Utopia timeline server (and their keys in `.env`).
- **Tools on dsh:** the space's computer as shell and files, the space's
  apps and platform builtins generated per turn, the whole Aseman API through
  one permission-checked catalog (`aseman_api_search` / `aseman_api_call`),
  `ask_user` (the turn pauses; the answer resumes the same Session), hand-offs,
  hiring and recruiting; dsh's own Agent Teams, todos, goals, workflows,
  compaction and session search.
- **Scoping:** a room agent stays in its space; the person's own Aseman acts
  across their account. Administration, credentials and money movement are
  never served to agents.
- **Memory:** notes and long-term memories kept by the node in Postgres with
  pgvector (a new optional `VectorIndex` database capability), recalled by
  meaning, learned from finished turns, billed to the project.
- **Timeline:** kept in the node's own database; agents search their own
  project's (`ASEMAN_TIMELINE=off` turns it off).
- **App UI gadgets:** agents make compact frameless gadgets with the same
  `appui_create` / `appui_publish` pipeline as desk windows (`kind: "gadget"`,
  `placement` chat / rail / desk / page). Made in the personal Aseman chat,
  a gadget is the person's own **universal floating widget** (across home
  tabs and while viewing workspaces); made in a space or DM it stays on that
  space's surfaces. One **gadgets handle** on the right screen edge opens
  the gadget manager. Agents only create; people remove. Desk apps stay
  framed windows; gadgets stay compact frameless widgets.
- **Typed API catalog:** `aseman_api_search` shows each action's body fields,
  read from the source by `cmd/gen-action-schemas` (kept current by a test).
- **Confinement:** a room agent, and a space's gadget, may name only its own
  space and the rooms and threads in it, whatever the field is called.
- **Personal Aseman:** acts only on DeepSeek Harness; its older in-node tools
  (proposals, reminders) are gone; proposals already stored are still
  answered. Long or team work goes to the person's workspace with
  `hand_to_workspace` (`users.brain_work`): its lead and team do it on the
  person's computer, and the result is written back into the Aseman chat as
  an answer to the note, with a card that opens the workspace.
- **Approvals on the personal computer:** what the personal Aseman does on the
  person's computer is decided by their workspace's rules, network policy and
  computer handover, and an approval is asked in that workspace (and on their
  phone).
- **Personal computer:** the agents of a person's direct chats work on that
  person's own computer (their home workspace's sandbox, made when they have
  none) for everything, not only shell commands: workspace files, file tools,
  the desk's computer and desktop, and the turn's computer. Each person in a
  shared direct chat works on their own. The personal Aseman has the same
  computer with its tools (shell, files, images, desktop), as the person.
- **Fix:** agents' platform tools (app building, files, the desk, AG-UI,
  proxies, routines, …) were refused with "invalid space id": the gateway
  sent on the governance gate's view of a `spaces.ask` (the tool's own
  arguments) as the whole ask. It now puts the gate's arguments back in
  place (the tool's args, the sandbox command, or an app function's payload).
- **Fix:** reports of direct messages have their own `direct_reports` table;
  they shared `chat_reports` with room reports, which lost who was reported.

## Unreleased: deep theme system

- **Installable theme packs** (`aseman.theme/v1`): colors, glass, radii,
  typography, motion, graphics, component styles, and shell layout (home /
  store / settings / profile slots) as safe JSON — no arbitrary Dart from the
  Store.
- **Design languages** reshape control anatomy (shape/fill/border/ink/shadow)
  for button, chip, input, card, sheet, FAB, nav, dialog, menu: presets for
  Material Expressive, Material 3, Fluent, Cupertino, Glass, Flat, Neo-brutal,
  Dense modern, plus Custom recipes. Theme Studio picks a language, edits
  recipes with live preview, or authors full JSON.
- **Store → Themes** tab, Theme Studio, Settings Appearance pack picker;
  builtins Sky / High contrast / Compact / Fluent / Cupertino / Neo-brutal;
  publish + install via marketplace type `theme`.
- **Per-pack color palettes**: each theme proposes its own accent / secondary /
  status swatches in Settings (no global Material color list); switching packs
  snaps to a palette that pack actually offers.
- **Design-language chrome**: SoftCard / GlassSurface / QuietList / FABs / chips
  honor pack shape (sharp / stadium / cut), fill, border, ink, and shadow —
  not only Material RRect + ripple with remapped radii.
- **Selection & continuous controls**: switch / checkbox / radio / slider /
  progress follow pack `toggle` and `slider` recipes; sharp languages use
  rectangular [PackSwitch] instead of platform-adaptive Cupertino switches.
- **Rich graphical recipes**: each control slot can declare gradients, effects
  (glow / sheen / grain / blur / opacity / focus ring), motion (press scale,
  hover lift, curves), typography, iconography, and per-state deltas
  (hovered / pressed / focused / selected / disabled). Extra named slots +
  `language.extras` cover arbitrary widgets; [ThemeChrome.look] /
  [ControlLook] resolve them for SoftCard and other chrome.
- **Quiet surfaces**: cards / sheets / bubbles no longer fill with the accent;
  Material `surfaceTint` is cleared and container roles are neutralized so
  palette choice colours buttons and chips, not every panel. Builtin packs use
  solid neutral cards and muted secondaries.
- **Palette wiring audit**: shared, admin, rooms, assistant, desk, feed, and
  market screens resolve status / identity / selection colours through
  [ThemeRoles] (`selectedFill`, `wellFill`, `bubbleFill`, `identity`, `status`)
  and `AppColors.*Of(context)` instead of hard-coded Material accents or
  loud `primaryContainer` washes; SoftCard accents no longer tint post cards.
- **Shaped avatars**: avatar faces use the same pack radius as their halo ring
  via [AvatarFace] / `avatarBorderRadius` (Fluent rounded, Neo-brutal sharp,
  Theme Studio `radiusControl`) instead of hard-coded circles.
- **Unified accent + part colours**: by default one selected palette accent
  colours every decorative UI part (identity, halos, selection, secondary /
  cyan fold into the brand). Packs may set `parts.unified: false` with
  per-part accents (`nav`, `feed`, `desk`, …); Theme Studio exposes the toggle
  and overrides. Status (success / warning / danger) stays semantic.
- **Theme ↔ Elpian UI composition**: packs declare `ui.disabled` (hide any
  shell / chrome slot) and `ui.surfaces` (inline trees or live QuickJS programs
  that replace / wrap / decorate slots via [ThemeSlotHost]). Chrome aliases
  (`chrome.feed.composer` ↔ `home.composer`, …) resolve together. Wrap mode
  embeds the built-in widget through `ThemeHostChild`.
- **Theme UI plugins (islands)**: packs declare `ui.islands` (`island.*`) as
  working Elpian panels — home tabs, profile entries, or full pages. Live
  panels run under [ThemeElpianHost] with the Aseman Elpian SDK plus
  `Aseman.api(namespace, action, body)` → signed-in core `/v1/{ns}/{action}`
  calls ([ThemeRuntimeScope]). Programs may also be inline `code` or loaded
  from `program` URL/asset. [AppFrontendTheme] ships pack tokens into
  stylesheets; VM hosts hot-reload on theme change.
- **Backend** `themes` namespace (`create`, `edit`, `get`, `apply`, `active`,
  `uninstall`, `import_samples`) with `KindTheme` bots and account-scoped
  active theme sync.
- **Aseman assistant** `create_theme` / `install_theme` propose tools generate
  and apply packs from a design brief.

## Unreleased: personal Aseman, calls and social parity

- **Personal brain** in Saved Messages: keep/answer, memory, proposals,
  reminders, work-on-it jobs, AI log, `@aseman` chat assistant, speech models.
- **Peer voice/video calls** (native WebRTC media + signaling/TURN; incoming
  call overlay; web stays signaling-only); privacy prefs; notify prefs;
  Android FCM MethodChannel (soft without google-services.json) alongside APNs.
- **Richer DMs** (reaction chips, hide/keep via users.dm_*; room messages carry
  `direct_id` so messenger actions work; voice waveform bars); credit
  applications; editable email templates; orbit strip; marketing links on auth.

## Unreleased: governance, proactive work and connections

What upgraders need to know first:

- **Agents no longer reach people's own computers by default.** Host access
  (the desktop app's "Let agents use this computer") is a node setting,
  Admin → Governance → Host access, off by default; while off, desktop apps
  stop answering and the `host_*` tools are not offered. Shared folders now
  come from project computers, attached to a message like a file
  (Attach → Project folder; agent tools
  `folder_list`, `folder_read`, `folder_write`).
- **Google is an app.** Gmail and Calendar moved from built-in agent tools to
  the Google app in the Apps catalog (Admin → Catalog → Connector apps).
  A node that had Google on lists the app by itself after it starts; people
  connect their account from Apps, and connecting adds the app to their home
  project. Composio and Arcade are set up on the same admin page.
- **Responsibilities** react to many more sources (see below); existing ones
  keep working unchanged.

- **Agent actions now pass a policy gate.** The new `governance` namespace
  decides every tool call, app call and sandbox command (CEL rules: deny, then
  ask, then allow) and records it. The default policy **asks the person before
  sending, paying, signing or deleting**, and before anything that changes
  their own computer; proactive work may only read. Edit it in Admin →
  Governance. Set `ASEMAN_GOVERNANCE_REQUIRED=1` to refuse every action while
  governance is not loaded.
- **Approvals** offer Allow once, Always allow and Refuse; standing grants are
  listed and revoked in Settings → What agents may always do; pending ones
  are answered on the home feed. `ASEMAN_APPROVAL_TIMEOUT` (30m).
- **Outside content is wrapped** as untrusted data before it reaches a model
  (app results, mail, files from a person's computer); outbound content is
  checked for credentials and card numbers.
- **Secrets**: agents ask for credentials with a masked box; they use
  `{{secret:name}}` and never see the value.
- **Network policy** per project for project computers, enforced by the new
  `aseman/egress-proxy` sidecar (`ASEMAN_EGRESS_IMAGE`); `ASEMAN_SANDBOX_RUNTIME=runsc`
  runs them under gVisor. Docker Compose now puts Postgres and timelines on an
  internal `data` network.
- **Human takeover** of a project computer pauses its agents.

New namespaces (all on by default): `governance`, `google`, `proactive`,
`responsibilities`, `channels`, `enterprise`, `hostaccess`. Their tables are
created on start; no manual migration.

New features:

- Tasks, the morning brief, inbox triage, background research and a first-day
  greeting (proactive), at the top of the home feed with the approvals
  waiting on the person; reply chips under agent messages.
- Responsibilities: agents own an area and react to GitHub, GitLab, Slack,
  Microsoft Teams, SMS, Stripe, Linear, Jira, Shopify and signed webhooks; to
  new mail, upcoming calendar events, feed items, changed API answers and
  changed app answers; and to schedules. Demonstrations: show an agent how,
  save it as a routine.
- Slack, Microsoft Teams and SMS (Twilio), including approvals there.
- Google (Gmail and Calendar), Composio and Arcade as apps.
- Enterprise: OIDC single sign-on (enforceable), SCIM 2.0 provisioning,
  organizations, SPIFFE workload identity for the agent runtime (`spire`
  Compose profile).
- Shared folders from project computers; optionally (admin switch) a
  person's own computer through the desktop app.
- Voice dictation (`developer.dictate`), room purpose, icon and color, a
  setup checklist and deeper Admin → Health checks.
- `deploy/helm/aseman`, `.github/workflows/ci.yml`, `evals/`, `docs/telemetry.md`.

New settings are listed in `.env.example` under "Governance and connections".
