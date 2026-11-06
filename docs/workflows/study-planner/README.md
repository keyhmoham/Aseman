# آسمان‌درس — an agentic study planner, as one workflow

[`../study-planner.json`](../study-planner.json) brings up a whole product on
Aseman: a study planner for Iranian school students whose plans are written
by a **custom agent the workflow creates**. The app collects the student's
answers; the agent decides the plan and writes the counsel; the app holds the
agent's answer to the rules, sends it back to fix what breaks one, and files
the accepted plan into the student's calendar.

## What the workflow makes

| Step | What |
| --- | --- |
| `org`, `team`, `platform` | the product's organization, its developers, its platform |
| `server_key` | a developer key (`platform: write`) for the app server, `ensure`d and sensitive; written once to `/workspace/secrets/<slug>/server.env` (`server_secrets`) |
| `space`, `planning_room`, `team_room` | the project; the app's asks run in temporary threads of **Planning** |
| `planner` | **the Planner agent**: its instructions are the planning method (spaced practice, interleaving, retrieval practice, the concerns' adaptations), the answer contract and the self-check tool |
| `helpers` | the **Curator** (keeps the course lists true to chap.sch.ir) and the **Counselor** (the team's questions) |
| `install` | the app written to `/workspace/apps/<slug>`, its 18 tests and the offline self-test run, served on the port |
| `healthy` | waits until `/healthz` says the agent is connected |
| `curriculum_check` | the official lists are served |
| `agent_plan` | **proof**: `plan_tool.py e2e` asks the running app for a real plan and waits until the Planner agent has made it (`prove_agent`) |
| `curate` | optional (`verify_curriculum`): the Curator checks the lists against chap.sch.ir and writes `curriculum.overrides.json`, which the app merges on every request |

| `elpian_app` | the **native Elpian frontend** opened on the project's desk: `appui_publish` (the platform bundles it, runs it on QuickJS against the server and replays its end-to-end scenarios first) (`elpian_frontend`) |

## Install or update: `deploy.sh`

One command installs the product on a node, or updates an install in place
(the workflow converges: a rerun changes only what differs; the students'
data and the key stay):

```bash
docs/workflows/study-planner/deploy.sh --server https://aseman.example.com
```

It bundles the app into the workflow, runs the app's tests, checks the
Elpian frontend on QuickJS with its scenarios, signs in when there is no
session (`--handle`, `$ASEMAN_PASSWORD`), validates on the node, shows the
plan (what would be created, updated or left unchanged — first install or
update), asks, runs and follows it, and keeps the run in `.deploy/` so a
failed one resumes with `--resume`. `--plan` only shows the plan, `--yes`
does not ask, and any input follows as `name=value`
(`product=… agent_model=gpt-5-mini verify_curriculum=true`). `--dev-api` is
the developer API as the project's computer reaches it (in the Docker
stack: `http://aseman:8080/dev/v1`). It uses `aseman` from `PATH`, or builds
it from `services/cmd/aseman`.

The same by hand, from the console door (it creates an organization and a key):

```bash
aseman workflow plan docs/workflows/study-planner.json developer_api_url=https://aseman.example.com/dev/v1
aseman workflow run  docs/workflows/study-planner.json developer_api_url=https://aseman.example.com/dev/v1
```

`developer_api_url` is the node's developer API as the space's computer
reaches it (`http://aseman:8080/dev/v1` inside the Docker stack). A rerun
changes only what differs; the students' data (`/workspace/data/<slug>`) and
the key file survive reinstalls.

## The agentic loop

```
student's answers ──► app: validate, compute the free slots and the settings
                       │   (session length, break, daily cap, bedtime, rest day…
                       │    from the stage, the goals and the concerns)
                       ▼
          brief (student, slots, refs, rules, answer shape)
                       │  POST {developer API}/platform/spaces/ask
                       ▼                (Planner agent, temp thread)
          the agent's JSON plan + counsel
                       │
          planner.check ── broken rules? ──► sent back to the agent (≤ planner_rounds)
                       │ ok
                       ▼
          assemble: timetable, every dated session, charts, advice
          with the agent's citations resolved from the catalog ──► calendar
```

The agent can only cite references the app gives it (`refs`), so every
source shown to a student is real; the help card for distress (۱۲۳ and ۱۴۸۰)
never depends on the agent.

## The app (`app/`)

- `data/curriculum.json` — the official courses of grades 1–12 and, from grade
  10, of each field (source: the textbook catalogue of سازمان پژوهش و
  برنامه‌ریزی آموزشی, chap.sch.ir).
- `data/goals.json`, `data/concerns.json` — goals and the evidence-based list
  of difficulties (ADHD, test anxiety, procrastination, sleep, learning
  disorders, burnout, …), each with what it changes in a plan, tips and
  peer-reviewed sources.
- `planner.py` — settings, free slots, the rules (`check`), a deterministic
  draft (tests and the offline self-test), and assembling the plan.
- `agent.py` — the brief, reading the reply, the ask-check-repair loop.
- `server.py` — standard-library HTTP server: catalogs, plan jobs, the
  calendar, ticking sessions done.
- `public/` — the page: a step-by-step wizard (grade, field, the official
  courses to confirm, goals, concerns, painting the free hours), the agent at
  work, the plan (counsel, weekly table, donut, bars), the Jalali calendar,
  and the today page that shows the day's sessions from the calendar.

- `elpian/` — the same product as a **native Elpian frontend** for the Aseman
  client (phone, desktop, web): the same steps, screens, palette and
  features, drawn as Flutter widgets from QuickJS. `src/util.js` (Persian
  digits, a Jalali calendar — QuickJS has no `Intl`; `test/jalali.test.mjs`
  checks it day by day against ICU for two centuries), `ui.js` (right-to-left
  rows, the night-sky header, navigation), `data.js` (the server API, the
  agent's job), `wizard.js`, `views.js` (today, calendar, plan), `main.js`
  (the app and its phone widget: today's sessions and the next one). The
  server serves the bundle at `GET /elpian/app.js`; requests through the
  gateway name the Aseman person (`X-Aseman-User`), whose profile is `me`.
  `e2e/*.json` are the journeys the platform replays before it opens the
  app, written by `../elpian_scenarios.py` (the plan and the agent's job are
  mocked there, so a check never costs a plan).

Local development (no Aseman needed — `draft` mode plans without the agent):

```bash
cd docs/workflows/study-planner/app
python3 test_app.py
PLANNER_MODE=draft PORT=8080 python3 server.py
```

The Elpian frontend, with the kit in `deploy/sandbox-computer/appui/elpian`
(QuickJS from `cd deploy/tool-runtime && npm ci`):

```bash
KIT=../../../../deploy/sandbox-computer/appui/elpian
node $KIT/bundle.mjs .
node $KIT/check.mjs elpian/app.js --server http://127.0.0.1:8080
node $KIT/drive.mjs run elpian/e2e --dir . --server http://127.0.0.1:8080
```

After changing anything under `app/`, refresh the workflow's assets:

```bash
python3 docs/workflows/study-planner/bundle.py
```
