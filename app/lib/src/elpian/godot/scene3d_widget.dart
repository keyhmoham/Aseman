/// `Scene3D` — an embedded Godot viewport as an ordinary Flutter widget.
///
/// Two ways to drive it, and you can use both at once:
///
///   * **declaratively**, with [initialScene] — the JSON DSL in `scene_dsl.dart`
///     builds the starting world;
///   * **imperatively**, with a [GodotSceneController] you own, whose
///     [GodotSceneController.godot] exposes the full reflective Godot API for
///     everything afterwards.
///
/// ```dart
/// final controller = GodotSceneController();
///
/// Scene3D(
///   controller: controller,
///   initialScene: const {
///     'environment': {'bg': '#0d1117'},
///     'camera': {'position': [0, 3, 8], 'rotation': [-18, 0, 0]},
///     'lights': [{'type': 'directional', 'shadow': true, 'rotation': [-50, -30, 0]}],
///     'nodes': [{'type': 'mesh', 'shape': 'torus', 'id': 'ring', 'color': '#6699ff'}],
///   },
///   onReady: (scene) {
///     final ring = scene.require('ring');
///     ring.set('scale', const Vector3(1.4, 1.4, 1.4));
///   },
/// )
/// ```
///
/// When no Godot artifact is present on the platform the widget renders
/// [placeholder] instead of a viewport and the controller still records ops, so
/// a `Scene3D` is safe to place in any tree — the surrounding 2D app is
/// unaffected.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/lenient.dart';
import '../core/node_events.dart';
import '../html_widgets/html_embedded_content.dart';
import '../models/elpian_node.dart';
import 'godot_binding.dart';
import 'godot_controller.dart';
import 'godot_object.dart';
import 'game_messages.dart'
    if (dart.library.js_interop) 'game_messages_web.dart';
import 'scene_assets.dart';
// The web viewport is selected at compile time; off the web the stub compiles
// instead, so `dart:ui_web` never reaches a native build.
import 'godot_web_surface.dart'
    if (dart.library.ui_web) 'godot_web_surface_web.dart';
import 'scene_dsl.dart';
import 'scene_taps.dart';

/// Owns a scene's engine controller and its built nodes across rebuilds.
///
/// Create one in your `State` and dispose it there; passing the same controller
/// to a rebuilt `Scene3D` keeps the world alive.
class GodotSceneController extends ChangeNotifier {
  GodotSceneController({GodotBinding? binding, SceneAssetEvent? onAssetEvent})
      : godot = GodotController(binding: binding) {
    assets = SceneAssets(godot, onEvent: (type, data) => onAssetEvent?.call(type, data));
  }

  /// The full engine API — `create`, `singleton`, `g3`, batching, callbacks.
  final GodotController godot;

  /// Loads the scene's `model` and `pack` nodes and reports on them.
  late final SceneAssets assets;

  GodotScene? _scene;
  bool _disposed = false;

  /// The nodes built from `initialScene`, once built.
  GodotScene? get scene => _scene;

  /// Whether a real engine is behind this controller.
  bool get isLive => godot.isLive;

  /// A node from the initial scene by its DSL `id`, or null before the scene
  /// is built.
  GodotObject? node(String id) => _scene?.byId(id);

  void _adopt(GodotScene scene) {
    _scene = scene;
    if (!_disposed) notifyListeners();
  }

  /// Replace the world with a new DSL scene, discarding the previous one.
  GodotScene replaceScene(Map<String, Object?> json) {
    for (final root in _scene?.roots ?? const <GodotObject>[]) {
      root.queueFree();
    }
    final built = SceneDsl(godot, assets: assets).build(json);
    _adopt(built);
    return built;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // Games stop (arena_stop) and the world goes with the widget.
    assets.dispose();
    for (final root in _scene?.roots ?? const <GodotObject>[]) {
      root.queueFree();
    }
    godot.dispose();
    super.dispose();
  }
}

/// An embedded Godot 3D viewport.
class Scene3D extends StatefulWidget {
  const Scene3D({
    super.key,
    this.controller,
    this.initialScene,
    this.onReady,
    this.placeholder,
    this.width,
    this.height,
    this.clickable = false,
    this.tapProps,
    this.onEvent,
  });

  /// Asset and game events: `assetprogress`, `assetload`, `asseterror` and
  /// `gameevent` (a mounted game's `arena_event`), with their data.
  final SceneAssetEvent? onEvent;

  /// The controller to drive this scene. When null the widget owns one for its
  /// lifetime.
  final GodotSceneController? controller;

  /// The declarative starting world. Built once, when the surface attaches.
  final Map<String, Object?>? initialScene;

  /// Called after [initialScene] is built and the surface is attached.
  final void Function(GodotScene scene)? onReady;

  /// Shown when no Godot engine is available on this platform.
  final Widget? placeholder;

  final double? width;
  final double? height;

  /// Report taps on this surface to [ElpianSceneTaps] — the hook server-driven
  /// UI uses to turn a 3D tap into navigation.
  final bool clickable;

  /// The props delivered to [ElpianSceneTaps] when [clickable] and tapped.
  final Map<String, dynamic>? tapProps;

  /// Build a `Scene3D` from an Elpian node — the registry entry point.
  ///
  /// Reads `initialScene` (or a bare `scene` / `world`) from props, plus
  /// `width`/`height` and the `clickable` / tap props the scene-tap hook uses.
  static Widget build(ElpianNode node, List<Widget> children) {
    final props = node.props;
    final scene = props['initialScene'] ?? props['scene'] ?? props['world'];
    final events = NodeEvents(node);
    return Scene3D(
      onEvent: node.events == null
          ? null
          : (type, data) {
              if (events.has(type)) events.emit(type, data: data);
            },
      key: node.key == null ? null : ValueKey(node.key),
      initialScene: scene is Map
          ? scene.map((k, v) => MapEntry('$k', v))
          : (scene is List ? {'nodes': scene} : null),
      width: _size(props['width']) ?? node.style?.width,
      height: _size(props['height']) ?? node.style?.height,
      clickable: props['clickable'] == true,
      tapProps: props,
      placeholder: children.isNotEmpty ? children.first : null,
    );
  }

  /// The browser build a `pack` node names (`web`), for a client without
  /// the engine: the game runs there as a web page instead of the
  /// placeholder. Returns `{id, url}` or null.
  static Map<String, String>? webFallbackOf(Map<String, Object?>? scene) {
    final nodes = scene?['nodes'];
    if (nodes is! List) return null;
    for (final n in nodes) {
      if (n is Map && n['type'] == 'pack') {
        final url = looseStr(n['web']) ?? '';
        if (url.isNotEmpty) {
          return {'id': looseStr(n['id']) ?? 'game', 'url': url};
        }
      }
    }
    return null;
  }

  @override
  State<Scene3D> createState() => _Scene3DState();
}

class _Scene3DState extends State<Scene3D> {
  GodotSceneController? _owned;
  bool _attached = false;

  GodotSceneController get _controller => widget.controller ?? _owned!;
  void Function()? _stopMessages;
  String? _listeningTo;

  /// Without the engine, a pack's browser build runs in an embedded page;
  /// its events are relayed as the node's `gameevent`.
  void _syncWebFallback() {
    final fallback = _controller.isLive ? null : Scene3D.webFallbackOf(widget.initialScene);
    final url = fallback?['url'];
    if (url == _listeningTo) return;
    _stopMessages?.call();
    _stopMessages = null;
    _listeningTo = url;
    if (fallback == null || url == null) return;
    final uri = Uri.base.resolve(url);
    final id = fallback['id']!;
    _stopMessages = listenGameMessages(uri.hasAuthority ? uri.origin : '', (event) {
      if (!mounted) return;
      widget.onEvent?.call('gameevent', {
        'id': id,
        if (event is Map) ...event.map((k, v) => MapEntry('$k', v)) else 'value': event,
      });
    });
    // Reported after this frame: this can run inside a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _listeningTo == url) {
        widget.onEvent?.call('assetload', {'id': id, 'src': url, 'kind': 'web'});
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _owned = GodotSceneController(
          onAssetEvent: (type, data) => widget.onEvent?.call(type, data));
    }
    // Attaching touches the platform channel, so it must not run during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attach();
      if (mounted) _syncWebFallback();
    });
  }

  Future<void> _attach() async {
    if (_attached || !mounted) return;
    _attached = true;

    final controller = _controller;
    final json = widget.initialScene;
    GodotScene? built;
    if (json != null && controller.scene == null) {
      built = SceneDsl(controller.godot, assets: controller.assets).build(json);
      controller._adopt(built);
    }

    await controller.godot.attachSurface();
    if (!mounted) return;

    final scene = built ?? controller.scene;
    if (scene != null) widget.onReady?.call(scene);
  }

  @override
  void didUpdateWidget(Scene3D oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A guest program drives this widget declaratively: it re-renders the node
    // with a new `initialScene` rather than calling the controller. Without
    // this the world would be built once and never change, which makes the
    // whole DSL path inert after first paint.
    //
    // Only rebuild when the scene actually differs — a parent rebuilding for
    // unrelated reasons must not tear down and re-create the world.
    final next = widget.initialScene;
    if (next != null &&
        !_sceneEquals(oldWidget.initialScene, next) &&
        _attached) {
      _controller.replaceScene(next);
      widget.onReady?.call(_controller.scene!);
    }
    _syncWebFallback();
  }

  /// Structural comparison of two scene descriptions.
  ///
  /// `identical` is too weak (a guest re-emits a fresh map every render) and
  /// `==` on nested maps is reference equality, so neither detects a real
  /// change. Comparing the encoded form is exact and cheap next to rebuilding
  /// a 3D world.
  static bool _sceneEquals(Map<String, Object?>? a, Map<String, Object?>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return jsonEncode(a) == jsonEncode(b);
  }

  @override
  void dispose() {
    _stopMessages?.call();
    _stopMessages = null;
    // Only tear down a controller this widget created; a caller-supplied one
    // outlives the widget by design.
    _owned?.dispose();
    _owned = null;
    if (widget.controller != null && _attached) {
      widget.controller!.godot.detachSurface();
    }
    super.dispose();
  }

  void _handleTap() {
    if (!widget.clickable) return;
    ElpianSceneTaps.handler?.call(widget.tapProps ?? const {});
  }

  @override
  Widget build(BuildContext context) {
    final fallback = _controller.isLive ? null : Scene3D.webFallbackOf(widget.initialScene);
    Widget surface = _controller.isLive
        ? _viewport()
        : fallback != null
            ? HtmlEmbeddedContent(
                key: ValueKey(fallback['url']),
                url: fallback['url']!,
                label: 'game',
                attributes: const {'allow': 'fullscreen; gamepad; autoplay', 'allowfullscreen': ''},
              )
            : (widget.placeholder ?? const _Scene3DPlaceholder());

    if (widget.clickable) {
      surface = GestureDetector(onTap: _handleTap, child: surface);
    }

    if (widget.width != null || widget.height != null) {
      surface = SizedBox(
        width: widget.width,
        height: widget.height,
        child: surface,
      );
    }
    return surface;
  }

  /// The native viewport hosting this surface's Godot render target.
  Widget _viewport() {
    final surfaceId = _controller.godot.surfaceId;
    // Checked before `defaultTargetPlatform`, which on the web reports the
    // *host OS* — mobile web would otherwise fall into the AndroidView/UiKitView
    // arms and ask for a native platform view that does not exist there.
    if (kIsWeb) {
      return buildGodotWebSurface(surfaceId) ??
          widget.placeholder ??
          const _Scene3DPlaceholder();
    }
    final params = <String, dynamic>{'surfaceId': surfaceId};
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidView(
          viewType: GodotChannels.viewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
          // The Godot view consumes its own gestures; without this the
          // surrounding Flutter scroll views would steal every drag.
          gestureRecognizers: const {},
        );
      case TargetPlatform.iOS:
        return UiKitView(
          viewType: GodotChannels.viewType,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
        );
      default:
        return widget.placeholder ?? const _Scene3DPlaceholder();
    }
  }
}

/// What a `Scene3D` shows where no engine is available.
///
/// Deliberately quiet and self-explanatory rather than an error: a 2D app with
/// a 3D panel should still be usable on a platform without the Godot artifact.
class _Scene3DPlaceholder extends StatelessWidget {
  const _Scene3DPlaceholder();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF10141D), Color(0xFF1A2233)],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.view_in_ar_outlined, size: 36, color: Colors.white24),
              SizedBox(height: 8),
              Text(
                '3D unavailable on this platform',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      );
}

/// A size: a finite, non-negative number, else null.
double? _size(Object? v) {
  final n = looseDouble(v);
  return n == null || n < 0 || !n.isFinite ? null : n;
}
