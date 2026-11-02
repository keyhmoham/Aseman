import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/core/notifications/push_notification_service.dart';
import 'package:aseman/src/data/services/aseman_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecordingService extends AsemanService {
  _RecordingService() : super(AsemanApiClient(baseUrl: 'http://localhost'));

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
            const MethodChannel('aseman/push_notifications'), null);
  });

  test('push notifications are unsupported on web-like desktop hosts', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(PushNotificationService.supported, isFalse);
  });

  test('iOS enable and disable keep APNs and backend registration in sync',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    SharedPreferences.setMockInitialValues({});
    final nativeCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('aseman/push_notifications'),
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

    expect(PushNotificationService.supported, isTrue);
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

  test('Android enable registers with platform android', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('aseman/push_notifications'),
      (call) async {
        if (call.method == 'requestToken') return 'fcm-token';
        return null;
      },
    );
    final backend = _RecordingService();
    final push = PushNotificationService(backend);

    expect(PushNotificationService.supported, isTrue);
    expect(await push.enable(), isTrue);
    expect(backend.bodies.single['platform'], 'android');
    expect(backend.bodies.single['token'], 'fcm-token');
  });

  test('Android enable returns false when FCM is not configured', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('aseman/push_notifications'),
      (call) async => null,
    );
    final backend = _RecordingService();
    final push = PushNotificationService(backend);
    expect(await push.enable(), isFalse);
    expect(backend.calls, isEmpty);
  });
}
