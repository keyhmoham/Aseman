# Weather tool

A ready-made Aseman tool, deployed with one script:

| | |
|---|---|
| **Backend** | managed, QuickJS — [`backend.js`](backend.js), run by the node as a Nomad service of the tool runtime image. Weather from [Open-Meteo](https://open-meteo.com) (free, no API key), reached through the runtime's `aseman.fetch`. |
| **Frontend** | none dedicated — agents build interactive UIs with `appui_create`; people can also call microtools from chat. |

Microtools (agents get them as tools too): `weather_report`, `current_weather`,
`daily_forecast`, `hourly_forecast`, `search_places`. Each takes a `city` (or
`latitude` + `longitude`) and `units` (`metric` or `imperial`).

## Deploy

```bash
# sign in once (or set ASEMAN_HANDLE / ASEMAN_PASSWORD for the script)
services/bin/aseman login --server http://localhost:8080 <handle> <password>

deploy/tools/weather/upsert.sh --server http://localhost:8080 --space <space-id> --city Lisbon
```

It **upserts**: a tool named `weather` you own is updated in place (new
backend program); one deployed some other way (not managed QuickJS)
is replaced; otherwise it is created. `--space` also adds it to a space,
`--dry-run` prints the calls without sending them. The aseman CLI is taken
from `PATH`, else `services/bin/aseman`, else built with Go.

Needs a node with the Nomad VMM and the tool runtime image. The managed
backend needs outbound internet to reach Open-Meteo.

## Test

```bash
# the backend on QuickJS, over MCP, with Open-Meteo stubbed (from deploy/tool-runtime, after npm install)
node --test ../tools/weather/test/backend.test.mjs
# …or against the real API
LIVE=1 node --test ../tools/weather/test/backend.test.mjs

# the upsert decisions (create, update in place, replace) with a stub CLI
deploy/tools/weather/test/upsert.test.sh
```
