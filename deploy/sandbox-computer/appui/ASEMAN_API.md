# Aseman page API (the contract your app is wired with)

Your app is served to people through the Aseman preview gateway at
`/v1/proxy/<id>/…`. Under that prefix the gateway itself answers
`_aseman/…` — it never reaches your server. It runs **as the person viewing
the page**, in this space, so the browser is where the app talks to Aseman:

```
browser ──► /v1/proxy/<id>/_aseman/api/*   (gateway: space apps + agents)
browser ──► /v1/proxy/<id>/anything-else   (your server, prefix stripped)
```

Your server cannot call `_aseman/api` (it has no session). Keep the server
for your own logic, storage and validation; do space-app and agent calls
from the page (use `vendor/aseman-sdk/aseman.js`, which handles the prefix,
errors and timeouts). Always use **relative** URLs (`_aseman/api/call`, not
`/_aseman/api/call`) or the SDK.

## Endpoints

All responses are JSON. Errors are non-2xx with `{"error": "message"}`.

| Op | Method | Request | Response |
|---|---|---|---|
| `context` | GET | — | `{space, user:{id, handle}, room?, preview:{id, title, path}}` |
| `tools` | GET | — | `{tools:[{name, id, description, microtools:[…]}]}` |
| `microtools` | GET | `?tool=<name or id>` | `{tool, id, microtools:[{name, description, schema}]}` |
| `call` | POST | `{tool, microtool, args}` | `{tool, microtool, result}` |
| `agents` | GET | — | `{agents:[{name, id, description, status}]}` |
| `ask` | POST | `{agent, prompt, history?}` | `{agent, bot_id, reply}` |
| `show` | POST | `{tool, microtool?, args?, title?, rect?}` | `{ok, window}` |
| `file/<id>` | GET | — | the stored file's bytes |

### `call` — space apps (microtools)

- `tool` is an app name or bot id from `APPS.json`; `microtool` one of its
  microtools; `args` must follow that microtool's `args_schema` in
  `APPS.json` exactly.
- `result` is already unwrapped from MCP. It is **often a plain text or
  markdown string**, sometimes a JSON object. Never assume REST shapes like
  `{results:[…]}`; branch on `typeof result` and parse what is there. Test
  with fixtures shaped like real replies.

### `ask` — space agents

- `agent` is an agent name or id from `APPS.json` → `agents`.
- **Every ask is a new, isolated conversation**: the agent works in a
  temporary thread of the room, created for that ask and deleted when the
  agent answers. Nothing from other asks or the room's chat leaks in.
- For multi-turn features (a chat panel), keep the turns in the page and
  send them as `history: [{role: "user"|"assistant", content}]` (latest 20
  are used). The SDK's `Aseman.conversation(agent)` does this for you.
- Agents can take from seconds to a few minutes: show progress, keep the UI
  responsive, allow cancel, never block other controls on an ask.
- Ask agents for **work that needs judgment** (drafting, analysing,
  summarising, planning, deciding). Ask for structured output when you
  render it (e.g. "Answer only with JSON: {…}") and parse defensively; or
  render the reply as markdown / OpenUI (see `vendor/aseman-openui`).

## SDK (`vendor/aseman-sdk/aseman.js`)

```html
<script src="vendor/aseman-sdk/aseman.js"></script>
<script type="module">
  const ctx = await Aseman.context();
  const forecast = await Aseman.call("weather", "forecast", { city: "Oslo" });
  const { reply } = await Aseman.ask("research", "Summarise: " + text);
  const chat = Aseman.conversation("assistant");
  const a1 = await chat.send("Plan my week");
  const a2 = await chat.send("Move gym to Friday"); // sends the history
  const json = await Aseman.askJSON("analyst", "Classify these rows …", { rows });
</script>
```

Errors throw `Aseman.Error` with `.status` and `.message`. Calls time out
(`call`: 2 min, `ask`: 6 min; override with `{timeoutMs}`) and accept
`{signal}` to cancel. Serve the `vendor/` folder statically from your server.
