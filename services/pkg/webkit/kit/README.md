# Tradera web UI kit — building a tool's interactive web frontend

When people want to **interact with a tool** (operate it, fill a form, place
an order, filter and drill into its data, configure it, a dashboard they
use), build an **interactive web page** for it: a small web app in the
sandbox, served through a preview gateway, that opens as a card window on
the room's desk next to the tools' own frontends. It looks exactly like the
app (this kit) and calls the tool's microtools through the Tradera API, as
the person using it. Do not rely on a generated (A2UI) frontend or
`ui_compose` for interaction: they show results; a page *does things*.

The kit's files are in the sandbox at `/opt/tradera/webkit/`
(`tradera-ui.js`, `tradera-ui.css`, `gallery.html` with every component, this
README). Through the gateway every preview serves them itself at
`/_tradera/kit/…` — link them there, never copy them into the page's build.

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
  <link rel="stylesheet" href="/_tradera/kit/tradera-ui.css">
  <script src="/_tradera/kit/tradera-ui.js"></script>
</head>
<body class="t-page">
  <t-column gap="16">
    <t-row justify="spaceBetween">
      <t-column gap="2"><t-text variant="h4" text="Weather"></t-text>
        <t-text variant="caption" bind-text="/fc/updated"></t-text></t-column>
      <t-icon-button icon="refresh" tooltip="Refresh" call="Weather/forecast"
        args='{"city":{"path":"/form/city"}}' into="/fc"></t-icon-button>
    </t-row>
    <t-row><t-search-field placeholder="City" bind-value="/form/city" weight="1"></t-search-field></t-row>
    <!-- loads now, and again whenever /form/city changes -->
    <t-data call="Weather/forecast" args='{"city":{"path":"/form/city"}}' into="/fc"></t-data>
    <t-show when='{"path":"/fc__loading"}'><t-skeleton variant="card"></t-skeleton></t-show>
    <t-grid min-column-width="160">
      <t-card><t-stat label="Temperature" bind-value="/fc/temp" format="number:1" icon="thermostat"></t-stat></t-card>
      <t-card><t-stat label="Humidity" bind-value="/fc/humidity" format="percent"></t-stat></t-card>
    </t-grid>
    <t-card><t-chart type="line" title="Next 24 h" bind-data="/fc/hours" x="time" x-format="time" y="temp" height="240"></t-chart></t-card>
    <t-card>
      <t-form call="Weather/set_alert" into="/alert" toast="Alert saved">
        <t-text-field name="threshold" label="Alert above (°C)" variant="number"></t-text-field>
        <t-button type="submit" variant="primary" text="Save alert"></t-button>
      </t-form>
    </t-card>
  </t-column>
  <script>Tradera.data.set('/form/city', 'Oslo');</script>
</body>
</html>
```

Root-relative URLs (`/_tradera/…`, `/app.js`) stay inside the preview: the
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

In script (`Tradera` is global; everything is async):

```js
const fc = await Tradera.call('Weather', 'forecast', { city: 'Oslo' }); // the microtool's value (MCP results unwrapped)
const wx = Tradera.tool('Weather'); await wx.forecast({ city: 'Rome' });  // same, as an object
await Tradera.tools();                // the space's tools with their microtools (name, description, schema)
await Tradera.microtools('Weather');  // asked live
await Tradera.context();              // {space, room, user: {id, handle}, preview}
await Tradera.load('/fc', 'Weather', 'forecast', { city: { path: '/form/city' } }, { every: 60 });
Tradera.poll(async () => …, 30000);   // paused while the page is hidden
await Tradera.show('Weather', { microtool: 'forecast', args: { city: 'Oslo' } }); // opens the tool's own frontend on the desk
Tradera.toast('Saved', { status: 'good' }); await Tradera.confirm('Delete the alert?', { destructive: true });
await Tradera.dialog({ title, content: node | 'markdown', actions: [{ label, variant, value }] });
Tradera.on('remove', (context, el) => …);  // handles {"event": {"name": "remove", "context": {…}}} actions
```

Errors are `Tradera.Error` (`message`, `code`, `status`). While developing
without the gateway, `Tradera.configure({ mock: { Weather: { forecast: (args) => ({…}) } } })`.

## 4. The data model and bindings

`Tradera.data` is one JSON model (`get(path)`, `set(path, v)`, `merge`,
`remove`, `batch(fn)`, `subscribe(fn)`). Bind any prop to it:
`bind-value="/form/city"` or `value='{"path": "/form/city"}'`; inputs write
back to it; anything reading a path re-renders when it changes. Props take
literals (attributes are parsed as JSON when they look like it), bindings,
and A2UI function calls: `text='{"call": "formatString", "args": {"value": "High ${/fc/high}°"}}'`.
In script, set props as properties: `el.data = rows`, `el.props = {…}`,
`el.set('value', 3)`. Build elements with `Tradera.el('stat', {label, value})`
and `Tradera.h('div', {class, on: {click}}, …children)`.

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
name (A2UI catalog, tool UI kit, Elpian widgets); camelCase props are
kebab-case attributes (`min-column-width`). Events: `t-press`, `t-change`
(`detail.value`), `t-select` (tapped row), `t-action`, `t-result`, `t-error`,
`t-submit`. The gallery (`/_tradera/kit/gallery.html`) shows them all.

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

**Escape hatches** — `t-surface` renders A2UI (messages or {components,
data}, the JSON tools' generated frontends use); `t-tool-frontend` {tool,
microtool, args} embeds a tool's own frontend (its generative surface with
working actions, or its result in an automatic view); `t-elpian` {node}
renders Elpian node trees; `t-auto-view` {value} shows any value in the view
that fits; every Elpian animation and gesture widget is there too
(`t-animated-container`, `t-fade-transition`, `t-pulse`, `t-shimmer`,
`t-inkwell`, `t-gesture-detector`, `t-dismissible`, `t-draggable`,
`t-drag-target`, …). Plain HTML (tables, forms, details, dialogs…) is styled
like the app too.

## 6. Design

The quality bar of generated surfaces applies: one root column, a header
(title + one caption line, its main action at the end), headline numbers in a
`t-grid` of `t-stat`s, then the main view, then details. Works at 360 px and
at 1400 px (Grids with min-column-width, no fixed widths); every control does
something that works; one primary button per block; format every number;
status colors only for state. Use `body class="t-page"`. Colors are CSS
variables (`var(--t-primary)`, `--t-surface`, `--t-series-1…8`, `--t-good`,
`--t-critical`…); the page follows the app's light/dark theme and accent by
itself — never hard-code colors or a theme.

## 7. Check it

Locally (in the sandbox, without the gateway) the kit's URLs answer only if
the served folder has them: `mkdir -p _tradera/kit && cp /opt/tradera/webkit/* _tradera/kit/`
(harmless: in the preview the gateway answers `/_tradera/…` itself). There
is no Tradera API locally: `Tradera.configure({ mock: … })` checks the
layout; then verify the real calls in the preview.

Before reporting: `proxy_get` with `probe: true`, open the page in the
desktop browser (`tradera-desktop open http://localhost:8080`), take a
screenshot, and click through every control.
