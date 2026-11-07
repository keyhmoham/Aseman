# Workflow installer

> **Brief:** one JSON document describes, in order, everything a product
> needs on Aseman: the developer organization, its team, platform and API
> keys; the spaces, rooms, agents and apps; the full source of an Elpian or
> web app written onto a space's computer, built, tested and served; model
> calls; and the checks that prove it worked. The developer API validates it,
> plans it (a dry run that says what it would create or update), and runs it.
> Running it again changes only what differs.

Code: `services/plugins/actions/developer/workflow` (the engine: format,
expressions, upserts, control flow) and
`services/plugins/actions/developer/workflows.go` (the node binding: who the
run acts as, what it may call, the stored runs, the HTTP and console doors).
A complete example: [`docs/workflows/fullstack-product.json`](workflows/fullstack-product.json).
An agentic product: [`docs/workflows/study-planner.json`](workflows/study-planner.json)
— a study planner whose plans are written by a custom Planner agent the
workflow creates ([`study-planner/README.md`](workflows/study-planner/README.md)).
A whole platform: [`docs/workflows/aseman-arena.json`](workflows/aseman-arena.json)
— a 3D gaming platform with players' garages, rooms bound to games, two
Godot games against AI built from source, leaderboards, friends and a Game
Forge agent that builds new games with the players
([`aseman-arena/README.md`](workflows/aseman-arena/README.md)).
Editors: [`docs/workflows/workflow.schema.json`](workflows/workflow.schema.json)
(JSON Schema 2020-12; point `"$schema"` at it for completion and checking).
**Writing one well** (patterns, pitfalls, a checklist — for models and
people): [`docs/workflows/AUTHORING.md`](workflows/AUTHORING.md), served as
`GET /v1/workflows/guide`.

---

## 1. Running one

### Developer host (API key)

The key needs **platform: write** to plan or run (read to validate and read
runs). Every step acts as **the person who created the key**, exactly like
`POST /v1/platform/{namespace}/{action}`, and what it creates is stamped with
the platform the key is bound to (or the organization's only platform).

| | |
| --- | --- |
| `POST /v1/workflows/validate` | `{workflow}` → `{valid, issues[], steps, inputs, secrets}` |
| `POST /v1/workflows/plan` | `{workflow, inputs}` → a run record with the plan (nothing is changed) |
| `POST /v1/workflows/runs` | `{workflow, inputs, secrets, async?, wait_seconds?, resume_from?}` → `200` with the report when it finishes within `wait_seconds` (default 540, at most 1500), else `202` with the run still going; `async: true` answers `202` at once |
| `GET /v1/workflows/runs` | the organization's runs, newest first (`?limit=`) |
| `GET /v1/workflows/runs/{id}` | one run with its full report |
| `POST /v1/workflows/runs/{id}/cancel` | stop a run (it rolls back if the workflow asks to) |
| `GET /v1/workflows/reference` | step kinds, built-in resources, functions, limits |
| `GET /v1/workflows/schema` | the JSON Schema |
| `GET /v1/workflows/guide` | the authoring guide (markdown in `content`) |

```bash
curl -sS https://dev.example.com/v1/workflows/runs \
  -H "Authorization: Bearer $ASEMAN_KEY" -H "Content-Type: application/json" \
  -d "$(jq -n --slurpfile wf docs/workflows/fullstack-product.json \
        '{workflow: $wf[0], inputs: {product: "Acme Bookings"}, secrets: {SESSION_SECRET: "…"}, async: true}')"
```

`workflow` may be the document itself or a JSON string of it. Long runs: use
`async` (or rely on the `202`) and follow `GET /v1/workflows/runs/{id}`; the
edge's and the web app's proxies end a request after 30 and 10 minutes.

### The CLI

`aseman workflow` (`go run ./cmd/aseman workflow help`) reaches either door:
with `--key` (or `$ASEMAN_DEVELOPER_KEY`, `--api` / `$ASEMAN_DEVELOPER_API_URL`)
the developer API, otherwise the session of `aseman login`.

```bash
aseman workflow validate docs/workflows/fullstack-product.json
aseman workflow plan     docs/workflows/fullstack-product.json product="Acme Bookings"
SESSION_SECRET=… aseman workflow run docs/workflows/fullstack-product.json \
    product="Acme Bookings" --assets ./my-app=app/ --key "$ASEMAN_DEVELOPER_KEY"
aseman workflow runs | get <id> | cancel <id> | schema | reference | guide
```

Declared secrets not given with `--secret NAME=VALUE` are read from the
environment variable of the same name. `--assets dir=prefix/` adds every file
under a local folder to the document's assets (text as text, the rest as
base64, executables keep `0755`; `.git`, `node_modules` and build folders are
skipped), so a whole source tree ships with the installer. A run still going
is followed, its log printed as it grows; the exit status says how it ended.

### Console (signed in)

**Developer API → Build → Workflows** in the app: open a `.json` file or start
from a template, give inputs and secrets, Validate (issues with their paths),
Plan, Run; a run is followed live (steps, what each created or updated,
outputs, log) and can be cancelled or resumed. Runs started with keys are
listed too.

Underneath, signed actions of the `developer` namespace, with `org`
("personal" or a team id): `workflow_validate`, `workflow_plan`,
`workflow_run`, `workflow_runs`, `workflow_run_get`, `workflow_run_cancel`,
`workflow_reference`, `workflow_schema`, `workflow_guide`. The console needs the **resources**
role in the organization (owner, admin or developer).

### What each door may call

| | Console | API key |
| --- | --- | --- |
| Platform actions (`spaces.*`, `bots.*`, `tools.*`, `routines.*`, …) | ✓ | ✓ |
| Node administration (`admin.*`, `*.admin_*`) | ✗ | ✗ |
| `developer.*`: platform, frontend, computers, files, models, usage | ✓ | ✓ (each needs the key's matching permission: computers, files, models, usage) |
| `developer.*`: organizations, members, keys, wallet funding, settings | ✓ (the person's role decides) | ✗ |
| `developer.workflow_*` | ✗ | ✗ |

So a key can never do more through a workflow than it could call itself, and
a whole organization (team, members, keys) is brought up from the console.
`developer.*` steps without an `org` use the run's organization; a key's run
cannot name another.

---

## 2. The document

```jsonc
{
  "aseman_workflow": "1",            // format version (required)
  "name": "acme-bookings",           // required
  "version": "1.0.0", "description": "…",
  "inputs":   { "product": {"type": "string", "default": "Acme", "required": false,
                            "enum": [...], "pattern": "…", "min": 3, "max": 40, "sensitive": false} },
  "secrets":  ["SESSION_SECRET"],    // or {"NAME": {"description", "required"}}
  "vars":     { "slug": "${{ slug(inputs.product) }}" },   // computed first, in dependency order
  "defaults": { "retry": {...}, "timeout": "5m", "continue_on_error": false,
                "with": {"developer": {"org": "…"}} },       // merged under every action of a namespace
  "options":  { "rollback_on_failure": true, "timeout": "45m", "max_steps": 5000,
                "org": "personal", "stamp_platform": false,
                "platform": "acme" },           // which of the org's platforms to stamp
  "assets":   { "app/server.py": "text", "logo.png": {"base64": "…"}, "cfg.json": {"json": {...}},
                "index.html": {"content": "…", "template": true, "mode": "0644"} },
  "templates": { "name": {"params": {...}, "steps": [...], "outputs": {...}} },
  "steps":    [ ... ],
  "on_failure": [ ... ],             // after rollback, with `failure` = {path, code, message}
  "finally":    [ ... ],             // always, with `outcome` = {status, error}
  "outputs":  { "preview": "${{ steps.install.outputs.proxy.url }}" }
}
```

Unknown fields are refused, so a typo is an error rather than a setting that
silently does nothing. Input `type`: string, number, integer, boolean,
object, list, any. Types: `inputs` arrive as JSON; `"3"` for an integer input
is accepted.

### Steps

Every step has exactly one kind, plus any of the common fields.

| Kind | Shape | Does |
| --- | --- | --- |
| `action` | `{"action": "spaces.space_create", "with": {...}}` | any action the door allows (see `GET /v1/platform`) |
| `upsert` | `{"upsert": {"resource": "agent", "with": {...}}}` | find, then create or update — see §3 |
| `model` | `{"model": {"type": "chat", "body": {"model": "…", "messages": [...]}}}` | a model call, routed, billed and logged like `/v1/chat/completions`; types: chat, embeddings, image, speech, transcription, rerank, decision. Chat answers carry `text` |
| `sandbox` | see §4 | write source onto a space's computer, run commands, serve a port |
| `wait` | `{"wait": {"action": "…", "with": {...}, "until": "result.status == 'running'", "interval": "5s", "timeout": "10m"}}` | poll until a condition holds (`result`, `polls`) |
| `set` | `{"set": {"name": "${{ … }}"}}` | set workflow vars |
| `assert` | `"expr"`, `{"that", "message"}` or a list | fail when false |
| `log` | `"text"` | a line in the run's log |
| `sleep` | `"10s"` | pause |
| `fail` | `"message"` | stop with an error |
| `steps` | `{"steps": [...], "parallel": false}` | a group; `parallel: true` runs them at once |
| `use` | `{"use": "template", "with": {...}}` | a template (its own step ids, `params` in scope) |

Common fields:

| Field | |
| --- | --- |
| `id` | how later steps refer to it: `steps.<id>.outputs`, `.status`, `.error`; upserts also `.id`, `.operation`. Letters, digits, `_`; unique |
| `name`, `description` | for people |
| `if` | `"${{ inputs.x }}"` or a bare expression; false skips the step |
| `for_each` | a list, an object (as `{key, value}` items) or a number; with `as`, `index_as`, `concurrency` (≤16) and `collect` (what each iteration adds to the outputs list; default its output). The loop's `if`/`outputs`/`export` apply once; `retry`, `timeout`, `on_error`, `compensate` per item. `loop` = `{index, first, last, length}` |
| `retry` | `{"attempts": 3, "delay": "2s", "backoff": 2, "max_delay": "30s", "on": ["unavailable", "timeout"]}` — by default everything but invalid_argument, permission, not_found, already_exists, finance and assertions is retried |
| `timeout` | per attempt |
| `continue_on_error` | the run goes on; `steps.<id>.status` is `failed` |
| `on_error` | steps run on failure, with `error` = `{path, code, message}` |
| `compensate` | a step that undoes this one on rollback, with `result` = its outputs |
| `outputs` | reshape what the step answers (`result` is the raw answer) |
| `export` | `{"var": "${{ result.x }}"}` — set workflow vars |
| `sensitive` | keep the request and outputs out of the stored run |
| `plan` | `"run"`: a plan runs this read-only action for real; `"skip"`: a plan leaves it out |

Error codes: `not_found`, `already_exists`, `invalid_argument`,
`permission`, `unauthenticated`, `conflict`, `unavailable`, `finance`,
`timeout`, `rate_limited`, `assertion`, `failed`, `invalid_workflow`,
`limit`, `cancelled`, `internal`.

---

## 3. Upserts

```jsonc
{"id": "agent", "upsert": {
  "resource": "agent",                       // a built-in kind, or "define" one
  "match": {"name": "Builder"},              // what identifies it (default: per resource, e.g. name)
  "with": {"name": "Builder", "model": "…", "instructions": "…"},
  "create_with": {...}, "update_with": {...},// only when creating / updating
  "mode": "upsert",                          // upsert | ensure (never update) | update (must exist) | create (must not)
  "skip_unchanged": true,                    // no update when the record already holds every value
  "rollback": true                           // delete it on rollback when this run created it
}}
```

Outputs: `{id, operation: created|updated|unchanged, created, record, result}`.
A plan answers `would_create`, `would_update`, `unchanged`, or
`create_or_update` when what it would look for is not known yet.

| Resource | Matched by | Actions |
| --- | --- | --- |
| `space` | name | `spaces.space_list` (paged) / `space_create` / `space_update` / `space_delete` |
| `room` | name in `space` | `spaces.room_list` (paged) / `room_create` / `room_update` / `room_delete` |
| `agent`, `app`, `theme` | name and kind | `bots.bot_list` (paged) / `bot_create` / `bot_edit` / `bot_delete` |
| `space_bot` | `bot` in `space` | `spaces.bots_list` / `bot_add` / `bot_remove` |
| `proxy` | `port` in `space` | `spaces.proxy_list` / `proxy_create` / `proxy_delete` |
| `org` | name | `developer.orgs_list` / `org_create` / `org_delete` (console) |
| `member` | handle in `org` | `developer.members_list` / `member_invite` / `member_role` / `member_remove` (console) |
| `platform` | slug in `org` (an org may have several) | `developer.platforms_list` / `platform_create` / `platform_rename` / `platform_delete` |
| `key` | name (active) in `org` | `developer.keys_list` / `key_create` / `key_update` / `key_delete` (console); the secret is in `outputs.result.secret` when created |
| `computer` | name in `org` | `developer.computers_list` / `computer_create` / `computer_delete` |

Any other resource, or a different way to find one:

```jsonc
"upsert": {"match": {"key": "theme"}, "with": {"space": "…", "key": "theme", "value": "dark"},
  "define": {
    "find":   {"action": "spaces.kv_list", "with": {"space": "${{ params.space }}"}, "items": "items"},
    "create": {"action": "spaces.kv_set",  "with": "${{ params }}", "id": "${{ params.key }}"},
    "update": {"action": "spaces.kv_set",  "with": "${{ params }}"},
    "delete": {"action": "spaces.kv_delete", "with": {"space": "${{ params.space }}", "key": "${{ id }}"}},
    "record_id": "key", "compare": ["value"]
  }}
```

In a define: `params` is match + with (+ create_with / update_with), `id`
the resource's id, `found` the matched record; `items` (a list) or `item`
(a singleton) says where records are in the find's answer; `page`
(`{"limit": 200, "max_pages": 50, "limit_field": "limit", "offset_field": "offset"}`)
reads page after page until a match or an empty page; `id` in create
is a path into its answer or an expression. A `define` next to `resource`
replaces just those parts of the built-in one.

---

## 4. Installing software: `sandbox`

```jsonc
{"id": "install", "sandbox": {
  "space": "${{ steps.space.outputs.id }}",
  "start": true,                 // wake the computer, wait until it runs
  "root": "apps/shop",           // under /workspace
  "clean": true,                 // empty the root first
  "assets": "app/",              // copy the assets under this prefix (prefix dropped); "*" all
  "files": {                     // and these
    "README.md": "# Shop",
    ".env": "SECRET=${{ secrets.SESSION_SECRET }}",
    "config.json": {"json": {...}},
    "logo.png": {"base64": "…"},
    "server.py": {"asset": "app/server.py", "mode": "0755"},
    "ci.yml": {"$raw": "${{ this stays as it is }}"}
  },
  "render": true,                // render ${{ }} in the step's own file texts (off by default)
  "env": {"PORT": 8080},         // exported to every command
  "workdir": "",                 // default: the root
  "exec": ["pip install -r requirements.txt",
           {"run": "pytest -q", "expect": "passed", "workdir": "tests", "env": {...}, "ignore_exit": false}],
  "proxy": {"port": 8080, "title": "Shop", "start": "python server.py", "replace": false}
}}
```

Files go through `spaces.sandbox_files` (a sleeping computer is woken when a
write needs it, and one that never ran is started); `clean` is `rm -rf` of
the root on the computer; commands go through `spaces.sandbox_exec`, each in its working
folder with the environment exported. **A command that exits non-zero fails
the step** (its output's tail is the error), as does an `expect` that does
not appear. The proxy (`spaces.proxy_create`) is reused when the port is
already served, unless `replace`. Outputs: `{space, root, files, commands:
[{command, exit_code, output}], proxy: {proxy_id, url, …}}`.

Assets are written byte for byte unless marked `"template": true`, so source
code that itself contains `${{` (a CI file, a template engine) is safe.

**A platform's frontend** must be an app the space's agents built and
published (`appui_create`, then `appui_publish`): it carries its backend and
its wiring to the space's agents and apps, and
`developer.platform_frontend_publish` refuses anything else. So a workflow
asks an agent for it — a `spaces.ask` step to the Builder ("build the
platform's frontend with appui_create, audience platform, …, appui_publish,
then platform_publish") — as the example does with `build_frontend`. An app
a workflow installs directly (like the example's booking server) is served
as a preview with `proxy`.

---

## 5. Expressions

`${{ … }}` anywhere in a string. A string that is exactly one expression keeps
its type (`"${{ inputs.count }}"` is a number); otherwise each is rendered as
text. `$${{` writes a literal `${{`; `{"$raw": value}` is never rendered.
`if`, `until` and `assert` take a bare expression too.

- Paths: `inputs.x`, `vars.x`, `secrets.X`, `steps.id.outputs.a[0]["b"]`,
  `assets["app/x.py"].size`, `run.id`. A field of null is null.
- Operators: `== != < <= > >= && || ! not + - * / % ?? in`, `c ? a : b`;
  `+` also joins text and lists and merges objects.
- Lambdas: `map(list, x => x.name)`, `filter(list, x => x.kind == 'agent')`,
  `find(list, 'name', 'Builder')`.
- Functions (full list in `/v1/workflows/reference`): text (`lower upper trim
  title slug replace split join substr truncate format indent regex_match
  regex_replace regex_find url_encode`), encoding (`json from_json base64
  base64_decode sha256`), checks (`default coalesce empty not_empty len
  contains type_of is_unknown`), objects (`keys values entries from_entries
  merge pick omit get has object`), lists (`list concat flatten unique reverse
  sort sort_by first last slice range index_of map pluck filter where find any
  all count group_by key_by sum min max`), numbers (`int number round floor
  ceil`), assets (`file file_base64 files`), and `now timestamp uuid
  random_hex`.

---

## 6. Runs, plans, safety

- **Validation first.** Every run validates the whole document — kinds,
  ids, references to `steps.<id>`, expressions, templates, inputs, and that
  each action exists and the door allows it — and runs nothing if it fails.
- **Plans** render every request, run only the reads an upsert needs to say
  what it would do, and show values not known yet as `«steps.x.outputs.id»`.
- **Idempotent.** Upserts find before they create, skip unchanged updates,
  and the sandbox reuses a served port: a second run reports `unchanged`.
- **Rollback.** With `options.rollback_on_failure`, a failed run undoes,
  newest first, what it created (upserts' deletes, served ports, each
  step's `compensate`). Status `rolled_back`; each undo is in `report.rollback`.
- **Resume.** `resume_from: <run id>` reuses the outputs of the top-level
  steps that run finished; the document and the inputs default to that
  run's, so only the secrets are given again. A step whose stored outputs
  had something hidden (a new key's secret), or that is `sensitive`, runs
  again rather than hand later steps a redacted value.
- **Secrets** are never stored. Their values, `sensitive` inputs and fields
  named like `secret`, `password`, `token` or `api_key` are replaced with
  `••••••` in the stored report, the events and the answer. Workflow requests
  are not written to the request log.
- **Limits:** 48 MB document, 5000 executed steps, depth 24, 16 at once,
  20 attempts, 1 h default / 6 h max run time, 3 runs at once per
  organization (counted across nodes).
- **Several nodes.** The node running a workflow saves a heartbeat every 20 s
  and looks for a cancel asked on any node (`dev_workflow_cancels`); a run
  without a heartbeat for 2 minutes reads `interrupted`, and cancelling it
  closes it.

The report: `{status, error, error_code, error_path, issues, inputs,
outputs, steps: [{path, id, kind, action, status, operation, attempts,
request, outputs, error, duration_ms}], rollback, events, counts}`; status
`running`, `succeeded`, `planned`, `failed`, `rolled_back`, `cancelled`.

---

## 7. Proving it on a whole node

`services/internal/plugins/host/testdata/workflow` boots a node from the
native plugins and runs the example from the console — organization,
member, platform, key, project, rooms, agents, the app written, tested and
answering HTTP, a model's welcome — then a rerun that creates nothing, a
key's workflow through the CLI on the developer API, and a rollback. As root
on a throwaway machine (the project's computer is that machine's
`/workspace`), after `make plugins` and `npm ci` in `deploy/tool-runtime`:

```bash
ASEMAN_WORKFLOW_E2E=1 go test ./internal/plugins/host -run WorkflowE2E
```
