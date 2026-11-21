# Aseman Peyda

One workflow installer that brings up the **aseman-peyda** organization and platform on Decillion, with **Peyda** as its product: a search engine for the Iranian web.

- **GLiNER2** ([fastino-ai/GLiNER2](https://github.com/fastino-ai/GLiNER2)) reads a query and turns it into a structured *frame*: domains, intent, and slots (product, brand, city, origin, destination, date, price range…).
- **iran-mcp** ([sepehr071/iran-mcp](https://github.com/sepehr071/iran-mcp)) is the search backend: the frame is turned into tool calls on 61 Iranian sites (Digikala, Torob, Divar, Snapp, MrBilit, Paziresh24, Kilid, TGJU, news, Wikipedia…), asked in parallel.
- **Google Maps** ([Google Maps Scraper Kit](https://github.com/mahanaicoach/google-maps-scraper-kit#use-it-with-claude-code-or-any-agent)) is a second search backend, for places and local businesses (cafés, restaurants, clinics, hotels, salons, workshops): name, category, rating and reviews, phone, opening status, address and the Maps link. The kit's engine runs unmodified on the project's computer and Peyda puts an MCP server in front of it (`peyda/gmaps_mcp.py`), so the gateway asks it exactly as it asks an iran-mcp server: in plain search and in the agentic loop, where the Analyst reviews and answers from its results.
- **Peyda Analyst**, a Decillion agent, is in the loop when **Agentic search** is on: it reads what GLiNER2 extracted and what the sites returned, decides whether to accept, write a better query (which goes back through GLiNER2 → iran-mcp) or ask the person, and then answers in the chat, remembering the conversation.
- The frontend is an **Elpian** program: a Google-like first page, a results page, and a chat page.

```
                         ┌──────────────────────── Decillion node ────────────────────────┐
 person ──► Peyda        │ platform "aseman-peyda"  /v1/platforms/aseman-peyda/app/       │
 (Elpian)   frontend ────┼─► project "Peyda" (one computer)                               │
                         │     Peyda server (FastAPI)                                      │
   plain search ─────────┼──►   GLiNER2 ─► frame ─► iran-mcp gateway ─► 61 stdio servers ─► sites
                         │                              │       └─► gmaps_mcp ─► kit engine ─► Google Maps
                         │                              ▲                                  │
   agentic search ───────┼──►   orchestrator ───────────┘  ◄── frame + results            │
                         │          │  ask (with the chat's history, as the person)        │
                         │          └────────► Peyda Analyst (agent) ──► refine / ask / answer
                         └──────────────────────────────────────────────────────────────────┘
```

## Run it

The installer creates an organization, invites people, makes keys and publishes a platform frontend, so it runs from the **console** (a signed-in person), not with an API key.

```bash
cd DecillionAIOS/services                         # the Decillion CLI lives in the DecillionAIOS repo
go run ./cmd/decillion login                      # once

W=../../Aseman/workflows/aseman-peyda             # this folder, from DecillionAIOS/services
A="--assets $W/app=app/ --assets $W/agents=agents/ --assets $W/brief=brief/"

go run ./cmd/decillion workflow validate $W/aseman-peyda.json $A
go run ./cmd/decillion workflow plan     $W/aseman-peyda.json $A team='["sara"]'

IRAN_PROXY_URL=http://user:pass@iran-proxy:3128 \
go run ./cmd/decillion workflow run      $W/aseman-peyda.json $A team='["sara"]'
```

Or in the console: **Developer API → Build → Workflows**. Open `aseman-peyda.json`, add the three folders as assets, give the inputs and secrets, Validate, Plan, Run.

The first run takes a while, often 15 to 30 minutes, and the workflow waits for it (CPU PyTorch, GLiNER2 and its ~600 MB checkpoint, 61 pinned iran-mcp packages, the test suite, a smoke test with the real model). Reruns are quick.

### Inputs

| Input | Default | |
| --- | --- | --- |
| `org`, `platform_name`, `platform_slug` | `aseman-peyda` | the organization and its platform (`/v1/platforms/<slug>/app/`) |
| `product` | `Peyda` | the product, and the title of its app |
| `team` | `[]` | handles invited as developers |
| `agent_model` | empty | the agents' model, exactly as your node's LLM provider lists it. **Set it** if the run stops with `model gpt-4o-mini is not offered by <provider>`: the node's fallback model is not offered by every provider. Pass it as `agent_model=<id>` |
| `gliner_model` | `fastino/gliner2.5-multi-v1` | the multilingual checkpoint (reads Persian). `gliner2.5-base-v1` is English only |
| `max_rounds` | `3` | the agentic loop's cap per message (1–5) |
| `default_city` | `تهران` | assumed for location-bound services when a query names no place |
| `build_frontend`, `rebuild_frontend` | `true`, `false` | have the Builder adopt and publish the frontend; force a rebuild |
| `manage_network` | `true` | when the node restricts the project's network, add what Peyda needs to the project's allowlist: the package, PyTorch and model hosts, the 61 sites' domains, the Iranian proxy's host. It only adds hosts. `false` leaves the policy alone |
| `egress_allow` | `[]` | extra hosts to allow, such as an API host a site uses outside its main domain (`*.example.com` works) |
| `hf_endpoint` | empty | a Hugging Face mirror's URL for the model download, for networks that cannot reach `huggingface.co` |
| `google_maps` | `true` | add the Google Maps service (installs the Google Maps Scraper Kit's engine at a pinned commit and, when the computer has no Chrome, its pinned headless Chrome). `false` leaves it out of the install and the catalog |

Secrets (all optional): `IRAN_PROXY_URL` (an HTTP proxy with an Iranian address: many iran-mcp sites answer only Iranian connections, and the others still work without it), `HF_TOKEN` (faster model download) and `GMAPS_PROXY_URL` (a proxy for the Google Maps engine's Chrome when Google refuses or rate-limits the computer's address; `http://user:pass@host:port`, or `socks5://host:port` without a password).

## What it does, and why it is safe to rerun

Every entity is an **upsert**: found by name, created when missing, updated when it differs, left alone when it does not.

| Step | Resource | Rerun |
| --- | --- | --- |
| `org` | organization `aseman-peyda` | unchanged |
| `team` | members, by handle | role updated if it differs |
| `platform` | platform, by slug | renamed if the name differs |
| `ops_key` | API key `aseman-peyda-ops`, bound to the platform | permissions and limits updated; the secret is shown only when created |
| `space`, `rooms` | project *Peyda*, rooms *Build* and *Operations* | updated if they differ |
| `agents` | **Peyda Analyst** and **Peyda Builder**, each installed in the project | instructions and model updated in place |
| `egress_now`, `egress_need`, `egress` | the project's network policy (with `google_maps`: also `codeload.github.com`, `storage.googleapis.com`, `google.com`, `*.google.com`, `*.gstatic.com`, `*.googleusercontent.com`, `*.ggpht.com`) | read; extended only when a needed host is missing (adds to the allowlist, keeps what is there, leaves `allow_all` alone); a rerun finds nothing to add |
| `install`, `install_wait`, `install_ok` | the app's files, then the Python environment, model, servers, the Google Maps engine, tests and smoke test | files rewritten to match the document; the install runs **in the background** on the project's computer (`scripts/run_install.sh`) and the workflow polls it, because one command may run only about 5 minutes (the node's `command_timeout_sec`). Packages are pinned; the run stops, with the install log, if any part fails. Don't rerun the workflow while an install is still running |
| `frontend_build` | the app, built by the Builder from the prepared project | **skipped** when an app titled *Peyda* exists and was built from the current source (`vars.stamp`, a hash of `app/`); otherwise the app is updated, never duplicated |
| `frontend` | the platform's published frontend | republished only when it is not already that app |

If the install stops at the network check, its log names the host and says why: `403 … network policy` (the project's policy refuses it: run with `manage_network=true`) or `502` (the policy allowed it but the node could not connect: the host is unreachable from the node's network; for the model use `hf_endpoint`, a mirror).

Nothing is rolled back on failure (`rollback_on_failure: false`): an install takes long and every step is idempotent, so the recovery is to fix the cause and run it again, or `resume_from` the failed run.

## The agentic loop

One chat message (`peyda/orchestrator.py`):

1. **plan** (only when the chat has history) — the Analyst turns "and cheaper ones?" into a complete standalone query, or answers from the conversation without searching.
2. **extract** — GLiNER2 reads the query: entities (12 slot labels) and two classifications (domains, intent) in one pass. Persian and Arabic digits, *million/thousand/Rial* and phrases like "زیر ۲۰ میلیون" are normalised to Toman by rules, which are more reliable than span labels for prices. A city gazetteer and a word list fill what the model leaves empty.
3. **search** — the catalog (`peyda/services.json`, generated from iran-mcp's own `servers.json`) routes the frame's domains to servers. Each tool's JSON Schema is read from the running server and filled from the slots by name. Place names are resolved to the codes tools take (airports, stations, city slugs); a required argument no slot can fill is reported as a **gap**, never invented.
4. **review** — the Analyst receives the frame, every service's status and its best hits, and answers `satisfied`, `refine` (a new query, optionally excluding services or choosing other domains), `ask_user` (a question: "which day do you want to fly?") or `give_up`.
5. On `refine` the new query goes back to step 2. The server, not the agent, owns the limits: `max_rounds`, a repeated query ends the loop, and the **best** round (by a score over results, service spread and priced or linked hits), not merely the last, is answered.
6. **answer** — the Analyst writes the Markdown answer, picks the hits shown as cards, and suggests follow-ups.

The conversation is the agent's memory: an `ask` is an isolated conversation, so the server sends the chat's history with every ask, plus a structured memory of earlier searches (query, frame, top results). If the platform or the agent is unreachable the turn still ends with the raw results, flagged as unreviewed.

If the chat shows **"The analyst was unavailable"**, the line under it (`Why: …`) is the reason the Peyda Analyst could not be reached or understood, taken from the platform's or the SDK's own error (the same text is in the server log as `the analyst failed`). Common causes: the agent's model is not one the node's provider offers (rerun with `agent_model=…`), the agent was renamed or removed (rerun the workflow, which recreates it), or the model answered in prose instead of the JSON the loop needs (choose a more capable `agent_model`). `DecillionError: route not found` means the app API URL the node handed the app (`X-Decillion-Api`) was wrong: nodes built before the fix in `AppAPIURL` (`services/plugins/actions/spaces/app_access.go`) sent `…/deepagents/v1/llm/appapi/v1`; Peyda corrects that URL itself, and rebuilding the node fixes it for every app.

Plain search (switch off) uses no agent and needs no sign-in. Chat needs a signed-in person: their own token reaches the Analyst, so the turn is billed to them.

## Google Maps (`peyda/gmaps.py`, `peyda/gmaps_mcp.py`)

The [Google Maps Scraper Kit](https://github.com/mahanaicoach/google-maps-scraper-kit#use-it-with-claude-code-or-any-agent) is not an MCP server or a library: it is a local HTTP engine (`engine/serve.py`) that drives a headless Chrome against Google Maps, with a job API, plus a CLI and a Claude Code skill around it. Peyda uses the engine and nothing else:

- **Install** (`scripts/install_gmaps.py`, run by `install.sh` unless `PEYDA_GMAPS=0`): the kit's source at the commit pinned in `peyda/gmaps.py` (`KIT_COMMIT`), from GitHub's archive, into `/workspace/.gmaps-kit`; then the kit's own `scripts/engine.py start`, which downloads its pinned Chrome for Testing headless shell (checked against its SHA-256) when the computer has no Chrome; the engine must answer, and is stopped again. A rerun keeps a kit that is already at that commit, with its Chrome.
- **Run**: `start.sh` starts the engine (it detaches) on `127.0.0.1:8765` (`PEYDA_GMAPS_PORT`), and the service starts it too if it is not running. The engine only listens on the computer itself.
- **The MCP server** (`python -m peyda.gmaps_mcp`) offers `gm_search(query, city, limit, lat, lon)` and `gm_status()`. A search is one engine job (depth 1: about 20 places, no e-mail, social or review crawling, so a search takes 10–40 s), stopped at `PEYDA_GMAPS_MAX_SECONDS` (40) with the places found so far, and then deleted. With no city and no coordinates, `default_city` is added to the query. Results are cached for 10 minutes, so the loop asking again costs nothing.
- **In Peyda** it is the catalog's `gmaps` service (`services.json`: `"module": "peyda.gmaps_mcp"`, `"timeout": 60`, `"switch": "PEYDA_GMAPS"`), answering `maps` (with Neshan and Balad) and also `food`, `health` and `stays`. The gateway launches it on Peyda's own interpreter and reads its schema like any other server's, so plain search, the agentic loop, the results page (filter chip, cards) and the Analyst's review and answer all include it without a special case. Each place shows its category, rating and reviews, phone, opening status and address, and links to Google Maps.
- **Any other agent** can use the same server: `claude mcp add peyda-gmaps -- /workspace/.venvs/peyda/bin/python -m peyda.gmaps_mcp` (run from the app folder, with the engine installed).

If the engine is not installed or not running, Google Maps reports `error` with the reason, like a site that is down, and the other services still answer.

## The frontend (`app/elpian/src`)

| Screen | |
| --- | --- |
| Home | wordmark, one search bar, the **Agentic search** switch, a Search button, example queries |
| Results | what was understood (domain, product, brand, city, route, price as tags), per-service filter chips, results grouped by service with prices in Toman and links, a note when services need more detail, services that had nothing or did not answer |
| Chat | the conversation with the Peyda Analyst: your messages, the answer in Markdown, result cards, a live trace while it works (extract → search → review rounds, per service), a collapsible "How I searched" with each round's query and the analyst's reason, follow-up chips, history, new chat |

Two engine limits shaped it. Elpian has no scroll-to-end, so a chat keeps the two newest exchanges on screen and folds older ones behind *Show earlier*. Elpian timers tick at 5 s at best, so a run is followed by a request the server holds open until something happens (`GET api/runs/<id>?wait=20`).

## Checking it

```bash
# Python server: the real MCP protocol against a fake iran-mcp server, the loop against a scripted agent
cd workflows/aseman-peyda/app && python -m venv .venv && .venv/bin/pip install -r requirements-dev.txt \
  && .venv/bin/pip install pytest pytest-asyncio httpx && .venv/bin/python -m pytest -q      # 105 tests

# The installer: check it against a node with `decillion workflow validate` / `plan` (see "Run it")

# The Elpian program: with the App UI kit (deploy/sandbox-computer/appui/elpian) and quickjs-emscripten
node scripts/stub_server.mjs 8787 &
node <kit>/bundle.mjs . && node <kit>/validate.mjs --program elpian/app.js --server http://127.0.0.1:8787 --strict
node <kit>/drive.mjs run elpian/e2e --server http://127.0.0.1:8787
```

On the project's computer the installer runs the server tests, `scripts/check_services.py` (starts all 61 iran-mcp servers and the Google Maps server and confirms every tool the catalog routes to exists) and `scripts/smoke_engine.py` (the real model reads Persian and English queries; a Google Maps search runs through the real engine; a chat turn runs end to end with a scripted agent).

The Google Maps tests (`tests/test_gmaps.py`) run the real MCP server against a fake engine (the kit's job API), in plain search and in an agentic turn. Against the real kit (its pinned commit and a Chromium), the install script installed, started, checked and stopped the engine, and a search for "coffee shop in Tehran" through the gateway returned 8 places in 16 s.

## Know before you rely on it

- **Licences.** iran-mcp is **PolyForm Noncommercial**; GLiNER2 is Apache-2.0. Running Peyda as a commercial product needs the iran-mcp author's permission. The Google Maps Scraper Kit is **AGPL-3.0** (with a separate commercial licence, see its `COMMERCIAL.md`): Peyda runs it unmodified as its own process and talks to it only over its local HTTP API; if you change the kit's code and offer Peyda to others, the AGPL asks you to publish those changes.
- **Google's terms.** Scraping Google Maps is against Google's Terms of Service, as the kit itself says, and Google rate-limits and can block an address for minutes to hours. Peyda keeps each search small (one keyword, about 20 places, cached for 10 minutes), but heavy use will be blocked; set `GMAPS_PROXY_URL`, or run with `google_maps=false`.
- **Live sites.** The installer's smoke test calls the real sites. In the run I did (from a non-Iranian address, through a filtering proxy) these answered: shops (Emalls, SnappShop, Technolife, Basalam), flights (MrBilit, Alibaba), doctors (Paziresh24, Doctoreto, Darukade, Exiryab) and the TGJU and gold feeds; Digikala and Torob returned nothing for the phone query; Okala needs a *city* (a neighbourhood such as Saadat Abad is reported as an error), Snapp and TapsiFood food search need coordinates and an Iranian address. Sites change and some refuse non-Iranian addresses, so expect some `error`, `empty` or `skipped` per service (set `IRAN_PROXY_URL`); the loop and the UI show this per service. Travel, food and groceries are the least certain.
- **Not run on a real Decillion node.** The installer was simulated end to end against a fake platform while it was written (including the background install, the network policy and a rerun), and its on-computer part (`scripts/run_install.sh`: network check, install, tests, 61-server check, smoke test) was run end to end in a clean container behind a copy of the node's egress proxy. The workflow itself was not run against a live node by me; its first runs surfaced a model name the node's provider lacked (`agent_model`), a 300 s command limit (hence the background install) and the network policy (hence `manage_network`). The Builder agent's step (it follows `brief/frontend-task.md` with `appui_create` / `appui_publish`) is the part still unexercised and the most likely to need a rerun or a tweak.
- **Persian reading.** Checked with the real `fastino/gliner2.5-multi-v1` on six queries (Persian and English). It tagged brands, cities, routes, dates and the "under 20 million" price correctly. Its weak spots: it over-scores the catch-all *shopping* domain on flight, doctor and rental queries (Peyda drops it when the query names a service and nothing to buy), it files a doctor's specialty under *product*, and its domain confidence runs low (0.3–0.7), so the lexicon backs it up. This was six queries, not a benchmark. Prices, digits, dates and cities are also handled by rules, and the loop is there to repair the rest.
- **Two Python environments.** The iran-mcp servers pin the MCP SDK 2.x, so they are installed in their own environment (`/workspace/.venvs/iran-mcp`), apart from the server and GLiNER2 (`/workspace/.venvs/peyda`). Peyda's MCP client code and tests run on both SDK generations.
- **Resources.** The computer needs about 3 GB of RAM for the model and a few GB of disk (CPU PyTorch, the checkpoint, the packages). The server, environment, model and chat database live under `/workspace` outside the app folder, so updates keep chats.
