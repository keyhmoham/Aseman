# Aseman App UI (OpenCode)

OpenCode and `aseman-appui` are baked into every `aseman/sandbox-computer`
image. New spaces get them by default.

## What agents call

| Platform builtin | Role |
|---|---|
| `appui_create` | Brief → OpenCode builds+tests fullstack UI → DeskWeb proxy card on hall |
| `opencode_run` | Distribute a coding task to OpenCode |
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

## Generated software → space apps

Frontends served through `/v1/proxy/…` call:

`POST _aseman/api/call` with `{ "tool", "microtool", "args" }`.

The gateway unwraps MCP `{ content: [{ type: "text", text }] }` so `result` is
the useful value (often a **string** of clean text/markdown). Generated UIs
must parse or display that text — they must not invent Hub/Exa REST JSON
shapes. See `AGENTS.md`.
