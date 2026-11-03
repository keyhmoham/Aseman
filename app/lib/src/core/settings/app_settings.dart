import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/theme_pack.dart';

/// Device theme: light, dark, or system, plus the active pack's palette.
///
/// Stored in [SharedPreferences], the app's local cache. That plugin writes
/// to the platform store on Android, iOS, macOS, Windows, and Linux, and to
/// `localStorage` on the web, so the choice survives a restart everywhere.
class AppSettingsController extends ChangeNotifier {
  static const storageKey = 'aseman.theme';
  static const defaultAccent = Color(0xFF8B7BFF);

  ThemeMode themeMode = ThemeMode.system;
  Color accent = defaultAccent;
  /// Empty until the user picks a pack palette (or restore finds one).
  String paletteId = '';

  bool _dirty = false;
  Future<void>? _save;

  /// Reads the cached theme. A missing or unreadable entry keeps the defaults.
  /// A change made in this session is left as the user set it.
  Future<void> restore() async {
    final epoch = _epoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != _epoch) return;
      final raw = prefs.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final mode = _mode(decoded['mode']);
      final color = _color(decoded['accent']);
      final palette = decoded['palette'];
      var changed = false;
      if (mode != null && mode != themeMode) {
        themeMode = mode;
        changed = true;
      }
      if (color != null && color != accent) {
        accent = color;
        changed = true;
      }
      if (palette is String && palette.isNotEmpty && palette != paletteId) {
        paletteId = palette;
        changed = true;
      }
      if (changed && epoch == _epoch) notifyListeners();
    } catch (_) {}
  }

  int _epoch = 0;

  void setThemeMode(ThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    _epoch++;
    notifyListeners();
    _scheduleSave();
  }

  /// Selects a palette option proposed by the active theme pack.
  void setPalette(ThemePaletteOption option) {
    if (paletteId == option.id && accent.toARGB32() == option.accent.toARGB32()) {
      return;
    }
    paletteId = option.id;
    accent = option.accent;
    _epoch++;
    notifyListeners();
    _scheduleSave();
  }

  /// Legacy accent-only setter — prefer [setPalette] so the id stays in sync.
  void setAccent(Color value) {
    if (accent == value) return;
    accent = value;
    _epoch++;
    notifyListeners();
    _scheduleSave();
  }

  /// When the theme pack changes, snap to a palette that pack actually offers.
  void syncPaletteToPack(ThemePack pack) {
    final resolved = pack.resolvePalette(paletteId: paletteId, accent: accent);
    if (paletteId == resolved.id &&
        accent.toARGB32() == resolved.accent.toARGB32()) {
      return;
    }
    paletteId = resolved.id;
    accent = resolved.accent;
    _epoch++;
    notifyListeners();
    _scheduleSave();
  }

  /// Completes once the latest theme settings have been written to cache.
  Future<void> flush() => _save ?? Future<void>.value();

  void _scheduleSave() {
    _dirty = true;
    _save ??= _flush();
  }

  Future<void> _flush() async {
    try {
      while (_dirty) {
        _dirty = false;
        final mode = themeMode;
        final color = accent;
        final palette = paletteId;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            storageKey,
            jsonEncode({
              'mode': mode.name,
              'accent': color.toARGB32().toRadixString(16).padLeft(8, '0'),
              'palette': palette,
            }),
          );
        } catch (_) {
          return;
        }
      }
    } finally {
      _save = null;
      if (_dirty) _save = _flush();
    }
  }

  static ThemeMode? _mode(Object? raw) {
    if (raw is! String) return null;
    for (final mode in ThemeMode.values) {
      if (mode.name == raw) return mode;
    }
    return null;
  }

  static Color? _color(Object? raw) {
    if (raw is! String) return null;
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    if (hex.length != 6 && hex.length != 8) return null;
    final value = int.tryParse(hex.length == 6 ? 'ff$hex' : hex, radix: 16);
    if (value == null) return null;
    return Color(value);
  }
}

class AppSettingsScope extends InheritedNotifier<AppSettingsController> {
  const AppSettingsScope({
    super.key,
    required AppSettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppSettingsController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, 'No AppSettingsScope found');
    return scope!.notifier!;
  }

  /// Null when the tree has no settings (tests, isolated previews).
  static AppSettingsController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppSettingsScope>()
        ?.notifier;
  }
}
