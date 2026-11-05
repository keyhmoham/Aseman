# Writing workflows: a guide for models

> **For:** a language model (or a person) asked to write an Aseman workflow
> installer — one JSON document that brings a product up through the
> developer API. Read this before writing one. The format reference is
> [`../WORKFLOWS.md`](../WORKFLOWS.md); the machine-checkable contract is
> [`workflow.schema.json`](workflow.schema.json); a complete, tested example
> is [`fullstack-product.json`](fullstack-product.json).
>
> The developer API serves this guide (`GET /v1/workflows/guide`, console
> action `developer.workflow_guide`), the schema (`/v1/workflows/schema`) and
> the live reference — every step kind, built-in resource and function
> (`/v1/workflows/reference`). The action catalog with each action's input
> fields is `GET /v1/platform`.

---

## 1. What you are writing

A workflow is an **installer**, not a script. A good one:

1. **Converges.** Run it once, the product exists. Run it ten times, it still
   exists exactly once, and only what changed in the document is changed on
   the platform. This comes from upserts, not from luck.
2. **Fails early and says why.** Inputs are typed and constrained; every
   reference is checkable before anything runs; the last steps are
   assertions that prove the product works.
3. **Leaves nothing half-made.** `options.rollback_on_failure` undoes what a
   failed run created; `finally` reports; `on_failure` explains.
4. **Keeps secrets secret.** Secrets come in at run time, never in the
   document; outputs that hold one are `sensitive`.
5. **Can be read.** Steps have ids that name what they make, `name`s a person
   understands, and phases in a sensible order.

Your output is a single JSON object. JSON has **no comments** and **no
trailing commas**; the decoder also refuses any field it does not know, so a
misspelt field is an error, not an ignored setting.

---

## 2. Before you write: decide these

Ask, or infer from the request and say what you assumed:

| Decide | Why it matters |
| --- | --- |
| **Which door runs it** — the console (signed-in person) or an API key | Only the console can create organizations, invite members, make keys or fund wallets. A key's workflow is held to the key's permissions and stamps what it makes with the org's sub-platform. If the product needs an org, its team or keys, it runs from the console. |
| **Is there a sub-platform** | `upsert platform` before anything that should belong to it. From the console, set `options.stamp_platform: true` if the spaces and agents should be the platform's. |
| **What the inputs are** | Everything a second customer would change: product name, team handles, model, ports, feature switches. Give each a type, a default when there is a sensible one, and constraints. |
| **What the secrets are** | API keys of third parties, session secrets, passwords. Declared in `secrets`, used as `${{ secrets.NAME }}`, never written in the document. |
| **What proves success** | A preview that answers, a test command that prints "passed", agents installed, a key created. These become `wait` and `assert` steps at the end. |
| **Which actions you need** | Use only actions that exist (`GET /v1/platform` lists them with their input fields). Do not invent namespaces or fields. |

---

## 3. The shape of a professional workflow

Order the steps in phases; later phases only reference earlier ones.

1. **Identity & money** (console only): `org`, `member` (for each teammate),
   wallet funding if asked.
2. **Platform & access:** `platform`, `key` (mode `ensure`, `sensitive`).
3. **Workspace:** `space`, its `room`s.
4. **Workers:** `agent`s and `app`s (`upsert`), then `space_bot` to install
   each in the space. A template keeps this to one line per agent.
5. **Software:** `sandbox` steps — write the source (assets), install
   dependencies, run the tests, serve the port.
6. **Readiness:** `wait` until the service answers.
7. **Content & handoff:** model calls, messages, asking an agent to do the
   creative part (e.g. build the platform's frontend).
8. **Acceptance:** `assert` what must be true.
9. `on_failure`, `finally`, `outputs` (ids and addresses the caller needs).

Set the run up for that:

```json
"defaults": {"retry": {"attempts": 3, "delay": "2s", "backoff": 2, "max_delay": "30s"}, "timeout": "5m"},
"options":  {"rollback_on_failure": true, "timeout": "45m"}
```

Defaults retry transient errors only (unavailable, timeout, internal…); a
refusal (permission, invalid_argument, not_found, already_exists, finance) is
never retried, so retries do not hide real mistakes.

---

## 4. Rules the engine enforces (and mistakes it will catch)

Write these right the first time.

**Ids and references**
- Step ids are letters, digits and `_` — `build_web`, never `build-web`
  (`-` is subtraction in an expression). Ids are unique in the document.
- Refer to a step as `steps.<id>.outputs…`, `steps.<id>.status`,
  `steps.<id>.error`. Upserts also give `steps.<id>.id`. A reference to a
  step that does not exist is a validation error.
- Inside a **template**, step ids are the template's own and cannot see the
  caller's steps; pass what it needs as `params`.

**One kind per step**
- Exactly one of `action`, `upsert`, `model`, `sandbox`, `wait`, `set`,
  `assert`, `log`, `sleep`, `fail`, `steps`, `use`. `with` goes only with
  `action` or `use`; an upsert's fields go inside `upsert.with`.

**Expressions** (`${{ … }}`)
- A string that is exactly one expression keeps the value's type:
  `"port": "${{ vars.port }}"` sends a number, `"with": "${{ params.agent }}"`
  an object. Mixed text renders as text.
- Text literals inside expressions are quoted: `'agent'` or `"agent"`
  (escape `"` as `\"` inside JSON strings — prefer single quotes).
- There is no `{…}` object literal and no `.method()` call. Use functions:
  `object('model', inputs.model)`, `merge(a, b)`, `pick(x, 'name')`,
  `lower(s)`, `len(list)`.
- Reading a field of null is null (`steps.x.outputs.missing.deeper` is
  null), so guard with `??` or `default()`, not with long `&&` chains.
- `a || b` answers the first truthy value; `a ?? b` the first non-null.
- `if`, `until` and `assert` also take a bare expression without `${{ }}`.
- Lambdas: `map(list, x => x.name)`, `filter(list, x => x.kind == 'agent')`;
  or by field: `find(list, 'name', 'Builder')`, `pluck(list, 'id')`.

**Source code is data**
- Put source files in `assets` and copy them with a sandbox step's
  `"assets": "app/"`. Assets are written **byte for byte** — a CI file's own
  `${{ github.sha }}` stays as it is.
- Only mark an asset `"template": true` when you *want* it rendered (an
  `index.html` with the product's name). A sandbox step's `"render": true`
  renders only that step's own `files`, never copied assets.
- For one literal value anywhere, `{"$raw": "…"}`; for a literal `${{` in a
  rendered string, write `$${{`.

**Agents and models**
- An agent's `model` is the **provider's model name** as the node names it
  (e.g. `gpt-5-mini`), or omit it for the node's default. A `model` step's
  `body.model` is a **developer catalog id** (`openai/gpt-5-mini`, from
  `GET /v1/models`). They are different: never feed one input to both.
- A **platform's frontend** can only be an app the space's agents built and
  published (`appui_create`, `appui_publish`). Do not try to
  `platform_frontend_publish` a preview you installed yourself; ask the
  Builder agent with `spaces.ask` to build and publish it.

**Sandbox**
- `root` and file paths are relative (no `..`, no leading `/`); the engine
  puts them under `/workspace`. Commands run in the root unless `workdir`.
- Every command's exit status counts: a non-zero exit fails the step with the
  end of its output. Add `"expect": "passed"` to also check what it printed;
  `"ignore_exit": true` only for commands that are allowed to fail.
- Use tools the computer has (`python3`, `node`, `sh`); prefer
  `python3 -c "import urllib.request…"` over assuming `curl`.
- Serve with `proxy: {port, title, start}`. The start command is how the
  preview keeps the service running; do not start servers with `&` in `exec`.

---

## 5. Patterns

### Upsert everything that has a name

Prefer `upsert` to a bare `*_create` action. `mode`:
`upsert` (default) creates or updates; `ensure` creates when missing and
never changes it (keys, one-off resources); `update` must exist; `create`
must not exist. Updates are skipped when nothing differs.

```json
{"id": "space", "name": "The project", "upsert": {"resource": "space",
 "with": {"name": "${{ inputs.product }}", "description": "Where ${{ inputs.product }} is built"}}}
```

For a resource with no built-in kind, `define` how it is found and made, so
it converges too (here, a setting kept in the space's key–value store):

```json
{"id": "theme", "upsert": {
  "match": {"key": "theme"},
  "with": {"space": "${{ steps.space.outputs.id }}", "key": "theme", "value": "dark"},
  "define": {
    "find":   {"action": "spaces.kv_list", "with": {"space": "${{ params.space }}"}, "items": "items"},
    "create": {"action": "spaces.kv_set",  "with": "${{ params }}", "id": "${{ params.key }}"},
    "update": {"action": "spaces.kv_set",  "with": "${{ params }}"},
    "delete": {"action": "spaces.kv_delete", "with": {"space": "${{ params.space }}", "key": "${{ id }}"}},
    "record_id": "key", "compare": ["value"]}}}
```

### A template per repeated unit, a loop over the inputs

```json
"templates": {
  "agent_in_space": {
    "params": {"space": {"type": "string", "required": true}, "agent": {"type": "object", "required": true}},
    "steps": [
      {"id": "agent",  "upsert": {"resource": "agent", "with": "${{ params.agent }}"}},
      {"id": "member", "upsert": {"resource": "space_bot", "with": {"space": "${{ params.space }}", "bot": "${{ steps.agent.outputs.id }}"}}}
    ],
    "outputs": {"id": "${{ steps.agent.outputs.id }}", "name": "${{ params.agent.name }}"}
  }
}
```

```json
{"id": "agents", "for_each": "${{ inputs.agents }}", "as": "agent", "concurrency": 3,
 "use": "agent_in_space", "with": {"space": "${{ steps.space.outputs.id }}", "agent": "${{ agent }}"}}
```

`steps.agents.outputs` is then the **list** of each iteration's outputs, so
later steps write `map(steps.agents.outputs, 'id')` or
`find(steps.agents.outputs, 'name', 'Builder').id`.

### Install, test, serve — then prove it answers

```json
{"id": "install", "timeout": "20m", "retry": {"attempts": 1}, "sandbox": {
  "space": "${{ steps.space.outputs.id }}", "start": true, "root": "apps/${{ vars.slug }}", "clean": true,
  "assets": "app/",
  "files": {".env": "PORT=8080\nSECRET=${{ secrets.SESSION_SECRET }}\n"}, "render": true,
  "exec": ["pip install -r requirements.txt", {"run": "python3 -m pytest -q", "expect": "passed"}],
  "proxy": {"port": 8080, "title": "${{ inputs.product }}", "start": "cd /workspace/apps/${{ vars.slug }} && python3 server.py"}}},
{"id": "healthy", "wait": {"action": "spaces.sandbox_exec",
  "with": {"space": "${{ steps.space.outputs.id }}", "command": "python3 -c \"import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3).read().decode())\" 2>&1 || true"},
  "until": "contains(result.output, 'ok')", "interval": "5s", "timeout": "3m"}}
```

Give the install step `retry: {attempts: 1}`: a failing test should stop the
run, not be retried three times. `clean: true` makes the folder exactly what
the document says.

### Hand creative work to an agent

Workflows lay the ground; agents build what needs judgement. Ask in plain
words, naming the tools and the done-condition:

```json
{"id": "frontend", "if": "${{ inputs.build_frontend }}", "timeout": "30m", "continue_on_error": true,
 "action": "spaces.ask", "with": {"space": "${{ steps.space.outputs.id }}",
   "bot": "${{ find(steps.agents.outputs, 'name', 'Builder').id }}",
   "body": "Build the frontend of the ${{ inputs.product }} platform: appui_create (audience platform), wire it to Concierge, test it, appui_publish it, then platform_publish it."}}
```

### Optional steps, tolerated failures, and the record of them

- `if` for feature switches (`"if": "${{ inputs.publish }}"`).
- `continue_on_error: true` only for steps whose failure must not stop the
  product (a welcome message); later steps check
  `steps.welcome.status == 'succeeded'`.
- `on_error` to react on the spot: `{"on_error": [{"log": "…${{ error.message }}"}]}`.

### Secrets and keys

```json
{"id": "server_key", "sensitive": true, "upsert": {"resource": "key", "mode": "ensure",
 "with": {"org": "${{ steps.org.outputs.id }}", "name": "${{ vars.slug }}-server",
          "permissions": {"models": "read", "chat": "write", "platform": "write"}}}}
```

A key's secret exists only in `steps.server_key.outputs.result.secret`, only
in the run that created it — write it straight into the app's settings with a
sandbox file in the same run if the app needs it; it is redacted everywhere it
would be stored. Never put a secret in `outputs` expecting to read it back.

### Rollback that undoes what you did

Upserts that created something delete it on rollback by themselves. For
anything else, add `compensate` to the step:

```json
{"id": "announce", "action": "spaces.message_send", "with": {"space": "${{ steps.space.outputs.id }}", "body": "Live!"},
 "compensate": {"action": "spaces.message_delete", "with": {"space": "${{ steps.space.outputs.id }}", "message": "${{ result.message_id }}"}}}
```

### Acceptance at the end

```json
{"assert": [
  {"that": "${{ len(steps.agents.outputs) == len(inputs.agents) }}", "message": "every agent is in the project"},
  {"that": "${{ not_empty(steps.install.outputs.proxy.url) }}", "message": "the app has a preview address"}]}
```

---

## 6. A complete, small workflow

A project with an agent, a page written and served, checked. Use it as a
skeleton.

```json workflow
{
  "$schema": "https://raw.githubusercontent.com/keyhmoham/Aseman/main/docs/workflows/workflow.schema.json",
  "aseman_workflow": "1",
  "name": "landing-page",
  "description": "A project with a writer agent and a landing page served from its computer.",
  "version": "1.0.0",
  "inputs": {
    "product": {"type": "string", "default": "Acme", "min": 2, "max": 40},
    "port":    {"type": "integer", "default": 8000, "min": 1024, "max": 65535}
  },
  "vars": {"slug": "${{ slug(inputs.product) }}"},
  "defaults": {"retry": {"attempts": 3, "delay": "2s", "backoff": 2}, "timeout": "5m"},
  "options": {"rollback_on_failure": true, "timeout": "20m"},
  "assets": {
    "site/index.html": {"template": true, "content": "<!doctype html><title>${{ inputs.product }}</title><h1>${{ inputs.product }}</h1>\n"}
  },
  "steps": [
    {"id": "space", "name": "Project", "upsert": {"resource": "space", "with": {"name": "${{ inputs.product }} site"}}},
    {"id": "writer", "name": "Writer agent", "upsert": {"resource": "agent",
      "with": {"name": "${{ inputs.product }} Writer", "instructions": "You write the copy of ${{ inputs.product }}'s site."}}},
    {"id": "writer_in_space", "upsert": {"resource": "space_bot",
      "with": {"space": "${{ steps.space.outputs.id }}", "bot": "${{ steps.writer.outputs.id }}"}}},
    {"id": "site", "name": "Write and serve the page", "retry": {"attempts": 1}, "sandbox": {
      "space": "${{ steps.space.outputs.id }}", "start": true, "root": "sites/${{ vars.slug }}", "clean": true,
      "assets": "site/",
      "exec": {"run": "test -s index.html && echo page-ok", "expect": "page-ok"},
      "proxy": {"port": "${{ inputs.port }}", "title": "${{ inputs.product }}",
                "start": "cd /workspace/sites/${{ vars.slug }} && python3 -m http.server ${{ inputs.port }}"}}},
    {"assert": [{"that": "${{ not_empty(steps.site.outputs.proxy.url) }}", "message": "the page has a preview address"}]}
  ],
  "on_failure": [{"log": "Failed at ${{ failure.path }}: ${{ failure.message }}"}],
  "outputs": {
    "space": "${{ steps.space.outputs.id }}",
    "agent": "${{ steps.writer.outputs.id }}",
    "preview": "${{ steps.site.outputs.proxy.url }}"
  }
}
```

A whole product — organization, team, platform, key, rooms, several agents,
a full-stack app with tests, a model call and an agent handoff — is
[`fullstack-product.json`](fullstack-product.json).

---

## 7. How to work: validate, plan, run, read the report

1. **Validate** (`POST /v1/workflows/validate`, `aseman workflow validate`).
   Fix every `error`; read every `warning` (an undeclared input or secret, an
   update or delete action this door cannot call — then updating or rolling
   back that resource will fail).
2. **Plan** (`/plan`). It runs only the reads upserts need and shows each
   step's rendered request, `would_create` / `would_update` / `unchanged`, and
   values not known yet as `«steps.space.outputs.id»`. Check the requests
   carry the fields the actions take.
3. **Run** (`/runs`, `async: true` for anything long), then follow
   `GET /v1/workflows/runs/{id}`.
4. **Read a failure** from the report, not the message alone:
   `error_path` is the step; that step's `request` is what was sent and
   `error` / `error_code` what came back; `events` has each command's exit
   code and the retries. Fix the document, then `resume_from` the run: the
   steps it finished are reused, only the secrets are given again.

Typical failures and their fix:

| Report says | Fix |
| --- | --- |
| `invalid_workflow` … `no step has that id` | a typo in `steps.<id>`, or a template step reaching outside the template |
| `… is not valid JSON for this format: unknown field` | a misspelt or misplaced field (e.g. `with` beside `upsert`) |
| `model … is not offered by …` from `bots.bot_create` | an agent got a catalog id; give it the provider's model name or none |
| `` `cmd` exited 1: … `` | the command failed on the computer; its output's tail is in the error |
| `permission` on `developer.key_create` from a key | run it from the console, or create the key beforehand |
| `only an app the space's agents built …` | ask an agent to build and publish the frontend |
| `the condition did not hold within …` | the service did not come up: read the install step's commands and the proxy's start command |

---

## 8. Checklist before you hand it over

- [ ] `aseman_workflow: "1"`, a `name`, a `version`, a one-line `description`.
- [ ] Every value a second customer would change is an input with a type,
      default and constraints; every credential is a declared secret.
- [ ] Every named thing is an upsert; keys are `mode: "ensure"` and
      `sensitive`.
- [ ] Ids are `snake_case`, unique, and say what the step makes.
- [ ] Source code is in `assets`, copied with `assets: "prefix/"`; only
      intentional templates are `template: true`.
- [ ] Tests run in the install step with `expect`; the install step has
      `retry: {attempts: 1}`; a `wait` proves the service answers.
- [ ] Agents get provider model names; model steps get catalog ids.
- [ ] `options.rollback_on_failure`, `on_failure`, and `outputs` with every
      id and address the caller needs.
- [ ] `assert` steps state what "done" means.
- [ ] It validates with no errors, and the plan reads as intended.
