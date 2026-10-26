# OpenUI component catalog

All components inherit Aseman theme CSS variables (`--md-sys-color-*` /
`--aseman-*`). Prefer these names; do not reinvent parallel agent widgets.

## Host islands (custom elements)

### `aseman-open-panel`

Agent-backed content island. Agent replies that are OpenUI JSON trees are
rendered with the full catalog; otherwise markdown.

| Attr | Meaning |
|---|---|
| `agent` | Agent name or bot id |
| `prompt` | Prompt template; `{{var}}` from `var-*` / `vars` JSON |
| `title` | Header label |
| `autorun` | `false` to wait for Run / `.run()` |
| `var-*` | Template variables |

Events: `aseman-openui:done` `{ reply, agent }`, `aseman-openui:error`.

### `aseman-open-query`

Data island — **either** microtool **or** agent.

| Attr | Meaning |
|---|---|
| `tool` + `microtool` + `args` | Programmed microtool path |
| `agent` + `prompt` | Agentic path |
| `title`, `autorun`, `var-*` | Same as panel |

### `aseman-open-action`

Button that asks an agent or calls a microtool.

| Attr | Meaning |
|---|---|
| `agent` + `prompt` | Ask agent |
| `tool` + `microtool` + `args` | Call microtool |
| `label`, `variant` | `filled` \| `tonal` \| `outlined` |
| `target` | CSS selector of panel/query to refresh or fill |

## Generative catalog (JSON trees)

Agents (and programmed code) can return / mount a tree. Format:

```json
{ "c": "Card", "p": { "title": "Status" }, "children": [
  { "c": "Text", "p": { "content": "All good" } }
]}
```

Aliases: `component` / `type` / `$type` for `c`, `props` for `p`. Wrappers
`{ "openui": { "root": … } }` and fenced ` ```openui ` blocks are accepted.

Load: `catalog.js` (+ styles in `openui.css`). Spec: `catalog.spec.json`
(~137 components). Hosts auto-load the catalog when painting panel/query
replies.

```js
const names = await AsemanOpenUI.components();
await AsemanOpenUI.mount("#out", {
  c: "AppShell",
  children: [{ c: "Section", p: { title: "Hi" }, children: [
    { c: "Metric", p: { label: "Uptime", value: "99.9%" } }
  ]}]
});
```

### Layout / chrome

`AppShell`, `Page`, `Section`, `Container`, `Center`, `Stack`, `Grid`,
`Split`, `Sidebar`, `Tabs`, `TabItem`, `Accordion`, `AccordionItem`,
`Drawer`, `AppBar`, `Toolbar`, `Footer`, `Spacer`, `Divider`, `Hero`

### Typography / media

`Text`, `Heading`, `Markdown`, `Code`, `CodeBlock`, `Pre`, `Quote`,
`Image`, `Avatar`, `Icon`, `Badge`, `Chip`, `Tag`, `Link`, `Kbd`

### Surfaces / feedback

`Card`, `Paper`, `Glass`, `Panel`, `Callout`, `Alert`, `Banner`, `Toast`,
`EmptyState`, `Result`, `Progress`, `Spinner`, `Skeleton`, `StatusDot`,
`Metric`, `Stat`, `Delta`

### Data display

`Table`, `DataList`, `KeyValue`, `List`, `ListItem`, `Timeline`,
`TimelineItem`, `BarChart`, `LineChart`, `AreaChart`, `PieChart`,
`DonutChart`, `Sparkline`, `Compare`, `CompareRow`

### Forms / controls

`Form`, `Field`, `FieldRow`, `Input`, `Textarea`, `Select`, `Checkbox`,
`Radio`, `Switch`, `Slider`, `Button`, `IconButton`, `ButtonGroup`,
`SearchBox`, `DateField`

### Chat / social / boards

`Chat`, `Bubble`, `Feed`, `FeedItem`, `Comment`, `NotificationItem`,
`Carousel`, `Kanban`, `KanbanColumn`, `KanbanCard`, `Tree`, `TreeItem`,
`Checklist`, `CheckItem`, `CalendarGrid`, `MapPlaceholder`, `FileRow`

### Tooling / misc

`ToolHeader`, `MicrotoolResult`, `BindingHint`, `Steps`, `Step`,
`Pagination`, `Breadcrumb`, `Menu`, `MenuItem`

Exact props: see `catalog.spec.json`.

## Preview APIs

- `GET  _aseman/api/agents`
- `POST _aseman/api/ask` `{ agent|bot, body|prompt }`
- `POST _aseman/api/call` `{ tool, microtool, args }`
- `GET  _aseman/kit/openui/*` (this kit: `openui.js`, `openui.css`,
  `catalog.js`, `catalog.spec.json`, docs)
