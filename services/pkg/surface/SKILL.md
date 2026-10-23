---
name: surface-frontend
description: Author Fixed Schema Aseman Surface Spec tool frontends (archetypes, embedded surface JSON, deterministic gate). Use when creating or reviewing generative tool UIs.
---

# Surface frontend (Fixed Schema)

Prefer **author once, bind always** — never a serve-time generate→LLM-judge loop.

## Skill contract

At the top of `frontend_skill`:

```
archetype: analytics_console
title: Weather
data_path: /report
microtool: weather_report
```

Or embed a full template:

````markdown
```surface
{"title":"…","components":[…],"data":[…],"actions":{…}}
```
````

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
