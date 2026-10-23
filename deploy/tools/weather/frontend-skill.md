# Weather — frontend

archetype: analytics_console
title: Weather
data_path: /report
microtool: weather_report
args: {"city": "{{DEFAULT_CITY}}"}
slots: {"kpis":[{"label":"Temperature","field":"current/temperature","format":"number:1"},{"label":"Humidity","field":"current/humidity","format":"integer"},{"label":"Wind","field":"current/wind_speed","format":"number:1"},{"label":"Precip","field":"current/precipitation","format":"number:1"},{"label":"Pressure","field":"current/pressure","format":"integer"}],"hero_array":"hours","hero_x":"label","hero_y":"temperature","hero_label":"Next hours","hero_type":"area","strip_array":"hours","strip_label":"label","strip_value":"temperature","gauge_field":"today/uv_index","gauge_label":"UV","gauge_max":11,"table_array":"days","table_columns":[{"field":"label","label":"Day"},{"field":"high","label":"High","format":"number:0"},{"field":"low","label":"Low","format":"number:0"},{"field":"condition","label":"Condition"}],"search_path":"/form/city","search_event":"search","search_label":"Show","toggles":{"metric":"°C","imperial":"°F"}}

A professional weather console as an Aseman Surface Spec Fixed Schema over AG-UI
(archetype `analytics_console`): visualization-first, sparse text, app layout that
works on phone and desktop. The surface is compiled once from this skill (no
serve-time generation loop); opening the tool only fills data bindings. Layout
slots above are weather-specific to this skill — other tools must declare their
own `archetype` / `slots` (or omit Fixed Schema and use LLM generation).

## Data

- Fill `/report` with the `weather_report` microtool for `{"city": "{{DEFAULT_CITY}}"}`.
  Everything shown comes from `/report`; never invent a value.
- Show a value with a binding (`{"path": "/report/current/condition"}`; inside a
  List item, relative: `{"path": "label"}`). Text that mixes words and values is
  a `formatString` call. A plain string is shown as written.
- `/report` holds: `place`, `summary`, `updated`, `unit_labels`, `current`,
  `today`, `hours`, and `days` (same fields as before).

## Layout (app screen)

Root is a Column: fixed header, then body Scroll with `"weight": 1`.
`layout: "app"`. Emit via AG-UI `aseman.surface.*` events from the node.

1. **Header** — place label (h4) + caption with updated; trailing Wrap:
   SearchField `/form/city`, primary Button "Show" → event `search`, and
   borderless "°C" / "°F" (`metric` / `imperial`).
2. **Now (KPI strip)** — Grid of Stat tiles (temperature, humidity, wind,
   precipitation, pressure).
3. **UV Gauge** — Gauge over `/report/today/uv_index`.
4. **Hero chart** — area Chart over `/report/hours`.
5. **Hour strip** — horizontal List over `/report/hours`.
6. **7-day** — dense Table over `/report/days`.
7. **Compact** (id `compact`, outside root): large Stat for temperature.

## Actions

- `search` / `metric` / `imperial` → `weather_report` with result at `/report`.

Prefer Stats, Charts, Gauge and Table over paragraphs.
