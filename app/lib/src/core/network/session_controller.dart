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
  bool _isAdmin = false;
  String _avatar = '';

  Session? get session => _session;
  bool get isAdmin => _isAdmin;

  /// The signed-in account's avatar: a stored picture's id, "" when none.
  String get avatar => _avatar;
  bool get isReady => _ready;
  bool get isLoggedIn => _session?.isLoggedIn ?? false;
  bool get isBusy => _busy;
  String? get error => _error;

  Future<void> _init() async {
    try {
      await service.restoreSession();
      _session = service.session;
      if (_session?.isLoggedIn ?? false) {
        await _refreshRole();
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
      await _refreshRole();
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
      await _refreshRole();
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
      await _refreshRole();
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
    await _refreshRole();
    await _enableNotificationsSafely();
    notifyListeners();
  }

  /// Reads the account's role from the server so admin-only surfaces stay
  /// hidden unless the backend says this account is an admin, and its avatar.
  Future<void> _refreshRole() async {
    try {
      _isAdmin = await service.fetchIsAdmin();
    } catch (_) {
      _isAdmin = false;
    }
    try {
      _avatar = await service.fetchMyAvatar();
    } catch (_) {
      _avatar = '';
    }
  }

  /// Sets (a stored picture's id) or clears ("") the account's avatar.
  Future<void> setAvatar(String fileId) async {
    await service.setMyAvatar(fileId);
    _avatar = fileId;
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
    _isAdmin = false;
    _avatar = '';
    notifyListeners();
  }

  void setSession(Session session) {
    _session = session;
    notifyListeners();
    _refreshRole().then((_) => notifyListeners());
  }
}
