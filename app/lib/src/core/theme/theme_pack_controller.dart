import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'default_theme_packs.dart';
import 'theme_pack.dart';

/// Active installable theme pack (device cache + optional account sync).
class ThemePackController extends ChangeNotifier {
  static const storageKey = 'aseman.theme_pack';
  static const idKey = 'aseman.theme_pack_id';
  static const listingKey = 'aseman.theme_listing_id';

  ThemePack pack = DefaultThemePacks.sky;
  String? listingId;
  String? themeBotId;

  bool _dirty = false;
  Future<void>? _save;
  int _epoch = 0;

  Future<void> restore() async {
    final epoch = _epoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (epoch != _epoch) return;
      final id = prefs.getString(idKey);
      final raw = prefs.getString(storageKey);
      listingId = prefs.getString(listingKey);
      themeBotId = prefs.getString('aseman.theme_bot_id');
      ThemePack? next;
      if (raw != null && raw.isNotEmpty) {
        next = ThemePack.tryDecode(raw);
      }
      if (next == null && id != null && id.isNotEmpty) {
        next = DefaultThemePacks.byId(id);
      }
      if (next != null && epoch == _epoch) {
        pack = next;
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Apply a pack locally (from store install, studio, or builtin picker).
  Future<void> apply(
    ThemePack next, {
    String? listing,
    String? botId,
  }) async {
    final err = next.validate();
    if (err != null) {
      throw FormatException(err);
    }
    pack = next;
    listingId = listing;
    themeBotId = botId;
    _epoch++;
    notifyListeners();
    _scheduleSave();
    await flush();
  }

  Future<void> applyBuiltin(String id) =>
      apply(DefaultThemePacks.byId(id), listing: null, botId: null);

  Future<void> clearToDefault() => applyBuiltin(DefaultThemePacks.skyId);

  /// Replace pack JSON from the server active-theme sync without wiping ids.
  Future<void> syncFromServer({
    required ThemePack next,
    String? listing,
    String? botId,
  }) async {
    if (next.id == pack.id &&
        listing == listingId &&
        botId == themeBotId &&
        listEquals(
          utf8.encode(next.encode()),
          utf8.encode(pack.encode()),
        )) {
      return;
    }
    await apply(next, listing: listing, botId: botId);
  }

  Future<void> flush() => _save ?? Future<void>.value();

  void _scheduleSave() {
    _dirty = true;
    _save ??= _flush();
  }

  Future<void> _flush() async {
    try {
      while (_dirty) {
        _dirty = false;
        final current = pack;
        final listing = listingId;
        final bot = themeBotId;
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(idKey, current.id);
          await prefs.setString(storageKey, current.encode());
          if (listing == null || listing.isEmpty) {
            await prefs.remove(listingKey);
          } else {
            await prefs.setString(listingKey, listing);
          }
          if (bot == null || bot.isEmpty) {
            await prefs.remove('aseman.theme_bot_id');
          } else {
            await prefs.setString('aseman.theme_bot_id', bot);
          }
        } catch (_) {
          return;
        }
      }
    } finally {
      _save = null;
      if (_dirty) _save = _flush();
    }
  }
}

class ThemePackScope extends InheritedNotifier<ThemePackController> {
  const ThemePackScope({
    super.key,
    required ThemePackController controller,
    required super.child,
  }) : super(notifier: controller);

  static ThemePackController of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<ThemePackScope>();
    assert(scope != null, 'No ThemePackScope found');
    return scope!.notifier!;
  }

  static ThemePackController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemePackScope>()
      ?.notifier;
}
