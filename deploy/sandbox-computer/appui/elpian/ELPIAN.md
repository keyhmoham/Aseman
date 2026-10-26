# Elpian App UI (the default frontend of Aseman apps)

An Aseman app is a fullstack project in the space's sandbox. Its **frontend is
an Elpian program**: plain JavaScript that runs on the **Elpian QuickJS
runtime inside the Aseman client** (phone, desktop and web alike) and draws
**native Flutter UI** from JSON view trees. There is no browser, no DOM, no
HTML/CSS files, no `fetch`, no npm packages and no modules in the frontend.
Its backend is your server in the sandbox, which the frontend reaches with
`Aseman.fetch`.

Write the frontend this way unless the brief explicitly asks for a web
frontend (then follow `AGENTS.md`'s web rules instead).

## How it runs

```
Aseman client (Flutter)                     sandbox
┌───────────────────────────────┐           ┌──────────────────────────┐
│ QuickJS: elpian/app.js        │  Aseman.fetch("api/…")  your server  │
│  ├ askHost('render', tree) ──►│ Flutter widgets          │ (serves     │
│  ├ Aseman.ask / call ────────►│ page API (agents, apps)  │  elpian/    │
│  └ handlers ◄── taps, input   │──────────────────────────►  app.js too)│
└───────────────────────────────┘           └──────────────────────────┘
```

1. Your server serves the bundle at **`GET /elpian/app.js`**
   (`Content-Type: application/javascript`), next to its own API routes.
2. The client downloads it through the preview gateway, prepends nothing,
   and runs it on QuickJS with the Aseman host.
3. The program renders by calling `askHost('render', JSON)` (the SDK's
   `App` does it for you). Taps and typing call the **global functions**
   named in the tree's `events`.
4. Everything outside the program is asynchronous: `Aseman.*` returns a
   **Task** (`then` / `catch` / `finally`), settled when the host answers.
   The screen stays live while an agent works.

## Project layout

```
elpian/src/*.js          your frontend (shared global scope; main.js last)
elpian/manifest.json     optional: {"files": ["src/state.js", "src/main.js"]} to fix the order
elpian/app.js            the bundle (generated: never edit it)
vendor/aseman-elpian/    this kit: SDK, OpenUI, bundle.mjs, check.mjs, nodes.json
server.* / src/…         your backend; it serves elpian/app.js and your API
```

Build and check:

```bash
node vendor/aseman-elpian/bundle.mjs .                     # -> elpian/app.js
node vendor/aseman-elpian/check.mjs elpian/app.js --apps APPS.json \
     --server http://127.0.0.1:$PORT                       # run it on QuickJS against your running server
```

`check.mjs` runs the program on QuickJS (the engine the client uses), against
a simulated Aseman host, and against your running server: it fails on
exceptions, unknown node types, events naming missing functions, handlers
that throw with a sample event, and server errors. The platform runs it too
before the app is shown; make it pass.

## Language rules (QuickJS)

* ES2020 JavaScript: `let`/`const`, arrow functions, classes, template
  strings, destructuring are fine. **No** `import`/`require`, `fetch`,
  `XMLHttpRequest`, `window`, `document`, `localStorage`, `Intl`, `setTimeout`
  from the browser, or `async`/`await` on Aseman calls: use the SDK's Tasks.
* Event handlers must be **global functions** (or created with
  `app.handler(key, fn)`, which makes one). Their names go into `events`.
* Keep state in the program (`app.state`); persist with your server.
* Never put secrets in the frontend; the person's identity reaches your
  server automatically (`X-Aseman-User-Token`, see `ASEMAN_API.md`).

## The SDK (`aseman-elpian.js`, always in the bundle)

```js
var app = App.create({
  state: { items: [], draft: "", busy: false },
  view: function (s, app) {                       // returns the view tree
    return { type: "Column", props: { style: { padding: "16", gap: "12" } }, children: [
      { type: "Text", props: { text: "Orders", style: { fontSize: "22", fontWeight: "bold" } } },
      app.input("draft", "draft", { hint: "New order" }),          // TextField bound to s.draft
      { type: "Button", props: { text: s.busy ? "Saving…" : "Add", disabled: s.busy },
        events: { tap: app.handler("add", add) } },
      { type: "DataGrid", props: { data: s.items, columns: [{ field: "title" }, { field: "total", type: "number", format: "currency:USD" }] } },
    ] };
  },
  init: function (app) { load(); },               // after the first render
});

function load() {
  Aseman.fetch("api/orders").then(function (r) { app.set({ items: r.json.items }); })
    .catch(function (e) { app.fail(e); });       // shows an error banner
}
function add(event, app) {                         // event is plain JSON
  app.set({ busy: true });
  Aseman.fetch("api/orders", { method: "POST", body: { title: app.state.draft } })
    .then(function () { app.set({ draft: "" }); load(); })
    .catch(function (e) { app.fail(e); })
    .finally(function () { app.set({ busy: false }); });
}
```

| API | |
|---|---|
| `App.create({state, view(state, app), init(app)})` | renders `view` now and after every `app.set(patch)` |
| `app.set(patch[, {silent}])`, `app.render()`, `app.fail(error)` | update and redraw; `fail` shows a dismissible error banner |
| `app.handler(key, fn)` | a global handler name for `events` (stable per key; errors are shown, not lost); `fn(event, app)` |
| `app.input(key, field, props)` | a `TextField` bound to `state[field]` |
| `Aseman.fetch(path, {method, body, query, headers})` | your server: resolves `{status, ok, json, text}`; rejects on non-2xx (`{raw: true}` to get them) |
| `Aseman.ask(agent, prompt, {history})` | a space agent: `{agent, reply}`. Every ask is a fresh, isolated conversation (a temporary room thread deleted after) |
| `Aseman.askJSON(agent, prompt, data)` | asks for JSON and parses it |
| `Aseman.conversation(agent)` | `.send(text)` keeps the history in the program |
| `Aseman.call(tool, microtool, args)` | a space app's microtool: its unwrapped result (often a markdown string) |
| `Aseman.agents()`, `Aseman.tools()`, `Aseman.microtools(tool)`, `Aseman.context()` | discovery |
| `Aseman.env()` | `{display: full\|compact\|sheet, theme: {mode, accent, colors}, user, space, room, title}`; `Aseman.onEnv(fn)` on change (the app re-renders by itself) |
| `Aseman.compact(summary)`, `Aseman.expand()` | the phone widget summary (see below), open in full |
| `Aseman.Task`, `Task.all([...])`, `Aseman.plain(v)`, `Aseman.parseJSON(text)`, `Aseman.log(...)` | utilities |

Who pays: every agent ask and app call from the frontend runs as **the person
using the app** and is billed to their wallet (see `ASEMAN_API.md`).

## View trees

A node is `{type, props?, children?, events?, key?}`. `props.style` is a
CSS-like object (numbers as strings or numbers):

| Style | Values |
|---|---|
| layout | `padding`, `margin`, `width`, `height`, `minWidth`, `maxWidth`, `minHeight`, `maxHeight`, `gap`, `justifyContent` (`flex-start` `center` `flex-end` `space-between` `space-around` `space-evenly`), `alignItems` (`flex-start` `center` `flex-end` `stretch`), `flexWrap`, `flex` |
| look | `backgroundColor`, `color`, `borderRadius`, `border`, `borderColor`, `borderWidth`, `boxShadow`, `opacity`, `gradient` |
| text | `fontSize`, `fontWeight`, `fontStyle`, `fontFamily` (`serif`, `monospace`), `textAlign`, `lineHeight`, `letterSpacing`, `textDecoration` |
| motion | `transitionDuration`, `animationName`, … (animated nodes below) |

**Theme:** the client draws the app with the person's Aseman theme (light or
dark, and their accent) and redraws it when they change it. The UI kit and
the Material widgets follow it by themselves; leave colors unset to get it.
Where you set a color, take it from `Aseman.env().theme.colors` (`primary`,
`onPrimary`, `primaryContainer`, `onPrimaryContainer`, `secondary`,
`tertiary`, `surface`, `onSurface`, `onSurfaceVariant`,
`surfaceContainer`, `surfaceContainerHighest`, `outline`, `error`) rather
than hard-coding one, unless the brief asks for a dedicated brand palette.

### Events

| Event | From | Event data (the handler's argument) |
|---|---|---|
| `tap`, `doubletap`, `longpress` | any node (the engine adds the gesture), `Button`, `InkWell` | `{type}` |
| `input` | `TextField` (each keystroke) | `{value}` |
| `submit` | `TextField` (enter) | `{}` |
| `change` | `Checkbox`, `Switch`, `Slider`, `Radio`, `Rating` | `{value}` |
| `select` | `Chart`, `DataGrid`, `Heatmap`, `Treemap`, `Graph`, `Timeline`, `TreeView` | `{data: {index, row, …}}` |

Give interactive nodes (`TextField`, `Checkbox`, `Switch`, `Slider`) a stable
`key` so they keep focus across renders.

### Elpian nodes (Flutter widgets)

| Node | Props (beyond `style`) |
|---|---|
| `Column`, `Row` | children laid out by `style.gap`, `justifyContent`, `alignItems` |
| `Wrap` | flowing children, spaced by `style.gap` |
| `Stack`, `Positioned` | overlays; `Positioned` uses `style.top/left/right/bottom` |
| `Container`, `Padding`, `Center`, `Align`, `SizedBox`, `ConstrainedBox`, `LimitedBox`, `OverflowBox`, `FittedBox`, `AspectRatio` (`aspectRatio`), `DecoratedBox`, `ClipRRect`, `Baseline` (`baseline`), `RotatedBox` (`quarterTurns`), `Transform`, `Opacity` (`opacity`) | box layout and decoration through `style` |
| `Expanded`, `Flexible` | `flex`, inside a `Row`/`Column` |
| `Spacer` | `flex` |
| `ListView` | `scrollDirection`, `scrollable`; scrolling lists |
| `GridView` | `crossAxisCount` |
| `IndexedStack` | `index`: shows one child |
| `Text` | `text`, `maxLines`, `overflow`, `softWrap`, `textAlign` |
| `Button` | `text`, `disabled`; `events.tap` |
| `TextField` | `hint`, `value`, `obscureText`, `multiline`, `maxLines`, `keyboardType` (`text` `number` `email` `phone` `url` `date`), `min`/`max` (dates); events `input`, `submit` |
| `Checkbox`, `Switch` | `value` (bool); `change` |
| `Radio` | `value`, `groupValue`; `change` |
| `Slider` | `value`, `min`, `max`; `change` |
| `Image` | `src` (https URL, `/v1/files/<id>/content`, a project file path, data URI), `fit` (`cover` `contain` …), `alt` |
| `Icon` | `icon` (a Material icon name: `home`, `search`, `add`, `delete`, `edit`, `settings`, `star`, …), `size`, `style.color` |
| `Card` | `elevation`; a Material card around its children |
| `Divider`, `VerticalDivider` | separators |
| `Chip` | `label` |
| `Badge` | `label` |
| `Tooltip` | `message` |
| `InkWell`, `GestureDetector` | make any child tappable (`events.tap`) |
| `Scaffold`, `AppBar` (`title`), `Drawer` | app chrome for a full-screen layout |
| `Dismissible`, `Draggable`, `DragTarget`, `Hero` | swipe, drag and drop, shared transitions |
| `MathExpression`, `Math` | `latex` / `expression` |
| `Canvas`, `CachedCanvas` | `commands`, `width`, `height`, `backgroundColor`: vector drawing (canvas commands) |
| `Scene3D` (also `scene3d`) | an embedded 3D scene (Godot) |
| `AnimatedContainer`, `AnimatedOpacity`, `AnimatedCrossFade` (`showFirst`), `AnimatedSwitcher` (`transitionType`), `AnimatedAlign`, `AnimatedPadding`, `AnimatedPositioned`, `AnimatedScale`, `AnimatedRotation`, `AnimatedSlide`, `AnimatedSize`, `FadeTransition`, `SlideTransition`, `ScaleTransition`, `RotationTransition`, `SizeTransition` (`axis`), `StaggeredAnimation`, `Shimmer`, `Pulse`, `AnimatedGradient` | motion: animate when their style changes between renders (`transitionDuration`, `animationName`, …) |

HTML-named nodes (`div`, `p`, `h1`…`h6`, `span`, `button`, `input`, `ul`,
`li`, `table`, …) also render, but prefer the Flutter nodes and the UI kit:
they are what the Aseman look is built from.

### UI kit nodes (data views, themed)

| Node | Props |
|---|---|
| `Chart` | `type`: `line` `area` `bar` `scatter` `bubble` `candlestick` `histogram` `pie` `donut` `radar` `heatmap` `treemap`; `data` (rows), `x`, `series` (`[field]` or `[{field, label, color}]`) or `y`; `title`, `stacked`, `horizontal`, `smooth`, `legend`, `xFormat`, `yFormat`, `height`; pie/donut: `label`, `value`; `select` event |
| `Sparkline` | `values`, `type` (`line`/`bar`/`area`), `height`, `width` |
| `Gauge` | `value`, `min`, `max`, `label`, `format`, `thresholds: [{value, status}]` |
| `Heatmap` | `data` of `{x, y, value}` or `rows`/`columns`/`values`; `format`, `diverging` |
| `Treemap` | `data`, `label`, `value`, `group`/`colorBy`, `format` |
| `Graph` | `nodes: [{id, label, group}]`, `edges: [{from, to, label, weight}]`, `layout` (`force` `circle` `tree`), `directed` |
| `DataGrid` | `data`, `columns: [{field, label, type, format, align, width}]` (types `text` `number` `trend` `badge` `progress` `sparkline` `image` `avatar` `boolean` `link`), `search`, `pageSize`, `sortable`, `striped`, `dense`, `maxHeight`, `title`, `emptyText`; `select` event |
| `Stat` | `label`, `value`, `format`, `delta`, `deltaFormat`, `deltaLabel`, `goodDirection`, `trend`, `icon`, `status`, `size` (`compact` `default` `hero`) |
| `KeyValue` | `items: [{label, value, format, type}]` or `data` + `labels`; `columns` |
| `Timeline` | `data: [{title, description, time, status, icon}]`, `timeFormat` |
| `TreeView` | `data: {label, value, icon, children}` (or a list), `expanded` |
| `JsonView` | `value`, `expanded` |
| `CodeBlock` | `code`, `language`, `lineNumbers`, `maxHeight` |
| `Progress` | `value`, `max`, `variant` (`linear`/`circular`), `label`, `showValue`, `status`, `size` |
| `Tag` | `text`, `status` (`good` `warning` `serious` `critical` `info`) or `color`, `variant` (`tonal` `filled` `outline`), `icon` |
| `Rating` | `value`, `max`, `size`; `change` event |
| `Callout` | `title`, `text`, `severity` (`info` `good` `warning` `critical`), `icon`; children below |
| `Avatar` | `name`, `url`, `size` |
| `ResponsiveGrid` | `columns` or `minColumnWidth` (+ `maxColumns`), `gap` |
| `Section` | `title`, `subtitle`, `icon`; children |
| `Expandable` | `title`, `subtitle`, `expanded`; children |
| `Scroll` | `direction`, `maxHeight`; children |

Formats: `number[:decimals]`, `integer`, `compact`, `percent[:decimals]`
(fractions), `currency[:CODE[:decimals]]`, `date`, `time`, `datetime`; a
leading `+` signs positives.

## OpenUI (agent-generated UI) in Elpian (`openui-elpian.js`, always in the bundle)

The same OpenUI component collection as the web kit (137 components, tree
`{c, p, children}`, see `vendor/aseman-openui/catalog.spec.json`) renders as
Elpian nodes. Mix agent-backed islands with programmed UI wherever the brief
calls for judgment (drafting, analysing, summarising, planning) — not
everything agent-driven, not nothing.

```js
view: function (s, app) {
  return { type: "Column", props: { style: { gap: "12", padding: "16" } }, children: [
    OpenUI.panel(app, "brief", { agent: "research", title: "Briefing",
                                 prompt: "Brief me on {{city}} today", vars: { city: s.city } }),
    OpenUI.action(app, "draft", { agent: "assistant", label: "Draft a reply",
                                  prompt: "Draft a polite reply to: {{msg}}", vars: { msg: s.msg } }),
    OpenUI.query(app, "forecast", { tool: "weather", microtool: "forecast", args: { city: s.city }, title: "Forecast" }),
    OpenUI.render({ c: "Card", p: { title: "Static" }, children: [{ c: "Markdown", p: { content: "**Hi**" } }] }),
  ] };
}
```

| API | |
|---|---|
| `OpenUI.panel(app, key, {agent, prompt, vars, title, auto, values})` | asks on first render (`auto: false` waits for a tap) and shows the answer |
| `OpenUI.action(app, key, {agent, prompt, label, vars})` | a button that asks and shows the answer below |
| `OpenUI.query(app, key, {tool, microtool, args, title})` | a section filled by a microtool's result |
| `OpenUI.render(tree, ctx)`, `OpenUI.fromReply(text, ctx)`, `OpenUI.markdown(text)` | render a tree, an agent reply (OpenUI JSON, fenced ```openui, or markdown), markdown |

Inside an island's answer, OpenUI buttons, forms and follow-up chips work:
a `Button`'s `action` (`"text"` or `{type: "ask", prompt}`) asks the same
agent a follow-up with the island's form values; `{type: "call", tool,
microtool, args}` runs a microtool; `{type: "set", set: {...}}` sets values.
Islands keep their state in `app.state.__openui[key]`; reuse a key to keep
one, use a new key for a new island.

## Phones: the compact widget

On a phone the app sits on the board as a widget; tapped, it opens in full.
`Aseman.env().display` is `compact`, `sheet` or `full`. Publish what the
widget shows with `Aseman.compact({title, value, format, delta, deltaFormat,
caption, trend, progress, status, icon, metrics: [{label, value}]})` and
call it again as data changes.

## Checklist

1. `elpian/src/*.js` written against this file; no browser APIs.
2. Server serves `GET /elpian/app.js` and its API; `start` serves both.
3. `node vendor/aseman-elpian/bundle.mjs .` then `check.mjs … --server …` pass.
4. Tests for the server, and for the frontend's pure logic (state updates,
   parsing microtool / agent replies) run with `node --test`.
5. `READY.json` has `"ui": "elpian"` and `"elpian": "elpian/app.js"`.
