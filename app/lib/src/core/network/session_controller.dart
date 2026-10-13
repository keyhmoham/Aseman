import 'package:flutter/foundation.dart';

import '../../data/services/tradera_service.dart';
import '../auth/federated_sign_in.dart';
import '../network/session_store.dart';
import '../notifications/push_notification_service.dart';

/// Holds the current signed-in session and notifies listeners on auth changes.
class SessionController extends ChangeNotifier {
  SessionController(this.service)
      : notifications = PushNotificationService(service) {
    _init();
  }

  final TraderaService service;
  final PushNotificationService notifications;

  Session? _session;
  bool _ready = false;
  bool _busy = false;
  String? _error;

  Session? get session => _session;
  bool get isReady => _ready;
  bool get isLoggedIn => _session?.isLoggedIn ?? false;
  bool get isBusy => _busy;
  String? get error => _error;

  Future<void> _init() async {
    try {
      await service.restoreSession();
      _session = service.session;
      if (_session?.isLoggedIn ?? false) {
        try {
          await notifications.sync();
        } catch (_) {}
      }
    } catch (_) {}
    _ready = true;
    notifyListeners();
  }

  Future<bool> login(String account, String password) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final s = await service.login(account: account, password: password);
      await SessionStore.save(s);
      _session = s;
      await _enableNotificationsSafely();
      _busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      _busy = false;
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String handle, String email, String password) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final s = await service.register(
          handle: handle, email: email, password: password);
      await SessionStore.save(s);
      _session = s;
      await _enableNotificationsSafely();
      _busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      _busy = false;
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> oauth(String provider, String identityToken) async {
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final s = await service.oauth(provider, identityToken);
      await SessionStore.save(s);
      _session = s;
      await _enableNotificationsSafely();
      _busy = false;
      notifyListeners();
      return true;
    } catch (e) {
      _busy = false;
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> adopt(Session session) async {
    await SessionStore.save(session);
    _session = session;
    await _enableNotificationsSafely();
    notifyListeners();
  }

  Future<void> _enableNotificationsSafely() async {
    try {
      await notifications.enable();
    } catch (_) {
      // Authentication succeeds independently of optional notification setup.
    }
  }

  Future<void> logout() async {
    try {
      await notifications.disable();
    } catch (_) {}
    try {
      await FederatedSignIn.instance.signOutGoogle();
    } catch (_) {}
    await service.logout();
    _session = null;
    notifyListeners();
  }

  void setSession(Session session) {
    _session = session;
    notifyListeners();
  }
}
