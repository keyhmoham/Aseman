# Creator plugins

A plugin is a small app made for people that stays: a screen of its own, a
backend when it needs one, and the platform actions it may call. The Aseman
app shows it as a floating gadget (on the conversation, the space's left
panel or the room's desk), or as a page; the person manages every plugin
from the plugins handle on the right edge of the screen. Made in someone's
own Aseman chat it is theirs everywhere; made in a space it belongs to that
space and its members.

This kit is on every computer at `/opt/aseman-appui/elpian/`:

| File | |
|---|---|
| `PLUGINS.md` | this guide |
| `ELPIAN.md` | the full Elpian reference: nodes, props, the SDK, **Design** (read it for Elpian plugins) |
| `aseman-elpian.js`, `aseman-plugin.js` | the SDK and plugin shim the app runs before an Elpian plugin |
| `aseman-web-plugin.js` | the bridge the app injects into a web plugin |
| `examples/showcase.js`, `examples/whiteboard.js` | reference apps in Material 3 Expressive |
| `aseman-plugin-check` (`plugin-check.mjs`) | checks a plugin the way the app runs it |
| `aseman-plugin-inline` (`plugin-inline.mjs`) | makes a web build one HTML document |
| `aseman-elpian elpian_describe '{"types":["Card"]}'`, `aseman-elpian elpian_icons '{"query":"calendar"}'` | a node's exact props; Material icon names |

## 1. Choose the UI: Elpian (default) or web

**Elpian** draws native Flutter UI in the person's theme, on every device:
forms, lists, trackers, boards, dashboards with standard charts (`Chart`,
`Stat`, `DataGrid`, `Kanban`, `Calendar`, `Gauge`, `Timeline` …). It is the
default and the right answer most of the time.

**Web** (`ui: "web"`) is one self-contained HTML document in the app's
sandboxed web frame. Choose it, and say why in `ui_reason`, when:

* the design needs **3D**: a scene, a globe, a model viewer, a 3D chart or
  physics (Three.js, Babylon.js, WebGL);
* the person **asked for web** technology (HTML/CSS/JS, a web library);
* the design needs **rich, professional visualization** Elpian cannot draw
  well: interactive maps, dense or animated charts (ECharts, D3, Plotly
  custom layouts), node graphs and network diagrams, a rich text or code
  editor, canvas animation, audio visualizers, timelines with zoom and pan.

When in doubt, Elpian. A web plugin works on Android, iOS, macOS and the
web app; on Windows and Linux desktops the person sees "open in browser"
instead, so a plain form or list is never a web plugin.

## 2. Workflow

Build the plugin in its own folder on the computer, check it, look at it,
then create it from the files:

```bash
mkdir -p /workspace/.plugins/reading-list && cd /workspace/.plugins/reading-list
# write frontend.js (Elpian) or index.html (web), and backend.js if it needs one
aseman-plugin-check frontend.js --permissions spaces.message_list            # Elpian
aseman-plugin-check dist/plugin.html --backend backend.js --screenshots shots # web
```

Fix every ERROR (the plugin is refused while there are any) and the WARNs
that matter; read the NOTEs (design advice). For web plugins, look at
`shots/phone.png` and `shots/desk.png` with `read_image` before you create
it. Then call `create_plugin` with `frontend_file` (and `backend_file`):
it runs the same check again and refuses a plugin that fails it.

To change a plugin, edit its files, check them again and call
`create_plugin` with its `plugin` id.

## 3. An Elpian plugin

The app runs `aseman-elpian.js` + `aseman-plugin.js` + your program on
QuickJS, so you have the whole SDK (`App.create`, `app.set`, `app.handler`,
`app.input`, `Aseman.env`, `Aseman.viewport`; ELPIAN.md, The SDK) plus
`Aseman.plugin`. There is no `Aseman.fetch` (a plugin has no server of its
own) and no phone widget.

| `Aseman.plugin.*` | Task (then / catch / finally) |
|---|---|
| `get(key)`, `set(key, value)` | the plugin's own store (no backend needed) |
| `call(fn, args)` | a function of your backend (`backend.js`) |
| `api(namespace, action, body)` | a platform action listed in `permissions` (`"spaces.message_list"`, `"routines.*"`), as the person using it; a space's plugin stays in its space |
| `context()` | `{plugin, name, scope, space, room, user, display}` |

```js
var app = App.create({
  state: { items: [], draft: "", loading: true },
  view: function (s, app) {
    var wide = Aseman.viewport().sizeClass !== "compact";
    return { type: "ListView", children: [{ type: "Column", props: { style: { padding: wide ? "24" : "16", gap: "16" } }, children: [
      { type: "Column", props: { style: { gap: "4" } }, children: [
        { type: "Text", props: { text: "Reading list", variant: "headlineSmallEmphasized" } },
        { type: "Text", props: { text: s.items.length + " to read", variant: "bodyMedium", color: "muted" } },
      ] },
      { type: "Row", props: { style: { gap: "8", alignItems: "center" } }, children: [
        { type: "Expanded", children: [app.input("draft", "draft", { label: "Add a book", icon: "menu_book", live: true })] },
        { type: "Button", props: { text: "Add", icon: "add", disabled: !s.draft }, events: { tap: app.handler("add", add) } },
      ] },
      s.loading ? { type: "LoadingIndicator" }
      : s.items.length ? { type: "ListGroup", children: s.items.map(function (b, i) {
          return { type: "ListTile", key: "b" + i, props: { title: b.title, leading: "book", trailing: "check_circle" },
                   events: { tap: app.handler("done_" + i, function () { done(i); }) } };
        }) }
      : { type: "EmptyState", props: { icon: "auto_stories", title: "Nothing to read yet", text: "Add the first book above." } },
    ] }] };
  },
  init: function (app) {
    Aseman.plugin.get("items").then(function (v) { app.set({ items: v || [], loading: false }); })
      .catch(function (e) { app.set({ loading: false }); app.fail(e); });
  },
});
function save(items) { app.set({ items: items }); Aseman.plugin.set("items", items).catch(function (e) { app.fail(e); }); }
function add(e, app) { if (app.state.draft) { save(app.state.items.concat([{ title: app.state.draft }])); app.set({ draft: "" }); } }
function done(i) { save(app.state.items.filter(function (_, j) { return j !== i; })); }
```

### Use the node made for it

Elpian has a node for most things people ask for, drawn and animated by the
app in the person's theme. Use it before building anything yourself
(`aseman-elpian elpian_describe '{"types":["Clock"]}'` gives its props):

| Asked for | Node |
|---|---|
| a clock, world clocks, a watch face | `Clock` (`mode: "analog"` or `"digital"`, `seconds`, `hour24`, `utcOffset`, `label`, `size`): live, it ticks by itself |
| a timer, a countdown | `Countdown` (ticks by itself) |
| a value against a range, a speedometer, a dial | `Gauge`, `RadialBars`, `Progress`, `BulletChart` |
| trends, comparisons, parts of a whole | `Chart` (`line` `bar` `area` `pie` …), `Sparkline`, `Funnel`, `Waterfall`, `Sankey`, `Sunburst`, `CalendarHeatmap` |
| key numbers | `Stat` on filled `Card`s in a `ResponsiveGrid` |
| a board, a schedule, dates | `Kanban`, `Gantt`, `Calendar`, `Timeline` |
| records, tables | `ListGroup` of `ListTile`s, `DataGrid`, `KeyValue`, `Leaderboard` |
| anything else that is a picture | a `Canvas` (below) — or a web plugin for 3D |

**Never draw a picture with text**: rows of `Text` holding dots, bullets,
slashes or emoji are not a clock, a chart or a shape; they break on every
screen and theme. The checker refuses it (`craft-text-art`), and refuses a
plugin named for something (an analog clock, a gauge) whose screen does not
use the node made for it or a `Canvas` (`craft-intent`).

### Drawing on a Canvas

A `Canvas` draws vector commands (`{type, params}`): `beginPath`,
`moveTo` / `lineTo` `{x, y}`, `arc` `{x, y, radius, startAngle, endAngle}`,
`fillCircle` / `strokeCircle` `{x, y, radius}`, `fillRect` `{x, y, width,
height}`, `fillText` `{text, x, y}`, `stroke`, `fill`, `setFillStyle` /
`setStrokeStyle` `{color}`, `setLineWidth` `{width}`, `setLineCap` `{cap}`,
`save` / `restore` / `translate` / `rotate`, gradients (ELPIAN.md, Elpian
nodes). Colors come from `Aseman.env().theme.colors`; size it from
`Aseman.viewport()` so it fits a phone. `app.every` runs every 5 s at
least: things that tick every second are nodes (`Clock`, `Countdown`).

```js
// A custom clock face on a Canvas: the theme's colors, sized to the window,
// redrawn every 30 s (app.every is 5 s at least; the Clock node ticks every
// second by itself when you need seconds).
var app = App.create({
  state: { now: Date.now() },
  view: function (s, app) {
    var v = Aseman.viewport(), size = Math.max(160, Math.min(320, v.width - 32, v.height - 120));
    return { type: "Column", props: { style: { padding: "16", gap: "12", alignItems: "center" } }, children: [
      { type: "Text", props: { text: "Studio clock", variant: "titleLargeEmphasized" } },
      { type: "Canvas", key: "face", props: { width: size, height: size, commands: face(size, new Date(s.now)) } },
    ] };
  },
  init: function (app) { app.every("tick", 30000, function () { app.set({ now: Date.now() }); }); },
});
function face(size, t) {
  var c = Aseman.env().theme.colors, r = size / 2, cmds = [];
  function hand(turns, length, width, color) {
    var a = turns * 2 * Math.PI - Math.PI / 2;
    cmds.push({ type: "setStrokeStyle", params: { color: color } }, { type: "setLineWidth", params: { width: width } },
      { type: "setLineCap", params: { cap: "round" } }, { type: "beginPath" }, { type: "moveTo", params: { x: r, y: r } },
      { type: "lineTo", params: { x: r + Math.cos(a) * length, y: r + Math.sin(a) * length } }, { type: "stroke" });
  }
  cmds.push({ type: "setFillStyle", params: { color: c.surfaceContainerHigh } }, { type: "fillCircle", params: { x: r, y: r, radius: r - 2 } });
  for (var i = 0; i < 12; i++) {
    var a = i / 12 * 2 * Math.PI;
    cmds.push({ type: "setFillStyle", params: { color: i % 3 ? c.outline : c.primary } },
      { type: "fillCircle", params: { x: r + Math.cos(a) * (r - 16), y: r + Math.sin(a) * (r - 16), radius: i % 3 ? 3 : 5 } });
  }
  hand((t.getHours() % 12 + t.getMinutes() / 60) / 12, r * 0.5, 8, c.onSurface);
  hand(t.getMinutes() / 60, r * 0.75, 5, c.primary);
  cmds.push({ type: "setFillStyle", params: { color: c.primary } }, { type: "fillCircle", params: { x: r, y: r, radius: 7 } });
  return cmds;
}
```

Design it like an app someone would screenshot: follow **ELPIAN.md,
Design** (Material 3 Expressive) to the letter: one clear hierarchy, `Text`
`variant` type roles (never `fontSize`), tonal `Card`s and `ListGroup`s (no
nested cards, no borders everywhere), colors from the theme (never hex),
one filled button per row, `icon` names (never emoji), every state designed
(loading, empty, error, busy). Gadgets are small windows (about 300×400 on
the chat, 260×340 on the left panel, 360×480 on the desk) that people can
resize; pages fill the screen: lay out from `Aseman.viewport()`.

## 4. A web plugin

One HTML document, everything inlined. The app's frame enforces this
policy, and the checker applies the same one:

```
default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' blob: data:;
style-src 'unsafe-inline' data:; img-src data: blob:; font-src data:; media-src data: blob:;
worker-src blob: data:; connect-src 'none'; frame-src 'none'
```

So no CDN `<script src>`, no `fetch`, no web fonts from Google, no remote
images: bundle libraries into the page, and reach data only through the
bridge. The app injects `aseman-web-plugin.js` first in `<head>`:

| | Promise |
|---|---|
| `Aseman.plugin.get / set / call / api / context` | as in Elpian (above) |
| `Aseman.env`, `Aseman.onEnv(fn)` | `{display, theme: {mode, colors, radius, font}, viewport}`; `fn` runs now and when the theme changes |

The person's theme is set on `:root` as CSS variables (`--aseman-primary`,
`--aseman-on-primary`, `--aseman-primary-container`, `--aseman-surface`,
`--aseman-on-surface`, `--aseman-on-surface-variant`,
`--aseman-surface-container`, `--aseman-surface-container-high`,
`--aseman-outline`, `--aseman-outline-variant`, `--aseman-error`, … every
color role kebab-cased; `--aseman-radius`, `--aseman-font`) and
`data-theme="light|dark"` on `<html>`. Use them for every color, so the
plugin matches the app in light and dark; read them in JS for canvas and
WebGL colors (`getComputedStyle(document.documentElement).getPropertyValue("--aseman-primary")`,
again in `Aseman.onEnv`).

Build with libraries:

```bash
cd /workspace/.plugins/globe
npm init -y >/dev/null && npm i three esbuild
# src/main.js imports from "three"; src/index.html has <script src="app.js"></script>
npx esbuild src/main.js --bundle --minify --format=iife --outfile=src/app.js
aseman-plugin-inline src/index.html -o dist/plugin.html
aseman-plugin-check dist/plugin.html --screenshots shots
```

Make it professional:

* **Responsive**: no fixed pixel widths; flex or grid that wraps; canvases
  sized to their container (`ResizeObserver`, `devicePixelRatio`); it must
  fit a 360×640 phone and a 1280×800 desk window.
* **Theme**: colors from the variables, `color-scheme` follows the theme,
  `font-family: var(--aseman-font)`, radii from `--aseman-radius`; no
  private palette unless the person asked for a brand look.
* **Polish**: a clear title and hierarchy, generous spacing (8-pt grid),
  smooth 60 fps animation (`requestAnimationFrame`, pause when hidden),
  loading and empty states, controls ≥ 40 px for touch, pointer and touch
  input both (`pointer*` events).
* **3D**: `WebGLRenderer({ antialias: true, alpha: true })`, size from the
  container, `OrbitControls` for touch, lights and materials that read well
  in both themes, a fallback message when WebGL is unavailable.
* **Small**: 6 MB at most with libraries; import only what you use
  (`import { Scene } from "three"`), minify.

## 5. A backend (optional)

Without one, the plugin has `get` / `set` (its own store). A backend is one
JavaScript program on QuickJS that declares `tools()` and one function per
tool; it keeps state with `askHost('aseman.kv.get' | 'aseman.kv.set',
{key, value})`:

```js
function tools() {
  return [{ name: "summary", description: "Totals by month", input: { type: "object", properties: { year: { type: "number" } } } }];
}
function summary(args) {
  var rows = JSON.parse(askHost("aseman.kv.get", { key: "rows" }) || "[]");
  return { months: rows.filter(function (r) { return r.year === args.year; }) };
}
```

The checker refuses a screen that calls a function the backend does not
declare, or a platform action not in `permissions`.

## Checklist

* [ ] Elpian unless 3D, web asked for, or a rich visualization Elpian cannot draw (`ui_reason` says which).
* [ ] `aseman-plugin-check` passes; web: the screenshots look right at phone and desk size.
* [ ] Every color from the person's theme; light and dark both read well.
* [ ] Loading, empty and error states are designed.
* [ ] Only the platform actions it needs are in `permissions`.
* [ ] `create_plugin` with `frontend_file` / `backend_file`, then tell the person where it is.
