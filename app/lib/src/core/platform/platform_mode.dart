import 'package:flutter/foundation.dart';

/// Which product environment this client is for.
///
/// Empty is main Aseman. A platform's own client is built with
/// `--dart-define=ASEMAN_PLATFORM=<slug>`; a web build can also be opened as
/// one with `?platform=<slug>`. In a platform's client people sign in to (and
/// up on) that platform's own accounts, and home is the frontend the
/// platform's organization published (an app the agents of a space built).
abstract final class PlatformMode {
  static const String _built = String.fromEnvironment('ASEMAN_PLATFORM');

  static final RegExp _slug = RegExp(r'^[a-z][a-z0-9-]{1,47}$');

  static String? _override;

  /// The platform's slug, or '' for main Aseman.
  static String get slug {
    final candidates = [
      _override,
      _built,
      if (kIsWeb) Uri.base.queryParameters['platform'],
    ];
    for (final c in candidates) {
      final v = (c ?? '').trim().toLowerCase();
      if (v.isNotEmpty) return _slug.hasMatch(v) ? v : '';
    }
    return '';
  }

  /// Whether this client is a platform's.
  static bool get active => slug.isNotEmpty;

  /// The `platform` field auth actions take ({} on main Aseman).
  static Map<String, String> get authField =>
      active ? {'platform': slug} : const {};

  /// Sets the platform in tests (null restores the build's).
  @visibleForTesting
  static set debugSlug(String? value) => _override = value;
}

/// A platform as its client shows it before and after sign-in.
@immutable
class PlatformInfo {
  const PlatformInfo({
    required this.id,
    required this.slug,
    required this.name,
    this.frontend,
  });

  factory PlatformInfo.fromJson(Map<String, dynamic> json) {
    final p = json['platform'] is Map
        ? (json['platform'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final f = json['frontend'] is Map
        ? PlatformFrontendInfo.fromJson(
            (json['frontend'] as Map).cast<String, dynamic>())
        : null;
    return PlatformInfo(
      id: '${p['id'] ?? ''}',
      slug: '${p['slug'] ?? ''}',
      name: '${p['name'] ?? p['slug'] ?? ''}',
      frontend: f,
    );
  }

  final String id;
  final String slug;
  final String name;

  /// The published frontend (null: the platform has none yet).
  final PlatformFrontendInfo? frontend;
}

/// A platform's published frontend.
@immutable
class PlatformFrontendInfo {
  const PlatformFrontendInfo({
    required this.title,
    required this.ui,
    required this.entry,
    required this.url,
  });

  factory PlatformFrontendInfo.fromJson(Map<String, dynamic> json) {
    final entry = '${json['entry'] ?? ''}';
    return PlatformFrontendInfo(
      title: '${json['title'] ?? ''}',
      ui: '${json['ui'] ?? 'elpian'}',
      entry: entry.isEmpty ? 'elpian/app.js' : entry,
      url: '${json['url'] ?? ''}',
    );
  }

  final String title;

  /// "elpian" (runs natively here) or "web" (a page in a web view).
  final String ui;

  /// The Elpian program's path in the app.
  final String entry;

  /// The gateway path: /v1/platforms/<slug>/app/.
  final String url;

  bool get isWeb => ui == 'web';
}
