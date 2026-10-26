# Elpian engine (copied)

The engine Aseman's tool frontends and miniapps run on, copied from
[Elpian](https://github.com/cosmopole-org/elpian)'s Flutter host
(`flutter/lib/src`, BSD-3-Clause). Aseman does not depend on any Elpian
package: this code, the native VM library (`packages/elpian_vm_native`) and
the web runtimes (`assets/elpian`) are part of the app.

| Here | What |
|---|---|
| `core/`, `css/`, `html_widgets/`, `widgets/`, `models/`, `parser/`, `canvas/` | the rendering engine: JSON nodes (HTML, CSS, the Flutter DSL, canvas) as Flutter widgets |
| `vm/` | the runtimes a program runs on: the Elpian VM (`ElpianVm`, FFI on devices, WebAssembly on the web) and QuickJS (`QuickJsVm`), the `ElpianVmWidget` that hosts one, host-call handling and governance |
| `superapp/` | the miniapp model: manifest ∩ grant → policy, and the governed host |
| `scope/`, `stream/`, `diagnostics/` | scoped components, streamed UI, tracing |
| `godot/` | the `Scene3D` widget: an embedded Godot 4 3D scene, driven by ops (its native engine is `packages/elpian_godot_native`; without the engine artifacts it shows a placeholder) |

Left out: the Next.js bridge, the `elpiand` fullstack client (Aseman wires
frontends to backends through its own node) and the generic WASM runtime.

Changes made to the copy, so a refresh can repeat them:

* the `wasm` runtime kind is removed;
* asset and font paths point at the app's own (`assets/elpian/…`,
  families `serif` / `monospace`);
* `ElpianEngine.selfDispatchingTypes` is extensible, for host widgets that
  dispatch their own events;

Aseman's code imports it only through `elpian.dart`. Elpian's own tests for
it run from `test/elpian`. Analysis follows Elpian's settings
(`analysis_options.yaml` here), not the app's stricter ones.

The bundled Liberation fonts (`assets/elpian/fonts`) are under the SIL Open
Font License 1.1.
