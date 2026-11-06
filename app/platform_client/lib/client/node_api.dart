import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// An error the node answered with.
class NodeException implements Exception {
  const NodeException(this.message, {this.status = 0, this.code = ''});

  final String message;
  final int status;
  final String code;

  @override
  String toString() => message;
}

/// The platform as the node describes it before anyone signs in.
class PlatformInfo {
  const PlatformInfo({
    required this.slug,
    required this.name,
    this.ui = '',
    this.entry = '',
    this.title = '',
    this.published = false,
  });

  factory PlatformInfo.fromJson(Map<String, dynamic> json, ClientConfig config) {
    final p = json['platform'] is Map
        ? (json['platform'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final f = json['frontend'] is Map
        ? (json['frontend'] as Map).cast<String, dynamic>()
        : null;
    final entry = '${f?['entry'] ?? ''}';
    return PlatformInfo(
      slug: '${p['slug'] ?? config.platform}',
      name: '${p['name'] ?? config.name}',
      ui: '${f?['ui'] ?? 'elpian'}',
      entry: entry.isEmpty ? 'elpian/app.js' : entry,
      title: '${f?['title'] ?? ''}',
      published: f != null,
    );
  }

  final String slug;
  final String name;

  /// "elpian" (runs here) or "web" (opens in the browser).
  final String ui;

  /// The Elpian program's path in the app.
  final String entry;
  final String title;

  /// Whether the platform has published a frontend.
  final bool published;

  bool get isElpian => ui != 'web';
}

/// Who is signed in (a person of the platform).
class Session {
  const Session({required this.token, required this.accountId, required this.handle});

  final String token;
  final String accountId;
  final String handle;
}

/// How far waking the frontend's computer has got (`_aseman/wake`).
class WakeReport {
  const WakeReport({required this.state, this.error = '', this.retryAfter = const Duration(seconds: 2)});

  factory WakeReport.fromJson(Map<String, dynamic> json) {
    final ms = (json['retry_after_ms'] as num?)?.toInt() ?? 0;
    return WakeReport(
      state: '${json['state'] ?? (json['ready'] == true ? 'ready' : 'waking')}',
      error: '${json['error'] ?? ''}',
      retryAfter: Duration(milliseconds: ms > 0 ? ms : 2000),
    );
  }

  /// "ready", "waking" or "failed".
  final String state;
  final String error;
  final Duration retryAfter;

  bool get ready => state == 'ready';
  bool get failed => state == 'failed';
}

/// The node, as this client uses it: the platform's public description, its
/// own accounts, and the frontend's wake door.
class NodeApi {
  NodeApi(this.config, {http.Client? client}) : _http = client ?? http.Client();

  final ClientConfig config;
  final http.Client _http;

  /// The connection this client talks to the node over.
  http.Client get httpClient => _http;
  Session? session;

  static const _timeout = Duration(seconds: 40);

  /// Headers that make a request the signed-in person's.
  Map<String, String> authHeaders() => {
        if (session != null) 'Authorization': 'Bearer ${session!.token}',
      };

  Future<Map<String, dynamic>> _action(String ns, String action, Map<String, dynamic> body) async {
    final http.Response res;
    try {
      res = await _http
          .post(Uri.parse('${config.node}/v1/$ns/$action'),
              headers: {'Content-Type': 'application/json', ...authHeaders()}, body: jsonEncode(body))
          .timeout(_timeout);
    } on TimeoutException {
      throw const NodeException('The server did not answer in time', status: 504);
    } on http.ClientException catch (e) {
      throw NodeException('No connection to the server: ${e.message}');
    }
    final decoded = _json(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode >= 400) {
      throw NodeException('${map['error'] ?? 'Request failed (HTTP ${res.statusCode})'}',
          status: res.statusCode, code: '${map['code'] ?? ''}');
    }
    return map;
  }

  /// The platform's name and published frontend. Needs no sign-in.
  Future<PlatformInfo> platformInfo() async =>
      PlatformInfo.fromJson(await _action('developer', 'platform_frontend', {'platform': config.platform}), config);

  /// Asks the frontend's computer to wake, waiting up to [wait]. Anyone may,
  /// so it carries no session: one that ended must not stop the wake.
  Future<WakeReport> wake({Duration wait = const Duration(seconds: 10)}) async {
    final uri = Uri.parse('${config.frontendUrl}_aseman/wake?wait=${wait.inSeconds}');
    final http.Response res;
    try {
      res = await _http.post(uri).timeout(wait + _timeout);
    } on TimeoutException {
      return const WakeReport(state: 'waking');
    } on http.ClientException catch (e) {
      throw NodeException('No connection to the server: ${e.message}');
    }
    final decoded = _json(res.body);
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode >= 400) {
      throw NodeException('${map['error'] ?? 'The app could not be woken (HTTP ${res.statusCode})'}',
          status: res.statusCode, code: '${map['code'] ?? ''}');
    }
    return WakeReport.fromJson(map);
  }

  Session _adopt(Map<String, dynamic> json) {
    final s = Session(
      token: '${json['token'] ?? ''}',
      accountId: '${json['account_id'] ?? ''}',
      handle: '${json['handle'] ?? ''}',
    );
    if (s.token.isEmpty) throw const NodeException('Signing in gave no session');
    session = s;
    unawaited(_save());
    return s;
  }

  /// Signs in to an account of the platform.
  Future<Session> signIn(String account, String password) async => _adopt(
      await _action('auth', 'login', {'account': account, 'password': password, 'platform': config.platform}));

  /// Makes an account on the platform and signs in to it.
  Future<Session> signUp(String handle, String email, String password) async => _adopt(await _action(
      'auth', 'register', {'handle': handle, 'email': email, 'password': password, 'platform': config.platform}));

  Future<void> signOut() async {
    try {
      if (session != null) await _action('auth', 'logout', const {});
    } catch (_) {}
    await forget();
  }

  /// Forgets the session on this device (one the node no longer accepts).
  Future<void> forget() async {
    session = null;
    await _save();
  }

  String get _key => 'aseman.platform.${config.platform}.session';

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final s = session;
      if (s == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode({'token': s.token, 'account_id': s.accountId, 'handle': s.handle}));
      }
    } catch (_) {}
  }

  /// Restores the session saved on this device.
  Future<void> restore() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      if (raw == null) return;
      final json = (jsonDecode(raw) as Map).cast<String, dynamic>();
      if ('${json['token'] ?? ''}'.isEmpty) return;
      session = Session(token: '${json['token']}', accountId: '${json['account_id'] ?? ''}', handle: '${json['handle'] ?? ''}');
    } catch (_) {}
  }

  static dynamic _json(String text) {
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }
}
