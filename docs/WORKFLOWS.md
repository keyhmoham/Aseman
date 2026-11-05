# Workflow installer

> **Brief:** one JSON document describes, in order, everything a product
> needs on Aseman: the developer organization, its team, sub-platform and API
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

---

## 1. Running one

### Developer host (API key)

The key needs **platform: write** to plan or run (read to validate and read
runs). Every step acts as **the person who created the key**, exactly like
`POST /v1/platform/{namespace}/{action}`, and what it creates is stamped with
the organization's sub-platform when it has one.

| | |
| --- | --- |
| `POST /v1/workflows/validate` | `{workflow}` → `{valid, issues[], steps, inputs, secrets}` |
| `POST /v1/workflows/plan` | `{workflow, inputs}` → a run record with the plan (nothing is changed) |
| `POST /v1/workflows/runs` | `{workflow, inputs, secrets, async?, resume_from?}` → `200` with the report, or `202` while it runs (`async: true`) |
| `GET /v1/workflows/runs` | the organization's runs, newest first (`?limit=`) |
| `GET /v1/workflows/runs/{id}` | one run with its full report |
| `POST /v1/workflows/runs/{id}/cancel` | stop a run (it rolls back if the workflow asks to) |
| `GET /v1/workflows/reference` | step kinds, built-in resources, functions, limits |

```bash
curl -sS https://dev.example.com/v1/workflows/runs \
  -H "Authorization: Bearer $ASEMAN_KEY" -H "Content-Type: application/json" \
  -d "$(jq -n --slurpfile wf docs/workflows/fullstack-product.json \
        '{workflow: $wf[0], inputs: {product: "Acme Bookings"}, secrets: {SESSION_SECRET: "…"}, async: true}')"
```

`workflow` may be the document itself or a JSON string of it.

### Console (signed in)

The same, as signed actions of the `developer` namespace, with `org`
("personal" or a team id): `workflow_validate`, `workflow_plan`,
`workflow_run`, `workflow_runs`, `workflow_run_get`, `workflow_run_cancel`,
`workflow_reference`. The console needs the **resources** role in the
organization (owner, admin or developer).

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
                "org": "personal", "stamp_platform": false },
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
| `space` | name | `spaces.space_list` / `space_create` / `space_update` / `space_delete` |
| `room` | name in `space` | `spaces.room_list` / `room_create` / `room_update` / `room_delete` |
| `agent`, `app`, `theme` | name and kind | `bots.bot_list` / `bot_create` / `bot_edit` / `bot_delete` |
| `space_bot` | `bot` in `space` | `spaces.bots_list` / `bot_add` / `bot_remove` |
| `proxy` | `port` in `space` | `spaces.proxy_list` / `proxy_create` / `proxy_delete` |
| `org` | name | `developer.orgs_list` / `org_create` / `org_delete` (console) |
| `member` | handle in `org` | `developer.members_list` / `member_invite` / `member_role` / `member_remove` (console) |
| `platform` | the org's one | `developer.platform_get` / `platform_create` / `platform_rename` / `platform_delete` |
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
(a singleton) says where records are in the find's answer; `id` in create
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
write needs it); commands through `spaces.sandbox_exec`, each in its working
folder with the environment exported. **A command that exits non-zero fails
the step** (its output's tail is the error), as does an `expect` that does
not appear. The proxy (`spaces.proxy_create`) is reused when the port is
already served, unless `replace`. Outputs: `{space, root, files, commands:
[{command, exit_code, output}], proxy: {proxy_id, url, …}}`.

Assets are written byte for byte unless marked `"template": true`, so source
code that itself contains `${{` (a CI file, a template engine) is safe. For an
Elpian or web App UI meant for agents to keep building, write the project
where `appui_create` would and have an agent `appui_publish` it, or publish
it as the platform's frontend with `developer.platform_frontend_publish`.

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
  steps that run finished (the document defaults to that run's). Stored
  outputs are redacted, so a secret a resumed step produced is not available.
- **Secrets** are never stored. Their values, `sensitive` inputs and fields
  named like `secret`, `password`, `token` or `api_key` are replaced with
  `••••••` in the stored report, the events and the answer. Workflow requests
  are not written to the request log.
- **Limits:** 48 MB document, 5000 executed steps, depth 24, 16 at once,
  20 attempts, 1 h default / 6 h max run time, 3 runs at once per
  organization. A run whose node stopped reads `interrupted`; cancelling it
  closes it.

The report: `{status, error, error_code, error_path, issues, inputs,
outputs, steps: [{path, id, kind, action, status, operation, attempts,
request, outputs, error, duration_ms}], rollback, events, counts}`; status
`running`, `succeeded`, `planned`, `failed`, `rolled_back`, `cancelled`.
