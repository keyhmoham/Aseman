# Tool frontend UI kit

Charts, graphs, tables, data views and layout pieces for **static** Elpian
tool frontends, on top of every Flutter and HTML node the Elpian engine
already renders.

| Mode | How a frontend uses the kit |
|---|---|
| **Static** (Elpian VM / QuickJS program) | Return kit nodes in the view tree: `{type: 'Chart', props: {...}, events: {select: 'onPick'}}`. Rendered by `kitEngine()` in `ToolFrontendView`. |

## Data views

Node type and its props. Field props name a key of each row (`a.b` reaches nested keys).

| Node | Props |
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
| `Progress` | `value`, `max`, `variant` (`linear`/`circular`), `wavy` (the M3 Expressive wavy bar), `label`, `showValue`, `format`, `color`/`status`, `size`, `thickness` |
| `Tag` / `Badge` | `text`, `color`/`status` (default: the accent), `variant` (`tonal` `filled` `outline`), `icon`, `dot` |
| `Rating` | `value`, `max`, `size`, `color`, `showValue` |
| `Callout` | `title`, `text`, `severity` (`info` `good` `warning` `critical`), `icon`; children below the text |
| `Avatar` | `name` (initials), `url`, `size`, `color` |

### More charts

| Node | Props |
|---|---|
| `Funnel` | `data` of `{label, value}` (`label`, `value` rename fields), `format`, `color` |
| `Waterfall` | `data` of `{label, value}` (`total: true` rows draw the running total), `start`, `startLabel`, `showTotal`, `totalLabel`, `format`, `height`, `upColor`, `downColor` |
| `Sankey` | `links` of `{from, to, value}` (`source`, `target`, `value` rename fields), `nodes` of `{id, label, color}`, `format`, `height` |
| `Gantt` | `data` of `{label, start, end, progress, group, status, color}`, `timeFormat` |
| `BoxPlot` | `data` of `{label, values}` (samples) or `{label, min, q1, median, q3, max, outliers}`, `format`, `height`, `colorful` |
| `BulletChart` | `items` of `{label, value, target, ranges, max, format}` (or one bullet's props) |
| `SegmentedBar` | `data` of `{label, value, color}`, `format`, `thickness`, `legend`, `showPercent` |
| `RadialBars` | `data` of `{label, value, max, color}`, `size`, `centerLabel`, `centerCaption`, `legend` |
| `Sunburst` | `data`: `{label, value, children}` or a list, `size`, `format`, `centerCaption` |
| `CalendarHeatmap` | `data` of `{date, value}`, `weeks`, `end`, `format`, `color` |
| `WordCloud` | `data` of `{text, value}`, `max`, `minSize`, `maxSize`, `colorful`, `height` |

`Chart` routes `type` `funnel` `waterfall` `sankey` `gantt` `boxplot` `sunburst` `bullet` `segmented` `radialbar` `calendar` `wordcloud` to these.

### Tables

| Node | Props |
|---|---|
| `PivotTable` | `data`, `rows`, `columns` (a field or a list), `value`, `aggregate` (`sum` `count` `avg` `min` `max`), `format`, `totals`, `heat`, `sort`, `maxHeight`; `select` `{row, column, value}` |
| `Leaderboard` | `data` of `{name, value, subtitle, avatar, change, id}`, `max`, `format`, `highlight`, `showBar` |

### App widgets

| Node | Props · events |
|---|---|
| `Tabs` | `tabs` of `{label, icon, badge}`, children are the panels, `selected`, `variant` · `change` |
| `Calendar` | `month`, `selected`, `events` of `{date, title, time, color, status}`, `firstDay`, `showEvents` · `select`, `change` |
| `Kanban` | `columns` of `{id, title, color, cards}`, `columnWidth`, `draggable` · `select`, `move` |
| `Carousel` | children or `items` of `{image, title, subtitle}`, `height`, `autoplay`, `viewportFraction`, `dots` · `change` |
| `Stepper` | `steps` of `{title, subtitle, state}`, `current`, `orientation` · `select` |
| `Chat` | `messages` of `{role, text, name, time, avatar}`, `typing`, `suggestions`, `showAvatars` · `select` |
| `Countdown` | `to` or `seconds`, `label`, `size` · `done` |
| `Clock` | `mode`, `utcOffset`, `label`, `size`, `seconds`, `hour24` |
| `EmptyState` | `icon`, `title`, `text`, `action`, `actionIcon`, `size` · `action` |
| `AvatarGroup` | `names` or `items` of `{name, url}`, `max`, `size` |
| `Pagination` | `page`, `pages`, `siblings` · `change` |
| `Breadcrumbs` | `items` of `{label, icon}` · `select` |

### Text views

| Node | Props · events |
|---|---|
| `Markdown` | `text` · `link` (without a handler, links open in the browser) |
| `LogView` | `lines` (strings or `{time, level, message, source}`), `title`, `filter`, `wrap`, `showTime`, `lineNumbers`, `follow`, `maxHeight` |
| `DiffView` | `before` + `after`, or a unified `diff`; `title`, `context`, `maxHeight` |
| `QRCode` | `data`, `size`, `ecc`, `color`, `background`, `rounded`, `label` (encoder: `qr_encoder.dart`, checked against two reference implementations) |

In an unbounded width (directly in a `Row`, in a horizontal scroll) every non-compact kit node takes a fallback width (`fallbackWidths` in `kit.dart`, 360 by default) instead of throwing.

**Formats** (`format`, `yFormat`, column `format`…): `number[:decimals]`, `integer`, `compact` (12.9K), `percent[:decimals]` (input is a fraction), `currency[:CODE[:decimals]]`, `date`, `time`, `datetime`. A leading `+` signs positive numbers.

**Colors**: series take the categorical hues in a fixed order: `blue` `orange` `aqua` `yellow` `magenta` `green` `violet` `red` (also `series-N`). Past eight series, the rest fold into "Other". `good` `warning` `serious` `critical` are reserved for status, and every status color comes with an icon or label. You can also use `#hex`. Light and dark each have their own validated steps.

**Taps**: `Chart`, `Heatmap`, `Treemap`, `Graph`, `DataGrid`, `Timeline` and `TreeView` send `select` with `{index, row, …}`:

* In a static program, declare `events: {select: 'handler'}`. The handler gets the event in the VM's typed-value form; `ToolTemplates.jsDashboardFrontend` shows how to unwrap it.

## Layout

| Node | Props |
|---|---|
| `ResponsiveGrid` | `columns` or `minColumnWidth` (+ `maxColumns`), `gap`, `runGap`; never more columns than children |
| `Section` | `title`, `subtitle`, `icon`, `trailing`, `gap` |
| `Expandable` | `title`, `subtitle`, `expanded` |
| `Scroll` | `direction`, `maxHeight` |
| Elpian `Wrap`, `Stack`, `Container`, `Center`, `SizedBox`, `AspectRatio` | same as Elpian layout nodes |
