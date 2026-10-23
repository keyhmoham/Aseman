# Weather — frontend

A professional weather console: visualization-first, sparse text, app layout
that works on phone and desktop.

## Data

- Fill `/report` with the `weather_report` microtool for `{"city": "{{DEFAULT_CITY}}"}`.
  Everything shown comes from `/report`; never invent a value.
- Show a value with a binding (`{"path": "/report/current/condition"}`; inside a
  List item, relative: `{"path": "label"}`). Text that mixes words and values is
  a `formatString` call, e.g. `{"call": "formatString", "args": {"value":
  "Updated ${/report/updated}"}, "returnType": "string"}`. A plain string is shown
  as written, so never put `${…}` or `{{…}}` in one.
- `/report` holds: `place` (`name`, `region`, `label`), `summary`, `updated`,
  `unit_labels`, `current` (`emoji`, `temperature_text`, `condition`,
  `feels_like_text`, `humidity_text`, `wind_text`, `gusts_text`,
  `pressure_text`, `cloud_cover_text`, `precipitation_text`), `today`
  (`range_text`, `precipitation_text`, `uv_index`, `sunrise`, `sunset`),
  `hours` (a list of `label`, `emoji`, `temperature` (a number),
  `temperature_text`, `precipitation_chance` (a number, %),
  `precipitation_chance_text`) and `days` (a list of `label`, `emoji`,
  `condition`, `high` and `low` (numbers), `range_text`,
  `precipitation_chance`, `precipitation_text`, `wind_max_text`).

## Layout (app screen)

Root is a Column: fixed header, then body Scroll with `"weight": 1`.

1. **Header** — place `label` (h4) + caption with `updated` (formatString
   "Updated ${/report/updated}"); trailing Wrap: SearchField `/form/city`,
   primary Button "Show" → event `search`, and borderless "°C" / "°F"
   (`metric` / `imperial`).
2. **Now (KPI strip)** — Grid (minColumnWidth 150) of Stat tiles, not a wall
   of text:
   - Temperature (`current/temperature_text`, icon weather), delta/caption
     feels-like via `feels_like_text` as deltaLabel or a caption under the grid;
   - Humidity (`humidity_text`), Wind (`wind_text`), Precipitation
     (`precipitation_text`), Pressure (`pressure_text`);
   - Gauge for UV (`today/uv_index`, min 0, max 11, thresholds 3 → warning,
     8 → critical).
   Skip the long `summary` paragraph unless there is spare room as a single
   caption — never a Card of prose.
3. **Hero chart** — Section "Next hours": area Chart over `/report/hours`
   (x `label`, series `temperature` "Temperature", smooth, height 260).
4. **Hour strip** — horizontal List over `/report/hours`: small Columns with
   `label` (caption), `emoji`, `temperature_text`, `precipitation_chance_text`
   (caption) — graphic strip, not a table of sentences.
5. **7-day** — Section: bar Chart over `/report/days` (x `label`, series
   `high` "High" and `low` "Low", height 240), then dense Table over
   `/report/days` (columns: `label` "Day", `emoji` "", `condition`,
   `range_text` "Temp" end-aligned, `precipitation_chance` "Rain" type
   progress max 100, `wind_max_text` "Wind").
6. **Compact** (id `compact`, outside root): one large Stat for temperature
   + condition caption, or Row of two Stats (temp + humidity) — board widget.

## Actions

- `search`: `weather_report` with `{"city": {"$context": "city"}}`, result at
  `/report`.
- `metric`: `weather_report` with `{"city": {"$context": "city"}, "units": "metric"}`,
  result at `/report`.
- `imperial`: `weather_report` with `{"city": {"$context": "city"}, "units": "imperial"}`,
  result at `/report`.

Prefer Stats, Charts, Gauge and Table over paragraphs. Calm product chrome:
generous gap 12–16, one Section/Card per block, weather emoji only as data
glyphs (not decoration).
