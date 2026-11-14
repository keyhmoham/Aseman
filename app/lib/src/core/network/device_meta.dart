import 'package:flutter/foundation.dart';

/// Local description of this install, stamped onto the session row
/// (`auth.session_update`).
Map<String, dynamic> thisDeviceMeta() {
  final platform = defaultTargetPlatform;
  var label = switch (platform) {
    TargetPlatform.iOS => 'iPhone',
    TargetPlatform.android => 'Android',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    _ => kIsWeb ? 'Web browser' : 'This device',
  };
  String? userAgent;
  if (kIsWeb) {
    // Avoid dart:html so the same library builds for mobile.
    label = 'Web browser';
  }
  return {
    'label': label,
    'platform': kIsWeb
        ? 'web'
        : switch (platform) {
            TargetPlatform.iOS => 'ios',
            TargetPlatform.android => 'android',
            TargetPlatform.macOS => 'macos',
            TargetPlatform.windows => 'windows',
            TargetPlatform.linux => 'linux',
            _ => 'unknown',
          },
    if (userAgent != null) 'user_agent': userAgent,
  };
}
