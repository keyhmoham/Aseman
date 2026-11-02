import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable sweep-gradient colors for a person or agent avatar ring.
///
/// Each identity is bound once on this device and written to
/// [SharedPreferences], so the same user or agent always gets the same ring
/// everywhere in the app (and after a restart).
abstract final class HaloRingCache {
  static const storageKey = 'aseman.halo.rings.v1';

  /// In-memory id → ARGB stops (closed loop: last equals first).
  static final Map<String, List<int>> _argb = {};

  static bool _loaded = false;
  static bool _dirty = false;
  static Future<void>? _save;

  /// Person account id → cache key.
  static String person(String accountId) {
    final id = accountId.trim();
    return id.isEmpty ? '' : 'p:$id';
  }

  /// Agent / bot id → cache key.
  static String agent(String agentId) {
    final id = agentId.trim();
    return id.isEmpty ? '' : 'a:$id';
  }

  /// Loads bindings from the device store. Safe to call more than once.
  static Future<void> restore() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is! String || key.isEmpty) return;
            if (value is! List) return;
            final stops = <int>[];
            for (final item in value) {
              if (item is int) {
                stops.add(item);
              } else if (item is num) {
                stops.add(item.toInt());
              }
            }
            if (stops.length >= 3) _argb[key] = stops;
          });
        }
      }
    } catch (_) {
      // Keep whatever is already in memory.
    } finally {
      _loaded = true;
    }
  }

  /// Clears memory (tests / logout). Does not wipe the device store unless
  /// [persist] is true. Sets [_loaded] false so the next [restore] re-reads.
  static Future<void> clear({bool persist = false}) async {
    _argb.clear();
    _dirty = false;
    _loaded = false;
    if (!persist) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(storageKey);
    } catch (_) {}
  }

  /// Sweep stops for [identity]. Empty identity returns the first bank entry
  /// without caching. New identities are derived, remembered, and scheduled
  /// for disk write.
  static List<Color> colorsFor(String identity) {
    final id = identity.trim();
    if (id.isEmpty) return List<Color>.from(_bank[0]);

    final existing = _argb[id];
    if (existing != null && existing.length >= 3) {
      return [for (final v in existing) Color(v)];
    }

    final derived = _derive(id);
    _argb[id] = [for (final c in derived) c.toARGB32()];
    _schedulePersist();
    return derived;
  }

  /// Whether [identity] already has a binding in this session / restored map.
  static bool has(String identity) => _argb.containsKey(identity.trim());

  /// Completes once the latest map has been written.
  static Future<void> flush() => _save ?? Future<void>.value();

  static List<Color> _derive(String id) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return List<Color>.from(_bank[hash % _bank.length]);
  }

  static void _schedulePersist() {
    _dirty = true;
    _save ??= _flush();
  }

  static Future<void> _flush() async {
    try {
      // Prefer having restore finish before the first write so we do not
      // clobber a colder disk map with a partial in-memory one.
      if (!_loaded) await restore();
      while (_dirty) {
        _dirty = false;
        final snapshot = <String, List<int>>{
          for (final e in _argb.entries) e.key: List<int>.from(e.value),
        };
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(storageKey, jsonEncode(snapshot));
        } catch (_) {
          return;
        }
      }
    } finally {
      _save = null;
      if (_dirty) _save = _flush();
    }
  }

  /// Curated closed-loop sweeps (last stop matches first).
  static const List<List<Color>> _bank = [
    [
      Color(0xFF8B7BFF),
      Color(0xFF58D7FF),
      Color(0xFF43D39E),
      Color(0xFF8B7BFF),
    ],
    [
      Color(0xFFFF6B79),
      Color(0xFFFFB648),
      Color(0xFF8B7BFF),
      Color(0xFFFF6B79),
    ],
    [
      Color(0xFF2A78D6),
      Color(0xFF58D7FF),
      Color(0xFF1BAF7A),
      Color(0xFF2A78D6),
    ],
    [
      Color(0xFFEB6834),
      Color(0xFFFFB648),
      Color(0xFFD55181),
      Color(0xFFEB6834),
    ],
    [
      Color(0xFF6250D6),
      Color(0xFF58D7FF),
      Color(0xFFB8860B),
      Color(0xFF6250D6),
    ],
    [
      Color(0xFF00838F),
      Color(0xFF43D39E),
      Color(0xFF8B7BFF),
      Color(0xFF00838F),
    ],
    [
      Color(0xFFD55181),
      Color(0xFF8B7BFF),
      Color(0xFFFF6B79),
      Color(0xFFD55181),
    ],
    [
      Color(0xFF2E7D32),
      Color(0xFF58D7FF),
      Color(0xFFFFB648),
      Color(0xFF2E7D32),
    ],
    [
      Color(0xFFE34948),
      Color(0xFFEB6834),
      Color(0xFF6250D6),
      Color(0xFFE34948),
    ],
    [
      Color(0xFF1BAF7A),
      Color(0xFF8B7BFF),
      Color(0xFF58D7FF),
      Color(0xFF1BAF7A),
    ],
    [
      Color(0xFFB8860B),
      Color(0xFFFF6B79),
      Color(0xFF2A78D6),
      Color(0xFFB8860B),
    ],
    [
      Color(0xFF58D7FF),
      Color(0xFFD55181),
      Color(0xFF43D39E),
      Color(0xFF58D7FF),
    ],
  ];
}
