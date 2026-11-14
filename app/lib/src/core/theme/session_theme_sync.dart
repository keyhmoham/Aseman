import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../data/services/aseman_service.dart';
import '../network/device_meta.dart';
import '../settings/app_settings.dart';
import 'theme_pack.dart';
import 'theme_pack_controller.dart';

/// Session-scoped theme sync (`auth.session_metadata_*` `/theming`).
///
/// A **new** session starts with empty `theme` / `theming` trees — it cannot
/// carry an older session's look. Only this session's tree is read; the
/// legacy account-level `themes.active` / `user_themes` row is never used
/// here (that was incorrectly re-applying old Decillion packs on login).
///
/// Device [SharedPreferences] hold the pre-login default (Sky + blue). When
/// this session's tree is empty we keep that default and publish it into the
/// session. When the tree already has theming (same session resumed) we
/// hydrate from it.
class SessionThemeSync {
  SessionThemeSync({
    required this.service,
    required this.settings,
    required this.packs,
  });

  final AsemanService service;
  final AppSettingsController settings;
  final ThemePackController packs;

  bool _pushing = false;
  bool _hydrating = false;
  Timer? _debounce;

  /// Stamp device label, then sync with **this** session's theming tree only.
  Future<void> syncFromServer() async {
    _hydrating = true;
    _debounce?.cancel();
    try {
      try {
        await service.sessionUpdate(meta: thisDeviceMeta());
      } catch (_) {}

      Map<String, dynamic> theming = const {};
      try {
        final tree = await service.sessionMetadataView();
        theming = _themingOf(tree);
      } catch (_) {
        // Node without session metadata: stay on the device default.
      }

      if (theming.isEmpty) {
        // New session — no saved look. Keep device Sky + blue and seed the tree.
        await pushNow();
        return;
      }

      final appearance = '${theming['appearance'] ?? ''}';
      final mode = _mode(appearance);
      if (mode != null) settings.hydrateThemeMode(mode);

      final pack = _packOf(theming);
      if (pack != null) {
        await packs.syncFromServer(
          next: pack,
          listing: _string(theming['listing_id']),
          botId: _string(theming['theme_id']),
        );
      }

      final palette = theming['palette_id'];
      final accent = theming['accent'];
      if (palette is String && palette.isNotEmpty) {
        final color =
            _color(accent is String ? accent : null) ?? settings.accent;
        settings.hydratePalette(paletteId: palette, accent: color);
      } else {
        final color = _color(accent is String ? accent : null);
        if (color != null) settings.hydrateAccent(color);
      }
      settings.syncPaletteToPack(packs.pack);
    } finally {
      _hydrating = false;
    }
  }

  /// Clears leftover account-level `user_themes` when switching to a builtin.
  Future<void> clearServerActiveTheme() async {
    try {
      await service.uninstallActiveTheme();
    } catch (_) {}
  }

  /// Debounced push of this device's look into **this** session's metadata.
  void schedulePush() {
    if (_hydrating || _pushing) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(pushNow());
    });
  }

  Future<void> pushNow() async {
    if (_pushing) return;
    _pushing = true;
    try {
      final packJson = packs.pack.encode();
      Map<String, dynamic>? packObj;
      try {
        final decoded = jsonDecode(packJson);
        if (decoded is Map) packObj = decoded.cast<String, dynamic>();
      } catch (_) {}
      final theming = <String, dynamic>{
        'active': true,
        'appearance': settings.themeMode.name,
        'palette_id': settings.paletteId,
        'accent': settings.accent
            .toARGB32()
            .toRadixString(16)
            .padLeft(8, '0'),
        'pack_json': packJson,
        if (packObj != null) 'pack': packObj,
        if (packObj != null) 'theme': packObj,
        if ((packs.themeBotId ?? '').isNotEmpty) 'theme_id': packs.themeBotId,
        if ((packs.listingId ?? '').isNotEmpty) 'listing_id': packs.listingId,
      };
      await service.sessionMetadataPatch([
        {'op': 'set', 'path': '/theming', 'value': theming},
        {'op': 'set', 'path': '/theme', 'value': theming},
      ]);
    } catch (_) {
      // Offline / older nodes without session metadata: local cache still works.
    } finally {
      _pushing = false;
    }
  }

  static Map<String, dynamic> _themingOf(Map<String, dynamic> tree) {
    final theming = tree['theming'];
    if (theming is Map && theming.isNotEmpty) {
      return theming.cast<String, dynamic>();
    }
    final theme = tree['theme'];
    if (theme is Map && theme.isNotEmpty) {
      return theme.cast<String, dynamic>();
    }
    return const {};
  }

  static ThemePack? _packOf(Map<String, dynamic> theming) {
    final raw = theming['pack_json'];
    if (raw is String && raw.isNotEmpty) {
      return ThemePack.tryDecode(raw);
    }
    final pack = theming['pack'] ?? theming['theme'];
    if (pack is Map) {
      try {
        return ThemePack.fromJson(pack.cast<String, dynamic>());
      } catch (_) {}
    }
    return null;
  }

  static String? _string(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return raw;
  }

  static ThemeMode? _mode(String raw) {
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }

  static Color? _color(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (hex.length != 6 && hex.length != 8) return null;
    final value = int.tryParse(hex.length == 6 ? 'ff$hex' : hex, radix: 16);
    if (value == null) return null;
    return Color(value);
  }
}
