# Aseman web UI kit — building a tool's interactive web frontend

When people want to **interact with a tool** (operate it, fill a form, place
an order, filter and drill into its data, configure it, a dashboard they
use), build an **interactive web page** for it: a small web app in the
sandbox, served through a preview gateway, that opens as a card window on
the room's desk next to the tools' own frontends. It looks exactly like the
app (this kit) and calls the tool's microtools through the Aseman API, as
the person using it. Do not rely on a generated (AG-UI Surface Spec) frontend or
`ui_compose` / `ui_present` for interaction: they show results; a page *does things*.

The kit's files are in the sandbox at `/opt/aseman/webkit/`
(`aseman-ui.js`, `aseman-ui.css`, `gallery.html` with every component, this
README). Through the gateway every preview serves them itself at
`/_aseman/kit/…` — link them there, never copy them into the page's build.

## 1. Build and expose

```sh
mkdir -p /workspace/weather-console && cd /workspace/weather-console
# index.html (+ any js/css of your own), then serve the folder:
python3 -m http.server 8080 --bind 0.0.0.0     # (the start command below)
```

Then `proxy_create` with `port`, `start` (the command above, run from
/workspace: `python3 -m http.server 8080 --bind 0.0.0.0 --directory /workspace/weather-console`),
`title` and **`tool`** (the tool the page is a frontend of). The page opens
by itself as a card window on the desk (give it `path` for a page other than
`/`); `web_show` opens it again, other pages of it, or makes it a tool's
frontend. Any stack works (plain HTML is best for a tool console; Vite/React
builds too — with `preserve_path` for frameworks that compile their base path).

## 2. The page

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Weather console</title>
  <link rel="stylesheet" href="/_aseman/kit/aseman-ui.css">
  <script src="/_aseman/kit/aseman-ui.js"></script>
</head>
<body class="t-app">
  <!-- The header stays put; the body region below takes the rest of the window. -->
  <t-row justify="spaceBetween">
    <t-column gap="2" weight="1"><t-text variant="h4" text="Weather"></t-text>
      <t-text variant="caption" bind-text="/fc/updated"></t-text></t-column>
    <t-icon-button icon="refresh" tooltip="Refresh" call="Weather/forecast"
      args='{"city":{"path":"/form/city"}}' into="/fc"></t-icon-button>
  </t-row>
  <t-search-field placeholder="City" bind-value="/form/city"></t-search-field>
  <!-- loads now, and again whenever /form/city changes -->
  <t-data call="Weather/forecast" args='{"city":{"path":"/form/city"}}' into="/fc"></t-data>
  <!-- The body: panes side by side on a desktop, tabs on a phone; each scrolls by itself. -->
  <t-split weight="1">
    <t-column title="Forecast" gap="16">
      <t-show when='{"path":"/fc__loading"}'><t-skeleton variant="card"></t-skeleton></t-show>
      <t-grid min-column-width="150">
        <t-card><t-stat label="Temperature" bind-value="/fc/temp" format="number:1" delta='{"path":"/fc/feels"}' delta-label="feels like" icon="thermostat"></t-stat></t-card>
        <t-card><t-stat label="Humidity" bind-value="/fc/humidity" format="percent" icon="water_drop"></t-stat></t-card>
        <t-card><t-stat label="Wind" bind-value="/fc/wind" icon="air"></t-stat></t-card>
        <t-card><t-gauge label="UV" bind-value="/fc/uv" min="0" max="11"></t-gauge></t-card>
      </t-grid>
      <t-card><t-chart type="area" title="Next 24 h" bind-data="/fc/hours" x="time" x-format="time" y="temp" smooth height="260"></t-chart></t-card>
    </t-column>
    <t-form title="Alert" call="Weather/set_alert" into="/alert" toast="Alert saved">
      <t-text-field name="threshold" label="Alert above (°C)" variant="number"></t-text-field>
      <t-button type="submit" variant="primary" text="Save alert"></t-button>
    </t-form>
  </t-split>
  <script>Aseman.data.set('/form/city', 'Oslo');</script>
</body>
</html>
```

Root-relative URLs (`/_aseman/…`, `/app.js`) stay inside the preview: the
gateway rewrites them. Tools are named by their name (case-insensitive) or
bot id; `call="Tool/microtool"`.

## 3. Calling tools (the page's backend)

Declarative, on any element that acts (buttons, icon buttons, cards, chips,
inks, menus' items, forms, inputs, `t-data`):

| attribute | |
|---|---|
| `call="Tool/microtool"` | the microtool to call (as the person viewing the page) |
| `args='{"city": {"path": "/form/city"}, "days": 3}'` | its arguments; `{"path"}` reads the data model |
| `into="/fc"` | where its value goes in the data model |
| `toast="Saved"` | a confirmation; failures always show as a toast |
| `then='{"functionCall": …}'` | an action after it (e.g. close a modal) |

`<t-data call args into every="60" lazy quiet>` loads a value on start, again
when the args it reads change, and every N seconds; `/fc__loading` and
`/fc__error` say how it is going. `<t-form call into>` submits its named
fields (`name="qty"`) as args.

In script (`Aseman` is global; everything is async):

```js
const fc = await Aseman.call('Weather', 'forecast', { city: 'Oslo' }); // the microtool's value (MCP results unwrapped)
const wx = Aseman.tool('Weather'); await wx.forecast({ city: 'Rome' });  // same, as an object
await Aseman.tools();                // the space's tools with their microtools (name, description, schema)
await Aseman.microtools('Weather');  // asked live
await Aseman.context();              // {space, room, user: {id, handle}, preview}
await Aseman.load('/fc', 'Weather', 'forecast', { city: { path: '/form/city' } }, { every: 60 });
Aseman.poll(async () => …, 30000);   // paused while the page is hidden
await Aseman.show('Weather', { microtool: 'forecast', args: { city: 'Oslo' } }); // opens the tool's own frontend on the desk
Aseman.toast('Saved', { status: 'good' }); await Aseman.confirm('Delete the alert?', { destructive: true });
await Aseman.dialog({ title, content: node | 'markdown', actions: [{ label, variant, value }] });
Aseman.on('remove', (context, el) => …);  // handles {"event": {"name": "remove", "context": {…}}} actions
```

Errors are `Aseman.Error` (`message`, `code`, `status`). While developing
without the gateway, `Aseman.configure({ mock: { Weather: { forecast: (args) => ({…}) } } })`.

## 4. The data model and bindings

`Aseman.data` is one JSON model (`get(path)`, `set(path, v)`, `merge`,
`remove`, `batch(fn)`, `subscribe(fn)`). Bind any prop to it:
`bind-value="/form/city"` or `value='{"path": "/form/city"}'`; inputs write
back to it; anything reading a path re-renders when it changes. Props take
literals (attributes are parsed as JSON when they look like it), bindings,
and Surface Spec function calls: `text='{"call": "formatString", "args": {"value": "High ${/fc/high}°"}}'`.
In script, set props as properties: `el.data = rows`, `el.props = {…}`,
`el.set('value', 3)`. Build elements with `Aseman.el('stat', {label, value})`
and `Aseman.h('div', {class, on: {click}}, …children)`.

Repeat a `<template>` per item: `<t-list each="/positions"><template>…
<t-text bind-text="symbol"></t-text>…</template></t-list>` (relative paths
read the item; `t-column`, `t-row`, `t-grid`, `t-wrap` and `t-for` repeat too).

Client actions (no round trip): `action='{"functionCall": {"call": "setValue",
"args": {"path": "/tab", "value": "orders"}}}'` — setValue, toggle,
increment {path, by, min, max}, append, removeAt, copyToClipboard,
showToast, openUrl, closeModal. `<t-show when='{"path": "/x"}'>` shows its
children while a condition holds (`slot="fallback"` children otherwise).
Functions: formatString, formatNumber, formatCurrency, formatDate, format,
formatPercent, formatCompact, formatRelative, now, pluralize, add, multiply,
subtract, divide, round, abs, clamp, percentChange, sum, average, min, max,
count, equals, notEquals, greaterThan, lessThan, isEmpty, contains, if,
coalesce, concat, join, upper, lower, truncate, get, required, regex,
length, numeric, email, and, or, not.

Formats (`format`, `y-format`, column formats): `number[:decimals]`,
`integer`, `compact`, `percent[:decimals]` (a fraction), `currency[:CODE[:decimals]]`,
`date`, `time`, `datetime`, `relative`; a leading `+` signs positives.

## 5. Components

Every element is `<t-…>` with the props of the app's component of the same
name (Surface Spec catalog, tool UI kit, Elpian widgets); camelCase props are
kebab-case attributes (`min-column-width`). Events: `t-press`, `t-change`
(`detail.value`), `t-select` (tapped row), `t-action`, `t-result`, `t-error`,
`t-submit`. The gallery (`/_aseman/kit/gallery.html`) shows them all.

**Layout** — `t-column` / `t-row` {justify, align, gap; children take
`weight`}, `t-grid` {columns | min-column-width (+max-columns), gap},
`t-wrap` {spacing, run-spacing}, `t-stack` {alignment, height} +
`t-positioned`, `t-box` / `t-container` {padding, margin, width, height,
max-width, color, gradient, border-radius, border-color, elevation,
alignment}, `t-card` {variant: outlined|filled|elevated, padding}, `t-panel`,
`t-panel-header` {title, subtitle, icon}, `t-section` {title, subtitle, icon,
trailing}, `t-expandable` {title, subtitle, expanded}, `t-accordion`,
`t-tabs` + `t-tab` {title, icon} (selected binding), `t-modal` {title,
variant: dialog|sheet; a slot="trigger" child}, `t-scroll` {direction,
max-height}, `t-carousel` {height, autoplay}, `t-center`, `t-spacer`,
`t-divider`, `t-aspect-ratio` {ratio}, `t-scaffold`, `t-app-bar` {title,
leading}, `t-show`, `t-for`.

**Content** — `t-text` {text, variant: h1…h5|body|caption, format; Markdown},
`t-markdown`, `t-icon` {name: Material names, snake_case or camelCase},
`t-image` {url, fit, variant, height}, `t-video`, `t-audio-player`,
`t-badge` / `t-tag` {text, status: good|warning|serious|critical | color,
variant: tonal|filled|outline, icon}, `t-chip`, `t-mini-tag`,
`t-status-tag`, `t-avatar`, `t-avatar-group`, `t-callout` {title, text,
severity}, `t-code-block`, `t-json-view`, `t-link`, `t-tooltip`,
`t-empty-state`, `t-loading`, `t-skeleton`, `t-steps`, `t-countdown`,
`t-math-expression`, `t-brand`.

**Inputs** (bind `value`) — `t-button` {text, variant: primary|default|
borderless|tonal|destructive, icon, full-width, checks}, `t-icon-button`
{icon, tooltip, variant}, `t-menu` {items: [{label, icon, action,
destructive}]}, `t-text-field` {label, variant: shortText|longText|number|
obscured, placeholder, helper, checks}, `t-search-field`, `t-checkbox`,
`t-switch`, `t-radio` {value, group-value}, `t-slider` {min, max, step,
format}, `t-range-slider`, `t-choice-picker` {options, variant:
multipleSelection}, `t-segmented-control` {options}, `t-segmented-tab-bar`,
`t-dropdown` {options}, `t-number-stepper` {min, max, step},
`t-date-time-input` {enable-date, enable-time}, `t-rating` {editable},
`t-form`, `t-form-field`.

**Data** — `t-stat` {label, value, format, delta, delta-format,
delta-label, good-direction, trend, icon, size: compact|default|hero},
`t-stat-card`, `t-trend`, `t-key-value` {items | data}, `t-table` /
`t-data-grid` {data, columns: [{field, label, type: text|number|trend|badge|
progress|sparkline|image|avatar|boolean|link, format, align}], search,
page-size, sort-by, dense, striped, selection, action}, `t-timeline`,
`t-tree-view`, `t-progress` {value, max, variant: linear|circular},
`t-gauge` {value, min, max, thresholds}, `t-sparkline`.

**Charts** — `t-chart` {type: line|area|bar|scatter|bubble|candlestick|
histogram|pie|donut|radar|heatmap|treemap, data, x, series | y, stacked,
horizontal, smooth, value-labels, x-format, y-format, height, selection};
`t-heatmap`, `t-treemap`, `t-graph` {nodes, edges, layout:
force|circle|tree, directed}.

**Markets** — `t-quote` {symbol, name, price, change, currency, trend, size:
row|large}, `t-order-book` {bids, asks, levels}, `t-ticker-tape`,
`t-allocation-bar`.

**Escape hatches** — ``t-surface` renders AG-UI surfaces (messages or {components,
data}, the JSON tools' generated frontends use); `t-tool-frontend` {tool,
microtool, args} embeds a tool's own frontend (its generative surface with
working actions, or its result in an automatic view); `t-elpian` {node}
renders Elpian node trees; `t-auto-view` {value} shows any value in the view
that fits; every Elpian animation and gesture widget is there too
(`t-animated-container`, `t-fade-transition`, `t-pulse`, `t-shimmer`,
`t-inkwell`, `t-gesture-detector`, `t-dismissible`, `t-draggable`,
`t-drag-target`, …). Plain HTML (tables, forms, details, dialogs…) is styled
like the app too.

## 6. Design (professional product UI)

Design as a senior product designer shipping a real application console —
visualization-first, sparse text — not a document, landing page or chat
card. It must work on a phone (~360 × 640) and a desktop window (~1400 × 900).

**Composition (top → bottom)**

1. Fixed header — title + one caption + main actions / filters.
2. KPI strip — `t-grid` (min-column-width ~160) of 3–5 `t-stat`s (value,
   format, delta / trend / sparkline when available).
3. Hero visualization — one `t-chart` / `t-gauge` / `t-heatmap` / domain
   viz (`t-quote`, `t-order-book`, `t-allocation-bar`…) answering the main
   question.
4. Supporting views — secondary charts, `t-tabs` / `t-segmented-control`,
   or `t-split` (list + detail).
5. Evidence — dense `t-table` (≤ 6–8 columns); selection → detail pane.

Prefer `t-stat`, `t-chart`, `t-gauge`, `t-table`, `t-sparkline` over walls
of `t-text` / `t-markdown` whenever the data is numeric, temporal,
categorical or tabular.

**App viewport**

- `<body class="t-app">` fills the window exactly and never scrolls as a
  whole. Children: a header that stays put, then the body region with
  `weight="1"`, optionally a bottom action bar.
- Growing content (tables, `t-for`, timelines, logs, details, long forms)
  scrolls inside its region: body is `t-scroll weight="1"`, `t-split` or
  `t-tabs weight="1"` — never a plain column that pushes the page taller.
- Side-by-side regions use `t-split` (panes with `title="…"`: side by side
  on desktop, tabs on a phone). Never a `t-row` of panes. Alternate lenses
  are `t-tabs`, not long stacked sections.
- Responsive: one column on a phone, no horizontal overflow, no fixed
  widths; tiles/fields in `t-grid` with min-column-width; button groups in
  `t-wrap`.
- No page patterns: no hero banners, landing sections, footers or long
  prose. Short labels (2–4 words); format every number; one primary button
  per region; status colors only for state.

Opening a page checks the viewport rules and refuses a page that would be
cut off or scroll like a web page. The model review also judges
visualization-first fitness. Colors are CSS variables (`var(--t-primary)`,
`--t-surface`, `--t-series-1…8`, `--t-good`, `--t-critical`…); the page
follows the app's light/dark theme — never hard-code colors or a theme.

## 7. Check it

Locally (in the sandbox, without the gateway) the kit's URLs answer only if
the served folder has them: `mkdir -p _aseman/kit && cp /opt/aseman/webkit/* _aseman/kit/`
(harmless: in the preview the gateway answers `/_aseman/…` itself). There
is no Aseman API locally: `Aseman.configure({ mock: … })` checks the
layout; then verify the real calls in the preview.

Opening the page (`proxy_create`, `web_show`) reviews it first. The node
fetches it and its own files, reads it the way the kit runs it (the kit
loaded, components that exist, valid JSON props, controls wired, inputs
bound, the viewport, theme variables, layout), checks every `call` against
the space's tools, microtools and argument schemas, runs what it loads (and
buttons whose microtool only reads) and looks every value shown up in what
came back, then has the page reviewed for fitness to the tool, cleanness
and the design standard. A page that does not work is not opened: you get
the report, fix it, and `web_show` it again until the review passes.

The node does not paint the page in a browser, so before reporting it ready
(and after every edit), **you must see the frontend window yourself** and
reform from the pixels — not from HTML alone. Repeat until nothing is left:

1. `proxy_get` with `probe: true`: the page and the kit load.
2. Open the page in the desktop browser
   (`aseman-desktop open http://localhost:8080`).
3. Screenshot at phone and desktop widths, then **read each PNG** so you
   see the UI:
   `aseman-desktop screenshot /workspace/ui-phone.png 360` then
   `aseman-desktop screenshot /workspace/ui-desktop.png 1400`, then
   `read_file` on both paths (the tool returns the image; judge layout,
   overflow, contrast, empty charts, cramped KPIs, text-heavy walls).
4. Click through every control: each call returns real data (no `/x__error`,
   no empty or missing values), each button does what its label says and
   the page shows the outcome; nothing is dead or decorative.
5. Review it as its user would: clean and standard (section 6), every
   number formatted and labelled, and right for the tool and what was asked.
6. Fix everything the screenshots and clicks found, then go back to 1.
   Do not say the page is ready until the pictures match the design standard.
