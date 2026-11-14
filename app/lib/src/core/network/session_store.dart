import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A signed-in device session: bearer token plus this device's Ed25519
/// signing key. Each device gets its own key and server-side metadata.
class Session {
  const Session({
    required this.accountId,
    required this.handle,
    required this.token,
    required this.privateKey,
    required this.publicKey,
    this.sessionId = '',
    this.homeSpaceId = '',
    this.email = '',
    this.platformId = '',
  });

  final String accountId;
  final String handle;
  final String token;
  final String privateKey;
  final String publicKey;

  /// Server id of this device session (`auth` sessions row).
  final String sessionId;
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
        'session_id': sessionId,
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
        sessionId: json['session_id'] as String? ?? '',
        homeSpaceId: json['home_space_id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        platformId: json['platform_id'] as String? ?? '',
      );

  Session copyWith({
    String? accountId,
    String? handle,
    String? token,
    String? privateKey,
    String? publicKey,
    String? sessionId,
    String? homeSpaceId,
    String? email,
    String? platformId,
  }) =>
      Session(
        accountId: accountId ?? this.accountId,
        handle: handle ?? this.handle,
        token: token ?? this.token,
        privateKey: privateKey ?? this.privateKey,
        publicKey: publicKey ?? this.publicKey,
        sessionId: sessionId ?? this.sessionId,
        homeSpaceId: homeSpaceId ?? this.homeSpaceId,
        email: email ?? this.email,
        platformId: platformId ?? this.platformId,
      );
}

/// One row from `auth.sessions_list`.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.kind,
    required this.createdAt,
    required this.expiresAt,
    this.updatedAt = '',
    this.lastSeenAt = '',
    this.publicKey = '',
    this.metadataId = '',
    this.current = false,
    this.meta = const {},
  });

  final String id;
  final String kind;
  final String createdAt;
  final String expiresAt;
  final String updatedAt;
  final String lastSeenAt;
  final String publicKey;
  final String metadataId;
  final bool current;
  final Map<String, dynamic> meta;

  factory DeviceSession.fromJson(Map<String, dynamic> json) {
    final rawMeta = json['meta'];
    Map<String, dynamic> meta = const {};
    if (rawMeta is Map) {
      meta = rawMeta.cast<String, dynamic>();
    } else if (rawMeta is String && rawMeta.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawMeta);
        if (decoded is Map) meta = decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    return DeviceSession(
      id: '${json['id'] ?? ''}',
      kind: '${json['kind'] ?? 'session'}',
      createdAt: '${json['created_at'] ?? ''}',
      expiresAt: '${json['expires_at'] ?? ''}',
      updatedAt: '${json['updated_at'] ?? ''}',
      lastSeenAt: '${json['last_seen_at'] ?? ''}',
      publicKey: '${json['public_key'] ?? ''}',
      metadataId: '${json['metadata_id'] ?? ''}',
      current: json['current'] == true,
      meta: meta,
    );
  }

  String get title {
    final label = '${meta['label'] ?? ''}'.trim();
    if (label.isNotEmpty) return label;
    final platform = '${meta['platform'] ?? ''}';
    if (platform == 'ios') return 'iPhone';
    if (platform == 'android') return 'Android';
    if (platform == 'web') return 'Web browser';
    if (platform == 'macos') return 'Mac';
    if (platform == 'windows') return 'Windows';
    if (platform == 'linux') return 'Linux';
    return current ? 'This device' : 'Signed-in device';
  }

  String get subtitle {
    final parts = <String>[];
    if (current) parts.add('This device');
    final when = lastSeenAt.isNotEmpty ? lastSeenAt : createdAt;
    if (when.isNotEmpty) parts.add(_relativeWhen(when));
    return parts.isEmpty ? 'Signed in' : parts.join(' · ');
  }

  static String _relativeWhen(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return iso;
    final sec = DateTime.now().difference(t).inSeconds;
    if (sec < 60) return 'Active now';
    if (sec < 3600) return 'Active ${sec ~/ 60} min ago';
    if (sec < 86400) return 'Active ${sec ~/ 3600} h ago';
    if (sec < 86400 * 7) return 'Active ${sec ~/ 86400} d ago';
    return 'Seen ${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
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
