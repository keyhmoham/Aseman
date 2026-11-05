# The developer API in your app's server

`app_developer_access` gave this app's **server** a developer API key of the
person's organization. `.aseman/server.env` holds it (loaded by the start
command and the SDKs):

| Setting | Value |
|---|---|
| `ASEMAN_DEVELOPER_API_URL` | the node's developer API (`…/dev/v1`) |
| `ASEMAN_DEVELOPER_KEY` | the key (`dk_live_…`): acts as the person who asked for it, spends from the organization |
| `ASEMAN_PLATFORM` | the organization's platform slug, when it has one |

Never send the key to the page, print it, log it, or commit it. The page
reaches the developer API only through routes of your own server.

## What it is for

| Need | Use |
|---|---|
| Judgment work the brief gives an agent of the space | **the agent** (`Aseman.fromRequest(req).ask(...)`), not the developer API |
| An app of the space (its microtools) | **the app** (`call`), not the developer API |
| A model call no agent is meant for (embeddings, a cheap classifier, a summary of your own data) | `developer.chat(...)` / `developer.request("embeddings", …)` |
| The platform's own product surface: its accounts, their spaces, rooms, agents, apps, posts, wallets… | `developer.platform(namespace, action, body)` — `POST /v1/platform/{namespace}/{action}`, as the person |
| Bringing up (or repeating) a whole setup in one go: spaces, agents and apps installed in them, software written to a computer and served, checked | a **workflow installer**: `POST /v1/workflows/runs` with one JSON document (idempotent: a rerun changes only what differs). Before writing one, read `GET /v1/workflows/guide` — how to write it well — and check it with `POST /v1/workflows/validate` |

`developer.catalog()` lists every action the platform collection offers (node
administration is never in it). Entities you create through it are stamped
with the organization's platform.

```js
const { Aseman } = require("./vendor/aseman-sdk/server.cjs");
const developer = Aseman.developer();                 // throws without access

// A space for each new customer of the platform, made as the person.
const { space } = await developer.platform("spaces", "space_create", { name: "Orders · " + customer });

// A model call that is not an agent's job.
const out = await developer.chat({ model: "gpt-5-mini", messages: [{ role: "user", content: text }] });
```

```python
from aseman_server import Aseman
developer = Aseman.developer()
developer.platform("posts", "post_create", {"body": "Welcome!"})
```

Errors throw `Aseman.Error` with `.status` and the API's message. Never call
the real API from tests: mock `Aseman.developer()`.
