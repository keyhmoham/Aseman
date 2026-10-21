# Tool frontend UI kit

Charts, graphs, tables, data views and layout pieces for tool frontends, on
top of every Flutter and HTML node the Elpian engine already renders. One
implementation serves both frontend modes:

| Mode | How a frontend uses the kit |
|---|---|
| **Static** (Elpian VM / QuickJS program) | Return kit nodes in the view tree: `{type: 'Chart', props: {...}, events: {select: 'onPick'}}`. Rendered by `kitEngine()` in `ToolFrontendView`. |
| **Generative** (A2UI) and agent widgets (`ui_compose`) | Use the components of Aseman's genui catalog (`lib/src/genui/catalog`): `{"id": "c", "component": "Chart", "data": {"path": "/history"}, ...}`. Props take literals, `{"path"}` bindings or function calls at any depth. |

The node (Go) knows the same component list (`services/pkg/a2ui`). It teaches it to models with `CatalogPrompt` and rejects components devices can't render. A test there checks that the two lists match.

## Data views

Node type (static) / component (A2UI) and its props. Field props name a key of each row (`a.b` reaches nested keys).

| Node / component | Props |
|---|---|
| `Chart` | `type`: `line` `area` `bar` `scatter` `bubble` `candlestick` `histogram` `pie` `donut` `radar` `heatmap` `treemap`; `data` (rows, or plain numbers); `x` (field); `series` (`[field]` or `[{field, label, color}]`) or `y`; `title`, `subtitle`, `stacked`, `horizontal`, `smooth`, `points`, `zero`, `valueLabels`, `legend`, `xFormat`, `yFormat`, `xLabel`, `yLabel`, `min`, `max`, `height`. Candlestick: `open` `high` `low` `close` fields. Bubble: `size` field. Pie/donut: `label`, `value` fields, `centerLabel`. Histogram: `field`, `bins`. |
| `Sparkline` | `values` (numbers or rows + `field`), `type` (`line`/`bar`/`area`), `color`, `height`, `width` |
| `Gauge` | `value`, `min`, `max`, `label`, `format`, `thresholds: [{value, status\|color}]`, `size` |
| `Heatmap` | `data` rows of `{x, y, value}` (fields renamable), or `rows`, `columns`, `values` (matrix); `format`, `diverging`, `showValues`, `cellHeight` |
| `Treemap` | `data`, `label`, `value`, `group` (categorical color) or `colorBy` (signed field: red ↔ gray ↔ blue), `format`, `colorFormat`, `height` |
| `Graph` | `nodes: [{id, label, group, color}]`, `edges: [{from, to, label, weight}]`, `layout` (`force` `circle` `tree`), `directed`, `size` (node field), `height` |
| `DataGrid` / `Table` | `data`, `columns: [{field, label, type, format, align, width, max, colors, color}]`, with column `type` being `text` `number` `trend` `badge` `progress` `sparkline` `image` `avatar` `boolean` `link`; `search`, `pageSize`, `sortable`, `sortBy`, `sortDirection`, `striped`, `dense`, `maxHeight`, `title`, `emptyText` |
| `Stat` | `label`, `value`, `format`, `delta`, `deltaFormat`, `deltaLabel`, `goodDirection` (`up`/`down`), `trend` (numbers), `icon`, `status`, `size` (`compact` `default` `hero`) |
| `KeyValue` | `items: [{label, value, format, type}]` or `data` (object) + `labels`, `formats`; `columns`, `layout` |
| `Timeline` | `data` rows of `{title, description, time, status, icon, color}`; `titleField`, `descriptionField`, `timeField`, `timeFormat` |
| `TreeView` | `data` (`{label, value, icon, children}` or a list of them); `labelField`, `childrenField`, `expanded` (levels), `format` |
| `JsonView` | `value`, `expanded` |
| `CodeBlock` | `code`, `language`, `lineNumbers`, `maxHeight` |
| `Progress` | `value`, `max`, `variant` (`linear`/`circular`), `label`, `showValue`, `format`, `color`/`status`, `size`, `thickness` |
| `Tag` / `Badge` | `text`, `color`/`status`, `variant` (`tonal` `filled` `outline`), `icon` |
| `Rating` | `value`, `max`, `size`, `color`, `showValue` (A2UI: `editable` with a bound `value`) |
| `Callout` | `title`, `text`, `severity` (`info` `good` `warning` `critical`), `icon`; children below the text |
| `Avatar` | `name` (initials), `url`, `size`, `color` |

**Formats** (`format`, `yFormat`, column `format`…): `number[:decimals]`, `integer`, `compact` (12.9K), `percent[:decimals]` (input is a fraction), `currency[:CODE[:decimals]]`, `date`, `time`, `datetime`. A leading `+` signs positive numbers.

**Colors**: series take the categorical hues in a fixed order: `blue` `orange` `aqua` `yellow` `magenta` `green` `violet` `red` (also `series-N`). Past eight series, the rest fold into "Other". `good` `warning` `serious` `critical` are reserved for status, and every status color comes with an icon or label. You can also use `#hex`. Light and dark each have their own validated steps.

**Taps**: `Chart`, `Heatmap`, `Treemap`, `Graph`, `DataGrid`, `Timeline` and `TreeView` send `select` with `{index, row, …}`:

* In a static program, declare `events: {select: 'handler'}`. The handler gets the event in the VM's typed-value form; `ToolTemplates.jsDashboardFrontend` shows how to unwrap it.
* In A2UI, `selection: {"path": "/selected"}` writes the tapped row there, so a detail view can bind to `/selected/…` without a round trip. `action` fires a Button-style action whose context resolves against the tapped row.

## Layout

| Node | Component | Props |
|---|---|---|
| `ResponsiveGrid` | `Grid` | `columns` or `minColumnWidth` (+ `maxColumns`), `gap`, `runGap`; never more columns than children |
| `Section` | `Section` | `title`, `subtitle`, `icon`, `trailing`, `gap` |
| `Expandable` | `Expandable` | `title`, `subtitle`, `expanded` |
| `Scroll` | `Scroll` | `direction`, `maxHeight` |
| Elpian `Wrap`, `Stack`, `Container`, `Center`, `SizedBox`, `AspectRatio` | `Wrap`, `Stack`, `Box`, `Center`, `Spacer`, `AspectRatio` | see `CatalogPrompt` |

A2UI's `Elpian` component embeds any raw Elpian node tree. Bindings inside its props are evaluated, `{"slot": "<component id>"}` places an A2UI component inside it, and an event whose value is an A2UI action fires that action. Use it when no component fits.
