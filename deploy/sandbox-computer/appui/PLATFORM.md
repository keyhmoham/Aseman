# Building a platform's frontend

`JOB.json` → `audience: "platform"`: this app becomes the **frontend of a
platform** — a product someone runs on Aseman as a developer organization
(Developer API → Platform). Once you `appui_publish` it, the person publishes
it in **Developer API → Platform → Frontend**, and the platform's people open
it at `/v1/platforms/<slug>/app/` (or in an Aseman client signed in to that
platform, where an Elpian frontend runs natively).

Everything in `AGENTS.md`, `ELPIAN.md` and `ASEMAN_API.md` still holds. This
page is what changes.

## Who uses it

| | Space app (default) | Platform frontend |
|---|---|---|
| People | members of this space | the platform's people — **not** members of this space |
| Signed out | never | yes: visitors before they sign in |
| Agents and apps | the space's, as the person using the app | the **same space's**, as the person who published the frontend, for the platform's person |
| Reach | everything the person may use | **only** the agents and apps in `APPS.json` |
| Billed to | the person using it | the person who published it (the platform's operator); usage names the platform's person |

The space's agents and apps are the platform's **backend services in the
loop**: research, drafting, support, pricing, moderation — whatever the brief
gives them. Use them for real, through the Aseman API, from the page or the
server. Never imitate one (a hard-coded reply, a direct model call, a fake
endpoint): `aseman-appui verify` checks your code against `APPS.json`, and the
gateway refuses any agent or app the frontend is not wired to.

## Requests your server gets

| Header | Value |
|---|---|
| `X-Aseman-Platform`, `X-Aseman-Platform-Id`, `X-Aseman-Platform-Name` | the platform the request came through (always, signed in or not) |
| `X-Aseman-User-Token` | only for a **signed-in** person: the token your server uses the space's agents and apps with for them |
| `X-Aseman-User`, `X-Aseman-User-Handle` | the signed-in person (the platform's) |
| `X-Aseman-Api` | the API URL |

```js
const { Aseman } = require("./vendor/aseman-sdk/server.cjs");
app.use(Aseman.middleware());          // req.aseman (signed in only), req.asemanPlatform

app.get("/api/catalog", async (req, res) => {
  res.json(await catalog.list());       // no agent needed: visitors get it too
});

app.post("/api/advice", async (req, res) => {
  if (!req.aseman) return res.status(401).json({ error: "Sign in to get advice" });
  const { reply } = await req.aseman.ask("Advisor", "Recommend for: " + req.body.need);
  res.json({ reply });                  // Advisor is in APPS.json → agents
});
```

```python
from aseman_server import Aseman
platform = Aseman.platform_of(request.headers)        # {slug, id, name}
if Aseman.has_user(request.headers):
    aseman = Aseman.from_headers(request.headers)      # aseman.user, aseman.platform
    quote = aseman.call("Pricing", "quote", {"sku": sku})   # an app in APPS.json
```

## Signing people in

The platform's people have the platform's own accounts. The platform's
Aseman client (built for it) signs them in and opens the frontend as its
home, already signed in. In a browser,
the frontend signs them in itself, through the gateway — the session goes
into the frontend's own HttpOnly cookie, never into your page or server:

```js
// vendor/aseman-sdk/aseman.js (page)
const { user, platform } = await Aseman.me();            // user null: a visitor
await Aseman.signIn(accountHandleOrEmail, password);      // POST _aseman/auth/login
await Aseman.signUp(handle, email, password);             // a new account on this platform
await Aseman.signOut();
location.reload();                                        // next requests carry the session
```

(An Elpian frontend runs in the Aseman client, which handles sign-in; it reads
`Aseman.context()` to know who is there.) Never ask for or store passwords on
your server, and never call the node's auth actions from your page.

## Rules

1. **Signed out first.** A visitor has no token: serve what needs no agent or
   app (the landing, the catalog, what the product is) and a clear sign-in.
   Never call the Aseman API for them, from the page or the server; on the
   page, `Aseman.context()` has no `user` for them and `_aseman/api/*`
   answers 401.
2. **Serve people with their request's token** (`Aseman.fromRequest(req)` /
   `req.aseman`), never the app key: the usage record then names the
   platform's person. `Aseman.app()` (the app key) is for work nobody is in
   front of — it runs as the person who asked for the app.
3. **Your data is per person.** Key what you store by `X-Aseman-User` (the
   platform's person id), never by the space or a shared default, and never
   show one person another's data.
4. **Only `APPS.json`.** The frontend reaches exactly the agents and apps it
   was built against (and only those microtools). Listing calls
   (`agents`, `tools`) show only those.
5. **No desk, no space files.** `_aseman/api/show` and `file/<id>` are not
   served to a platform's people: render results in the app itself.
6. **Branding is the platform's.** Use the platform's name
   (`X-Aseman-Platform-Name`, `Aseman.context().platform.name`) where the
   product names itself; keep Aseman's theming (light/dark, accent) unless the
   brief asks for a dedicated brand look.
7. **Test both doors.** Unit/API tests for a signed-out request (no token
   headers: no Aseman calls, a sign-in prompt) and a signed-in one (mocked
   server SDK). With an Elpian frontend, save e2e scenarios for both.
