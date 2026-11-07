import 'package:aseman/src/elpian/elpian.dart';
import 'package:flutter_test/flutter_test.dart';

/// An engine stand-in that answers the calls the asset loader makes, so the
/// loader's whole conversation with Godot can be checked without an engine.
class ScriptedBinding implements GodotBinding {
  ScriptedBinding({this.cached = false, this.gltfOk = true, this.httpCode = 200});

  /// Whether the asset is already in the device cache.
  bool cached;
  final bool gltfOk;
  final int httpCode;
  final List<Op> ops = [];
  int _host = -100;
  int? httpHandle;
  int? completedCallback;
  int? gameEventCallback;
  final Map<int, String> created = {};

  @override
  GodotSignalDispatch? onSignal;

  @override
  bool get isLive => false;

  @override
  void post(List<Op> batch) => batch.forEach(_apply);

  @override
  Future<List<Wire>> send(List<Op> batch) async => batch.map(_apply).toList();

  Wire _apply(Op op) {
    ops.add(op);
    if (op.containsKey(OpKey.create)) {
      created[op[OpKey.def] as int] = op[OpKey.create] as String;
      if (op[OpKey.create] == 'HTTPRequest') httpHandle = op[OpKey.def] as int;
      return op[OpKey.def];
    }
    if (op.containsKey(OpKey.singleton) || op.containsKey(OpKey.load)) {
      return op[OpKey.def];
    }
    if (op.containsKey(OpKey.connect)) {
      if (op[OpKey.connect] == 'request_completed') completedCallback = op[OpKey.cb] as int;
      if (op[OpKey.connect] == 'arena_event') gameEventCallback = op[OpKey.cb] as int;
      return null;
    }
    switch (op[OpKey.method]) {
      case 'load_resource_pack':
        return cached;
      case 'append_from_file':
        return cached && gltfOk ? 0 : 7; // ERR_FILE_NOT_FOUND
      case 'generate_scene':
        return {'ref': _host--};
      case 'instantiate':
        return {'ref': _host--};
      case 'has_signal':
      case 'has_method':
        return true;
      case 'request':
        // The download "finishes" on the next turn.
        Future.microtask(() {
          cached = httpCode < 400;
          onSignal?.call(completedCallback!, [0, httpCode, <String>[], <int>[]]);
        });
        return 0;
      case 'get_downloaded_bytes':
        return 10;
      case 'get_body_size':
        return 100;
    }
    return null;
  }

  List<String> methods() => [for (final o in ops) if (o[OpKey.method] != null) '${o[OpKey.method]}'];

  @override
  Future<void> mountSurface(int surfaceId, int mountHandle) async {}

  @override
  Future<void> releaseSurface(int surfaceId) async {}

  @override
  Future<Map<String, Object?>?> stats() async => null;

  @override
  void dispose() {}
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('cache paths are stable per address and version', () {
    final a = SceneAssets.cachePath('https://x/a.pck', '1', 'pck');
    expect(a, SceneAssets.cachePath('https://x/a.pck', '1', 'pck'));
    expect(a, isNot(SceneAssets.cachePath('https://x/a.pck', '2', 'pck')));
    expect(a, matches(RegExp(r'^user://elpian_asset_[0-9a-f]{16}\.pck$')));
    // FNV-1a 64 of the empty string.
    expect(SceneAssets.fnv64(''), 'cbf29ce484222325');
  });

  test('a cached model loads without downloading', () async {
    final binding = ScriptedBinding(cached: true);
    final events = <String>[];
    final controller = GodotController(binding: binding);
    final dsl = SceneDsl(controller, assets: SceneAssets(controller, onEvent: (t, d) => events.add('$t:${d['id']}')));
    final scene = dsl.build({
      'nodes': [
        {'type': 'model', 'id': 'car', 'src': 'https://cdn/covered_car.glb', 'position': [1, 0, 2], 'scale': 2},
      ],
    });
    expect(scene.byId('car'), isNotNull, reason: 'the placeholder exists at once');
    await settle();
    expect(binding.methods(), containsAllInOrder(['append_from_file', 'generate_scene', 'add_child']));
    expect(binding.httpHandle, isNull);
    expect(events, ['assetload:car']);
  });

  test('a missing pack downloads, mounts, instances and starts the game', () async {
    final binding = ScriptedBinding(cached: false);
    final events = <String, Map<String, Object?>>{};
    final controller = GodotController(binding: binding);
    final dsl = SceneDsl(controller, assets: SceneAssets(controller, onEvent: (t, d) => events[t] = d));
    dsl.build({
      'nodes': [
        {
          'type': 'pack', 'id': 'game', 'src': 'https://arena/games/arena-chess.pck',
          'scene': 'res://arena/chess/main.tscn', 'version': '1.0.0', 'params': {'level': 4},
        },
      ],
    });
    await settle();
    final calls = binding.methods();
    expect(calls, containsAllInOrder([
      'load_resource_pack', 'request', 'load_resource_pack', 'instantiate', 'has_signal', 'add_child', 'has_method', 'call_deferred',
    ]));
    expect(binding.created.values, contains('HTTPRequest'));
    final download = binding.ops.firstWhere((o) => o[OpKey.props] is Map && (o[OpKey.props] as Map).containsKey('download_file'));
    expect((download[OpKey.props] as Map)['download_file'], startsWith('user://elpian_asset_'));
    final start = binding.ops.lastWhere((o) => o[OpKey.method] == 'call_deferred');
    expect((start[OpKey.args] as List).first, 'arena_start');
    expect(events['assetload']?['kind'], 'pack');
    // The game's own events reach the program, decoded.
    binding.onSignal!(binding.gameEventCallback!, ['{"type":"result","outcome":"win","score":300}']);
    expect(events['gameevent'], {'id': 'game', 'type': 'result', 'outcome': 'win', 'score': 300});
  });

  test('a failed download is reported, not thrown', () async {
    final binding = ScriptedBinding(cached: false, httpCode: 404);
    final errors = <Map<String, Object?>>[];
    final controller = GodotController(binding: binding);
    SceneDsl(controller, assets: SceneAssets(controller, onEvent: (t, d) {
      if (t == 'asseterror') errors.add(d);
    })).build({
      'nodes': [
        {'type': 'pack', 'id': 'g', 'src': 'https://arena/missing.pck', 'scene': 'res://x/main.tscn', 'version': 'x'},
        {'type': 'pack', 'id': 'bad', 'src': 'https://arena/a.pck', 'scene': 'main.tscn'},
        {'type': 'model', 'id': 'm'},
      ],
    });
    await settle();
    expect(errors.map((e) => e['id']), containsAll(['g', 'bad', 'm']));
    expect(errors.firstWhere((e) => e['id'] == 'g')['message'], contains('HTTP 404'));
  });
}
