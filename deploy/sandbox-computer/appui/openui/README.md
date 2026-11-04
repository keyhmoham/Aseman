# Aseman OpenUI

Agent-backed UI islands for App UIs. Mix freely with programmed
frontend + backend — not biased to always-agent or always-code.

OpenUI components use the **same** Aseman adaptive theme tokens and the same
host UI library look (Material 3 Expressive by default) as the rest of the app.

## When to use what

| Need | Approach |
|---|---|
| Stable CRUD, forms, charts with known APIs | Programmed UI + your server and/or `_aseman/api/call` microtools |
| Reasoning, drafting, open-ended Q&A, adaptive copy | OpenUI panel/action → space **agent** via `_aseman/api/ask` |
| Same screen | Mix both side by side |

## Load

```html
<link rel="stylesheet" href="_aseman/kit/openui/openui.css" />
<script type="module" src="_aseman/kit/openui/openui.js"></script>
```

Or from the copy `aseman-appui` places at `vendor/aseman-openui/`.

## Elements

```html
<!-- Agent-backed section -->
<aseman-open-panel
  agent="research"
  title="Briefing"
  prompt="Summarize status for {{city}}"
  var-city="Oslo"
></aseman-open-panel>

<!-- Microtool-backed section (programmed data) -->
<aseman-open-query
  tool="weather"
  microtool="forecast"
  args='{"city":"Oslo"}'
  title="Forecast"
></aseman-open-query>

<!-- Agent OR microtool action -->
<aseman-open-action agent="assistant" prompt="Draft a polite follow-up" label="Draft"></aseman-open-action>
```

Islands auto-detect OpenUI JSON in agent/microtool replies and paint the
full catalog (`catalog.js` / `catalog.spec.json`, ~137 components). Plain
text/markdown still works.

## JS API

```js
const { ask, call, agents, mount, components } = AsemanOpenUI;
const list = await agents();
const { reply } = await ask({ agent: "research", prompt: "…" });
const result = await call({ tool: "weather", microtool: "forecast", args: { city: "Oslo" } });

await mount("#slot", {
  c: "Card",
  p: { title: "Forecast" },
  children: [{ c: "Metric", p: { label: "High", value: "21°" } }],
});
await components(); // catalog names
```

Tree format: `{ "c": "ComponentName", "p": { … }, "children": [ … ] }`.
See `COMPONENTS.md` and `catalog.spec.json`.

## Theming

Do not restyle OpenUI with a private palette. Rely on `--md-sys-color-*` /
`--aseman-*` (injected by DeskWeb). Dedicated brand briefs still follow light/dark
from Aseman; keep OpenUI on those surface tokens.
