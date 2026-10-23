---
name: surface-frontend
description: Author Fixed Schema Aseman Surface Spec tool frontends (archetypes, embedded surface JSON, deterministic gate). Use when creating or reviewing generative tool UIs.
---

# Surface frontend (Fixed Schema)

Prefer **author once, bind always** — never a serve-time generate→LLM-judge loop.

## Skill contract

Fixed Schema applies **only** when the skill names an `archetype:` or embeds a
````surface``` fence. Prose words like “analytics”, “KPI”, or “weather” never
opt a tool in.

At the top of `frontend_skill`:

```
archetype: analytics_console
title: My console
data_path: /report
microtool: my_report
args: {"q": "default"}
slots: {"kpis":[{"label":"Total","field":"total","format":"integer"}],"hero_array":"series","hero_x":"label","hero_y":"value","table_array":"rows"}
```

Domain layout (weather KPIs, CRM columns, …) belongs in that tool’s `slots` /
embedded surface — not in platform heuristics.

Or embed a full template:

````markdown
```surface
{"title":"…","components":[…],"data":[…],"actions":{…}}
```
````

Skills without `archetype` / ```surface``` use the bounded LLM generator at serve time.

## Archetypes

| Name | Use |
|---|---|
| `analytics_console` | KPI Grid → hero Chart → evidence Table + compact |
| `form_workbench` | Header + form Scroll + submit |
| `entity_detail` | KeyValue detail |
| `chat_card` | Inline ChatCard |

## Gate (blocking codes)

Deterministic only: `missing_compact`, `missing_kpi_strip`, `viz_density_prose`, `nested_card`, `placeholder_copy`, app shell, props, live fill, actions.

LLM polish is **advice** and must not drive repair.
