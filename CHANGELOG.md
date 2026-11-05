# Changelog

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
