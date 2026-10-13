import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/core/notifications/push_notification_service.dart';
import 'package:tradera/src/data/services/tradera_service.dart';

class _RecordingService extends TraderaService {
  _RecordingService() : super(TraderaApiClient(baseUrl: 'http://localhost'));

  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    calls.add('$namespace.$action');
    bodies.add(body);
    return const <String, dynamic>{'ok': true};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('tradera/push_notifications'), null);
  });

  test('push notifications are restricted to the native iOS target', () {
    expect(PushNotificationService.supported, isFalse);
  });

  test('enable and disable keep APNs and backend registration in sync',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    final nativeCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('tradera/push_notifications'),
      (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'requestToken' || call.method == 'currentToken') {
          return 'abc123';
        }
        return null;
      },
    );
    final backend = _RecordingService();
    final push = PushNotificationService(backend);

    expect(await push.enable(), isTrue);
    expect(await push.isEnabled(), isTrue);
    expect(backend.calls, ['users.push_register']);
    expect(backend.bodies.single, {
      'token': 'abc123',
      'platform': 'ios',
      'environment': 'development',
    });

    await push.disable();
    expect(await push.isEnabled(), isFalse);
    expect(backend.calls, ['users.push_register', 'users.push_unregister']);
    expect(backend.bodies.last, {'token': 'abc123'});
    expect(nativeCalls, ['requestToken', 'unregister']);
  });
}
