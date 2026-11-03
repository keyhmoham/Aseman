import 'dart:ui';

import 'package:flutter/material.dart';

import 'design_language.dart';
import 'theme_chrome.dart';

/// Resolved graphical look for one control slot under the active pack.
///
/// Widgets should prefer this over ad-hoc Material defaults so packs can drive
/// shape, fill, gradient, effects, motion, type, and icons in one place.
@immutable
class ControlLook {
  const ControlLook({
    required this.slot,
    required this.recipe,
    required this.shape,
    required this.fill,
    required this.padding,
    required this.ink,
    required this.motion,
    required this.effects,
    this.gradient,
    this.shadows,
    this.textStyle,
    this.iconSize,
    this.labelsUppercase = false,
  });

  final String slot;
  final ControlRecipe recipe;
  final OutlinedBorder shape;
  final Color fill;
  final EdgeInsets padding;
  final InkKind ink;
  final ControlMotion motion;
  final ControlEffects effects;
  final Gradient? gradient;
  final List<BoxShadow>? shadows;
  final TextStyle? textStyle;
  final double? iconSize;
  final bool labelsUppercase;

  Decoration get decoration {
    final glow = effects.glow > 0
        ? [
            BoxShadow(
              color: fill.withValues(alpha: .35),
              blurRadius: effects.glow,
              spreadRadius: effects.glowSpread,
            ),
          ]
        : const <BoxShadow>[];
    final allShadows = <BoxShadow>[
      ...?shadows,
      ...glow,
    ];
    if (gradient != null) {
      return ShapeDecoration(
        gradient: gradient,
        shape: shape,
        shadows: allShadows.isEmpty ? null : allShadows,
      );
    }
    return ShapeDecoration(
      color: fill.withValues(alpha: (fill.a * effects.opacity).clamp(0.0, 1.0)),
      shape: shape,
      shadows: allShadows.isEmpty ? null : allShadows,
    );
  }

  /// Wraps [child] with opacity / blur / scale from the recipe effects+motion.
  Widget decorate(
    Widget child, {
    bool pressed = false,
    bool hovered = false,
  }) {
    var out = child;
    final scale = pressed && motion.pressScale != 1
        ? motion.pressScale
        : (hovered && motion.hoverScale != 1 ? motion.hoverScale : 1.0);
    final lift = hovered ? motion.hoverLift : 0.0;
    if (scale != 1 || lift != 0) {
      out = AnimatedContainer(
        duration: motion.duration,
        curve: motion.flutterCurve,
        transform: Matrix4.identity()
          ..translate(0.0, -lift)
          ..scale(scale),
        transformAlignment: Alignment.center,
        child: out,
      );
    }
    if (effects.blur > 0) {
      out = ImageFiltered(
        imageFilter: ImageFilter.blur(
          sigmaX: effects.blur,
          sigmaY: effects.blur,
        ),
        child: out,
      );
    }
    if (effects.opacity < 1) {
      out = Opacity(opacity: effects.opacity.clamp(0.0, 1.0), child: out);
    }
    return out;
  }
}

/// Resolves [ControlLook] from the active pack for a named slot.
extension ControlLookX on BuildContext {
  ControlLook controlLook(
    String slot, {
    Color? accent,
    bool selected = false,
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
    bool disabled = false,
    TextStyle? baseText,
  }) =>
      ThemeChrome.look(
        this,
        slot,
        accent: accent,
        selected: selected,
        hovered: hovered,
        pressed: pressed,
        focused: focused,
        disabled: disabled,
        baseText: baseText,
      );
}
