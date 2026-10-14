# Weather — frontend

A clean, rich weather view for one place at a time.

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

## Layout (top to bottom, in one Column)

1. **Search row** — a Row with a TextField labelled "City" bound to
   `/form/city` (weight 1) and a primary Button "Show" that sends the event
   `search` with context `{"city": {"path": "/form/city"}}`.
2. **Now** — a Card:
   - the place `label` (variant h4) and, under it, `updated` as a caption
     (formatString "Updated ${/report/updated}");
   - a Row with the current `emoji` in a large heading (h1) next to a Column
     of `temperature_text` (h1) and `condition` (h5);
   - `feels_like_text` and today's `range_text` as captions;
   - `summary` as body text.
3. **Details** — a Grid (minColumnWidth 140) of compact Stat tiles, each
   with its icon: Humidity (`humidity_text`), Wind (`wind_text`), Gusts
   (`gusts_text`), Pressure (`pressure_text`), Cloud cover
   (`cloud_cover_text`), and a Gauge for the UV index (`today/uv_index`,
   min 0, max 11, thresholds 3 → warning, 8 → critical). Under them, a
   caption with the sunrise and sunset (formatString
   "🌅 ${/report/today/sunrise} · 🌇 ${/report/today/sunset}").
4. **Next hours** — a Section titled "Next hours" with an area Chart over
   `/report/hours`: x `label`, one series `temperature` labelled
   "Temperature", smooth, height 180; under it a horizontal List over
   `/report/hours` of small Columns: `label` (caption), `emoji`,
   `temperature_text`, and `precipitation_chance_text` (caption).
5. **7 days** — a Section titled "7-day forecast" with a bar Chart over
   `/report/days` (x `label`, series `high` "High" and `low` "Low", height
   200), then a Table over `/report/days`, dense, columns: `label` "Day",
   `emoji` "", `condition`, `range_text` "Temp" (end-aligned),
   `precipitation_chance` "Rain" (type progress, max 100), `wind_max_text`
   "Wind".
6. **Units** — a Row of two borderless Buttons, "°C" and "°F", sending the
   events `metric` and `imperial` with context `{"city": {"path": "/report/place/name"}}`.
7. A caption at the bottom: "Weather data: Open-Meteo".

## Actions

- `search`: `weather_report` with `{"city": {"$context": "city"}}`, result at
  `/report`.
- `metric`: `weather_report` with `{"city": {"$context": "city"}, "units": "metric"}`,
  result at `/report`.
- `imperial`: `weather_report` with `{"city": {"$context": "city"}, "units": "imperial"}`,
  result at `/report`.

Keep it calm and readable: generous spacing, one Card or Section per block, no
decoration beyond the weather emoji.
