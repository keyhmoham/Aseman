import 'package:flutter/material.dart';

import 'aseman_tokens.dart';
import 'shell_layout.dart';
import 'theme_ui_spec.dart';

/// Resolves registered feature slots against a theme pack's shell spec.
///
/// Themes can only place widgets for [FeatureSlots.known] ids. Builders
/// supply the concrete feature widgets; unknown/missing slots are skipped.
class ShellSlotRegistry {
  ShellSlotRegistry(Map<String, WidgetBuilder> builders)
      : _builders = Map.unmodifiable(builders);

  final Map<String, WidgetBuilder> _builders;

  Widget? build(BuildContext context, String slot) {
    if (!FeatureSlots.isKnown(slot)) return null;
    final builder = _builders[slot];
    if (builder == null) return null;
    return builder(context);
  }

  List<Widget> buildAll(BuildContext context, Iterable<String> slots) {
    final out = <Widget>[];
    for (final slot in slots) {
      final child = build(context, slot);
      if (child != null) out.add(child);
    }
    return out;
  }
}

/// Reads [AsemanTokens.shell] for the active pack (defaults to Sky shell).
ShellLayoutSpec shellOf(BuildContext context) =>
    AsemanTokens.maybeOf(context)?.shell ?? const ShellLayoutSpec();

/// Label + icon metadata for known home phone tabs.
class ShellTabMeta {
  const ShellTabMeta(this.slot, this.label, this.icon);

  final String slot;
  final String label;
  final IconData icon;

  static const home = <String, ShellTabMeta>{
    FeatureSlots.homeChats:
        ShellTabMeta(FeatureSlots.homeChats, 'Chats', Icons.forum_rounded),
    FeatureSlots.homeExplore: ShellTabMeta(
        FeatureSlots.homeExplore, 'Explore', Icons.travel_explore_rounded),
    FeatureSlots.homeYou:
        ShellTabMeta(FeatureSlots.homeYou, 'You', Icons.person_rounded),
  };

  static const store = <String, ShellTabMeta>{
    FeatureSlots.storeLibrary: ShellTabMeta(
        FeatureSlots.storeLibrary, 'Library', Icons.grid_view_rounded),
    FeatureSlots.storeDiscover: ShellTabMeta(
        FeatureSlots.storeDiscover, 'Discover', Icons.travel_explore_rounded),
    FeatureSlots.storeThemes: ShellTabMeta(
        FeatureSlots.storeThemes, 'Themes', Icons.palette_rounded),
  };

  static const settings = <String, ShellTabMeta>{
    FeatureSlots.settingsAppearance: ShellTabMeta(
        FeatureSlots.settingsAppearance,
        'Appearance',
        Icons.palette_outlined),
    FeatureSlots.settingsAccount: ShellTabMeta(
        FeatureSlots.settingsAccount, 'Account', Icons.person_outline_rounded),
    FeatureSlots.settingsNotifications: ShellTabMeta(
        FeatureSlots.settingsNotifications,
        'Notifications',
        Icons.notifications_outlined),
    FeatureSlots.settingsAdvanced: ShellTabMeta(
        FeatureSlots.settingsAdvanced, 'Advanced', Icons.tune_rounded),
  };
}

List<String> _enabled(BuildContext context, Iterable<String> slots) {
  final ui = AsemanTokens.maybeOf(context)?.ui;
  if (ui == null || ui.disabled.isEmpty) return slots.toList();
  return [for (final s in slots) if (!ui.isDisabled(s)) s];
}

/// Ordered store tab metas from the active shell (unknown / disabled dropped).
List<ShellTabMeta> storeTabsOf(BuildContext context) {
  final tabs = _enabled(context, shellOf(context).store.resolvedTabs);
  return [
    for (final id in tabs)
      if (ShellTabMeta.store[id] != null) ShellTabMeta.store[id]!,
  ];
}

/// Ordered settings section metas from the active shell.
List<ShellTabMeta> settingsSectionsOf(BuildContext context) {
  final sections = _enabled(context, shellOf(context).settings.resolvedSections);
  return [
    for (final id in sections)
      if (ShellTabMeta.settings[id] != null) ShellTabMeta.settings[id]!,
  ];
}

/// Ordered home phone tab metas from the active shell (built-ins + islands).
List<ShellTabMeta> homePhoneTabsOf(BuildContext context) {
  final ui = AsemanTokens.maybeOf(context)?.ui ?? const ThemeUiSpec();
  final tabs = _enabled(context, shellOf(context).home.resolvedPhoneTabs);
  final out = <ShellTabMeta>[];
  for (final id in tabs) {
    final builtin = ShellTabMeta.home[id];
    if (builtin != null) {
      out.add(builtin);
      continue;
    }
    final island = ui.islandFor(id);
    if (island != null && island.placement == ThemeIslandPlacement.homeTab) {
      out.add(ShellTabMeta(island.id, island.title, island.iconData));
    }
  }
  // Islands declared as home tabs but not yet listed in shell.phone_tabs.
  for (final island in ui.islandsFor(ThemeIslandPlacement.homeTab)) {
    if (out.any((t) => t.slot == island.id)) continue;
    out.add(ShellTabMeta(island.id, island.title, island.iconData));
  }
  return out;
}

/// Ordered profile menu entry slot ids from the active shell (+ theme islands).
List<String> profileEntriesOf(BuildContext context) {
  final ui = AsemanTokens.maybeOf(context)?.ui ?? const ThemeUiSpec();
  final entries = _enabled(context, shellOf(context).profile.resolvedEntries);
  final out = [...entries];
  for (final island in ui.islandsFor(ThemeIslandPlacement.profile)) {
    if (!out.contains(island.id)) out.add(island.id);
  }
  return out;
}
