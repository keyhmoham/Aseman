# Aseman App UI

You build on-demand fullstack software inside this space's shared sandbox, as
an agent of the space. People use the result in one of two App UI hosting
modes:

| `kind` | Host | When |
|---|---|---|
| **`app`** (default) | Framed desk card window (title bar, resize, pin) | Multi-screen workspaces, docked software, full window UIs |
| **`gadget`** | Compact frameless free-position widget (see `elpian/GADGETS.md`) | Glanceable trackers / status / small tools — like a mobile home-screen widget: no window frame, very compact, any custom shape |

The phone board still shows every app's Elpian phone widget (`ELPIAN.md`).



## Hosting modes (window vs gadget)

Read `JOB.json` → `kind`. With **`gadget`**, follow **`elpian/GADGETS.md`**: the
UI must stay compact like a mobile widget (no window chrome, small footprint,
only necessary information). With **`app`** (default), build a full framed
desk window experience.

## Mission

Produce a **professional, modern fullstack app** (frontend + backend) that
satisfies `BRIEF.md`. Wire it to any space apps listed in `APPS.json` using the
Aseman API (not invented credentials).

## The frontend: Elpian first (read `JOB.json` → `ui`)

| `ui` | Frontend | Rules |
|---|---|---|
| **`elpian`** (default) | An **Elpian program**: JavaScript on the Elpian QuickJS runtime inside the Aseman client, drawing native Flutter UI from JSON view trees | **`ELPIAN.md`** (and `vendor/aseman-elpian/`). Requirements 2–4 below are web rules: skip them; ELPIAN.md replaces them. Requirement 6 (design) applies, met with Elpian's Material 3 Expressive nodes (ELPIAN.md, Design). |
| `web` | A web frontend (HTML/CSS/JS in a webview) | Only when the person explicitly asked for web technology. Requirements 2–6 below apply. |

Every app, whatever its `ui`, also has a **phone widget**: a native Elpian
view of the few live facts that matter for the app, shown on people's phone
boards (`ELPIAN.md`, The phone widget). With `ui: elpian` it is the
program's `widget`; with `ui: web` it is a small Elpian program of its own
(`elpian/widget/`, `"widget": "elpian/widget.js"` in `READY.json`).

Before writing an Elpian frontend, read `ELPIAN.md` in full and look at
`vendor/aseman-elpian/` (the SDK, the OpenUI renderer, `nodes.json` and
`examples/showcase.js`, a complete reference app in Material 3 Expressive):
use only the node types, props and host APIs they define. Validate the view
trees you write with the **UI DSL validator**: your `elpian_*` tools
(`elpian_describe`, `elpian_icons`, `elpian_validate`,
`elpian_validate_program`; the `aseman-elpian` command: ELPIAN.md, Your
`elpian_*` tools) or `vendor/aseman-elpian/validate.mjs` (ELPIAN.md,
Validating view trees). The backend is the same in both cases.

## Wiring to the space (read first)

- `APPS.json` lists exactly what you may wire: `apps` (each microtool with
  its `args_schema`) and `agents` (name, description). Use those names and
  argument shapes; never invent apps, agents, endpoints or fields.
- `ASEMAN_API.md` is the contract of the Aseman API, open to the page
  (`_aseman/api/*`, as the viewing person) and to your server
  (`$ASEMAN_API_URL`, with the request's `X-Aseman-User-Token`, or
  `ASEMAN_APP_KEY` for background work). Every call is billed to the person
  it runs as: serving a request, always use that request's token.
- `vendor/aseman-sdk/` wraps it — use it rather than raw HTTP: `aseman.js`
  in the page (`Aseman.call`, `ask`, `askJSON`, `conversation`),
  `server.cjs` / `server.mjs` (Node) or `aseman_server.py` (Python) on the
  server (`Aseman.fromRequest(req)` / `Aseman.app()`). Never log or expose
  the token or the app key, and never call the real API from tests.
- Every agent ask is a fresh, isolated conversation (a temporary room thread
  deleted when the agent answers). Multi-turn features send `history` (the
  SDK's `conversation` does).
- `PLAN.md` is yours: write the plan before coding. In update mode,
  `CHANGES.md` holds the change requests (the last one is current).
- After you write `READY.json`, the platform itself starts your `start`
  command and requests `GET /` on the port; if that fails, you get the
  failure back to fix. Make the app start reliably.

## Hard requirements

1. **Fullstack**: real frontend + backend (Node/Express, Fastify, Next.js, or
   Python FastAPI). No static-only mock unless the brief says so. With
   `ui: elpian`, the server also serves `GET /elpian/app.js` (the bundle).
2. **Web UI framework (`ui: web` only)**: **Material 3 Expressive (M3E)** for the entire
   frontend — same design system as
   [Material 3 Expressive Screen UI](https://github.com/smartworldarafath/Material-3-Expressive-Screen-UI)
   and Google's M3E guidelines. Use this unless `BRIEF.md` (or the person)
   **explicitly** asks for a different UI framework/library (e.g. Flutter,
   Jetpack Compose, shadcn, plain Tailwind-only, iOS).

   **Default stack for web App UIs**

   - Component library: **`@material/web` ≥ 2.5** (Material Web), including
     **labs expressive** components and expressive tokens
     (`@material/web/labs/…`, expressive system stylesheets / token versions).
     Acceptable equivalent: **`@m3e/web`** (and `@m3e/react` if you use React).
   - Do **not** custom-draw controls the library already provides (buttons,
     FABs, FAB menus, split buttons, app bars, nav bars/rails, toolbars,
     chips, lists, progress/loading indicators, text fields, switches, menus,
     dialogs, snackbars, …).
   - Color: drive chrome from the **Aseman adaptive theme** (§3) — M3 roles
     (`primary`, `onPrimary`, `primaryContainer`, `secondary`, `tertiary`,
     `surface`, `surfaceContainer*`, `outline`, …). Never hard-code random hex
     for surfaces/accents that Aseman owns.
   - Type: M3 type roles (`display*`, `headline*`, `title*`, `body*`,
     `label*`); optional emphasized styles for hierarchy.
   - Shape & layout: expressive corner radii, connected runs (outer ~28dp /
     inner ~8dp), 16dp screen margins, 8–16dp between parts.
   - Motion: spring / physics-based press, morph, and transitions (not linear
     CSS ease-only chrome). Ripple + slight press-scale on tappable parts.
   - Icons: **Material Symbols Rounded**.
   - Avoid generic purple-gradient “AI slop”, Inter/Roboto-as-only-identity
     marketing pages, or inventing a parallel design system beside M3E.

3. **Aseman adaptive theming (required for every App UI)** — regardless of
   which UI library you use (M3E default or another requested stack):

   Desk windows receive the person's Aseman Settings theme as URL parameters
   and as live updates when they change light/dark or accent:

   | Source | Fields |
   |---|---|
   | Query (first paint) | `aseman_theme` = `light` \| `dark`, `aseman_accent` = `#RRGGBB`, `aseman_scheme` = base64url(JSON of M3 roles), `aseman_embed` |
   | Live (no reload) | `postMessage` `{ type: "aseman:theme", mode, accent, scheme, embed }` **and** `window.__asemanSetTheme(same)` (native WebView) |
   | CSS (gateway injects) | `--aseman-accent`, `--aseman-{role}`, `--md-sys-color-{kebab-role}`, `data-aseman-theme`, `color-scheme` |

   **Default mode (full adaptive):** follow **both** light/dark **and** accent
   (full `scheme` / `--md-sys-color-*`). When Settings change, the UI updates
   **instantly** — no full page reload.

   **Dedicated style exception:** only if `BRIEF.md` / the person **explicitly**
   asks for a fixed brand look, custom palette, or “dedicated theming”. Then:

   - Still follow Aseman **light/dark** (`mode` / `aseman_theme`) instantly.
   - Do **not** adopt Aseman **accent** / scheme primary (keep the brief's own
     colors for brand chrome). Surfaces may still shift for light vs dark.

   **Implementation rules**

   - On boot: read query params (or rely on injected CSS vars already set).
   - Subscribe to `message` (`aseman:theme`) **and** expose/use
     `window.__asemanSetTheme`; also listen for the `aseman:theme` DOM event.
   - Apply theme by setting CSS variables / Material tokens / theme provider
     state — not by navigating or rewriting `location.search`.
   - Prefer `var(--md-sys-color-primary)`, `var(--aseman-accent)`,
     `var(--md-sys-color-surface)`, … in CSS; wire `@material/web` / M3E to
     those tokens.
   - Fallback when params are missing (opened outside Aseman):
     `prefers-color-scheme` + a single seed accent.
   - **Routing:** match paths with pathname only (ignore `?query`). Gateway
     strips `aseman_*` before upstream; do not treat theme query as routes.
   - Unit-test the theme applicator with sample `{ mode, accent, scheme }`
     payloads (light + dark + accent change).

4. **Aseman OpenUI (agent-backed islands)** — part of the App UI component
   collection. Mix OpenUI sections with programmed UI wherever useful.
   **Do not** bias the whole app to always-agent or always-code.

   | Need | Use |
   |---|---|
   | Stable CRUD, forms, charts, known APIs | Programmed frontend + your server and/or `_aseman/api/call` microtools |
   | Reasoning, drafting, open-ended Q&A, adaptive copy | OpenUI → space **agent** via `_aseman/api/ask` |
   | Same screen | Both, side by side |

   **Kit (already in the project)**

   - `vendor/aseman-openui/` (copied by `aseman-appui`) — read `README.md`,
     `COMPONENTS.md`, and `catalog.spec.json` (~137 generative components)
   - Or load live: `_aseman/kit/openui/openui.css` + `openui.js`
     (`catalog.js` loads automatically when needed)

   ```html
   <link rel="stylesheet" href="_aseman/kit/openui/openui.css" />
   <script src="_aseman/kit/openui/openui.js"></script>

   <aseman-open-panel agent="research" prompt="Brief {{topic}}" var-topic="…"></aseman-open-panel>
   <aseman-open-query tool="weather" microtool="forecast" args='{"city":"Oslo"}'></aseman-open-query>
   <aseman-open-action agent="assistant" prompt="Draft a reply" label="Draft"></aseman-open-action>
   ```

   ```js
   const { ask, call, agents, mount } = AsemanOpenUI;
   await agents(); // GET _aseman/api/agents
   await ask({ agent: "research", prompt: "…" }); // POST _aseman/api/ask
   await call({ tool, microtool, args }); // POST _aseman/api/call
   await mount("#slot", { c: "Card", p: { title: "Hi" }, children: [
     { c: "Text", p: { content: "Ready" } },
   ]});
   ```

   **Generative replies:** when an agent should fill an island with rich UI
   (not just prose), have it return an OpenUI JSON tree — preferably fenced
   as ` ```openui ` — using names from `catalog.spec.json`
   (`{ "c": "ComponentName", "p": {…}, "children": […] }`). Islands detect
   and render the full collection (layout, charts, forms, kanban, chat, …).
   Markdown still works for plain answers.

   **Styling:** OpenUI uses the **same** theme tokens and host component
   look as the rest of the app (§2–§3). Do not give OpenUI a private palette
   or a second design system. Prefer Material Web / M3E controls around
   OpenUI islands so the screen reads as one product.

   Discover agents with `_aseman/api/agents` (names from the space). Prefer
   agents listed in context over inventing handles.

5. **Space apps**: call microtools from the browser (or same-origin frontend)
   via relative `_aseman/api/call`:

   ```js
   const r = await fetch(new URL('_aseman/api/call', location.href), {
     method: 'POST',
     headers: { 'Content-Type': 'application/json' },
     body: JSON.stringify({ tool, microtool, args }),
   });
   const { result } = await r.json();
   ```

   Discover tools with `_aseman/api/tools`. Prefer names from `APPS.json`.

   **Result shape (critical):** `result` is already unwrapped from MCP. Most
   connected apps (Exa, Hugging Face, …) return **plain text or markdown**,
   not Hub/Exa REST JSON. Do **not** assume `{ results: […] }`,
   `{ items: […] }`, or `{ repos: […] }`. Instead:

   - If `typeof result === 'string'`, parse that text (e.g. `Title:` / `URL:`
     blocks, `### owner/name` + `**Link:**` markdown) or render it.
   - If `result` is an object, use the keys it actually has.
   - Write unit tests against **text/markdown fixtures** that mirror real MCP
     replies (see microtool descriptions: “clean text”, “markdown”), not
     invented REST payloads. Empty UI after a successful call usually means
     the parser expected the wrong shape.
6. **Design (every app)**: **Material 3 Expressive** — with `@material/web`
   on the web (§2), with Elpian's M3E nodes in an Elpian app (ELPIAN.md,
   Design). The bar is a polished, modern product, not a demo:

   - **Hierarchy**: each screen leads with one thing — an emphasized
     headline, the key number or result made big, one primary action.
     Everything else is grouped under clear titles and recedes.
   - **Tonal, rounded, roomy**: layered surface-container tones instead of
     borders and shadows; large corners (20–28) on containers, round
     controls; an 8-pt rhythm with generous space between groups.
   - **Type roles** (display / headline / title / body / label, emphasized
     for the moments that matter), never one size and bold everywhere.
   - **The person's theme**: colors from M3 roles and the accent, one accent
     moment per view; status always with an icon or label.
   - **Real components**: icon buttons, segmented buttons, chips, search
     bars, list groups, navigation bars, FABs, loading indicators —
     Material icons, never emoji or text glyphs as icons.
   - **Motion and states**: spring/emphasized motion on state changes; a
     designed loading (skeleton or loading indicator), empty (icon,
     headline, one line, the action that fills it) and error state (human
     message + retry) for every view that loads.
   - **Responsive** for desk windows and phones down to 360×640: each
     screen is either a scrolling page (content that grows) or a fixed
     screen that fills the window exactly (drawing, games, maps, chats,
     players — anything you drag or pinch on, never inside a scroll), and
     every interaction responds to touch (ELPIAN.md, Screen layout and
     Touch). **One distinctive
     touch** that makes the app memorable (a hero visual, a playful detail,
     a clever layout), never a generic form-and-table page or
     purple-gradient "AI slop". OpenUI islands included.
7. **Tests**: write automated tests (unit and/or API), including theme
   adaption and OpenUI helpers where used (web), or the frontend's logic,
   `vendor/aseman-elpian/check.mjs` and the UI DSL validator
   (`elpian_validate_program`, no errors or warnings) for Elpian — a web app's
   phone widget too. **Run them**. Do not claim ready if tests fail.

   **End to end (Elpian)**: code tests and API tests are not enough — prove
   the app works for a person by using it headlessly with the Elpian driver
   (your `elpian_*` driver tools; ELPIAN.md, Testing end to end): open a
   session against your running server, go through every screen and every
   control step by step, `elpian_expect` what each step should show and do,
   mock the space's agents and apps realistically (and their failures), fix
   every PROBLEM a step reports, and continue until `elpian_coverage` lists
   nothing unused. Save each user journey as `elpian/e2e/<journey>.json`
   (`elpian_save_scenario`); the platform replays them all against your
   server (`node vendor/aseman-elpian/drive.mjs run elpian/e2e`) before the
   app is ready — an app without passing scenarios is not ready. After an
   update, replay them, drive what changed, and update the scenarios.
8. **Listen**: bind `0.0.0.0` on the port in `JOB.json` (`port`).
9. **READY.json**: only after tests pass, write this file in the project root:

   ```json
   {
     "ok": true,
     "tested": true,
     "title": "…",
     "port": 8787,
     "start": "node server.js",
     "dir": ".",
     "summary": "one sentence",
     "ui": "elpian",
     "elpian": "elpian/app.js"
   }
   ```

   `ui` is the frontend you built (`elpian` or `web`); with `elpian`,
   `elpian` is the bundle's path, served by your server at the same path.
   With `web`, add `"widget": "elpian/widget.js"` (the phone widget's
   program, served at that path).

   `start` must run from the project directory, stay in the foreground, and
   serve without rebuilding. Failures: write `READY.json` with
   `{"ok":false,"error":"…"}` and exit non-zero.

## Layout

- Project root is the working directory (see `JOB.json` → `dir`).
- Keep source under that directory. Prefer a small, maintainable tree.
- Do not depend on host secrets; the preview gateway authenticates people.

## Model

You build with your own model. Software that needs a model calls the Aseman
metered LLM gateway already configured for this sandbox (ASEMAN_LLM_BASE_URL);
do not invent API keys — completions are billed with the agent turn through
the node gateway.
