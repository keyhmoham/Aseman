/// Run-time assets for the scene DSL: glTF models and Godot resource packs
/// fetched by address, cached on the device, and mounted into the world.
///
/// Two DSL node types use it:
///
/// ```json
/// {"type": "model", "id": "car", "src": "https://…/covered_car.glb",
///  "position": [2, 0, -1], "rotation": [0, 30, 0], "scale": 1.0}
///
/// {"type": "pack", "id": "game", "src": "https://…/arena-chess.pck",
///  "scene": "res://arena/chess/main.tscn",
///  "params": {"level": 3}, "version": "1.0.0+sha"}
/// ```
///
/// A `model` is a binary glTF (`.glb`) loaded with `GLTFDocument` and turned
/// into nodes; a `pack` is a resource pack (`.pck`) mounted with
/// `ProjectSettings.load_resource_pack`, whose `scene` is instanced — a whole
/// Godot game, script and all, running inside the `Scene3D`. When the
/// instanced scene has an `arena_start(params)` method it is called with
/// `params`; its `arena_event(json)` signal reaches the Elpian program as the
/// node's `gameevent` event.
///
/// Everything goes through the reflective op protocol: an `HTTPRequest` node
/// downloads into `user://elpian_asset_<hash>` (the address, with `version`, names
/// the file, so a new version is a new file), and a second visit loads the
/// cached file without downloading. The DSL node is an ordinary `Node3D`
/// placeholder, addressable at once; what loads is added under it. Progress
/// and failures are reported, never thrown: a missing asset leaves the
/// placeholder empty and the rest of the world intact.
library;

import 'dart:async';
import 'dart:convert';

import 'package:aseman/src/elpian/core/lenient.dart';

import 'godot_controller.dart';
import 'godot_object.dart';
import 'protocol.dart';

/// What the loader reports: `assetprogress` `{id, src, loaded, total}`,
/// `assetload` `{id, src, kind}`, `asseterror` `{id, src, message}`, and
/// `gameevent` (a pack's own events, decoded from its JSON).
typedef SceneAssetEvent = void Function(String type, Map<String, Object?> data);

class SceneAssets {
  SceneAssets(this.controller, {this.onEvent, this.timeout = const Duration(minutes: 5)});

  final GodotController controller;
  final SceneAssetEvent? onEvent;
  final Duration timeout;

  /// Packs mounted in this engine already (a pack mounts once per process).
  static final Set<String> _mounted = {};

  /// The game nodes this loader instanced, so a host can stop them.
  final List<GodotObject> games = [];

  bool _disposed = false;

  /// The file a cached copy of [src] lives in.
  static String cachePath(String src, String version, String ext) =>
      'user://elpian_asset_${fnv64('$src#$version')}.$ext';

  /// A stable 64-bit FNV-1a hash, as 16 hex digits.
  static String fnv64(String s) {
    var h = BigInt.parse('cbf29ce484222325', radix: 16);
    final prime = BigInt.parse('100000001b3', radix: 16);
    final mask = (BigInt.one << 64) - BigInt.one;
    for (final b in utf8.encode(s)) {
      h = ((h ^ BigInt.from(b)) * prime) & mask;
    }
    return h.toRadixString(16).padLeft(16, '0');
  }

  void dispose() {
    _disposed = true;
    for (final g in games) {
      g.callVoid('call_deferred', ['arena_stop']);
    }
  }

  void _emit(String type, Map<String, Object?> data) {
    if (_disposed) return;
    onEvent?.call(type, data);
  }

  // -------------------------------------------------------------------------
  // model
  // -------------------------------------------------------------------------

  /// Loads the glTF at [spec]'s `src` under [holder].
  Future<GodotObject?> loadModel(GodotObject holder, Map<String, Object?> spec) async {
    final src = looseStr(spec['src']) ?? '';
    final id = looseStr(spec['id']) ?? src;
    if (src.isEmpty) {
      _emit('asseterror', {'id': id, 'src': src, 'message': 'a model needs src'});
      return null;
    }
    final version = looseStr(spec['version']) ?? '';
    final ext = src.toLowerCase().split('?').first.endsWith('.gltf') ? 'gltf' : 'glb';
    final path = cachePath(src, version, ext);
    try {
      var scene = await _gltf(path);
      if (scene == null) {
        await _download(src, path, id);
        scene = await _gltf(path);
      }
      if (scene == null) {
        _emit('asseterror', {'id': id, 'src': src, 'message': 'not a glTF model'});
        return null;
      }
      holder.addChild(scene);
      _emit('assetload', {'id': id, 'src': src, 'kind': 'model'});
      return scene;
    } catch (e) {
      _emit('asseterror', {'id': id, 'src': src, 'message': '$e'});
      return null;
    }
  }

  /// The nodes of the glTF at [path], or null when it is not there (or not
  /// a glTF).
  Future<GodotObject?> _gltf(String path) async {
    final doc = controller.create('GLTFDocument');
    final state = controller.create('GLTFState');
    final err = await doc.call('append_from_file', [path, state]);
    if (err is! int || err != 0) {
      return null;
    }
    final root = await doc.call('generate_scene', [state]);
    return root is GodotRef ? GodotObject(controller, root.id) : null;
  }

  // -------------------------------------------------------------------------
  // pack
  // -------------------------------------------------------------------------

  /// Mounts the pack at [spec]'s `src`, instances its `scene` under
  /// [holder] and starts it with `params`.
  Future<GodotObject?> loadPack(GodotObject holder, Map<String, Object?> spec) async {
    final src = looseStr(spec['src']) ?? '';
    final scenePath = looseStr(spec['scene']) ?? '';
    final id = looseStr(spec['id']) ?? src;
    if (src.isEmpty || !scenePath.startsWith('res://')) {
      _emit('asseterror', {'id': id, 'src': src, 'message': 'a pack needs src and a res:// scene'});
      return null;
    }
    final version = looseStr(spec['version']) ?? '';
    final path = cachePath(src, version, 'pck');
    try {
      if (!_mounted.contains(path)) {
        final settings = controller.projectSettings();
        var ok = await settings.call('load_resource_pack', [path, true]);
        if (ok != true) {
          await _download(src, path, id);
          ok = await settings.call('load_resource_pack', [path, true]);
        }
        if (ok != true) {
          _emit('asseterror', {'id': id, 'src': src, 'message': 'the pack could not be mounted'});
          return null;
        }
        _mounted.add(path);
      }
      final packed = controller.load(scenePath);
      final made = await packed.call('instantiate');
      if (made is! GodotRef) {
        _emit('asseterror', {'id': id, 'src': src, 'message': 'the pack has no scene $scenePath'});
        return null;
      }
      final game = GodotObject(controller, made.id);
      games.add(game);
      final hasEvents = await game.call('has_signal', ['arena_event']);
      if (hasEvents == true) {
        game.connect('arena_event', (args) {
          final raw = args.isEmpty ? null : args.first;
          Object? decoded;
          try {
            decoded = raw is String ? jsonDecode(raw) : raw;
          } catch (_) {
            decoded = {'raw': '$raw'};
          }
          _emit('gameevent', {
            'id': id,
            if (decoded is Map) ...decoded.map((k, v) => MapEntry('$k', v)) else 'value': decoded,
          });
        });
      }
      holder.addChild(game);
      final params = spec['params'];
      final starts = await game.call('has_method', ['arena_start']);
      if (starts == true) {
        game.callVoid('call_deferred', ['arena_start', params is Map ? params.map((k, v) => MapEntry('$k', v)) : <String, Object?>{}]);
      }
      _emit('assetload', {'id': id, 'src': src, 'kind': 'pack'});
      return game;
    } catch (e) {
      _emit('asseterror', {'id': id, 'src': src, 'message': '$e'});
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // download
  // -------------------------------------------------------------------------

  /// Downloads [src] into [path] with an `HTTPRequest` node, reporting
  /// progress about twice a second.
  Future<void> _download(String src, String path, String id) async {
    final http = controller.create('HTTPRequest');
    http.setAll({'download_file': path, 'use_threads': true, 'timeout': timeout.inSeconds.toDouble()});
    controller.mount(http);
    final done = Completer<List<Object?>>();
    http.connect('request_completed', (args) {
      if (!done.isCompleted) done.complete(args);
    });
    final err = await http.call('request', [src]);
    if (err is int && err != 0) {
      http.queueFree();
      throw StateError('the download could not start (error $err)');
    }
    final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) async {
      if (done.isCompleted || _disposed) return;
      try {
        final loaded = await http.call('get_downloaded_bytes');
        final total = await http.call('get_body_size');
        _emit('assetprogress', {'id': id, 'src': src, 'loaded': loaded, 'total': total});
      } catch (_) {}
    });
    try {
      final args = await done.future.timeout(timeout);
      final result = args.isNotEmpty ? args[0] : null;
      final code = args.length > 1 ? args[1] : null;
      if (result != 0 || code is! int || code >= 400) {
        throw StateError('the download failed (result $result, HTTP $code)');
      }
    } finally {
      ticker.cancel();
      http.queueFree();
    }
  }
}
