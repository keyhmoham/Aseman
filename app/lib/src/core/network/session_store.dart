import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A signed-in session: the bearer token plus the Ed25519 identity keypair.
class Session {
  const Session({
    required this.accountId,
    required this.handle,
    required this.token,
    required this.privateKey,
    required this.publicKey,
    this.homeSpaceId = '',
    this.email = '',
    this.platformId = '',
  });

  final String accountId;
  final String handle;
  final String token;
  final String privateKey;
  final String publicKey;
  final String homeSpaceId;
  final String email;

  /// The platform the account belongs to ('' for main Aseman).
  final String platformId;

  bool get isLoggedIn => token.isNotEmpty && accountId.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'account_id': accountId,
        'handle': handle,
        'token': token,
        'private_key': privateKey,
        'public_key': publicKey,
        'home_space_id': homeSpaceId,
        'email': email,
        'platform_id': platformId,
      };

  factory Session.fromJson(Map<String, dynamic> json) => Session(
        accountId: json['account_id'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        token: json['token'] as String? ?? '',
        privateKey: json['private_key'] as String? ?? '',
        publicKey: json['public_key'] as String? ?? '',
        homeSpaceId: json['home_space_id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        platformId: json['platform_id'] as String? ?? '',
      );
}

/// Persists the session across app launches.
class SessionStore {
  static const _key = 'aseman.session';

  static Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return Session.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(session.toJson()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
