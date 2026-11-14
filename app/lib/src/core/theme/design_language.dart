import 'package:flutter/material.dart';

import 'theme_pack.dart';

/// How corners are drawn for a control family.
enum ShapeKind {
  /// Continuous rounded rectangle (Material default).
  rounded,

  /// Fully pill / stadium.
  stadium,

  /// Near-squircle: large continuous radius relative to size.
  squircle,

  /// Hard corners (neo-brutal / dense modern).
  sharp,

  /// Cut / chamfered corners via BeveledRectangleBorder.
  cut,
}

/// How a control is filled.
enum FillKind {
  solid,
  tonal,
  outline,
  glass,
  gradient,
  text,
}

/// Ink / press feedback language.
enum InkKind {
  ripple,
  highlight,
  none,
}

/// Named accent role for fills, borders, and glows.
enum AccentRole {
  primary,
  secondary,
  surface,
  onSurface,
  success,
  warning,
  danger,
  custom,
}

/// Motion curve tokens packs can declare without shipping Dart.
enum MotionCurveKind {
  standard,
  emphasized,
  decelerate,
  accelerate,
  linear,
  spring,
}

/// First-class design language for a theme pack.
///
/// Presets cover mainstream systems; `custom` (or any unknown id) uses the
/// recipes in this object as the source of truth so modern/custom languages
/// can reshape every control family without shipping Dart.
@immutable
class DesignLanguage {
  const DesignLanguage({
    this.id = materialExpressive,
    this.label = 'Material Expressive',
    this.button = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.solid,
      radius: 999,
      paddingH: 20,
      paddingV: 14,
      ink: InkKind.ripple,
    ),
    this.chip = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.tonal,
      radius: 999,
      paddingH: 6,
      paddingV: 6,
      ink: InkKind.ripple,
    ),
    this.input = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.tonal,
      radius: 16,
      borderWidth: 0,
      ink: InkKind.none,
    ),
    this.card = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.solid,
      radius: 20,
      borderWidth: 1,
      borderAlpha: 0.28,
      elevation: 0,
      accentRole: AccentRole.surface,
    ),
    this.sheet = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.glass,
      radius: 24,
      elevation: 0,
    ),
    this.fab = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.solid,
      radius: 16,
      elevation: 3,
      ink: InkKind.ripple,
    ),
    this.navPill = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.glass,
      radius: 999,
      elevation: 0,
    ),
    this.dialog = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.glass,
      radius: 28,
    ),
    this.menu = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.glass,
      radius: 16,
      borderWidth: 1,
      borderAlpha: 0.4,
    ),
    this.chatBubble = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.tonal,
      radius: 20,
      paddingH: 14,
      paddingV: 10,
    ),
    this.panelHeader = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.glass,
      radius: 20,
    ),
    this.toggle = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.solid,
      radius: 999,
      borderWidth: 0,
      ink: InkKind.ripple,
      minHeight: 32,
    ),
    this.slider = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.solid,
      radius: 999,
      borderWidth: 0,
      elevation: 1,
      minHeight: 4,
    ),
    this.avatar = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.tonal,
      radius: 999,
    ),
    this.listTile = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.tonal,
      radius: 12,
      paddingH: 12,
      paddingV: 10,
      ink: InkKind.ripple,
    ),
    this.badge = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.solid,
      radius: 999,
      paddingH: 6,
      paddingV: 2,
    ),
    this.tooltip = const ControlRecipe(
      shape: ShapeKind.rounded,
      fill: FillKind.solid,
      radius: 8,
      paddingH: 10,
      paddingV: 6,
      elevation: 4,
    ),
    this.tab = const ControlRecipe(
      shape: ShapeKind.stadium,
      fill: FillKind.tonal,
      radius: 999,
      paddingH: 14,
      paddingV: 8,
    ),
    this.divider = const ControlRecipe(
      shape: ShapeKind.sharp,
      fill: FillKind.solid,
      radius: 0,
      borderWidth: 1,
      borderAlpha: 0.35,
      minHeight: 1,
    ),
    this.extras = const {},
    this.shadow = const ShadowRecipe(),
    this.interaction = const InteractionRecipe(),
    this.iconSize = 22,
    this.controlHeight = 48,
    this.denseControlHeight = 40,
  });

  static const materialExpressive = 'material_expressive';
  static const material = 'material';
  static const fluent = 'fluent';
  static const cupertino = 'cupertino';
  static const glass = 'glass';
  static const flat = 'flat';
  static const neoBrutal = 'neo_brutal';
  static const denseModern = 'dense_modern';
  static const custom = 'custom';

  final String id;
  final String label;
  final ControlRecipe button;
  final ControlRecipe chip;
  final ControlRecipe input;
  final ControlRecipe card;
  final ControlRecipe sheet;
  final ControlRecipe fab;
  final ControlRecipe navPill;
  final ControlRecipe dialog;
  final ControlRecipe menu;
  final ControlRecipe chatBubble;
  final ControlRecipe panelHeader;

  /// Switch / checkbox / radio selection controls.
  final ControlRecipe toggle;

  /// Continuous value controls (slider / linear progress).
  final ControlRecipe slider;
  final ControlRecipe avatar;
  final ControlRecipe listTile;
  final ControlRecipe badge;
  final ControlRecipe tooltip;
  final ControlRecipe tab;
  final ControlRecipe divider;

  /// Arbitrary extra slots (`components`-style overrides at language level).
  final Map<String, ControlRecipe> extras;
  final ShadowRecipe shadow;
  final InteractionRecipe interaction;
  final double iconSize;
  final double controlHeight;
  final double denseControlHeight;

  ControlRecipe recipeFor(String slot) {
    final known = switch (slot) {
      'button' || 'filled_button' || 'outlined_button' => button,
      'chip' => chip,
      'input' || 'field' => input,
      'card' => card,
      'sheet' || 'bottom_sheet' => sheet,
      'fab' => fab,
      'nav_pill' || 'navPill' => navPill,
      'dialog' => dialog,
      'menu' || 'popup' => menu,
      'chat_bubble' || 'chatBubble' => chatBubble,
      'panel_header' || 'panelHeader' => panelHeader,
      'toggle' ||
      'switch' ||
      'checkbox' ||
      'radio' ||
      'selection' =>
        toggle,
      'slider' || 'progress' || 'progress_indicator' => slider,
      'avatar' => avatar,
      'list_tile' || 'listTile' || 'tile' => listTile,
      'badge' => badge,
      'tooltip' => tooltip,
      'tab' || 'tabs' => tab,
      'divider' => divider,
      _ => null,
    };
    if (known != null) return known;
    return extras[slot] ?? card;
  }

  /// Merge a component override onto the language default for [slot].
  ControlRecipe resolve(String slot, ComponentStyle? override) {
    final base = recipeFor(slot);
    if (override == null) return base;
    return base.mergeStyle(override);
  }

  DesignLanguage copyWith({
    String? id,
    String? label,
    ControlRecipe? button,
    ControlRecipe? chip,
    ControlRecipe? input,
    ControlRecipe? card,
    ControlRecipe? sheet,
    ControlRecipe? fab,
    ControlRecipe? navPill,
    ControlRecipe? dialog,
    ControlRecipe? menu,
    ControlRecipe? chatBubble,
    ControlRecipe? panelHeader,
    ControlRecipe? toggle,
    ControlRecipe? slider,
    ControlRecipe? avatar,
    ControlRecipe? listTile,
    ControlRecipe? badge,
    ControlRecipe? tooltip,
    ControlRecipe? tab,
    ControlRecipe? divider,
    Map<String, ControlRecipe>? extras,
    ShadowRecipe? shadow,
    InteractionRecipe? interaction,
    double? iconSize,
    double? controlHeight,
    double? denseControlHeight,
  }) =>
      DesignLanguage(
        id: id ?? this.id,
        label: label ?? this.label,
        button: button ?? this.button,
        chip: chip ?? this.chip,
        input: input ?? this.input,
        card: card ?? this.card,
        sheet: sheet ?? this.sheet,
        fab: fab ?? this.fab,
        navPill: navPill ?? this.navPill,
        dialog: dialog ?? this.dialog,
        menu: menu ?? this.menu,
        chatBubble: chatBubble ?? this.chatBubble,
        panelHeader: panelHeader ?? this.panelHeader,
        toggle: toggle ?? this.toggle,
        slider: slider ?? this.slider,
        avatar: avatar ?? this.avatar,
        listTile: listTile ?? this.listTile,
        badge: badge ?? this.badge,
        tooltip: tooltip ?? this.tooltip,
        tab: tab ?? this.tab,
        divider: divider ?? this.divider,
        extras: extras ?? this.extras,
        shadow: shadow ?? this.shadow,
        interaction: interaction ?? this.interaction,
        iconSize: iconSize ?? this.iconSize,
        controlHeight: controlHeight ?? this.controlHeight,
        denseControlHeight: denseControlHeight ?? this.denseControlHeight,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'button': button.toJson(),
        'chip': chip.toJson(),
        'input': input.toJson(),
        'card': card.toJson(),
        'sheet': sheet.toJson(),
        'fab': fab.toJson(),
        'nav_pill': navPill.toJson(),
        'dialog': dialog.toJson(),
        'menu': menu.toJson(),
        'chat_bubble': chatBubble.toJson(),
        'panel_header': panelHeader.toJson(),
        'toggle': toggle.toJson(),
        'slider': slider.toJson(),
        'avatar': avatar.toJson(),
        'list_tile': listTile.toJson(),
        'badge': badge.toJson(),
        'tooltip': tooltip.toJson(),
        'tab': tab.toJson(),
        'divider': divider.toJson(),
        if (extras.isNotEmpty)
          'extras': {for (final e in extras.entries) e.key: e.value.toJson()},
        'shadow': shadow.toJson(),
        'interaction': interaction.toJson(),
        'icon_size': iconSize,
        'control_height': controlHeight,
        'dense_control_height': denseControlHeight,
      };

  factory DesignLanguage.fromJson(Map<String, dynamic> json) {
    final id = '${json['id'] ?? materialExpressive}';
    final preset = presetOf(id);
    ControlRecipe read(String key, ControlRecipe fallback) => json[key] is Map
        ? ControlRecipe.fromJson(
            Map<String, dynamic>.from(json[key] as Map), fallback)
        : fallback;
    final extras = <String, ControlRecipe>{};
    final extrasRaw = json['extras'];
    if (extrasRaw is Map) {
      for (final e in extrasRaw.entries) {
        if (e.value is Map) {
          extras['${e.key}'] = ControlRecipe.fromJson(
            Map<String, dynamic>.from(e.value as Map),
          );
        }
      }
    }
    return DesignLanguage(
      id: id,
      label: '${json['label'] ?? preset.label}',
      button: read('button', preset.button),
      chip: read('chip', preset.chip),
      input: read('input', preset.input),
      card: read('card', preset.card),
      sheet: read('sheet', preset.sheet),
      fab: read('fab', preset.fab),
      navPill: read('nav_pill', preset.navPill),
      dialog: read('dialog', preset.dialog),
      menu: read('menu', preset.menu),
      chatBubble: read('chat_bubble', preset.chatBubble),
      panelHeader: read('panel_header', preset.panelHeader),
      toggle: read('toggle', preset.toggle),
      slider: read('slider', preset.slider),
      avatar: read('avatar', preset.avatar),
      listTile: read('list_tile', preset.listTile),
      badge: read('badge', preset.badge),
      tooltip: read('tooltip', preset.tooltip),
      tab: read('tab', preset.tab),
      divider: read('divider', preset.divider),
      extras: extras.isEmpty ? preset.extras : extras,
      shadow: json['shadow'] is Map
          ? ShadowRecipe.fromJson(
              Map<String, dynamic>.from(json['shadow'] as Map))
          : preset.shadow,
      interaction: json['interaction'] is Map
          ? InteractionRecipe.fromJson(
              Map<String, dynamic>.from(json['interaction'] as Map))
          : preset.interaction,
      iconSize: parseDouble(json['icon_size'], preset.iconSize),
      controlHeight: parseDouble(json['control_height'], preset.controlHeight),
      denseControlHeight:
          parseDouble(json['dense_control_height'], preset.denseControlHeight),
    );
  }

  /// Named presets. Unknown ids start from Material Expressive so custom
  /// packs can override only the recipes they care about.
  static DesignLanguage presetOf(String id) => switch (id) {
        material => const DesignLanguage(
            id: material,
            label: 'Material 3',
            button: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 20,
              paddingH: 24,
              paddingV: 12,
            ),
            chip: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 8,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 12,
              borderWidth: 1,
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 16,
              borderWidth: 1,
              borderAlpha: 0.22,
              elevation: 0,
              accentRole: AccentRole.surface,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 16,
              elevation: 3,
            ),
            navPill: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 16,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 16,
              ink: InkKind.ripple,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.solid,
              radius: 999,
              minHeight: 4,
            ),
            chatBubble: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 16,
              paddingH: 14,
              paddingV: 10,
              accentRole: AccentRole.surface,
            ),
          ),
        fluent => const DesignLanguage(
            id: fluent,
            label: 'Fluent',
            button: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              paddingH: 16,
              paddingV: 10,
              ink: InkKind.highlight,
              motion: ControlMotion(
                durationMs: 120,
                curve: MotionCurveKind.decelerate,
                pressScale: 0.98,
                hoverLift: 1,
              ),
              typography: ControlTypography(weight: 600, size: 13),
              states: ControlStates(
                hovered: ControlStateStyle(elevation: 2),
                pressed: ControlStateStyle(elevation: 0, scale: 0.98),
                disabled: ControlStateStyle(opacity: 0.4),
              ),
            ),
            chip: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.outline,
              radius: 4,
              borderWidth: 1,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              borderWidth: 1,
              borderAlpha: 0.55,
              effects: ControlEffects(focusRing: 2, focusRingAlpha: 0.45),
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              elevation: 0,
              borderWidth: 1,
              borderAlpha: 0.22,
              accentRole: AccentRole.surface,
              motion: ControlMotion(hoverLift: 1, durationMs: 160),
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              elevation: 2,
            ),
            navPill: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 4,
            ),
            dialog: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              elevation: 8,
            ),
            menu: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              elevation: 4,
              borderWidth: 1,
              borderAlpha: 0.25,
            ),
            chatBubble: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              borderWidth: 1,
              borderAlpha: 0.2,
              paddingH: 12,
              paddingV: 8,
            ),
            panelHeader: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              borderWidth: 1,
              borderAlpha: 0.2,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 2,
              borderWidth: 1,
              borderAlpha: 0.4,
              ink: InkKind.highlight,
              minHeight: 20,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 2,
              minHeight: 4,
              elevation: 0,
            ),
            avatar: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 4,
            ),
            shadow: ShadowRecipe(blur: 12, y: 4, alpha: 0.18),
            interaction: InteractionRecipe(
              ink: InkKind.highlight,
              pressScale: 0.98,
            ),
            controlHeight: 32,
            denseControlHeight: 28,
            iconSize: 16,
          ),
        cupertino => const DesignLanguage(
            id: cupertino,
            label: 'Cupertino',
            button: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 12,
              paddingH: 18,
              paddingV: 12,
              ink: InkKind.highlight,
            ),
            chip: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.tonal,
              radius: 999,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 10,
              borderWidth: 0,
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 14,
              elevation: 0,
              borderWidth: 0,
              accentRole: AccentRole.surface,
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 14,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.solid,
              radius: 999,
            ),
            navPill: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.tonal,
              radius: 999,
            ),
            dialog: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 14,
            ),
            chatBubble: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 18,
              paddingH: 14,
              paddingV: 10,
              accentRole: AccentRole.surface,
            ),
            panelHeader: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 14,
              accentRole: AccentRole.surface,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.solid,
              radius: 999,
              ink: InkKind.highlight,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.solid,
              radius: 999,
              minHeight: 4,
            ),
            interaction: InteractionRecipe(
              ink: InkKind.highlight,
              pressScale: 0.97,
            ),
            controlHeight: 44,
            denseControlHeight: 36,
          ),
        glass => const DesignLanguage(
            id: glass,
            label: 'Glass',
            button: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.glass,
              radius: 999,
              borderWidth: 1,
              borderAlpha: 0.35,
            ),
            chip: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.glass,
              radius: 999,
              borderWidth: 1,
              borderAlpha: 0.3,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.glass,
              radius: 18,
              borderWidth: 1,
              borderAlpha: 0.25,
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.glass,
              radius: 28,
              borderWidth: 1,
              borderAlpha: 0.4,
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.glass,
              radius: 28,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 18,
              elevation: 3,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.glass,
              radius: 999,
              borderWidth: 1,
              borderAlpha: 0.35,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.stadium,
              fill: FillKind.glass,
              radius: 999,
              minHeight: 6,
            ),
            shadow: ShadowRecipe(blur: 24, y: 10, alpha: 0.16),
          ),
        flat => const DesignLanguage(
            id: flat,
            label: 'Flat',
            button: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              elevation: 0,
              ink: InkKind.highlight,
            ),
            chip: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 6,
              elevation: 0,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              borderWidth: 1,
              borderAlpha: 0.35,
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 12,
              elevation: 0,
              borderWidth: 1,
              borderAlpha: 0.25,
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 12,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 12,
              elevation: 0,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              borderWidth: 1,
              borderAlpha: 0.35,
              ink: InkKind.highlight,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 4,
              minHeight: 4,
              elevation: 0,
            ),
            shadow: ShadowRecipe(blur: 0, y: 0, alpha: 0),
            interaction: InteractionRecipe(ink: InkKind.highlight),
          ),
        neoBrutal => const DesignLanguage(
            id: neoBrutal,
            label: 'Neo-brutal',
            button: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
              paddingH: 18,
              paddingV: 12,
              elevation: 0,
              ink: InkKind.none,
              motion: ControlMotion(
                durationMs: 90,
                curve: MotionCurveKind.linear,
                pressScale: 0.97,
              ),
              effects: ControlEffects(focusRing: 0),
              typography: ControlTypography(
                weight: 800,
                letterSpacing: 0.2,
                allCaps: true,
              ),
              states: ControlStates(
                pressed: ControlStateStyle(scale: 0.96, elevation: 0),
                hovered: ControlStateStyle(glow: 0),
                selected: ControlStateStyle(
                  accentRole: AccentRole.secondary,
                  borderWidth: 3,
                ),
              ),
            ),
            chip: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.outline,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
            ),
            input: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
            ),
            card: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
              elevation: 0,
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
            ),
            navPill: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
            ),
            dialog: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
            ),
            menu: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
            ),
            chatBubble: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.tonal,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
              paddingH: 14,
              paddingV: 10,
            ),
            panelHeader: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
              ink: InkKind.none,
              minHeight: 28,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.solid,
              radius: 0,
              borderWidth: 2,
              borderAlpha: 1,
              minHeight: 8,
              elevation: 0,
            ),
            avatar: ControlRecipe(
              shape: ShapeKind.sharp,
              fill: FillKind.tonal,
              radius: 0,
            ),
            shadow: ShadowRecipe(blur: 0, y: 4, x: 4, alpha: 1, hard: true),
            interaction: InteractionRecipe(
              ink: InkKind.none,
              pressScale: 0.99,
            ),
            controlHeight: 48,
          ),
        denseModern => const DesignLanguage(
            id: denseModern,
            label: 'Dense modern',
            button: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 10,
              paddingH: 14,
              paddingV: 8,
            ),
            chip: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 8,
              paddingH: 8,
              paddingV: 4,
            ),
            input: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 10,
            ),
            card: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 14,
              elevation: 0,
              borderWidth: 1,
              borderAlpha: 0.28,
            ),
            sheet: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 16,
            ),
            fab: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 12,
            ),
            navPill: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.tonal,
              radius: 12,
            ),
            toggle: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 10,
              ink: InkKind.ripple,
              minHeight: 28,
            ),
            slider: ControlRecipe(
              shape: ShapeKind.rounded,
              fill: FillKind.solid,
              radius: 8,
              minHeight: 3,
            ),
            controlHeight: 40,
            denseControlHeight: 32,
            iconSize: 18,
          ),
        custom => const DesignLanguage(
            id: custom,
            label: 'Custom',
          ),
        _ => const DesignLanguage(),
      };

  static List<DesignLanguage> get presets => [
        presetOf(materialExpressive),
        presetOf(material),
        presetOf(fluent),
        presetOf(cupertino),
        presetOf(glass),
        presetOf(flat),
        presetOf(neoBrutal),
        presetOf(denseModern),
        presetOf(custom),
      ];
}

/// Declarative gradient stop for pack fills / sheens.
@immutable
class GradientStopSpec {
  const GradientStopSpec({required this.color, this.stop});

  final Color color;
  final double? stop;

  Map<String, dynamic> toJson() => {
        'color': colorToHex(color),
        if (stop != null) 'stop': stop,
      };

  factory GradientStopSpec.fromJson(Map<String, dynamic> json) =>
      GradientStopSpec(
        color: parseColor(json['color']) ?? const Color(0xFF3B82F6),
        stop: json['stop'] == null ? null : parseDouble(json['stop'], 0),
      );
}

@immutable
class GradientSpec {
  const GradientSpec({
    this.stops = const [],
    this.beginX = -1,
    this.beginY = -1,
    this.endX = 1,
    this.endY = 1,
    this.radial = false,
  });

  final List<GradientStopSpec> stops;
  final double beginX;
  final double beginY;
  final double endX;
  final double endY;
  final bool radial;

  bool get isEmpty => stops.length < 2;

  Gradient? toGradient() {
    if (isEmpty) return null;
    final colors = [for (final s in stops) s.color];
    final hasStops = stops.every((s) => s.stop != null);
    final positions =
        hasStops ? [for (final s in stops) s.stop!.clamp(0.0, 1.0)] : null;
    if (radial) {
      return RadialGradient(
        colors: colors,
        stops: positions,
        center: Alignment(beginX, beginY),
        radius: 1.1,
      );
    }
    return LinearGradient(
      begin: Alignment(beginX, beginY),
      end: Alignment(endX, endY),
      colors: colors,
      stops: positions,
    );
  }

  Map<String, dynamic> toJson() => {
        'stops': stops.map((s) => s.toJson()).toList(),
        'begin': [beginX, beginY],
        'end': [endX, endY],
        if (radial) 'radial': true,
      };

  factory GradientSpec.fromJson(Map<String, dynamic> json) {
    final stops = <GradientStopSpec>[];
    final raw = json['stops'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          stops.add(
              GradientStopSpec.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    List<double> pair(Object? v, double a, double b) {
      if (v is List && v.length >= 2) {
        return [parseDouble(v[0], a), parseDouble(v[1], b)];
      }
      return [a, b];
    }

    final begin = pair(json['begin'], -1, -1);
    final end = pair(json['end'], 1, 1);
    return GradientSpec(
      stops: stops,
      beginX: begin[0],
      beginY: begin[1],
      endX: end[0],
      endY: end[1],
      radial: json['radial'] == true,
    );
  }
}

/// Graphical effects layered on a control (glow, blur, sheen, grain…).
@immutable
class ControlEffects {
  const ControlEffects({
    this.opacity = 1,
    this.blur = 0,
    this.glow = 0,
    this.glowSpread = 0,
    this.sheen = 0,
    this.grain = 0,
    this.saturate = 1,
    this.contrast = 1,
    this.parallax = 0,
    this.focusRing = 0,
    this.focusRingAlpha = 0.35,
    this.backdropBlur = 0,
  });

  final double opacity;
  final double blur;
  final double glow;
  final double glowSpread;
  final double sheen;
  final double grain;
  final double saturate;
  final double contrast;
  final double parallax;
  final double focusRing;
  final double focusRingAlpha;
  final double backdropBlur;

  bool get isIdentity =>
      opacity == 1 &&
      blur <= 0 &&
      glow <= 0 &&
      sheen <= 0 &&
      grain <= 0 &&
      saturate == 1 &&
      contrast == 1 &&
      parallax <= 0 &&
      focusRing <= 0 &&
      backdropBlur <= 0;

  ControlEffects copyWith({
    double? opacity,
    double? blur,
    double? glow,
    double? glowSpread,
    double? sheen,
    double? grain,
    double? saturate,
    double? contrast,
    double? parallax,
    double? focusRing,
    double? focusRingAlpha,
    double? backdropBlur,
  }) =>
      ControlEffects(
        opacity: opacity ?? this.opacity,
        blur: blur ?? this.blur,
        glow: glow ?? this.glow,
        glowSpread: glowSpread ?? this.glowSpread,
        sheen: sheen ?? this.sheen,
        grain: grain ?? this.grain,
        saturate: saturate ?? this.saturate,
        contrast: contrast ?? this.contrast,
        parallax: parallax ?? this.parallax,
        focusRing: focusRing ?? this.focusRing,
        focusRingAlpha: focusRingAlpha ?? this.focusRingAlpha,
        backdropBlur: backdropBlur ?? this.backdropBlur,
      );

  ControlEffects merge(ControlEffects? other) {
    if (other == null) return this;
    return copyWith(
      opacity: other.opacity != 1 ? other.opacity : opacity,
      blur: other.blur > 0 ? other.blur : blur,
      glow: other.glow > 0 ? other.glow : glow,
      glowSpread: other.glowSpread > 0 ? other.glowSpread : glowSpread,
      sheen: other.sheen > 0 ? other.sheen : sheen,
      grain: other.grain > 0 ? other.grain : grain,
      saturate: other.saturate != 1 ? other.saturate : saturate,
      contrast: other.contrast != 1 ? other.contrast : contrast,
      parallax: other.parallax > 0 ? other.parallax : parallax,
      focusRing: other.focusRing > 0 ? other.focusRing : focusRing,
      focusRingAlpha:
          other.focusRing > 0 ? other.focusRingAlpha : focusRingAlpha,
      backdropBlur: other.backdropBlur > 0 ? other.backdropBlur : backdropBlur,
    );
  }

  Map<String, dynamic> toJson() => {
        if (opacity != 1) 'opacity': opacity,
        if (blur > 0) 'blur': blur,
        if (glow > 0) 'glow': glow,
        if (glowSpread > 0) 'glow_spread': glowSpread,
        if (sheen > 0) 'sheen': sheen,
        if (grain > 0) 'grain': grain,
        if (saturate != 1) 'saturate': saturate,
        if (contrast != 1) 'contrast': contrast,
        if (parallax > 0) 'parallax': parallax,
        if (focusRing > 0) 'focus_ring': focusRing,
        if (focusRingAlpha != 0.35) 'focus_ring_alpha': focusRingAlpha,
        if (backdropBlur > 0) 'backdrop_blur': backdropBlur,
      };

  factory ControlEffects.fromJson(Map<String, dynamic> json) => ControlEffects(
        opacity: parseDouble(json['opacity'], 1),
        blur: parseDouble(json['blur'], 0),
        glow: parseDouble(json['glow'], 0),
        glowSpread: parseDouble(json['glow_spread'], 0),
        sheen: parseDouble(json['sheen'], 0),
        grain: parseDouble(json['grain'], 0),
        saturate: parseDouble(json['saturate'], 1),
        contrast: parseDouble(json['contrast'], 1),
        parallax: parseDouble(json['parallax'], 0),
        focusRing: parseDouble(json['focus_ring'], 0),
        focusRingAlpha: parseDouble(json['focus_ring_alpha'], 0.35),
        backdropBlur: parseDouble(json['backdrop_blur'], 0),
      );
}

/// Per-control motion (press scale, hover lift, durations, curves).
@immutable
class ControlMotion {
  const ControlMotion({
    this.durationMs = 180,
    this.curve = MotionCurveKind.standard,
    this.pressScale = 1,
    this.hoverLift = 0,
    this.hoverScale = 1,
    this.enterOffsetY = 0,
    this.reduceMotion = false,
  });

  final int durationMs;
  final MotionCurveKind curve;
  final double pressScale;
  final double hoverLift;
  final double hoverScale;
  final double enterOffsetY;
  final bool reduceMotion;

  bool get isIdentity =>
      durationMs == 180 &&
      curve == MotionCurveKind.standard &&
      pressScale == 1 &&
      hoverLift == 0 &&
      hoverScale == 1 &&
      enterOffsetY == 0 &&
      !reduceMotion;

  Curve get flutterCurve => switch (curve) {
        MotionCurveKind.emphasized => Curves.easeInOutCubicEmphasized,
        MotionCurveKind.decelerate => Curves.easeOutCubic,
        MotionCurveKind.accelerate => Curves.easeInCubic,
        MotionCurveKind.linear => Curves.linear,
        MotionCurveKind.spring => Curves.elasticOut,
        MotionCurveKind.standard => Curves.easeOutCubic,
      };

  Duration get duration => Duration(milliseconds: durationMs.clamp(0, 2000));

  ControlMotion copyWith({
    int? durationMs,
    MotionCurveKind? curve,
    double? pressScale,
    double? hoverLift,
    double? hoverScale,
    double? enterOffsetY,
    bool? reduceMotion,
  }) =>
      ControlMotion(
        durationMs: durationMs ?? this.durationMs,
        curve: curve ?? this.curve,
        pressScale: pressScale ?? this.pressScale,
        hoverLift: hoverLift ?? this.hoverLift,
        hoverScale: hoverScale ?? this.hoverScale,
        enterOffsetY: enterOffsetY ?? this.enterOffsetY,
        reduceMotion: reduceMotion ?? this.reduceMotion,
      );

  ControlMotion merge(ControlMotion? other) {
    if (other == null) return this;
    return copyWith(
      durationMs: other.durationMs != 180 ? other.durationMs : durationMs,
      curve: other.curve != MotionCurveKind.standard ? other.curve : curve,
      pressScale: other.pressScale != 1 ? other.pressScale : pressScale,
      hoverLift: other.hoverLift != 0 ? other.hoverLift : hoverLift,
      hoverScale: other.hoverScale != 1 ? other.hoverScale : hoverScale,
      enterOffsetY: other.enterOffsetY != 0 ? other.enterOffsetY : enterOffsetY,
      reduceMotion: other.reduceMotion || reduceMotion,
    );
  }

  Map<String, dynamic> toJson() => {
        if (durationMs != 180) 'duration_ms': durationMs,
        if (curve != MotionCurveKind.standard) 'curve': curve.name,
        if (pressScale != 1) 'press_scale': pressScale,
        if (hoverLift != 0) 'hover_lift': hoverLift,
        if (hoverScale != 1) 'hover_scale': hoverScale,
        if (enterOffsetY != 0) 'enter_offset_y': enterOffsetY,
        if (reduceMotion) 'reduce_motion': true,
      };

  factory ControlMotion.fromJson(Map<String, dynamic> json) => ControlMotion(
        durationMs: parseInt(json['duration_ms'], 180),
        curve: _curve(json['curve']),
        pressScale: parseDouble(json['press_scale'], 1),
        hoverLift: parseDouble(json['hover_lift'], 0),
        hoverScale: parseDouble(json['hover_scale'], 1),
        enterOffsetY: parseDouble(json['enter_offset_y'], 0),
        reduceMotion: json['reduce_motion'] == true,
      );

  static MotionCurveKind _curve(Object? raw) {
    final s = '$raw';
    for (final v in MotionCurveKind.values) {
      if (v.name == s) return v;
    }
    return MotionCurveKind.standard;
  }
}

@immutable
class ControlTypography {
  const ControlTypography({
    this.size,
    this.weight,
    this.letterSpacing,
    this.height,
    this.allCaps = false,
    this.fontFamily = '',
  });

  final double? size;
  final int? weight;
  final double? letterSpacing;
  final double? height;
  final bool allCaps;
  final String fontFamily;

  bool get isEmpty =>
      size == null &&
      weight == null &&
      letterSpacing == null &&
      height == null &&
      !allCaps &&
      fontFamily.isEmpty;

  TextStyle apply(TextStyle base) {
    FontWeight? w;
    if (weight != null) {
      w = FontWeight.values.firstWhere(
        (x) => x.value == weight,
        orElse: () => FontWeight.w700,
      );
    }
    return base.copyWith(
      fontSize: size,
      fontWeight: w,
      letterSpacing: letterSpacing,
      height: height,
      fontFamily: fontFamily.isEmpty ? null : fontFamily,
    );
  }

  Map<String, dynamic> toJson() => {
        if (size != null) 'size': size,
        if (weight != null) 'weight': weight,
        if (letterSpacing != null) 'letter_spacing': letterSpacing,
        if (height != null) 'height': height,
        if (allCaps) 'all_caps': true,
        if (fontFamily.isNotEmpty) 'font_family': fontFamily,
      };

  factory ControlTypography.fromJson(Map<String, dynamic> json) =>
      ControlTypography(
        size: json['size'] == null ? null : parseDouble(json['size'], 14),
        weight: json['weight'] == null ? null : parseInt(json['weight'], 700),
        letterSpacing: json['letter_spacing'] == null
            ? null
            : parseDouble(json['letter_spacing'], 0),
        height: json['height'] == null ? null : parseDouble(json['height'], 1),
        allCaps: json['all_caps'] == true,
        fontFamily: '${json['font_family'] ?? ''}',
      );
}

@immutable
class ControlIconography {
  const ControlIconography({
    this.size,
    this.filled = false,
    this.weight,
    this.opticalSize,
  });

  final double? size;
  final bool filled;
  final double? weight;
  final double? opticalSize;

  bool get isEmpty =>
      size == null && !filled && weight == null && opticalSize == null;

  Map<String, dynamic> toJson() => {
        if (size != null) 'size': size,
        if (filled) 'filled': true,
        if (weight != null) 'weight': weight,
        if (opticalSize != null) 'optical_size': opticalSize,
      };

  factory ControlIconography.fromJson(Map<String, dynamic> json) =>
      ControlIconography(
        size: json['size'] == null ? null : parseDouble(json['size'], 22),
        filled: json['filled'] == true,
        weight: json['weight'] == null ? null : parseDouble(json['weight'], 400),
        opticalSize: json['optical_size'] == null
            ? null
            : parseDouble(json['optical_size'], 24),
      );
}

/// State deltas layered onto a base [ControlRecipe].
@immutable
class ControlStateStyle {
  const ControlStateStyle({
    this.fill,
    this.borderWidth,
    this.borderAlpha,
    this.elevation,
    this.opacity,
    this.scale,
    this.glow,
    this.accentRole,
  });

  final FillKind? fill;
  final double? borderWidth;
  final double? borderAlpha;
  final double? elevation;
  final double? opacity;
  final double? scale;
  final double? glow;
  final AccentRole? accentRole;

  bool get isEmpty =>
      fill == null &&
      borderWidth == null &&
      borderAlpha == null &&
      elevation == null &&
      opacity == null &&
      scale == null &&
      glow == null &&
      accentRole == null;

  Map<String, dynamic> toJson() => {
        if (fill != null) 'fill': fill!.name,
        if (borderWidth != null) 'border_width': borderWidth,
        if (borderAlpha != null) 'border_alpha': borderAlpha,
        if (elevation != null) 'elevation': elevation,
        if (opacity != null) 'opacity': opacity,
        if (scale != null) 'scale': scale,
        if (glow != null) 'glow': glow,
        if (accentRole != null) 'accent': accentRole!.name,
      };

  factory ControlStateStyle.fromJson(Map<String, dynamic> json) =>
      ControlStateStyle(
        fill: json['fill'] == null
            ? null
            : ControlRecipe._fill(json['fill'], FillKind.solid),
        borderWidth: json['border_width'] == null
            ? null
            : parseDouble(json['border_width'], 0),
        borderAlpha: json['border_alpha'] == null
            ? null
            : parseDouble(json['border_alpha'], 0),
        elevation: json['elevation'] == null
            ? null
            : parseDouble(json['elevation'], 0),
        opacity:
            json['opacity'] == null ? null : parseDouble(json['opacity'], 1),
        scale: json['scale'] == null ? null : parseDouble(json['scale'], 1),
        glow: json['glow'] == null ? null : parseDouble(json['glow'], 0),
        accentRole: _accent(json['accent']),
      );

  static AccentRole? _accent(Object? raw) {
    if (raw == null) return null;
    final s = '$raw';
    for (final v in AccentRole.values) {
      if (v.name == s) return v;
    }
    return null;
  }
}

@immutable
class ControlStates {
  const ControlStates({
    this.hovered = const ControlStateStyle(),
    this.pressed = const ControlStateStyle(),
    this.focused = const ControlStateStyle(),
    this.selected = const ControlStateStyle(),
    this.disabled = const ControlStateStyle(),
  });

  final ControlStateStyle hovered;
  final ControlStateStyle pressed;
  final ControlStateStyle focused;
  final ControlStateStyle selected;
  final ControlStateStyle disabled;

  bool get isEmpty =>
      hovered.isEmpty &&
      pressed.isEmpty &&
      focused.isEmpty &&
      selected.isEmpty &&
      disabled.isEmpty;

  ControlStateStyle forFlags({
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
    bool selected = false,
    bool disabled = false,
  }) {
    if (disabled) return this.disabled;
    if (pressed) return this.pressed;
    if (selected) return this.selected;
    if (focused) return this.focused;
    if (hovered) return this.hovered;
    return const ControlStateStyle();
  }

  Map<String, dynamic> toJson() => {
        if (!hovered.isEmpty) 'hovered': hovered.toJson(),
        if (!pressed.isEmpty) 'pressed': pressed.toJson(),
        if (!focused.isEmpty) 'focused': focused.toJson(),
        if (!selected.isEmpty) 'selected': selected.toJson(),
        if (!disabled.isEmpty) 'disabled': disabled.toJson(),
      };

  factory ControlStates.fromJson(Map<String, dynamic> json) {
    ControlStateStyle read(String key) => json[key] is Map
        ? ControlStateStyle.fromJson(Map<String, dynamic>.from(json[key] as Map))
        : const ControlStateStyle();
    return ControlStates(
      hovered: read('hovered'),
      pressed: read('pressed'),
      focused: read('focused'),
      selected: read('selected'),
      disabled: read('disabled'),
    );
  }
}

@immutable
class ControlRecipe {
  const ControlRecipe({
    this.shape = ShapeKind.rounded,
    this.fill = FillKind.solid,
    this.radius = 16,
    this.borderWidth = 0,
    this.borderAlpha = 0.4,
    this.elevation = 0,
    this.paddingH = 12,
    this.paddingV = 10,
    this.ink = InkKind.ripple,
    this.minHeight,
    this.maxWidth,
    this.accentRole = AccentRole.primary,
    this.gradient,
    this.effects = const ControlEffects(),
    this.motion = const ControlMotion(),
    this.typography = const ControlTypography(),
    this.iconography = const ControlIconography(),
    this.states = const ControlStates(),
    this.clip = true,
    this.labelsUppercase = false,
  });

  final ShapeKind shape;
  final FillKind fill;
  final double radius;
  final double borderWidth;
  final double borderAlpha;
  final double elevation;
  final double paddingH;
  final double paddingV;
  final InkKind ink;
  final double? minHeight;
  final double? maxWidth;
  final AccentRole accentRole;
  final GradientSpec? gradient;
  final ControlEffects effects;
  final ControlMotion motion;
  final ControlTypography typography;
  final ControlIconography iconography;
  final ControlStates states;
  final bool clip;
  final bool labelsUppercase;

  ControlRecipe copyWith({
    ShapeKind? shape,
    FillKind? fill,
    double? radius,
    double? borderWidth,
    double? borderAlpha,
    double? elevation,
    double? paddingH,
    double? paddingV,
    InkKind? ink,
    double? minHeight,
    double? maxWidth,
    AccentRole? accentRole,
    GradientSpec? gradient,
    ControlEffects? effects,
    ControlMotion? motion,
    ControlTypography? typography,
    ControlIconography? iconography,
    ControlStates? states,
    bool? clip,
    bool? labelsUppercase,
  }) =>
      ControlRecipe(
        shape: shape ?? this.shape,
        fill: fill ?? this.fill,
        radius: radius ?? this.radius,
        borderWidth: borderWidth ?? this.borderWidth,
        borderAlpha: borderAlpha ?? this.borderAlpha,
        elevation: elevation ?? this.elevation,
        paddingH: paddingH ?? this.paddingH,
        paddingV: paddingV ?? this.paddingV,
        ink: ink ?? this.ink,
        minHeight: minHeight ?? this.minHeight,
        maxWidth: maxWidth ?? this.maxWidth,
        accentRole: accentRole ?? this.accentRole,
        gradient: gradient ?? this.gradient,
        effects: effects ?? this.effects,
        motion: motion ?? this.motion,
        typography: typography ?? this.typography,
        iconography: iconography ?? this.iconography,
        states: states ?? this.states,
        clip: clip ?? this.clip,
        labelsUppercase: labelsUppercase ?? this.labelsUppercase,
      );

  ControlRecipe mergeStyle(ComponentStyle style) => copyWith(
        shape: style.shapeKind ?? shape,
        fill: style.fillKind ?? fill,
        radius: style.radius ?? radius,
        borderWidth: style.borderWidth ?? borderWidth,
        borderAlpha: style.borderAlpha ?? borderAlpha,
        elevation: style.elevation ?? elevation,
        paddingH: style.padding ?? paddingH,
        paddingV: style.paddingV ?? paddingV,
        ink: style.inkKind ?? ink,
        minHeight: style.minHeight ?? minHeight,
        accentRole: style.accentRole ?? accentRole,
        effects: style.effects != null ? effects.merge(style.effects) : effects,
        motion: style.motion != null ? motion.merge(style.motion) : motion,
        typography: style.typography ?? typography,
        iconography: style.iconography ?? iconography,
        states: style.states ?? states,
        gradient: style.gradient ?? gradient,
      );

  /// Applies a state delta (hover/press/…) onto this recipe.
  ControlRecipe withState(ControlStateStyle state) {
    if (state.isEmpty) return this;
    return copyWith(
      fill: state.fill ?? fill,
      borderWidth: state.borderWidth ?? borderWidth,
      borderAlpha: state.borderAlpha ?? borderAlpha,
      elevation: state.elevation ?? elevation,
      accentRole: state.accentRole ?? accentRole,
      effects: effects.copyWith(
        opacity: state.opacity ?? effects.opacity,
        glow: state.glow ?? effects.glow,
      ),
      motion: motion.copyWith(
        pressScale: state.scale ?? motion.pressScale,
      ),
    );
  }

  OutlinedBorder border({Color? sideColor}) {
    final side = borderWidth > 0 && sideColor != null
        ? BorderSide(
            color: sideColor.withValues(alpha: borderAlpha), width: borderWidth)
        : BorderSide.none;
    return switch (shape) {
      ShapeKind.stadium => StadiumBorder(side: side),
      ShapeKind.sharp => RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: side,
        ),
      ShapeKind.cut => BeveledRectangleBorder(
          borderRadius: BorderRadius.circular(radius.clamp(0, 16)),
          side: side,
        ),
      ShapeKind.squircle => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius <= 0 ? 28 : radius * 1.35),
          side: side,
        ),
      ShapeKind.rounded => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: side,
        ),
    };
  }

  BorderRadius get borderRadius => switch (shape) {
        ShapeKind.stadium => BorderRadius.circular(999),
        ShapeKind.sharp => BorderRadius.zero,
        ShapeKind.squircle =>
          BorderRadius.circular(radius <= 0 ? 28 : radius * 1.35),
        ShapeKind.cut || ShapeKind.rounded => BorderRadius.circular(radius),
      };

  Map<String, dynamic> toJson() => {
        'shape': shape.name,
        'fill': fill.name,
        'radius': radius,
        if (borderWidth != 0) 'border_width': borderWidth,
        if (borderAlpha != 0.4) 'border_alpha': borderAlpha,
        if (elevation != 0) 'elevation': elevation,
        'padding_h': paddingH,
        'padding_v': paddingV,
        'ink': ink.name,
        if (minHeight != null) 'min_height': minHeight,
        if (maxWidth != null) 'max_width': maxWidth,
        if (accentRole != AccentRole.primary) 'accent': accentRole.name,
        if (gradient != null && !gradient!.isEmpty) 'gradient': gradient!.toJson(),
        if (!effects.isIdentity) 'effects': effects.toJson(),
        if (!motion.isIdentity) 'motion': motion.toJson(),
        if (!typography.isEmpty) 'typography': typography.toJson(),
        if (!iconography.isEmpty) 'iconography': iconography.toJson(),
        if (!states.isEmpty) 'states': states.toJson(),
        if (!clip) 'clip': false,
        if (labelsUppercase) 'labels_uppercase': true,
      };

  factory ControlRecipe.fromJson(
    Map<String, dynamic> json, [
    ControlRecipe fallback = const ControlRecipe(),
  ]) =>
      ControlRecipe(
        shape: _shape(json['shape'], fallback.shape),
        fill: _fill(json['fill'], fallback.fill),
        radius: parseDouble(json['radius'], fallback.radius),
        borderWidth: parseDouble(json['border_width'], fallback.borderWidth),
        borderAlpha: parseDouble(json['border_alpha'], fallback.borderAlpha),
        elevation: parseDouble(json['elevation'], fallback.elevation),
        paddingH: parseDouble(json['padding_h'], fallback.paddingH),
        paddingV: parseDouble(json['padding_v'], fallback.paddingV),
        ink: _ink(json['ink'], fallback.ink),
        minHeight: json['min_height'] == null
            ? fallback.minHeight
            : parseDouble(json['min_height'], 0),
        maxWidth: json['max_width'] == null
            ? fallback.maxWidth
            : parseDouble(json['max_width'], 0),
        accentRole: _accentRole(json['accent'], fallback.accentRole),
        gradient: json['gradient'] is Map
            ? GradientSpec.fromJson(
                Map<String, dynamic>.from(json['gradient'] as Map))
            : fallback.gradient,
        effects: json['effects'] is Map
            ? ControlEffects.fromJson(
                Map<String, dynamic>.from(json['effects'] as Map))
            : fallback.effects,
        motion: json['motion'] is Map
            ? ControlMotion.fromJson(
                Map<String, dynamic>.from(json['motion'] as Map))
            : fallback.motion,
        typography: json['typography'] is Map
            ? ControlTypography.fromJson(
                Map<String, dynamic>.from(json['typography'] as Map))
            : fallback.typography,
        iconography: json['iconography'] is Map
            ? ControlIconography.fromJson(
                Map<String, dynamic>.from(json['iconography'] as Map))
            : fallback.iconography,
        states: json['states'] is Map
            ? ControlStates.fromJson(
                Map<String, dynamic>.from(json['states'] as Map))
            : fallback.states,
        clip: json['clip'] is bool ? json['clip'] as bool : fallback.clip,
        labelsUppercase: json['labels_uppercase'] == true ||
            fallback.labelsUppercase,
      );

  static ShapeKind _shape(Object? raw, ShapeKind fallback) {
    final s = '$raw';
    for (final v in ShapeKind.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }

  static FillKind _fill(Object? raw, FillKind fallback) {
    final s = '$raw';
    for (final v in FillKind.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }

  static InkKind _ink(Object? raw, InkKind fallback) {
    final s = '$raw';
    for (final v in InkKind.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }

  static AccentRole _accentRole(Object? raw, AccentRole fallback) {
    if (raw == null) return fallback;
    final s = '$raw';
    for (final v in AccentRole.values) {
      if (v.name == s) return v;
    }
    return fallback;
  }
}

@immutable
class ShadowRecipe {
  const ShadowRecipe({
    this.blur = 18,
    this.y = 8,
    this.x = 0,
    this.alpha = 0.12,
    this.hard = false,
  });

  final double blur;
  final double y;
  final double x;
  final double alpha;
  final bool hard;

  List<BoxShadow> resolve(ColorScheme scheme, {Color? accent}) {
    if (alpha <= 0 && blur <= 0) return const [];
    final dark = scheme.brightness == Brightness.dark;
    if (hard) {
      return [
        BoxShadow(
          color: (accent ?? scheme.onSurface)
              .withValues(alpha: alpha.clamp(0, 1)),
          offset: Offset(x, y),
          blurRadius: 0,
        ),
      ];
    }
    // Nav / elevated chrome: accent bloom (never a pale wash in dark mode).
    if (accent != null) {
      final bloom = (dark ? (alpha * 1.8).clamp(0.16, 0.42) : alpha)
          .clamp(0.0, 1.0)
          .toDouble();
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? .38 : alpha * .75),
          blurRadius: blur,
          offset: Offset(x, y),
        ),
        BoxShadow(
          color: accent.withValues(alpha: bloom),
          blurRadius: blur * 1.15,
          spreadRadius: -2,
          offset: Offset(x, y * .55),
        ),
      ];
    }
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? (alpha * 2).clamp(0.2, 0.45) : alpha),
        blurRadius: blur,
        offset: Offset(x, y),
      ),
    ];
  }

  Map<String, dynamic> toJson() => {
        'blur': blur,
        'y': y,
        'x': x,
        'alpha': alpha,
        if (hard) 'hard': true,
      };

  factory ShadowRecipe.fromJson(Map<String, dynamic> json) => ShadowRecipe(
        blur: parseDouble(json['blur'], 18),
        y: parseDouble(json['y'], 8),
        x: parseDouble(json['x'], 0),
        alpha: parseDouble(json['alpha'], 0.12),
        hard: json['hard'] == true,
      );
}

@immutable
class InteractionRecipe {
  const InteractionRecipe({
    this.ink = InkKind.ripple,
    this.pressScale = 1,
    this.hoverAlpha = 0.08,
    this.durationMs = 180,
    this.curve = MotionCurveKind.standard,
    this.hoverLift = 0,
    this.focusRing = 0,
  });

  final InkKind ink;
  final double pressScale;
  final double hoverAlpha;
  final int durationMs;
  final MotionCurveKind curve;
  final double hoverLift;
  final double focusRing;

  ControlMotion get asMotion => ControlMotion(
        durationMs: durationMs,
        curve: curve,
        pressScale: pressScale,
        hoverLift: hoverLift,
      );

  Map<String, dynamic> toJson() => {
        'ink': ink.name,
        if (pressScale != 1) 'press_scale': pressScale,
        'hover_alpha': hoverAlpha,
        if (durationMs != 180) 'duration_ms': durationMs,
        if (curve != MotionCurveKind.standard) 'curve': curve.name,
        if (hoverLift != 0) 'hover_lift': hoverLift,
        if (focusRing > 0) 'focus_ring': focusRing,
      };

  factory InteractionRecipe.fromJson(Map<String, dynamic> json) =>
      InteractionRecipe(
        ink: ControlRecipe._ink(json['ink'], InkKind.ripple),
        pressScale: parseDouble(json['press_scale'], 1),
        hoverAlpha: parseDouble(json['hover_alpha'], 0.08),
        durationMs: parseInt(json['duration_ms'], 180),
        curve: ControlMotion._curve(json['curve']),
        hoverLift: parseDouble(json['hover_lift'], 0),
        focusRing: parseDouble(json['focus_ring'], 0),
      );
}
