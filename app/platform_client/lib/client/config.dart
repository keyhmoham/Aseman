import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What this build of the client is for: one platform's published frontend
/// on one Aseman node.
///
/// `platform_client_build` (on the space's computer) writes it into
/// `assets/client.json` before building:
///
/// ```json
/// {"node": "https://aseman.example", "platform": "acme", "name": "Acme",
///  "frontend": "https://aseman.example/v1/platforms/acme/app/", "accent": "#4F5BD5"}
/// ```
///
/// `frontend` is the address of the frontend (the platform's door to the
/// Elpian app's proxy); `node` and `platform` follow from it when left out.
/// `--dart-define=ASEMAN_FRONTEND_URL=…` (or `ASEMAN_NODE_URL` and
/// `ASEMAN_PLATFORM`) override the file, for development.
@immutable
class ClientConfig {
  const ClientConfig({
    required this.node,
    required this.platform,
    required this.name,
    this.accent,
  });

  /// The node's origin, e.g. `https://aseman.example` (no trailing slash).
  final String node;

  /// The platform's slug.
  final String platform;

  /// The platform's name until the node tells its current one.
  final String name;

  /// The accent color (ARGB), or null for the default.
  final int? accent;

  static final RegExp _slug = RegExp(r'^[a-z][a-z0-9-]{1,47}$');
  static final RegExp _door = RegExp(r'^(.*)/v1/platforms/([a-z][a-z0-9-]{1,47})/app/?$');

  /// The gateway path of the frontend: `/v1/platforms/<slug>/app/`.
  String get frontendPath => '/v1/platforms/$platform/app/';

  /// The frontend's full address.
  String get frontendUrl => '$node$frontendPath';

  bool get isValid =>
      _slug.hasMatch(platform) &&
      (Uri.tryParse(node)?.hasScheme ?? false) &&
      node.startsWith('http');

  /// Reads a config from JSON (and the build's overrides).
  factory ClientConfig.fromJson(
    Map<String, dynamic> json, {
    String frontendOverride = '',
    String nodeOverride = '',
    String platformOverride = '',
  }) {
    var node = '${json['node'] ?? ''}'.trim();
    var platform = '${json['platform'] ?? ''}'.trim().toLowerCase();
    final frontend = frontendOverride.isNotEmpty
        ? frontendOverride
        : '${json['frontend'] ?? ''}'.trim();
    final door = _door.firstMatch(frontend);
    if (door != null) {
      if (frontendOverride.isNotEmpty || node.isEmpty) node = door.group(1)!;
      if (frontendOverride.isNotEmpty || platform.isEmpty) {
        platform = door.group(2)!;
      }
    }
    if (nodeOverride.isNotEmpty) node = nodeOverride.trim();
    if (platformOverride.isNotEmpty) {
      platform = platformOverride.trim().toLowerCase();
    }
    node = node.replaceFirst(RegExp(r'/+$'), '');
    final name = '${json['name'] ?? ''}'.trim();
    return ClientConfig(
      node: node,
      platform: platform,
      name: name.isEmpty ? platform : name,
      accent: parseColor('${json['accent'] ?? ''}'),
    );
  }

  /// `#RRGGBB` or `#AARRGGBB` as ARGB (null when it is neither).
  static int? parseColor(String hex) {
    final v = hex.trim().replaceFirst('#', '');
    if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(v)) return null;
    final n = int.parse(v, radix: 16);
    return v.length == 6 ? 0xFF000000 | n : n;
  }

  static const _frontendDefine = String.fromEnvironment('ASEMAN_FRONTEND_URL');
  static const _nodeDefine = String.fromEnvironment('ASEMAN_NODE_URL');
  static const _platformDefine = String.fromEnvironment('ASEMAN_PLATFORM');

  /// The config this build carries.
  static Future<ClientConfig> load([AssetBundle? bundle]) async {
    Map<String, dynamic> json = const {};
    try {
      final raw = await (bundle ?? rootBundle).loadString('assets/client.json');
      final decoded = jsonDecode(raw);
      if (decoded is Map) json = decoded.cast<String, dynamic>();
    } catch (_) {
      // No file: the build's defines must say it.
    }
    return ClientConfig.fromJson(json,
        frontendOverride: _frontendDefine,
        nodeOverride: _nodeDefine,
        platformOverride: _platformDefine);
  }
}
