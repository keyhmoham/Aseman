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
| `org`, `team`, `platform` | the product's organization, its developers, its sub-platform |
| `server_key` | a developer key (`platform: write`) for the app server, `ensure`d and sensitive; written once to `/workspace/secrets/<slug>/server.env` (`server_secrets`) |
| `space`, `planning_room`, `team_room` | the project; the app's asks run in temporary threads of **Planning** |
| `planner` | **the Planner agent**: its instructions are the planning method (spaced practice, interleaving, retrieval practice, the concerns' adaptations), the answer contract and the self-check tool |
| `helpers` | the **Curator** (keeps the course lists true to chap.sch.ir) and the **Counselor** (the team's questions) |
| `install` | the app written to `/workspace/apps/<slug>`, its 18 tests and the offline self-test run, served on the port |
| `healthy` | waits until `/healthz` says the agent is connected |
| `curriculum_check` | the official lists are served |
| `agent_plan` | **proof**: `plan_tool.py e2e` asks the running app for a real plan and waits until the Planner agent has made it (`prove_agent`) |
| `curate` | optional (`verify_curriculum`): the Curator checks the lists against chap.sch.ir and writes `curriculum.overrides.json`, which the app merges on every request |

Run it from the console (it creates an organization and a key):

```bash
aseman workflow validate docs/workflows/study-planner.json
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

Local development (no Aseman needed — `draft` mode plans without the agent):

```bash
cd docs/workflows/study-planner/app
python3 test_app.py
PLANNER_MODE=draft PORT=8080 python3 server.py
```

After changing anything under `app/`, refresh the workflow's assets:

```bash
python3 docs/workflows/study-planner/bundle.py
```
