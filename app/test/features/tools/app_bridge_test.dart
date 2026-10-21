import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/core/theme/app_colors.dart';
import 'package:tradera/src/data/services/tradera_service.dart';
import 'package:tradera/src/features/tools/elpian/app_bridge.dart';
import 'package:tradera/src/features/tools/presentation/app_frontend_theme.dart';

/// A service whose sandbox methods return canned values (no network).
class _SandboxStubService extends TraderaService {
  _SandboxStubService() : super(TraderaApiClient(baseUrl: 'http://localhost'));

  String lastCommand = '';

  @override
  Future<String> sandboxExec(String spaceId, String command) async {
    lastCommand = command;
    if (command.contains('for f in')) {
      return 'a.txt\tf\t12\t1700000000\nb\t d\t0\t1700000001\n';
    }
    if (command.startsWith('head -c')) return 'hello from file';
    if (command.contains('base64 -d')) return 'written';
    return 'ok';
  }

  @override
  Future<Map<String, dynamic>> sandboxStatus(String spaceId) async => {
        'space_id': spaceId,
        'bot_id': 'sbx-1',
        'name': 'sbx',
        'status': 'running'
      };

  @override
  Future<Map<String, dynamic>> sandboxStart(String spaceId) async =>
      {'bot_id': 'sbx-1', 'status': 'running'};

  @override
  Future<Map<String, dynamic>> sandboxStop(String spaceId) async =>
      {'bot_id': 'sbx-1', 'status': 'stopped'};
}

void main() {
  test('app theme stylesheet maps semantic classes to AppColors', () {
    final sheet = AppFrontendTheme.stylesheet();
    final rules = (sheet['rules'] as List).cast<Map<String, dynamic>>();
    final bySelector = {
      for (final r in rules) r['selector'] as String: (r['styles'] as Map),
    };
    expect(bySelector['.primary']?['color'], isNotEmpty);
    expect(bySelector['.danger']?['color'], isNotEmpty);
    expect(bySelector['.bg']?['backgroundColor'], isNotEmpty);
    expect(bySelector['.panel-card']?['borderRadius'], isNotEmpty);

    // The classes carry the actual theme hex values.
    expect(bySelector['.primary']?['color'],
        '#${(AppColors.primary.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}');
    expect(bySelector['.muted']?['color'],
        '#${(AppColors.muted.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}');
  });

  test('bridge sandbox.exec returns typed output', () async {
    final service = _SandboxStubService();
    final bridge = AppHostBridge(service,
        botId: 'bot-1', userId: 'u1', spaceId: 'space-1');
    final handlers = bridge.buildHostHandlers();

    final raw = await handlers['sandbox.exec']!('sandbox.exec', '["ls -la"]');
    final typed = jsonDecode(raw) as Map<String, dynamic>;
    expect(typed['type'], 'string');
    expect(typed['data'], isA<Map<String, dynamic>>());
    expect((typed['data'] as Map<String, dynamic>)['value'], isA<String>());
    expect(service.lastCommand, 'ls -la');
  });

  test('bridge sandbox.status returns typed object', () async {
    final bridge = AppHostBridge(_SandboxStubService(),
        botId: 'bot-1', spaceId: 'space-1');
    final raw = await bridge.buildHostHandlers()['sandbox.status']!(
        'sandbox.status', '[]');
    final typed = jsonDecode(raw) as Map<String, dynamic>;
    final value = typed['data'] as Map<String, dynamic>;
    expect((value['value'] as Map<String, dynamic>)['bot_id'], 'sbx-1');
  });

  test('bridge without spaceId hides sandbox handlers', () {
    final bridge = AppHostBridge(_SandboxStubService(), botId: 'bot-1');
    expect(bridge.buildHostHandlers().containsKey('sandbox.exec'), isFalse);
    expect(bridge.buildHostHandlers().containsKey('server.call'), isTrue);
  });

  test('web index.html includes the Elpian VM and QuickJS web runtimes', () {
    // Without these the browser throws "QuickJS web runtime not loaded" and
    // apps (Sandbox Explorer included) cannot boot on the web target.
    final index = File('web/index.html').readAsStringSync();
    for (final runtime in const [
      'elpian/web_runtime/quickjs_web_runtime.js',
      'elpian/web_runtime/elpian_wasm_loader.js',
    ]) {
      expect(index, contains('assets/assets/$runtime'));
      // Served from the app's own assets (lib/src/elpian is part of the app).
      expect(File('assets/$runtime').existsSync(), isTrue, reason: runtime);
    }
    expect(index, contains('script type="module"'));
  });
}
