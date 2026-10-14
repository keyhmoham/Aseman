/// Elpian inside Tradera: the engine a tool's frontend runs on.
///
///   * the rendering engine: JSON nodes (HTML, CSS, the Flutter DSL, canvas)
///     rendered as Flutter widgets;
///   * the runtimes a miniapp's program runs on: the Elpian VM (bytecode, on
///     the native library in packages/elpian_vm_native, or WebAssembly on the
///     web) and QuickJS;
///   * the miniapp host (manifest, grant, governed runtime) and the A2UI
///     renderer agents' and generated frontends are drawn with.
///
/// Copied from Elpian's Flutter host (github.com/cosmopole-org/elpian,
/// flutter/lib/src), not depended on: see README.md here. Tradera's own code
/// reaches it only through this library.
library;

// ── The rendering engine ───────────────────────────────────────────
export 'core/elpian_engine.dart';
export 'core/elpian_services.dart';
export 'core/event_system.dart';
export 'core/widget_registry.dart';
export 'models/css_style.dart';
export 'models/elpian_node.dart';

// ── Runtimes ───────────────────────────────────────────────────────
export 'vm/elpian_vm.dart';
export 'vm/elpian_vm_widget.dart';
export 'vm/host_api_catalog.dart';
export 'vm/host_handler.dart';
export 'vm/quickjs_vm.dart';
export 'vm/runtime_kind.dart';
export 'vm/vm_runtime_client.dart';

// ── Miniapps: manifest, grant and the governed host ────────────────
export 'superapp/mini_app.dart';
export 'superapp/mini_app_host.dart';
export 'vm/governance/models.dart';

// ── Embedded Godot 3D: the Scene3D widget, its controller and protocol ──
export 'godot/godot_binding.dart';
export 'godot/godot_controller.dart';
export 'godot/godot_object.dart';
export 'godot/godot_values.dart';
export 'godot/protocol.dart';
export 'godot/scene3d_widget.dart';
export 'godot/scene_dsl.dart';
export 'godot/scene_taps.dart';

// ── Agent-generated UI (A2UI v0.9.1) ───────────────────────────────
export 'a2ui/a2ui.dart';
