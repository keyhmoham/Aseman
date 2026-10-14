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
  `hours` (a list of `label`, `emoji`, `temperature_text`,
  `precipitation_chance_text`) and `days` (a list of `label`, `emoji`,
  `condition`, `range_text`, `precipitation_text`, `wind_max_text`).

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
3. **Details** — a Card with two Rows of three small Columns each (a caption
   label over a value): Humidity / Wind / Gusts, then Pressure / Cloud cover /
   UV index (`today/uv_index`). Under them, a caption row with the
   `today` sunrise and sunset (formatString "🌅 ${/report/today/sunrise} · 🌇 ${/report/today/sunset}").
4. **Next hours** — a Card titled "Next hours" (h5) holding a List over
   `/report/hours`; each item is a Row: `label` (weight 1), `emoji`,
   `temperature_text`, and `precipitation_chance_text` as a caption.
5. **7 days** — a Card titled "7-day forecast" (h5) holding a List over
   `/report/days`; each item is a Row: `label` (weight 2), `emoji`,
   `condition` (weight 2, caption), `range_text`; and under the row the
   `precipitation_text` and `wind_max_text` as one caption (formatString
   "${precipitation_text} · ${wind_max_text}").
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

Keep it calm and readable: generous spacing, one card per section, no
decoration beyond the weather emoji.
