import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/services/aseman_service.dart';

/// Coordinates the iOS APNs token with the signed-in backend account.
class PushNotificationService {
  PushNotificationService(this.service);

  static const _channel = MethodChannel('aseman/push_notifications');
  static const _tokenKey = 'aseman.push.token';
  static const _enabledKey = 'aseman.push.enabled';

  final AsemanService service;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<bool> isEnabled() async {
    if (!supported) return false;
    return (await SharedPreferences.getInstance()).getBool(_enabledKey) ??
        false;
  }

  Future<bool> enable() async {
    if (!supported) return false;
    final token = await _channel.invokeMethod<String>('requestToken');
    if (token == null || token.isEmpty) return false;
    await service.invokeAction('users', 'push_register', body: {
      'token': token,
      'platform': 'ios',
      'environment': kReleaseMode ? 'production' : 'development',
    });
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_tokenKey, token);
    await preferences.setBool(_enabledKey, true);
    return true;
  }

  /// Refreshes a previously granted token after session restoration without
  /// surprising the user with a first-time permission prompt.
  Future<void> sync() async {
    if (!supported || !await isEnabled()) return;
    final token = await _channel.invokeMethod<String>('requestToken');
    if (token == null || token.isEmpty) return;
    await service.invokeAction('users', 'push_register', body: {
      'token': token,
      'platform': 'ios',
      'environment': kReleaseMode ? 'production' : 'development',
    });
    await (await SharedPreferences.getInstance()).setString(_tokenKey, token);
  }

  Future<void> disable() async {
    if (!supported) return;
    final preferences = await SharedPreferences.getInstance();
    final token = preferences.getString(_tokenKey) ??
        await _channel.invokeMethod<String>('currentToken');
    if (token != null && token.isNotEmpty) {
      await service
          .invokeAction('users', 'push_unregister', body: {'token': token});
    }
    await _channel.invokeMethod<void>('unregister');
    await preferences.remove(_tokenKey);
    await preferences.setBool(_enabledKey, false);
  }
}
