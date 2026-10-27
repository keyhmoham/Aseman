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
elpian/e2e/*.json        end-to-end scenarios: journeys through the app (the driver saves and replays them)
vendor/aseman-elpian/    this kit: SDK, OpenUI, bundle.mjs, check.mjs, nodes.json,
                         validate.mjs + schema.mjs + icons.json (the UI DSL validator),
                         drive.mjs (the headless driver, for end-to-end tests),
                         examples/showcase.js (a reference app in M3 Expressive: scrolling pages),
                         examples/whiteboard.js (a reference app with a fixed, touch-driven screen)
server.* / src/…         your backend; it serves elpian/app.js and your API
```

Build and check:

```bash
node vendor/aseman-elpian/bundle.mjs .                     # -> elpian/app.js
node vendor/aseman-elpian/check.mjs elpian/app.js --apps APPS.json \
     --server http://127.0.0.1:$PORT                       # run it on QuickJS against your running server
```

`check.mjs` runs the program on QuickJS (the engine the client uses), against
a simulated Aseman host (a small phone, 360×640, then a 1280×800 desk window),
and against your running server: it fails on exceptions, unknown node types,
events naming missing functions, handlers that throw with the event data the
client sends (gestures as the finger makes them: start, moves, end), server
errors, every error the **UI DSL validator** finds in what the program
renders (below), and the validator's findings that break the app for the
person using it: a drawing surface inside a scroll, handlers inside a control,
an overlay that swallows taps, a touch target with no size, sizes larger than
a phone, a fixed screen taller than a phone. The platform runs it too before
the app is shown; make it pass.

## Your `elpian_*` tools

Every builder of an app has the same `elpian_*` tools (the validator and the
headless driver below), reached one of two ways:

* **OpenCode** has them as MCP servers (`elpian`, `elpian-driver`): call them
  as tools.
* **An Aseman agent** has them as the `aseman-elpian` command on the sandbox
  shell, with the same names and arguments (a JSON object), run from the
  project directory (or with `--dir`):
  `aseman-elpian elpian_open '{"server":"http://127.0.0.1:8787"}'`,
  `aseman-elpian elpian_tap '{"target":"Add task"}'`,
  `aseman-elpian elpian_validate @tree.json` (arguments from a file; `-` reads
  stdin). Driver sessions stay open between commands, exactly as across MCP
  calls; `aseman-elpian tools [name]` lists the tools and their arguments and
  `aseman-elpian stop` ends the project's sessions. Start your server in the
  background while you test (`nohup … > server.log 2>&1 &`).

## Validating view trees (the UI DSL validator)

`vendor/aseman-elpian/validate.mjs` checks Elpian view trees against the
engine's own schema (`schema.mjs`, kept in sync with the Flutter builders and
measured layout behaviour). Use it while you build, not only at the end. You
have it two ways:

| Your tools (`elpian_*`, see below) | Command line |
|---|---|
| `elpian_validate {tree}` / `{file}` (`mode: "widget"`, `openui: true`) | `node vendor/aseman-elpian/validate.mjs tree.json [--widget] [--openui]` (`-` reads stdin) |
| `elpian_validate_program {bundle, server, apps}` | `node vendor/aseman-elpian/validate.mjs --program elpian/app.js --server http://127.0.0.1:$PORT [--apps APPS.json]` |
| `elpian_describe {types: ["ListTile"]}` (no types: every node) | `node vendor/aseman-elpian/validate.mjs --describe ListTile,Button` / `--list` |
| `elpian_icons {query: "calendar"}` | `grep calendar vendor/aseman-elpian/icons.json` |

The program mode runs your bundle like `check.mjs` (QuickJS, simulated host,
your server) and **explores its states**: from every distinct state it fires
every handler with the event data the client really sends (several values
per input), breadth first, and validates **every screen it reaches**, as the
app and as the phone widget. A finding that only shows after some taps says
how to get there — `(reached after: tap "÷" → tap "=")` — and so does a
`view` that throws in some state. While exploring, writes to your server are
answered from its earlier answers, so it is not flooded.
Options: `--json`, `--strict` (warnings fail too), `--no-design`, `--quiet`.
The exit code is 1 when there are errors.

What it checks, each finding with its path (`Scaffold > ListView > Column >
Row > TextField#q`, `$.children[0]…`), why it matters and the fix:

* **Shape:** `type` present and drawn; only `type`, `props`, `children`,
  `events`, `key`, `style` on a node (`child`, `onTap`, props at the top
  level are caught). Conditional children are fine — `null`, `undefined`
  and `false` entries are dropped (`cond ? node : null` works) and nested
  arrays flatten — but a bare string child is drawn as plain Text with no
  type role (a warning).
* **Props:** unknown props (with "did you mean"), types — strict where the
  builder casts (`Switch` `value: "true"`, `TextField` `hint: 42` throw),
  enums, ranges (`opacity` 0..1, `flex` ≥ 1, `Slider` min < max), required
  content, Material icon names, value formats, and **data fields** (`Chart`
  `x`/`y`/`series`, `DataGrid` `columns[].field` must exist on the rows).
* **Styles:** unknown keys, value types and units (`rem`, `"16 16 0 0"` as a
  radius, CSS strings for `border`, negative padding), colors that do not
  parse, hard-coded colors outside the person's theme (a design note).
* **Events:** handlers must be names (strings) and JS identifiers; events a
  node never fires (`Button` `press`); events on a widget; **one tap handler
  on differently labelled controls** (a tap carries no data about which was
  tapped, so they all do the same thing — give each its own
  `app.handler(key, fn)`).
* **Keys:** string keys; unique among siblings (Flutter throws) and unique in
  the tree when nodes have events (events are dispatched by key); interactive
  inputs without a key lose focus.
* **Parents and children:** `Expanded`/`Flexible`/`Spacer` directly in a
  `Row`/`Column` (not a wrapping one, without events on them), `Positioned`
  in a `Stack`; children a node ignores or drops (`Text` with children,
  several children in `Center`); unknown slots; `ListGroup` children.
* **Layout (measured):** nodes that throw without a width bound (`TextField`,
  `SearchBar`, `ListTile`, `ListGroup`, `ListView`, `Chart`, `DataGrid`,
  `Section`, `Callout`, … directly in a `Row`: wrap them in `Expanded`) or a
  height bound (`Scaffold`, `Drawer` inside a scroll), and `Expanded` in a
  `Column` inside a scrolling list.
* **Touch:** a node that follows the finger (`drag*`, `pointermove`,
  `scale*`) inside a scroll (`gesture-in-scroll`: make the screen fixed);
  swipes on the axis of the scroll around them; handlers inside a control
  that is tapped as a whole (`Icon` with `tap` inside a `Button`); events
  under `pointerEvents: "none"`; empty boxes with events and no size; a
  painted `Positioned` overlay that covers interactive siblings in a
  `Stack` (give it `pointerEvents: "none"`).
* **Fits a phone:** sizes wider or taller than a small phone (360×640)
  where nothing scrolls them; a screen that does not scroll but needs more
  height than a phone gives it (`layout-screen-overflow`); `Row`s that need
  more width than they get (`layout-row-overflow`). Sizes are lower bounds
  from the M3 specs, so a finding is a real overflow.
* **Phone widget:** no tables, lists, inputs or chrome, at most
  80 nodes, no events.
* **Design (notes):** M3E practice — type roles instead of font sizes, one
  filled button per row, icons instead of emoji, no nested cards, tooltips
  on icon buttons, alt text on images.

```bash
echo '{"type":"Row","children":[{"type":"TextField","props":{"hint":"Search"}}]}' | node vendor/aseman-elpian/validate.mjs -
# ERROR [layout-unbounded-width] Row > TextField
#   TextField has no width bound here (it is directly in a Row …) — Flutter throws …
#   fix: Wrap it in Expanded (inside the Row), or give it/its parent a style.width.
```

## Testing end to end (the headless driver)

`check.mjs` and the validator prove the program runs and renders. They do
not prove the app *works*: that adding an order shows it in the list, that
the filter filters, that the save button is enabled once the form is
filled. Prove that by **using the app as a person does, headlessly**, with
the Elpian driver — like a headless browser, but for Elpian: no
screenshots, the screen is a text outline. Your `elpian_*` driver tools
(an MCP server for OpenCode, `aseman-elpian` for an agent: Your `elpian_*`
tools, above) keep a session open across calls:

| Tool | |
|---|---|
| `elpian_open` | run the bundle against your running server (`server`, default the `JOB.json` port; or `start: "node server.js"`); answers with the first screen |
| `elpian_snapshot` | the screen now: one line per text, control and data view |
| `elpian_tap`, `elpian_type`, `elpian_select`, `elpian_toggle`, `elpian_gesture`, `elpian_fire` | use a control |
| `elpian_wait` | let held requests through (`release`), pass time (`ms`: timers and `app.every` fire), or wait `until` an expectation holds |
| `elpian_expect` | assert the screen, a control, the app's state, the request the last action made |
| `elpian_mock` | answers for the space's agents and apps (and your server's paths): replies, failures, held requests |
| `elpian_env` | the viewport (`phone`, `desk`, `"WxH"`), the theme (`light`, `dark`), `display: "widget"` |
| `elpian_state`, `elpian_network`, `elpian_logs`, `elpian_coverage`, `elpian_reload`, `elpian_close` | look inside, start over |
| `elpian_save_scenario`, `elpian_run_scenarios` | save the session as `elpian/e2e/<name>.json`; replay them all |

A screen reads like this (refs `e1`, `e2` … stay the same for the same
control across renders):

```
Screen 360×640 (compact, light) · render 4
- Scaffold
  - Text "Team tasks"
  - IconButton [e1] "Refresh" icon=refresh (on: tap)
  - SegmentedButton [e4] options: Open* | Done | All (on: change)
  - ListGroup [e5]
    - ListTile [e6] "Write spec" — "ana · due today" trailing="Urgent" (on: tap)
  - TextField [e8] "What needs doing?" value="" icon=edit (on: input)
  - Button [e12] "Add task" icon=add disabled (on: tap)
  - NavigationBar [e7] items: Tasks* (1) | New | Insights (on: change)
```

Target a control by its ref (`"e12"`), by `{key}`, or by the text it shows
(`"Add task"`, `{type: "Button", text: "Delete", nth: 1}`,
`{text: "Delete", within: "e6"}`); tapping an option's label (`"Insights"`)
picks it. Each action runs the handler the client runs, with the event data
the client sends, settles the requests it makes (your server for real), and
answers with the screen's changes, the requests and the **PROBLEMS** it
found:

```
✓ tap Button "Add task"
requests: POST /api/tasks → 201 · GET /api/tasks → 200
screen changes:
- - TextField [e8] "What needs doing?" value="Buy milk" icon=edit (on: input)
+ - ListTile [e13] "Buy milk" — "me · due today" (on: tap)
problems: none
```

It behaves like the phone: a **disabled** control, a control under
`pointerEvents: "none"` or a handler inside a `Button` does nothing (and it
says why); a tap on a label reaches the control around it; a text field
shows what was typed; `Tabs` and `Expandable` switch by themselves; time
only passes when you `elpian_wait` (`ms`). Problems are exceptions (a
handler or the view throws, a `TypeError` that `app.fail` turned into a
banner), error banners nobody expected, server 5xx or no answer, renders
that break (the validator's errors), and dead controls (a button without a
handler).

**How to test an app**, after it builds and `check.mjs` passes, with the
server running:

1. `elpian_open`; read the first screen.
2. Go section by section (each destination, tab, dialog, form, list) and
   use **every control** on it: type real values, pick every option, tap
   every action, swipe and drag what follows the finger. After each step
   that should change something, `elpian_expect` it: the text a person now
   sees (`text`, `noText`), the control (`target` + `value`, `on`,
   `selected`, `disabled`, `rows`), the state (`state: {"items.length": 3}`),
   the request it made (`request: {method: "POST", path: "api/orders",
   body: {…}}`).
3. Mock the space realistically (`elpian_mock`): agent replies shaped like
   real ones (`{op: "ask", agent, reply}`), microtool results as the text
   they really are (`{op: "call", tool, microtool, result}`). Then the
   unhappy paths: a failing agent or server path (`error`, `status`) must
   show a human error state (`elpian_expect {errorBanner: …}` or your own
   error view), and a held request (`hold: true`) must show a loading
   state before `elpian_wait {release: true}`.
4. Check the layout on a phone and a desk window, light and dark
   (`elpian_env`), and the phone widget (`display: "widget"`).
5. Every PROBLEM is a bug: fix the code, rebuild, `elpian_reload`, repeat
   the step. `elpian_coverage` lists the controls no step has used yet:
   continue until it lists none.
6. Save each user journey (`elpian_save_scenario`, one session per journey:
   `elpian_open` again for the next) and replay them all with
   `elpian_run_scenarios`. The platform replays `elpian/e2e/*.json` against
   your server before the app is shown — an app without passing scenarios
   is not ready.

A scenario is plain JSON you can also write or edit by hand:

```json
{ "name": "add a task", "viewport": "phone",
  "mocks": [{ "op": "ask", "agent": "planner", "reply": "Start with the spec." }],
  "steps": [
    { "do": "tap", "target": "New" },
    { "do": "type", "target": { "key": "draft" }, "text": "Buy milk" },
    { "do": "tap", "target": { "type": "Button", "text": "Add task" } },
    { "expect": { "text": "Buy milk", "request": { "method": "POST", "path": "api/tasks" } } },
    { "do": "select", "target": { "key": "filter" }, "value": "Done" },
    { "expect": { "noText": "Buy milk" } }
  ] }
```

Steps: `tap`, `double_tap`, `long_press`, `type` (`text`, `clear`,
`submit`, `keystrokes`), `clear`, `submit`, `select` (`value`), `toggle`
(`on`), `swipe` (`direction`), `drag` (`from`, `to`, `steps`; or `to` a
drop target), `pinch` (`scale`, `rotation`), `hover`, `move` (a Kanban
`card` `to` a column), `link` (`href`), `remove`, `fire` (`event`,
`data`), `wait` (`release`, `ms`, `until`), `env`, `mock`, `setState`,
`reload` — or `{ "expect": {…} }`. A scenario fails when a step cannot be
done, an expectation fails, or a problem is left at the end (expect an
error banner you meant to show). Scenarios run one after another against
the same server, so do not depend on the data an earlier run left behind:
create what a journey needs in the journey, and assert on what it created.
On the command line:

```bash
node vendor/aseman-elpian/drive.mjs run elpian/e2e --server http://127.0.0.1:$PORT   # replay; exit 1 on failure
node vendor/aseman-elpian/drive.mjs snapshot --server http://127.0.0.1:$PORT         # the first screen
```

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
    return { type: "Column", props: { style: { padding: "16", gap: "16" } }, children: [
      { type: "Text", props: { text: "Orders", variant: "headlineMediumEmphasized" } },
      app.input("draft", "draft", { label: "New order", icon: "edit" }),  // TextField bound to s.draft
      { type: "Button", props: { text: "Add", icon: "add", loading: s.busy },
        events: { tap: app.handler("add", add) } },
      { type: "Card", props: { variant: "filled", style: { padding: "8" } }, children: [
        { type: "DataGrid", props: { data: s.items, columns: [{ field: "title" }, { field: "total", type: "number", format: "currency:USD" }] } } ] },
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
| `app.handler(key, fn)` | a global handler name for `events` (stable per key, any characters: `app.handler("key_" + label, …)` for each key of a keypad; errors are shown, not lost); `fn(event, app)` |
| `app.input(key, field, props)` | a `TextField` bound to `state[field]` (props: `label`, `hint`, `icon`, `helper`, …; `search: true` draws a `SearchBar`; `live: true` redraws on every keystroke — needed when the view depends on what is typed, like a button enabled once there is text: otherwise it redraws only on the next `set`) |
| `Aseman.fetch(path, {method, body, query, headers})` | your server: resolves `{status, ok, json, text}`; rejects on non-2xx (`{raw: true}` to get them) |
| `Aseman.ask(agent, prompt, {history})` | a space agent: `{agent, reply}`. Every ask is a fresh, isolated conversation (a temporary room thread deleted after) |
| `Aseman.askJSON(agent, prompt, data)` | asks for JSON and parses it |
| `Aseman.conversation(agent)` | `.send(text)` keeps the history in the program |
| `Aseman.call(tool, microtool, args)` | a space app's microtool: its unwrapped result (often a markdown string) |
| `Aseman.agents()`, `Aseman.tools()`, `Aseman.microtools(tool)`, `Aseman.context()` | discovery |
| `Aseman.env()` | `{display: full\|compact\|sheet, widget: {size, shape} (compact), theme: {mode, accent, colors}, viewport, user, space, room, title}`; `Aseman.onEnv(fn)` on change (the app re-renders by itself) |
| `Aseman.viewport()` | `{width, height, sizeClass: compact\|medium\|expanded, orientation}`: the space the app is drawn in (phones are `compact`, < 600 wide; desk windows usually `expanded`, ≥ 840). The app re-renders when it changes: pick the layout from it (see Screen layout) |
| `App.create({…, widget: {view, refresh, size, shape, refreshMs, static}})` | the phone widget (required; see The phone widget) |
| `app.every(key, ms, fn)`, `app.isWidget()` | a timer (min 5 s); whether it is drawn as the widget now |
| `Aseman.compact(summary)`, `Aseman.expand()` | a published summary instead of a drawn widget; open in full |
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
Where you set a color, take it from `Aseman.env().theme.colors` — the full
set of Material 3 roles: `primary`, `onPrimary`, `primaryContainer`,
`onPrimaryContainer`, the same four for `secondary`, `tertiary` and `error`,
`surface`, `onSurface`, `onSurfaceVariant`, `surfaceContainerLowest` /
`Low` / (plain) / `High` / `Highest`, `inverseSurface`, `onInverseSurface`,
`outline`, `outlineVariant` — rather than hard-coding one, unless the brief
asks for a dedicated brand palette. Most nodes take roles by name, so you
rarely need hex at all (`Text` `color: "muted"`, `Card` `tone: "primary"`,
`Tag` `status`). See **Design** below.

### Screen layout: a scrolling page or a fixed screen

Apps open on phones (360–430 wide, 640–930 tall) as often as in desk
windows, and the window can be any size. Decide for **each screen** which
of two layouts it is — do not make every screen one long scroll:

| Kind | For | Shape |
|---|---|---|
| **Scrolling page** | content that grows: feeds, lists, forms, dashboards, settings, articles | `Scaffold` > `ListView` > `Column` (padding 16, gap 16–24) — `examples/showcase.js` |
| **Fixed screen** | the screen *is* the tool and fills the window exactly: whiteboards and drawing, canvases and games, maps, 3D scenes, chats (messages scroll, the composer stays), calculators, players, editors, anything you drag, pinch or swipe on | `Scaffold` > `Column` (`alignItems: "stretch"`): fixed parts (a header `Row`, a toolbar) take their height, the main part takes the rest in an `Expanded`; a part of it that grows scrolls inside its own `Expanded` > `ListView` — `examples/whiteboard.js` |

```js
// A fixed screen: fits any window, nothing scrolls around the surface.
{ type: "Scaffold", children: [
  { type: "Column", props: { style: { alignItems: "stretch" } }, children: [
    { type: "Row", props: { style: { padding: "12 16", gap: "8", alignItems: "center" } }, children: [
      { type: "Expanded", children: [{ type: "Text", props: { text: "Sketch", variant: "headlineSmallEmphasized" } }] },
      { type: "IconButton", key: "undo", props: { icon: "undo", tooltip: "Undo" }, events: { tap: app.handler("undo", undo) } },
    ] },
    { type: "Expanded", children: [                       // all the free height
      { type: "Canvas", key: "board", props: { commands: s.commands },
        events: { dragstart: app.handler("down", down), drag: app.handler("move", move), dragend: app.handler("up", up) } },
    ] },
  ] },
  { type: "NavigationBar", props: { selected: s.tab, items: [/* … */] }, events: { change: app.handler("tab", tab) } },
] }
```

Rules that make both kinds fit every screen:

* **Never** put a drawing surface, a map, a 3D scene or anything that
  follows the finger inside a `ListView` / `Scroll`: the page would scroll
  instead (older clients) or could only be scrolled around it, and the
  surface scrolls out of view. The check fails on it (`gesture-in-scroll`).
* A fixed screen must fit a **360×640 phone** (less the app bar and
  navigation bar): only the `Expanded` parts stretch; when the fixed parts
  are too tall, move what grows into an `Expanded` > `ListView`, or show less
  on small screens. The check fails on overflow (`layout-screen-overflow`).
* No fixed `width` above 360 or `height` above 640 where nothing scrolls
  them: leave sizes unset so nodes fill the space, cap them with `maxWidth`,
  use percentages, or size from `Aseman.viewport()`. A `Canvas` without
  `width`/`height` fills its box (in an `Expanded`: the free space).
* `Row`s must fit 360 px: put texts in `Expanded` (with `maxLines` /
  `overflow: "ellipsis"`), let chips and buttons wrap (`Wrap`), use
  `IconButton`s for secondary actions on phones.
* **Adapt to the window**: `Aseman.viewport().sizeClass` is `compact` on
  phones, `medium` on small tablets, `expanded` on desk windows — e.g. a
  `NavigationBar` and one column on `compact`, two panes side by side
  (a `Row` of `Expanded`s) on `expanded`; a toolbar `Row` on wide screens,
  stacked rows on phones. The app re-renders when the window changes.

### Events

Every handler gets the event as plain JSON: its `type`, `target` (the node's
key), the fields below, and `data`. Read `e.value` for every `change` and
`input`, whichever node sent it (`data`'s fields are also at the top level).
Positions are `{x, y}` in logical px: **`localPosition`** on the node itself
(a canvas's own coordinates: draw at them), `position` on the screen, and
`delta` since the last move.

| Event | From | Event data (besides `type`, `target`) |
|---|---|---|
| `tap`, `doubletap`, `longpress` | any node (the engine adds the gesture), `Button`, `InkWell` | — |
| `tapdown`, `tapup`, `longpressstart` / `longpressmove` / `longpressend`, `secondarytap` | any node | `localPosition`, `position` |
| `dragstart`, `drag`, `dragend` | any node (`Canvas`, a `Container`, a `Card`, …): one finger (or the mouse) moving on it | `localPosition`, `position`, `delta`; `dragend` also `velocity` |
| `pointerdown`, `pointermove`, `pointerup`, `pointercancel` | any node: raw touches, every finger (`pointerId`) | `localPosition`, `position`, `delta`, `pointerId`, `pressure` |
| `scalestart`, `scaleupdate`, `scaleend` (`pinch*`, `rotate*`: only with two fingers) | any node: pinch-zoom, rotate, two-finger pan | `scale` (1 at the start), `rotation` (radians), `focalPoint`, `localFocalPoint` |
| `swipeleft`, `swiperight`, `swipeup`, `swipedown` | any node: a fling | `velocity` |
| `resize` | `Canvas`, when it is laid out at a new size | `width`, `height` |
| `input` | `TextField` (each keystroke) | `value` |
| `submit` | `TextField` (enter) | — |
| `change` | `Checkbox`, `Switch`, `Slider`, `Radio`, `Rating`, `Chip` (with `selected`), `SegmentedButton`, `NavigationBar` (`value` = index), `Tabs`, `Carousel`, `Pagination` | `value` |
| `input`, `submit` | `SearchBar` (like `TextField`) | `value` / — |
| `remove` | `Chip` (`variant: "input"`) | — |
| `select` | `Chart`, `DataGrid`, `Heatmap`, `Treemap`, `Graph`, `Timeline`, `TreeView` | `index`, `row`, … (also under `data`) |

Give interactive nodes (`TextField`, `SearchBar`, `Checkbox`, `Switch`,
`Slider`, `SegmentedButton`) a stable `key` so they keep focus across
renders.

### Touch and nested gestures

* **The innermost node wins.** A tap on a `Button` inside a tappable `Card`
  runs only the button's handler; a tap elsewhere on the card runs the
  card's. So never put handlers *inside* a control that is tapped as a whole
  (`Button`, `IconButton`, `FAB`, `Chip`, `SegmentedButton`,
  `NavigationBar`, `Switch`, `Checkbox`, `Slider`, `TextField`): put the
  event on the control itself.
* **A node that follows the finger owns the touches that start on it.**
  With `drag*`, `pointermove` or `scale*`, a stroke that starts on it is its
  own as soon as it moves — the scroll, drawer or page view around it does
  not get it — while taps on buttons over it (a toolbar on a canvas) still
  work. Handlers fire in order: `dragstart`, then `drag` for each move,
  then `dragend` (also when the touch is cancelled); keep the stroke being
  drawn in state from `dragstart` and finish it in `dragend`.
* **Swipes** only take their own axis: `swipeleft` / `swiperight` on rows of
  a vertical list are fine; `swipeup` / `swipedown` there steal the list's
  scrolling (and sideways swipes inside a `Carousel` or horizontal list
  steal its paging).
* **Overlays**: anything with a background on top of a `Stack` (a scrim, a
  HUD backdrop) takes the touches of what is under it. Give it
  `style.pointerEvents: "none"` to let touches through; events inside
  such a node never fire.
* **Something to touch**: a node with events needs a size — an empty
  `Container` in a `Column` is 0 px tall; give it a height or padding, or
  put it in an `Expanded`.
* Keep keys unique: events are dispatched by key.

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
| `FractionallySizedBox` | `widthFactor`, `heightFactor` (0..1 of the space) |
| `CircularProgressIndicator`, `LinearProgressIndicator` | `value` (0..1; omit to spin / sweep). Prefer `LoadingIndicator` and the kit's `Progress` |
| `AnimatedDefaultTextStyle`, `TweenAnimationBuilder` (`tweenType`: `opacity` `scale` `rotation` `translateX` `translateY`) | text-style and value animations |
| `Text` | `text`, **`variant`** (an M3 type role: `displayLarge` `displayMedium` `displaySmall` `headlineLarge` `headlineMedium` `headlineSmall` `titleLarge` `titleMedium` `titleSmall` `bodyLarge` `bodyMedium` `bodySmall` `labelLarge` `labelMedium` `labelSmall`; add `Emphasized` for the bolder expressive weight, e.g. `headlineMediumEmphasized`), `color` (a role: `primary` `secondary` `tertiary` `error` `muted`), `maxLines`, `overflow`, `softWrap`, `textAlign` |
| `Button` | `text`, **`variant`** (`filled` default, `tonal`, `outlined`, `text`, `elevated`, `danger`), `icon` / `trailingIcon` (Material icon names), `size` (`xs` 32 · `s` 40 default · `m` 56 · `l` 96 · `xl` 136 high), `shape` (`round` / `square`), `selected` (a toggle button), `loading`, `fullWidth`, `tooltip`, `disabled`; events `tap`, `longpress`. Corners morph and the button springs when pressed |
| `IconButton` | `icon`, `variant` (`standard` `filled` `tonal` `outlined`), `size`, `shape`, `selected` + `selectedIcon` (a toggle), `tooltip`, `disabled`; `tap` |
| `FAB` (also `FloatingActionButton`) | `icon` (default `add`), `label` (extended FAB), `size` (`small` `medium` `large`), `variant` (`primary` `secondary` `tertiary` `surface`); `tap`. In a `Scaffold` it floats bottom-right |
| `SegmentedButton` | `segments: [{value, label, icon}]` (or strings), `selected` (a value, or a list with `multi`), `multi`, `size` (`s`/`m`); `change` `{value}`. The connected button group: filters, view switches, 2–5 short options |
| `TextField` | `hint`, `label` (floating label), `icon` / `trailingIcon`, `prefix` / `suffix` (`$`, `kg`), `helper`, `error`, `variant` (`filled` default / `outlined`), `value`, `obscureText`, `multiline`, `maxLines`, `keyboardType` (`text` `number` `email` `phone` `url` `date` `time`), `min`/`max` (dates), `disabled`; events `input`, `submit` |
| `SearchBar` | `hint`, `value`, `icon`, `trailingIcon`; events `input`, `submit` (a pill search field) |
| `Checkbox`, `Switch` | `value` (bool), `label` (tapping the label toggles too), `disabled`; `change` |
| `Radio` | `value`, `groupValue`; `change` |
| `Slider` | `value`, `min`, `max`, `step` or `divisions`, `label` (`true` or a suffix like `"%"`: a value bubble while dragging); `change` |
| `Image` | `src` (https URL, `/v1/files/<id>/content`, a project file path, data URI), `fit` (`cover` `contain` …), `alt`; size it with `style.width` / `style.height`, round it inside a `ClipRRect` |
| `Icon` | `icon` (a Material Symbols name, drawn rounded: `home`, `search`, `add`, `edit`, `delete`, `settings`, `insights`, `payments`, `event`, `auto_awesome`, `rocket_launch`, … ~650 names; also camelCase / kebab-case), `size`, `style.color` |
| `Card` | `variant` (`filled` tonal, `elevated`, `outlined`; default the theme's card), `tone` (`primary` `secondary` `tertiary` `error` `inverse`: a highlighted card in that container color), `radius`, `elevation`; `style.padding` (inside) and `style.gap` (between children); with `events.tap` it ripples and springs |
| `ListTile` | `title`, `subtitle`, `overline`, `leading` (an icon: drawn in a tonal rounded square), `leadingAvatar` (a name: initials), `leadingImage`, `trailing` (an icon), `trailingText` (a time, an amount), `selected`, `dense`, `lines` (3 wraps the subtitle), `disabled`; `tap`, `longpress` |
| `ListGroup` | `title`, `variant` (`tonal` / `outlined`), `radius`, `innerRadius`, `gap`; children (`ListTile`s) become one segmented M3E group: tonal tiles 2px apart, large outer and small inner corners |
| `NavigationBar` | `items: [{icon, selectedIcon, label, badge}]` (3–5), `selected` (index), `labels` (`always` `selected` `never`); `change` `{value: index}`. In a `Scaffold`, the bottom bar |
| `LoadingIndicator` | `size` (48), `contained`: the M3E loading indicator, a soft shape morphing as it spins. For waits; `Progress` for measurable work |
| `Divider`, `VerticalDivider` | separators |
| `Chip` | `label`, `icon`, `selected` (a filter chip with a check; `change`), `variant` (`assist` `filter` `input` `suggestion`); `tap`, `remove` (input chips) |
| `Badge` | `label` or `count` (`99+` past `max`); no label = a dot; around its child (an `Icon`) |
| `Tooltip` | `message` |
| `InkWell`, `GestureDetector` | make any child tappable (`events.tap`) |
| `Scaffold`, `AppBar` (`title`), `Drawer` | app chrome for a full-screen layout: children go to slots by type (`AppBar`, `FAB`, `NavigationBar`, `Drawer`) or `props.slot`; the rest is the body |
| `Dismissible`, `Draggable`, `DragTarget`, `Hero` | swipe, drag and drop, shared transitions |
| `MathExpression`, `Math` | `latex` / `expression` |
| `Canvas`, `CachedCanvas` | `commands` (`{type, params}`: `beginPath`, `moveTo`/`lineTo` `{x, y}`, `setStrokeStyle` `{color}`, `setLineWidth` `{width}`, `setLineCap` `{cap}`, `stroke`, `fillRect`, `fillCircle`, `fillText`, …), `width`, `height` (`Canvas` without them fills its box: put it in an `Expanded`), `backgroundColor`: vector drawing, clipped to the canvas. `resize` `{width, height}`; draw with `drag*` / `pointer*` events at `e.localPosition` (see Touch) |
| `Scene3D` (also `scene3d`) | an embedded 3D scene (Godot) |
| `AnimatedContainer`, `AnimatedOpacity`, `AnimatedCrossFade` (`showFirst`), `AnimatedSwitcher` (`transitionType`), `AnimatedAlign`, `AnimatedPadding`, `AnimatedPositioned`, `AnimatedScale`, `AnimatedRotation`, `AnimatedSlide`, `AnimatedSize`, `FadeTransition`, `SlideTransition`, `ScaleTransition`, `RotationTransition`, `SizeTransition` (`axis`), `StaggeredAnimation`, `Shimmer`, `Pulse`, `AnimatedGradient` | motion: animate when their style changes between renders (`transitionDuration`, `animationName`, …) |

HTML-named nodes (`div`, `p`, `h1`…`h6`, `span`, `button`, `input`, `ul`,
`li`, `table`, …) also render, but prefer the Flutter nodes and the UI kit:
they are what the Aseman look is built from.

### UI kit nodes (data views, themed)

| Node | Props |
|---|---|
| `Chart` | `type`: `line` `area` `bar` `scatter` `bubble` `candlestick` `histogram` `pie` `donut` `radar` `heatmap` `treemap` (and every chart below by name: `funnel` `waterfall` `sankey` `gantt` `boxplot` `sunburst` `bullet` `segmented` `radialbar` `calendar` `wordcloud`, with that node's props); `data` (rows), `x`, `series` (`[field]` or `[{field, label, color}]`) or `y`; `title`, `stacked`, `horizontal`, `smooth`, `legend`, `xFormat`, `yFormat`, `height`; pie/donut: `label`, `value`; `select` event |
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
| `Progress` | `value`, `max`, `variant` (`linear`/`circular`), `wavy` (the expressive wavy bar, for work in progress), `label`, `showValue`, `status`, `size`, `thickness` |
| `Tag` | `text`, `status` (`good` `warning` `serious` `critical` `info`) or `color` (default: the accent), `variant` (`tonal` `filled` `outline`), `icon`, `dot` |
| `Rating` | `value`, `max`, `size`; `change` event |
| `Callout` | `title`, `text`, `severity` (`info` `good` `warning` `critical`), `icon`; children below |
| `Avatar` | `name`, `url`, `size` |
| `ResponsiveGrid` | `columns` or `minColumnWidth` (+ `maxColumns`), `gap` |
| `Section` | `title`, `subtitle`, `icon`; children |
| `Expandable` | `title`, `subtitle`, `icon`, `expanded`; children |
| `Scroll` | `direction`, `maxHeight`; children |

**More charts** (all themed, with hover tooltips; `select` sends the mark tapped):

| Node | Props |
|---|---|
| `Funnel` | `data: [{label, value}]` (`label`/`value` rename the fields), `format`, `color`, `title`: stages as centered bars with share of the first stage and step conversion |
| `Waterfall` | `data: [{label, value}]` (a row with `total: true` draws the running total), `start`, `startLabel`, `showTotal` (default true), `totalLabel`, `format`, `height`, `upColor`/`downColor` |
| `Sankey` | `links: [{from, to, value}]`, `nodes: [{id, label, color}]` (optional), `format`, `height`: flows between nodes in layers |
| `Gantt` | `data: [{label, start, end, progress, group, status, color}]` (ISO dates), `timeFormat`: tasks on a time axis, today marked; `start == end` is a milestone |
| `BoxPlot` | `data: [{label, values: [...]}]` (raw samples: outliers shown) or `[{label, min, q1, median, q3, max}]`, `format`, `colorful` |
| `BulletChart` | `items: [{label, value, target, ranges: [a, b, c], max, format}]` (or one bullet's props): progress against a target over qualitative bands |
| `SegmentedBar` | `data: [{label, value, color}]`, `format`, `thickness`, `showPercent`, `legend`: one bar split into parts (storage, budget, status mix) |
| `RadialBars` | `data: [{label, value, max, color}]` (≤ 6), `size`, `centerLabel`, `centerCaption`, `legend`: activity rings |
| `Sunburst` | `data: {label, children: [{label, value, children}]}` (or a list), `size`, `format`: a hierarchy as rings |
| `CalendarHeatmap` | `data: [{date, value}]`, `weeks` (26), `end`, `format`, `color`: a contribution graph, one cell a day |
| `WordCloud` | `data: [{text, value}]`, `max` (60), `colorful`, `height` |

**Tables:**

| Node | Props |
|---|---|
| `PivotTable` | `data` (rows), `rows` (a field or list), `columns` (a field or list), `value`, `aggregate` (`sum` `count` `avg` `min` `max`), `format`, `totals` (default true), `heat` (default true), `sort`, `maxHeight`; `select` `{row, column, value}` |
| `Leaderboard` | `data: [{name, value, subtitle, avatar, change, id}]`, `max` (10), `format`, `highlight` (a name or id: "you"), `showBar`; ranked with medals for the top three |

**App widgets** (interactive, drawn natively):

| Node | Props · events |
|---|---|
| `Tabs` | `tabs: [{label, icon, badge}]` (or strings), children = one panel per tab, `selected`, `variant` (`primary`/`secondary`) · `change` `{value}` |
| `Calendar` | `month` (`yyyy-MM`), `selected` (`yyyy-MM-dd`), `events: [{date, title, time, color, status}]`, `firstDay` (`monday`/`sunday`), `showEvents` · `select` `{date, events}`, `change` `{month}` |
| `Kanban` | `columns: [{id, title, color, cards: [{title, subtitle, tags, assignee, due, priority}]}]`, `columnWidth` · `select` `{column, index, card}`, `move` `{card, from, to, fromId, toId}` (long-press drag; update your state to move it) |
| `Carousel` | children (slides) or `items: [{image, title, subtitle}]`, `height` (200), `autoplay` (ms), `viewportFraction`, `dots` · `change` `{value}` |
| `Stepper` | `steps: [{title, subtitle, state}]` (or strings; `state` `done` `current` `error`), `current`, `orientation` · `select` `{index}` |
| `Chat` | `messages: [{role: user\|assistant\|system, text, name, time, avatar}]` (light markdown), `typing`, `suggestions`, `showAvatars` · `select` `{text}` (a suggestion) |
| `Countdown` | `to` (ISO time) or `seconds`, `label`, `size` (`compact` `default` `hero`) · `done` |
| `Clock` | `mode` (`analog`/`digital`), `utcOffset` (hours), `label`, `size`, `seconds`, `hour24` |
| `EmptyState` | `icon`, `title`, `text`, `action` (button label), `actionIcon`, `size` · `action` |
| `AvatarGroup` | `names` or `items: [{name, url}]`, `max` (4), `size` |
| `Pagination` | `page` (1-based), `pages`, `siblings` · `change` `{value}` |
| `Breadcrumbs` | `items: [{label, icon}]` (or strings) · `select` `{index, label}` |

**Text and data views:**

| Node | Props · events |
|---|---|
| `Markdown` | `text` (headings, lists, task lists, quotes, fenced code with highlighting, tables, images, links, **bold** / *italic* / `code` / ~~strike~~), `size` · `link` `{href}` (without a handler, links open in the browser) |
| `LogView` | `lines` (strings like `"10:01 ERROR failed"`, or `[{time, level, message, source}]`), `title`, `filter`, `wrap`, `lineNumbers`, `follow` (keeps the end in view), `maxHeight` |
| `DiffView` | `before` + `after` (or a unified `diff`), `title`, `context` (3), `maxHeight`: changed lines on green/red, unchanged runs folded |
| `QRCode` | `data` (a URL or text), `size` (160), `ecc` (`L` `M` `Q` `H`), `label`, `rounded`: scannable in light and dark |

In a `Row` without a width bound, these views take a natural fallback
width rather than throwing; wrap them in `Expanded` to fill the row (the
validator warns: `layout-fallback-width`).

Formats: `number[:decimals]`, `integer`, `compact`, `percent[:decimals]`
(fractions), `currency[:CODE[:decimals]]`, `date`, `time`, `datetime`; a
leading `+` signs positives.

## Design: Material 3 Expressive (required)

Aseman apps are drawn in **Material 3 Expressive (M3E)**: Google's most
recent Material language — bold, tonal, rounded, springy, and calm where it
matters. The Elpian nodes above already *are* M3E (button shape morphing,
spring motion, tonal containers, rounded Material Symbols, the 2024 slider
and progress styles); your job is to compose them into screens that feel
designed, not assembled. Aim for an app someone would screenshot.

**Start from `vendor/aseman-elpian/examples/showcase.js`**: a complete app
(header, hero stat, KPI cards, segmented filter, grouped list, form, agent
island, navigation bar, loading / empty states, phone widget) that passes
`check.mjs`. Borrow its structure and idioms; make the content yours. Its
screens are scrolling pages; for a screen that is a tool (drawing, a game, a
map, a chat, a player), start from **`examples/whiteboard.js`**: a fixed
screen with a toolbar and a drawing surface that fills the window, strokes
from drag events, and an adaptive layout from `Aseman.viewport()`.

### Principles

1. **One clear hierarchy per screen.** A header (an emphasized headline, one
   supporting line, at most one primary action), then content in titled
   groups. The eye should land on the single most important thing first —
   make it big (`Stat` `size: "hero"`, `displaySmallEmphasized`), give it
   the accent (`Card` `tone: "primary"`), and let everything else recede.
2. **Tonal surfaces, not lines and shadows.** Layer `surface` →
   `surfaceContainer*` roles: `Card` `variant: "filled"` for groups,
   `ListGroup` for lists, `tone` cards to highlight. Avoid borders around
   every box, drop shadows, and cards nested in cards.
3. **Expressive shape.** Large corner radii on containers (20–28), fully
   round controls, a tonal rounded square behind icons (`ListTile`
   `leading`, `Stat` `icon`, `Section` `icon`). Contrast shapes: a square
   `selected` button among round ones, a `FAB` `size: "large"` as the hero
   action.
4. **Type with contrast.** Use `Text` `variant` roles, never ad-hoc
   `fontSize`/`fontWeight` for UI text: `display*`/`headline*`
   `Emphasized` for the moment that matters, `title*` for group and card
   titles, `body*` for reading, `label*` for meta. Big numbers + calm body
   text = expressive; everything bold = noise. `color: "muted"` for
   secondary text.
5. **Color from the person's theme.** Leave colors unset; when you need
   emphasis use roles (`tone`, `variant`, `status`, `color: "primary"`).
   One accent moment per view. Status is never color alone: `Tag` /
   `Callout` carry an icon or label.
6. **Motion with purpose.** State changes animate: wrap swapped content in
   `AnimatedSwitcher`, sizes in `AnimatedSize` / `AnimatedContainer`.
   Waits show a `LoadingIndicator` (or `Shimmer` skeletons shaped like the
   content), long work a `Progress` (`wavy: true` while active). Never a
   frozen screen.
7. **Rhythm.** An 8-pt grid: screen padding 16 (24 on wide windows), 12–16
   between cards, 24–32 between sections, 8–12 inside groups. Tap targets
   ≥ 40 high.
8. **Responsive.** Desk windows are wide, phones narrow (down to 360×640):
   lay out cards with `ResponsiveGrid` (`minColumnWidth` 260–320), stats
   with `minColumnWidth` 160; switch layouts on `Aseman.viewport().sizeClass`;
   pick a scrolling page or a fixed screen per screen (see Screen layout);
   multi-screen apps use `NavigationBar` (3–5 destinations) or a
   `SegmentedButton`.

### Which node for which need

| Need | Use |
|---|---|
| The screen's main action | `Button` (`filled`, often `size: "m"` with an `icon`), or a `FAB` (extended with `label`) |
| Secondary / tertiary actions | `Button` `tonal` / `outlined` / `text`; `IconButton` for icon-only (`tooltip`!) |
| Switch views / filter by one option | `SegmentedButton` (2–5 short options); many options: `Chip`s with `selected` in a `Wrap` |
| Destinations of a multi-screen app | `NavigationBar` in a `Scaffold`, keep the screen in state |
| Lists of things (people, tasks, files, settings) | `ListGroup` of `ListTile`s (`leading` icon or `leadingAvatar`, `trailingText` meta, `tap`) |
| Key numbers | `Stat` (`icon`, `format`, `delta`, `trend`) on filled cards in a `ResponsiveGrid` |
| A highlighted fact / summary | `Card` `tone: "primary"` (or `tertiary`) with a `headline*Emphasized` text |
| Search | `SearchBar` (or `app.input(key, field, {search: true, hint})`) |
| Forms | `TextField` with `label`, `icon`, `helper` / `error`; `Switch` / `Checkbox` with `label`; `Slider` with `label`; group fields in a filled `Card`, primary `Button` at the end |
| Tables | `DataGrid` (records), `PivotTable` (totals by group), `Leaderboard` (rankings), `KeyValue` (one record) |
| Charts | `Chart` (trends, comparisons, parts), `Funnel` (conversion), `Waterfall` (how a total moved), `Sankey` (flows), `Gantt` (schedules), `BoxPlot` (spread), `BulletChart` (against a target), `SegmentedBar` (a mix), `RadialBars` (goals), `Sunburst` (hierarchies), `CalendarHeatmap` (activity by day), `WordCloud` (themes) — inside a filled `Card` |
| Sections of a screen | `Tabs` (panels), `Stepper` (a process), `Carousel` (featured items), `Breadcrumbs` + `Pagination` (navigation) |
| Planning and time | `Calendar` (events by day), `Kanban` (work by stage), `Gantt`, `Countdown`, `Clock` |
| Conversation and text | `Chat` (a thread with an agent), `Markdown` (agent answers, docs), `LogView`, `DiffView`, `CodeBlock` |
| Sharing | `QRCode` (a link to open on a phone), `AvatarGroup` (who is in) |
| Nothing to show yet | `EmptyState` with the action that fills it |

### A screen, composed

```js
// A scrolling page (see Screen layout for fixed screens).
view: function (s, app) {
  var c = Aseman.env().theme.colors;
  return { type: "ListView", children: [{ type: "Column", props: { style: { padding: "16", gap: "24" } }, children: [
    // Header: emphasized headline, supporting line, the one primary action.
    { type: "Row", props: { style: { alignItems: "center", gap: "12" } }, children: [
      { type: "Expanded", children: [{ type: "Column", props: { style: { gap: "4" } }, children: [
        { type: "Text", props: { text: "Orders", variant: "headlineMediumEmphasized" } },
        { type: "Text", props: { text: s.open + " open · updated " + s.updated, variant: "bodyMedium", color: "muted" } },
      ] }] },
      { type: "Button", props: { text: "New order", icon: "add", size: "m" }, events: { tap: app.handler("new", newOrder) } },
    ] },
    // The hero fact, on the accent container.
    { type: "Card", props: { tone: "primary", style: { padding: "20", gap: "8" } }, children: [
      { type: "Stat", props: { label: "Revenue today", value: s.revenue, format: "currency:USD:0",
                               delta: s.delta, deltaFormat: "+percent", deltaLabel: "vs yesterday", trend: s.trend, size: "hero" } },
    ] },
    // Supporting numbers.
    { type: "ResponsiveGrid", props: { minColumnWidth: 160, gap: 12 }, children: s.kpis.map(function (k) {
      return { type: "Card", props: { variant: "filled", style: { padding: "16" } }, children: [
        { type: "Stat", props: { label: k.label, value: k.value, icon: k.icon, format: k.format } } ] };
    }) },
    // A filter and a grouped list.
    { type: "SegmentedButton", key: "filter", props: { selected: s.filter, segments: [
      { value: "open", label: "Open", icon: "inbox" }, { value: "done", label: "Done", icon: "task_alt" }, { value: "all", label: "All" } ] },
      events: { change: app.handler("filter", function (e, app) { app.set({ filter: e.value }); }) } },
    { type: "AnimatedSwitcher", children: [ s.items.length ? { type: "ListGroup", key: s.filter, children: s.items.map(function (o) {
      return { type: "ListTile", props: { title: o.customer, subtitle: o.summary, leading: "receipt_long",
               trailingText: o.total }, events: { tap: app.handler("open_" + o.id, function () { openOrder(o.id); }) } };
    }) } : { type: "EmptyState", key: "empty", props: { icon: "inbox", title: "No orders yet",
             text: "New orders show up here as they come in.", action: "New order" },
             events: { action: app.handler("new_empty", newOrder) } } ] },
  ] }] };
}
```

### Every state is designed

* **Loading:** `Shimmer` around boxes shaped like the content
  (`borderRadius` 8–16), or a `LoadingIndicator` with a short line of what
  is happening. Keep the header visible.
* **Empty:** an `EmptyState` — an icon in a tonal rounded square, a title,
  one muted sentence, and the action that fills it.
* **Error:** `Callout` `severity: "critical"` with a human sentence (never
  a stack trace) and a `tonal` "Try again" button with the `refresh` icon;
  `app.fail(e)` does this for you.
* **Busy actions:** `Button` `loading: true` (it spins and disables) rather
  than replacing the label; confirm results inline (`Tag`, `Callout`
  `good`), not with alerts.
* **Agent islands** (`OpenUI.panel` / `action`) already draw M3E cards,
  loading indicators and retry buttons: place them like any other card.

### Don't

* Hard-code hex colors, gray-on-gray text, or a private palette (unless the
  brief asks for a brand look).
* Use `fontSize` / `fontWeight: "bold"` for UI text instead of `variant`.
* Put more than one `filled` button side by side; make the rest `tonal`,
  `outlined` or `text`.
* Use emoji or text characters as icons (`"+"`, `"›"`, `"⚙"`): use `icon`
  names.
* Wrap everything in outlined boxes or nest cards in cards; separate with
  space and tonal surfaces instead.
* Leave a screen a single long column of plain text, or center body text.
* Use HTML nodes (`div`, `p`, `button`) for app UI.

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

## The phone widget (required)

On a phone, the desk is a board of widgets: every app sits there as a small
tile, and a tap opens it in full. **Every app ships its own widget**: a
second, glanceable view of the same program that shows the few live facts
that matter for what the app is for — the number to watch, the next thing
due, the latest result, the trend. Design it with the same care as the app.

```js
App.create({
  state: { orders: [], revenue: 0, trend: [] },
  view: function (s, app) { /* the full app */ },
  init: function (app) { load(app); },                 // runs in both displays
  widget: {
    size: "medium",                                     // small 1×1 · medium 2×1 · large 2×2
    shape: "card",                                      // card · squircle · pill · circle · leaf
    refreshMs: 60000,                                   // live: refresh runs on this timer (min 5 s)
    refresh: function (app) { load(app); },             // defaults to init
    view: function (s, app) {
      var size = (Aseman.env().widget || {}).size || "medium";
      var open = s.orders.filter(function (o) { return !o.done; }).length;
      return { type: "Row", props: { style: { gap: "12", padding: "12", alignItems: "center" } }, children: [
        { type: "Stat", props: { label: "Revenue today", value: s.revenue, format: "currency:USD:0",
                                 trend: s.trend, size: "compact" } },
        size === "small" ? null : { type: "Column", props: { style: { gap: "4" } }, children: [
          { type: "Tag", props: { text: open + " open", status: open ? "warning" : "good" } },
          { type: "Sparkline", props: { values: s.trend, height: 28 } },
        ] },
      ].filter(Boolean) };
    },
  },
});
```

When the program runs as the widget, `Aseman.env().display` is `compact`
and `Aseman.env().widget` is `{size, shape}` (the tile the person chose,
which can differ from yours); the SDK draws `widget.view` instead of `view`,
tells the board your preferred size and shape, runs `init`, then `refresh`
every `refreshMs`. Opened in full (`display` `sheet` or `full`), the same
program draws `view` — no restart, same state.

Make it good:

* **Live, from real data**: the widget loads its data (your server, a space
  app, an agent's summary) — never placeholders. `widget.static: true` only
  for an app that truly has no changing data.
* **One glance, one story**: lead with the single most useful value
  (`Stat` with `format`, `delta`, `trend`), then at most two supporting
  facts (`Tag`, `Sparkline`, `Progress`, `Gauge`, a short `Text`, a tiny
  `Chart` in `large`). No tables, lists, inputs or app chrome
  (`DataGrid`, `ListView`, `TextField`, `AppBar` are refused); at most
  80 nodes.
* **Glanceable nodes**: `Stat`, `Tag`, `Sparkline`, `Progress`, `Gauge`,
  `RadialBars` (goals), `SegmentedBar` (a mix), `CalendarHeatmap` (a streak),
  `Countdown`, `Clock`, `QRCode`, `AvatarGroup`, a tiny `Chart`.
* **Fit every size**: read `Aseman.env().widget.size` — `small` shows one
  value, `medium` a value and a fact or trend, `large` a small chart or
  three facts. Keep text short; no scrolling.
* **Theme**: leave colors to the theme (or `env().theme.colors`); status by
  `Tag`/`Stat` `status`, not raw colors.
* **States**: show a quiet skeleton or `—` while loading and a short line
  on errors, never a stack trace.
* **No interaction**: taps open the full app; don't put events in the
  widget.

`check.mjs` runs the program as its widget too: it fails when there is no
widget, when it is not glanceable, when it loads no live data, or when its
refresh throws.

You can also publish a summary instead of drawing (`Aseman.compact({title,
value, format, delta, …})`), but a drawn `widget` is expected.

### A web app's widget

An app with a web frontend (`ui: web`) has a native widget too: a small
Elpian program of its own, in `elpian/widget/*.js`, bundled to
`elpian/widget.js` (`bundle.mjs . --widget`) and served by your server at
`GET /elpian/widget.js`. It is only ever drawn as the widget; opened, the
web app shows. Write it exactly like an Elpian app with a widget, and reach
your server with `Aseman.fetch` as usual:

```js
App.create({
  state: { due: null, count: 0 },
  view: function (s, app) { return app.widgetSpec().view(s, app); },   // never shown in full
  init: function (app) {
    Aseman.fetch("api/summary").then(function (r) { app.set({ due: r.json.next, count: r.json.open }); });
  },
  widget: { size: "medium", view: function (s) { /* … */ } },
});
```

Check it with `check.mjs elpian/widget.js --widget-only …`; `READY.json`
names it: `"widget": "elpian/widget.js"`.

## Checklist

1. `elpian/src/*.js` written against this file; no browser APIs; designed
   to **Design: Material 3 Expressive** (type roles, tonal surfaces, icons,
   designed loading / empty / error states).
2. Each screen is a scrolling page or a fixed screen (Screen layout); it
   fits a 360×640 phone and a desk window; nothing that follows the finger
   is inside a scroll; handlers read `e.value` / `e.localPosition`.
3. Server serves `GET /elpian/app.js` and its API; `start` serves both.
4. `node vendor/aseman-elpian/bundle.mjs .` then `check.mjs … --server …`
   pass, and `elpian_validate_program` (or `validate.mjs --program …`)
   reports no errors or warnings for the app and the widget.
5. Tests for the server, and for the frontend's pure logic (state updates,
   parsing microtool / agent replies) run with `node --test`.
6. A `widget` that shows live, use-case-specific facts at a glance in every
   size (see The phone widget); `check.mjs` passes for it too.
7. Driven end to end with the Elpian driver: every screen and every
   control used, expectations after each step, no PROBLEM left,
   `elpian_coverage` empty; each journey saved in `elpian/e2e/*.json` and
   `elpian_run_scenarios` (`drive.mjs run elpian/e2e`) passing.
8. `READY.json` has `"ui": "elpian"` and `"elpian": "elpian/app.js"`.
