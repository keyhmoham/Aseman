# Aseman App UI

`aseman-appui`, the Elpian toolchain (`aseman-elpian`) and OpenCode are baked
into every `aseman/sandbox-computer` image. New spaces get them by default.

## Two builders, one app system

The node's **OpenCode switch** (Admin → AI → OpenCode, `spaces.opencode_set`)
picks who builds on-demand apps. It is **off by default**.

| | OpenCode off (default) | OpenCode on |
|---|---|---|
| Builder | the space's agents (or a developer specialist the lead staffs) | OpenCode, briefed by the agents |
| `appui_create` | `aseman-appui prepare`: the project and the build task (`TASK.md`) | `aseman-appui build`: OpenCode builds, the platform verifies, repair rounds, opens |
| Validator / driver | `aseman-elpian <tool> '{json}'` on the shell (driver sessions persist between commands) | the same tools as MCP servers (`opencode/opencode.json`) |
| Verify and open | `appui_publish {dir}` → `aseman-appui verify`; not ready → the problem and `REPAIR.md`, fix and publish again | inside `appui_create` |
| Other coding | the agents, directly in the sandbox | `opencode_run` |

Both get the same project (guides, SDKs, `APPS.json`, `JOB.json`, the app's
server key), the same plan/build/test/end-to-end steps, the same platform
checks before an app opens, and the same update flow (`appui_create` with an
existing `dir`, `CHANGES.md`). `appui_status` reads `STATUS.json` /
`READY.json` in either mode.

## What agents call

| Platform builtin | Role |
|---|---|
| `appui_create` | Brief → the project is laid out; OpenCode on: it plans, builds and tests a fullstack app → platform verifies it → DeskWeb card; off: the agent gets the build task. Pass an existing `dir` to change that app |
| `appui_publish` | The platform verifies an app (READY.json, start and answer, Elpian bundle, QuickJS check against the live server, end-to-end scenarios) and opens it; also re-verifies and reopens any app |
| `appui_status` | Job STATUS / READY |
| `opencode_run` | OpenCode on: every other coding task (agents never write code themselves) |
| `opencode_status` | OpenCode on: same as `appui_status` |
| `opencode_models` | OpenCode on: backbone / model selection |

While it is on, OpenCode is also listed in `spaces.tools_list` as a builtin
app with microtools `run`, `status`, `models`, `build` (mapped to the builtins
above). While it is off, the `opencode_*` tools and that app are not listed,
calling them fails, and the sandbox's OpenCode is never configured or run.

## LLM backbone + billing (OpenCode on)

OpenCode does **not** use OpenCode Zen free models. During `appui_create` /
`opencode_run`, the platform injects the **current agent turn's** metered LLM
credential into the sandbox:

- Base URL: `{ASEMAN_AGENT_NODE_URL}/deepagents/v1/llm` (same proxy agents use)
- API key: the turn bearer token
- Model: `aseman/default` (gateway rewrites to the agent's admin-configured model)

Completions go through `serveChat` → `meter` → turn `InvocationUsage` →
`billAgentTurn` / `BillAndRecordUsage` — the same path as agent chat tokens.

Optional node env:

```bash
ASEMAN_AGENT_NODE_URL=http://aseman:8080   # sandbox must reach this host
ASEMAN_SANDBOX_LLM_URL=…/deepagents/v1/llm # override when sandboxes cannot resolve the node
OPENCODE_MODEL=aseman/default              # client-facing id (not "free")
OPENCODE_RUN_TIMEOUT_SECS=600              # per OpenCode session wall clock
```

## Desk

Generated App UIs open on the **room desk where the person asked**. Pass
`room=home` only to put a card on the space hall (“My desk”).

## Default UI framework

OpenCode App UIs default to **Material 3 Expressive** (Google M3E), implemented
with **`@material/web` ≥ 2.5** (expressive labs/tokens) — the same design
system the [Material 3 Expressive Screen UI](https://github.com/smartworldarafath/Material-3-Expressive-Screen-UI)
studio targets. Use another UI stack only when the brief explicitly asks.
Details live in `AGENTS.md`.

## Adaptive theming (all App UIs)

Desk web windows pass the person's Aseman Settings into every open App UI:

- URL: `aseman_theme`, `aseman_accent`, `aseman_scheme`, `aseman_embed`
- Live: `postMessage` / `__asemanSetTheme` with `{ type: "aseman:theme", … }`
- Gateway shim sets `--md-sys-color-*` / `--aseman-*` CSS variables on load
  and on each update

Generated apps must follow **light/dark + accent** instantly by default. If
the brief asks for a dedicated brand look, they still follow light/dark from
Aseman but keep their own accent/palette.

## OpenUI (agent-backed islands)

`appui/openui/` is the **Aseman OpenUI** kit. On each build it is copied to
`vendor/aseman-openui/` and also served at `_aseman/kit/openui/`. OpenCode
mixes `<aseman-open-panel|query|action>` with programmed UI under the same
theme. Islands render the full generative catalog (`catalog.js` /
`catalog.spec.json`, ~137 components) when agents return OpenUI JSON trees;
markdown otherwise. Preview APIs: `_aseman/api/agents`, `_aseman/api/ask`,
plus existing `call` / `tools`.

## Elpian frontends (the default)

Every App UI's frontend is an **Elpian program** unless the person explicitly
asked for web technology (`appui_create` `ui: "web"`). The program is plain
JavaScript the Aseman client runs on its Elpian QuickJS runtime and draws
with native widgets, the UI kit and the person's theme — on desktop and
phones alike. Everything for it is in [`elpian/`](elpian):

| File | What |
|---|---|
| [`ELPIAN.md`](elpian/ELPIAN.md) | The guide every builder follows: runtime rules, every node type and its props, events, styling and theme, the SDK, OpenUI, layout, checklist |
| `aseman-elpian.js` | The SDK in every program: `App` (state, view, handlers), `Aseman.*` (agents, apps, the app's server, env, phone widget), Tasks |
| `openui-elpian.js` | The OpenUI collection (all 137 components of the web kit) rendered as Elpian/UI-kit nodes, and agent-backed islands (`OpenUI.panel` / `action` / `query`) |
| `bundle.mjs` | `elpian/src/*.js` → `elpian/app.js` (SDK + OpenUI + the app) |
| `check.mjs` | Runs the program on QuickJS against a simulated host (a 360×640 phone, then a desk window) and the live server; fails on errors, unknown nodes, missing or throwing handlers (gestures fired as the finger makes them), the validator's errors on every render, and its findings that break touch or phones (a surface in a scroll, an overlay over taps, a screen taller than a phone, …) |
| `validate.mjs`, `schema.mjs`, `icons.json` | The UI DSL validator: checks view trees (props, styles, events, keys, parent–child relations, measured layout constraints, touch and nested gestures, fitting a phone, widget rules, M3E design lint) against the engine's schema; CLI (`validate.mjs tree.json`, `--program app.js`, `--describe Type`) |
| `validate-mcp.mjs` | The validator as an MCP server (`elpian_validate`, `elpian_validate_program`, `elpian_describe`, `elpian_icons`), registered for OpenCode in `opencode/opencode.json` |
| `drive.mjs` | The **headless driver**: uses the app as a person does, without a screen (a headless browser for Elpian). A session runs the bundle on QuickJS against the live server, reads the screen as a text outline with stable refs, and taps, types, selects, toggles, swipes, drags and pinches controls with the event data the client sends (disabled and unreachable controls do nothing). Each step reports the screen's changes, the requests and the problems (exceptions, unexpected error banners, server failures, broken renders, dead controls). It also asserts the screen, state and requests, mocks the space's agents and apps (replies, failures, held requests), passes time, and changes the viewport and theme. Sessions save as scenarios (`elpian/e2e/*.json`); `drive.mjs run` replays them, and coverage names the controls no step used |
| `drive-mcp.mjs` | The driver as a stateful MCP server for OpenCode (`elpian_open`, `elpian_snapshot`, `elpian_tap`, `elpian_type`, `elpian_select`, `elpian_toggle`, `elpian_gesture`, `elpian_fire`, `elpian_wait`, `elpian_expect`, `elpian_state`, `elpian_env`, `elpian_mock`, `elpian_network`, `elpian_logs`, `elpian_coverage`, `elpian_reload`, `elpian_save_scenario`, `elpian_run_scenarios`, `elpian_close`), registered as `elpian-driver` in `opencode/opencode.json` |
| `mcp-stdio.mjs` | The small stdio MCP server both servers use |
| `elpian-cli.mjs` | `aseman-elpian`: every tool of both servers on the shell, for the space's agents (`aseman-elpian tools`, `aseman-elpian elpian_open '{"server":"http://127.0.0.1:8787"}'`, …). The validator runs in the command; driver tools go to a per-project driver process on a unix socket, so sessions persist between commands (`aseman-elpian stop` ends it; it also exits after `ASEMAN_ELPIAN_IDLE_SECS`, default 1800, unused) |
| `examples/showcase.js` | A reference app in Material 3 Expressive that passes the check and the validator (scrolling pages) |
| `examples/whiteboard.js` | A reference app with a fixed, touch-driven screen (a drawing surface that fills any window, an adaptive toolbar) that passes them too |
| `nodes.json` | The node types the engine and UI kit draw (a test keeps it equal to the engine source) |

The app's server serves `GET /elpian/app.js`; `READY.json` says
`"ui": "elpian", "elpian": "elpian/app.js"`. During verification the
platform rebuilds the bundle, checks the server serves it, and runs
`check.mjs` against the running server, then replays the app's end-to-end
scenarios (`drive.mjs run elpian/e2e`, which the builder wrote while driving
the app headlessly through every screen and control; an Elpian app without
them is not ready; `ASEMAN_APPUI_E2E=0` skips this); failures go back to the
builder (OpenCode's repair rounds, or `appui_publish`'s answer). The
desk window then runs the program natively (`ElpianAppView`), waking the
sandbox and starting the server first like any preview. Test the kit with
`node --test deploy/sandbox-computer/appui/elpian/test/*.test.mjs`
(after `npm install` in `deploy/tool-runtime`, for QuickJS).

## What the builder is given (per build)

| File | What |
|---|---|
| `BRIEF.md` / `CHANGES.md` | The request; follow-up changes append to `CHANGES.md` (`--mode update`) |
| `APPS.json` | Space apps with microtools **and their argument schemas**, and space agents |
| `ASEMAN_API.md` | The page API contract (`_aseman/api/*`) with exact request/response shapes |
| `vendor/aseman-sdk/aseman.js` | Client SDK: `call`, `ask`, `askJSON`, `conversation`, `show` |
| `vendor/aseman-openui/` | OpenUI kit for agent-backed islands |

After the builder reports READY, the platform verifies the app itself
(`aseman-appui build` after OpenCode, `aseman-appui verify` through
`appui_publish` after the agents): `READY.json` must be complete, and the
`start` command must serve `GET /` on the port (and, for Elpian, the checks
above). OpenCode gets the failures as repair rounds (`ASEMAN_APPUI_REPAIRS`,
default 2) before `appui_create` reports an error; an agent gets them as
`appui_publish`'s answer and `REPAIR.md`, and publishes again once fixed.
The agents' task (`TASK.md`) is OpenCode's build prompt with the agents'
own tools.

## App servers use the space too

An app's backend uses the space's agents and apps through the same API as
its pages, at `$ASEMAN_API_URL/<op>` (the node's `/appapi/v1`):

- **Serving a person:** every request the gateway forwards carries
  `X-Aseman-User-Token` (plus `X-Aseman-User`, `-Space`, `-Room`, `-Api`).
  Calls with it run as that person and are billed to their wallet.
- **Background work:** `ASEMAN_APP_KEY` (in `.aseman/server.env`, mode 600)
  runs as, and bills, the person who asked for the app. It is stored hashed
  on the node, rotates on every rebuild and stops working when the app's
  preview is deleted.

Both go through `spaces.ask` like a person's own ask: funds checked first,
one charge per ask (the bot's time plus the agent turn's metered model
usage), the project's budget applies, and usage reads "space ask via app
<title>". SDKs: `vendor/aseman-sdk/server.cjs` / `server.mjs` (Node) and
`aseman_server.py` (Python).

## Agents in generated apps

`_aseman/api/ask` runs every ask in a **temporary room thread**: the agent
starts a fresh conversation, nothing from the room or from other asks leaks
in, and the thread (its messages and the agent's runtime checkpoints) is
deleted as soon as the agent answers. Apps carry multi-turn context with
`history`.

## Generated software → space apps

Frontends served through `/v1/proxy/…` call:

`POST _aseman/api/call` with `{ "tool", "microtool", "args" }`.

The gateway unwraps MCP `{ content: [{ type: "text", text }] }` so `result` is
the useful value (often a **string** of clean text/markdown). Generated UIs
must parse or display that text — they must not invent Hub/Exa REST JSON
shapes. See `AGENTS.md`.
