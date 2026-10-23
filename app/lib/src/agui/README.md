# AG-UI Surface Spec (agui)

Aseman renders generative / dynamic UIs with the **AG-UI** protocol and the
**Aseman Surface Spec** catalog — tools' Fixed Schema Surface Bundles, agents'
`ui_compose` / `ui_present` widgets, desk windows, compact phone tiles, and
inline chat surfaces (`kind: agui`).

| Directory | What it holds |
|---|---|
| `protocol/` | AG-UI events ↔ surface ops (`aseman.surface.*`) |
| `runtime/` | Surfaces, bindings, actions, functions, presentation |
| `catalog/` | Basic, Aseman, extended, markets, chrome, spatial (2D/3D) |
| `widgets/` | `AgUiSurfaceView`, `AgUiView`, compact tiles |

The node (`services/pkg/agui`, `services/pkg/surface`) compiles Fixed Schema /
archetype bundles, validates with a deterministic gate, and emits AG-UI
events. Opening a tool is **bind-only**. Interactive web consoles use the
professional web kit (`services/pkg/webkit`) as the Open band.
