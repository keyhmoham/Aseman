# Aseman API (the contract your app is wired with)

Your app is served to people through the Aseman preview gateway at
`/v1/proxy/<id>/…`. The same API is open to the page and to your server:

```
browser ──► /v1/proxy/<id>/_aseman/api/<op>   (gateway, as the person viewing)
browser ──► /v1/proxy/<id>/anything-else      (your server, prefix stripped)
server  ──► $ASEMAN_API_URL/<op>              (node, as a person: see below)
```

From the page, use **relative** URLs (`_aseman/api/call`, not
`/_aseman/api/call`) or `vendor/aseman-sdk/aseman.js`. From your server, use
the server SDK (below). Put agent and app calls wherever the feature belongs:
the page for interactive work, the server for work that needs your data,
secrets, validation, or runs without a person (schedules, webhooks, queues).

## Who pays

Every call runs as a person of the space and is charged to **that person's
wallet**, exactly like their own ask (funds checked first, the project's
budget applies, usage recorded as "via app <title>"):

| Where the call comes from | Runs as / billed to |
|---|---|
| The page (`_aseman/api/*`) | the person viewing the page |
| Your server, serving a request (`X-Aseman-User-Token`) | the person whose request it is |
| Your server, background work (`ASEMAN_APP_KEY`) | the person who asked for the app |

So: while serving a request, always use that request's token — never the
app key — so the person using the app pays for what they asked for. Use the
app key only for work nobody is in front of. Never call the API from tests.

## From your server

Every request the gateway forwards to your server carries:

| Header | Value |
|---|---|
| `X-Aseman-User-Token` | the person's token (about 15 minutes; a fresh one comes with each request) |
| `X-Aseman-User`, `X-Aseman-User-Handle` | who is using the app |
| `X-Aseman-Space`, `X-Aseman-Room` | where |
| `X-Aseman-Api` | the API URL (same as `ASEMAN_API_URL`) |

Call `<ASEMAN_API_URL>/<op>` (the ops below) with
`Authorization: Bearer <token>`: the request's `X-Aseman-User-Token`, or
`ASEMAN_APP_KEY` for background work. `.aseman/server.env` (written by
Aseman, loaded by the start command and the SDKs) holds `ASEMAN_API_URL` and
`ASEMAN_APP_KEY`; never print, log, commit or send either to the browser.

```js
// Node (Express shown; any framework): vendor/aseman-sdk/server.cjs or server.mjs
const { Aseman } = require("./vendor/aseman-sdk/server.cjs");
app.use(Aseman.middleware());                       // req.aseman: the person using the app
app.post("/api/summary", async (req, res) => {
  const { reply } = await req.aseman.ask("research", "Summarise: " + req.body.text);
  res.json({ reply });
});
setInterval(() => Aseman.app().ask("research", "Nightly digest"), 24 * 3600e3); // background
```

```python
# Python: vendor/aseman-sdk/aseman_server.py (standard library only)
from aseman_server import Aseman
aseman = Aseman.from_headers(request.headers)       # FastAPI/Flask request
reply = aseman.ask("research", "Summarise: " + text)["reply"]
Aseman.app().call("weather", "forecast", {"city": "Oslo"})   # background
```

Server SDK methods match the page SDK: `context`, `tools`, `microtools`,
`call`, `agents`, `ask` (with `history`), `askJSON` / `ask_json`. A request
without `X-Aseman-User-Token` (a health check, a webhook) has no person:
answer it without Aseman calls, or use the app key.

## Endpoints

Ops are the same from the page (`_aseman/api/<op>`) and the server
(`$ASEMAN_API_URL/<op>`). All responses are JSON. Errors are non-2xx with `{"error": "message"}`.

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
