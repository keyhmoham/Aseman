# Aseman App UI (OpenCode)

OpenCode and `aseman-appui` are baked into every `aseman/sandbox-computer`
image. New spaces get them by default.

## What agents call

| Platform builtin | Role |
|---|---|
| `appui_create` | Brief → OpenCode plans, builds and tests a fullstack app → platform verifies it → DeskWeb card; pass an existing `dir` to change that app |
| `opencode_run` | Every other coding task (agents never write code themselves) |
| `opencode_status` | Job STATUS / READY |
| `opencode_models` | Backbone / model selection |

OpenCode is also listed in `spaces.tools_list` as a builtin app with microtools
`run`, `status`, `models`, `build` (mapped to the builtins above).

## LLM backbone + billing

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
`room=home` only to put a card on the space hall (“My trading desk”).

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

## What OpenCode is given (per build)

| File | What |
|---|---|
| `BRIEF.md` / `CHANGES.md` | The request; follow-up changes append to `CHANGES.md` (`--mode update`) |
| `APPS.json` | Space apps with microtools **and their argument schemas**, and space agents |
| `ASEMAN_API.md` | The page API contract (`_aseman/api/*`) with exact request/response shapes |
| `vendor/aseman-sdk/aseman.js` | Client SDK: `call`, `ask`, `askJSON`, `conversation`, `show` |
| `vendor/aseman-openui/` | OpenUI kit for agent-backed islands |

After OpenCode reports READY, `aseman-appui build` verifies the app itself:
`READY.json` must be complete, and the `start` command must serve `GET /` on
the port. Failures go back to OpenCode as repair rounds
(`ASEMAN_APPUI_REPAIRS`, default 2) before `appui_create` reports an error.

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
