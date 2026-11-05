import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'shell_layout.dart';

/// How a theme-declared Elpian surface attaches to a shell / chrome slot.
enum ThemeSurfaceMode {
  /// Hide the built-in widget and show only the Elpian surface.
  replace,

  /// Render Elpian above / before the built-in child.
  before,

  /// Render Elpian below / after the built-in child.
  after,

  /// Wrap the built-in child (Elpian may embed it via ThemeHostChild).
  wrap;

  static ThemeSurfaceMode parse(Object? raw,
      [ThemeSurfaceMode fallback = replace]) {
    final s = '$raw'.toLowerCase().trim();
    for (final v in ThemeSurfaceMode.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }
}

/// Where a theme island is offered in the shell.
enum ThemeIslandPlacement {
  /// Extra phone / home tab (id listed in shell.home.phone_tabs).
  homeTab,

  /// Extra profile menu entry.
  profile,

  /// Extra settings section.
  settings,

  /// Full-screen page opened via navigate / profile action.
  page,

  /// Free-floating overlay host (rendered only when explicitly shown).
  overlay;

  static ThemeIslandPlacement parse(Object? raw,
      [ThemeIslandPlacement fallback = page]) {
    final s = '$raw'.toLowerCase().trim().replaceAll('_', '').replaceAll('-', '');
    return switch (s) {
      'hometab' || 'home' || 'tab' => ThemeIslandPlacement.homeTab,
      'profile' || 'you' => ThemeIslandPlacement.profile,
      'settings' => ThemeIslandPlacement.settings,
      'overlay' => ThemeIslandPlacement.overlay,
      _ => ThemeIslandPlacement.page,
    };
  }
}

/// Source of an Elpian view: static tree and/or runnable program.
@immutable
class ThemeElpianSource {
  const ThemeElpianSource({
    this.inline,
    this.code = '',
    this.program = '',
    this.sdk = true,
  });

  /// Inline Elpian JSON view tree (`type`/`props`/`children`).
  final Map<String, dynamic>? inline;

  /// Inline QuickJS program source (theme UI plugin).
  final String code;

  /// Program URL (`https://…`) or Flutter asset path to load.
  final String program;

  /// When true, prepend the Aseman Elpian SDK before [code]/[program].
  final bool sdk;

  bool get isEmpty =>
      (inline == null || inline!.isEmpty) &&
      code.trim().isEmpty &&
      program.trim().isEmpty;

  bool get hasInline => inline != null && inline!.isNotEmpty;

  bool get hasProgram => code.trim().isNotEmpty || program.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        if (hasInline) 'inline': inline,
        if (code.trim().isNotEmpty) 'code': code,
        if (program.trim().isNotEmpty) 'program': program.trim(),
        if (!sdk) 'sdk': false,
      };

  factory ThemeElpianSource.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const ThemeElpianSource();
    final inlineRaw = json['inline'] ?? json['view'] ?? json['tree'];
    Map<String, dynamic>? inline;
    if (inlineRaw is Map) {
      inline = Map<String, dynamic>.from(inlineRaw);
    }
    final sdkRaw = json['sdk'];
    return ThemeElpianSource(
      inline: inline,
      code: '${json['code'] ?? json['script'] ?? json['js'] ?? ''}',
      program: '${json['program'] ?? json['path'] ?? json['entry'] ?? ''}',
      sdk: sdkRaw is bool ? sdkRaw : true,
    );
  }
}

/// One Elpian-backed surface attached to a known slot or chrome id.
@immutable
class ThemeSurfaceSpec {
  const ThemeSurfaceSpec({
    required this.slot,
    this.mode = ThemeSurfaceMode.replace,
    this.elpian = const ThemeElpianSource(),
  });

  /// [FeatureSlots] id, [ThemeChromeSlots] id, or island id.
  final String slot;
  final ThemeSurfaceMode mode;
  final ThemeElpianSource elpian;

  bool get isEmpty => elpian.isEmpty;

  Map<String, dynamic> toJson() => {
        'slot': slot,
        'mode': mode.name,
        'elpian': elpian.toJson(),
      };

  factory ThemeSurfaceSpec.fromJson(String slotKey, Map<String, dynamic> json) {
    final slot = '${json['slot'] ?? slotKey}'.trim();
    return ThemeSurfaceSpec(
      slot: slot.isEmpty ? slotKey : slot,
      mode: ThemeSurfaceMode.parse(json['mode']),
      elpian: ThemeElpianSource.fromJson(
        json['elpian'] is Map
            ? Map<String, dynamic>.from(json['elpian'] as Map)
            : (json['inline'] is Map ||
                    json['program'] != null ||
                    json['code'] != null
                ? json
                : null),
      ),
    );
  }
}

/// A new UI section / page contributed by a theme pack (Elpian island).
@immutable
class ThemeIslandSpec {
  const ThemeIslandSpec({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.icon = 'extension',
    this.placement = ThemeIslandPlacement.page,
    this.elpian = const ThemeElpianSource(),
  });

  /// Stable id, conventionally `island.<name>`.
  final String id;
  final String title;
  final String subtitle;
  final String icon;
  final ThemeIslandPlacement placement;
  final ThemeElpianSource elpian;

  bool get isEmpty => id.isEmpty || elpian.isEmpty;

  IconData get iconData => _materialIcon(icon);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        'icon': icon,
        'placement': placement.name,
        'elpian': elpian.toJson(),
      };

  factory ThemeIslandSpec.fromJson(String key, Map<String, dynamic> json) {
    var id = '${json['id'] ?? key}'.trim();
    if (id.isNotEmpty && !id.contains('.')) id = 'island.$id';
    return ThemeIslandSpec(
      id: id,
      title: '${json['title'] ?? json['label'] ?? id}',
      subtitle: '${json['subtitle'] ?? json['description'] ?? ''}',
      icon: '${json['icon'] ?? 'extension'}',
      placement: ThemeIslandPlacement.parse(json['placement'] ?? json['place']),
      elpian: ThemeElpianSource.fromJson(
        json['elpian'] is Map
            ? Map<String, dynamic>.from(json['elpian'] as Map)
            : (json['inline'] is Map ||
                    json['program'] != null ||
                    json['code'] != null
                ? json
                : null),
      ),
    );
  }

  static IconData _materialIcon(String raw) {
    final key = raw.trim().toLowerCase().replaceAll('-', '_');
    return switch (key) {
      'home' => Icons.home_rounded,
      'explore' || 'discover' => Icons.explore_rounded,
      'chat' || 'chats' || 'forum' => Icons.forum_rounded,
      'settings' || 'tune' => Icons.tune_rounded,
      'wallet' || 'payments' => Icons.account_balance_wallet_rounded,
      'store' || 'market' => Icons.storefront_rounded,
      'admin' => Icons.admin_panel_settings_rounded,
      'palette' || 'theme' => Icons.palette_rounded,
      'bolt' || 'flash' => Icons.bolt_rounded,
      'dashboard' => Icons.dashboard_rounded,
      'map' => Icons.map_rounded,
      'person' || 'profile' => Icons.person_rounded,
      _ => Icons.extension_rounded,
    };
  }
}

/// Extra chrome regions themes may disable or decorate beyond [FeatureSlots].
abstract final class ThemeChromeSlots {
  static const feedAssistant = 'chrome.feed.assistant';
  static const feedComposer = 'chrome.feed.composer';
  static const workspaceHeader = 'chrome.workspace.header';
  static const workspaceRail = 'chrome.workspace.rail';
  static const floatingAppBar = 'chrome.floating_app_bar';
  static const homeTabBar = 'chrome.home.tab_bar';
  static const callOverlay = 'chrome.calls.overlay';

  static const known = <String>{
    feedAssistant,
    feedComposer,
    workspaceHeader,
    workspaceRail,
    floatingAppBar,
    homeTabBar,
    callOverlay,
  };

  static bool isKnown(String id) => known.contains(id);
}

/// Maps chrome aliases ↔ feature slots so packs can disable either id.
abstract final class ThemeSlotAliases {
  static const _pairs = <String, String>{
    ThemeChromeSlots.workspaceHeader: FeatureSlots.workspaceHeader,
    ThemeChromeSlots.workspaceRail: FeatureSlots.workspaceRail,
    ThemeChromeSlots.feedComposer: FeatureSlots.homeComposer,
    ThemeChromeSlots.floatingAppBar: FeatureSlots.workspaceHeader,
  };

  static String canonical(String slot) => _pairs[slot] ?? slot;

  static Set<String> equivalents(String slot) {
    final canon = canonical(slot);
    final out = <String>{canon, slot};
    for (final e in _pairs.entries) {
      if (e.key == slot ||
          e.value == slot ||
          e.value == canon ||
          e.key == canon) {
        out.add(e.key);
        out.add(e.value);
      }
    }
    return out;
  }
}

/// Theme-declared UI composition: disable built-ins, attach Elpian surfaces,
/// and/or contribute new working islands (pages / tabs / panels).
@immutable
class ThemeUiSpec {
  const ThemeUiSpec({
    this.disabled = const {},
    this.surfaces = const {},
    this.islands = const {},
  });

  /// Slot / chrome ids that must not render (even prebuilt ones).
  final Set<String> disabled;

  /// Elpian surfaces keyed by slot id.
  final Map<String, ThemeSurfaceSpec> surfaces;

  /// New UI sections / pages contributed by the pack (`island.*`).
  final Map<String, ThemeIslandSpec> islands;

  bool get isEmpty =>
      disabled.isEmpty && surfaces.isEmpty && islands.isEmpty;

  bool isDisabled(String slot) {
    for (final id in ThemeSlotAliases.equivalents(slot)) {
      if (disabled.contains(id)) return true;
    }
    return false;
  }

  ThemeSurfaceSpec? surfaceFor(String slot) {
    for (final id in ThemeSlotAliases.equivalents(slot)) {
      final surface = surfaces[id];
      if (surface != null) return surface;
    }
    return null;
  }

  ThemeIslandSpec? islandFor(String id) => islands[id];

  List<ThemeIslandSpec> islandsFor(ThemeIslandPlacement placement) => [
        for (final island in islands.values)
          if (island.placement == placement && !isDisabled(island.id)) island,
      ];

  ThemeUiSpec copyWith({
    Set<String>? disabled,
    Map<String, ThemeSurfaceSpec>? surfaces,
    Map<String, ThemeIslandSpec>? islands,
  }) =>
      ThemeUiSpec(
        disabled: disabled ?? this.disabled,
        surfaces: surfaces ?? this.surfaces,
        islands: islands ?? this.islands,
      );

  Map<String, dynamic> toJson() {
    if (isEmpty) return const {};
    return {
      if (disabled.isNotEmpty) 'disabled': disabled.toList()..sort(),
      if (surfaces.isNotEmpty)
        'surfaces': {
          for (final e in surfaces.entries) e.key: e.value.toJson(),
        },
      if (islands.isNotEmpty)
        'islands': {
          for (final e in islands.entries) e.key: e.value.toJson(),
        },
    };
  }

  factory ThemeUiSpec.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const ThemeUiSpec();
    final disabled = <String>{};
    final rawDisabled = json['disabled'] ?? json['hide'] ?? json['hidden'];
    if (rawDisabled is List) {
      for (final item in rawDisabled) {
        final id = '$item'.trim();
        if (id.isEmpty) continue;
        if (FeatureSlots.isKnown(id) ||
            ThemeChromeSlots.isKnown(id) ||
            id.startsWith('chrome.') ||
            id.startsWith('island.') ||
            id.contains('.')) {
          disabled.add(id);
        }
      }
    }
    final surfaces = <String, ThemeSurfaceSpec>{};
    final rawSurfaces = json['surfaces'] ?? json['panels'];
    if (rawSurfaces is Map) {
      for (final e in rawSurfaces.entries) {
        final key = '${e.key}'.trim();
        if (key.isEmpty || e.value is! Map) continue;
        final spec = ThemeSurfaceSpec.fromJson(
          key,
          Map<String, dynamic>.from(e.value as Map),
        );
        if (spec.slot.isEmpty || spec.isEmpty) continue;
        surfaces[spec.slot] = spec;
      }
    }
    final islands = <String, ThemeIslandSpec>{};
    final rawIslands = json['islands'] ?? json['plugins'] ?? json['pages'];
    if (rawIslands is Map) {
      for (final e in rawIslands.entries) {
        final key = '${e.key}'.trim();
        if (key.isEmpty || e.value is! Map) continue;
        final island = ThemeIslandSpec.fromJson(
          key,
          Map<String, dynamic>.from(e.value as Map),
        );
        if (island.isEmpty) continue;
        islands[island.id] = island;
      }
    }
    return ThemeUiSpec(
      disabled: disabled,
      surfaces: surfaces,
      islands: islands,
    );
  }
}
