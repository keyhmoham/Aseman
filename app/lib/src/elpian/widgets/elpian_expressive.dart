/// Material 3 Expressive building blocks shared by the Elpian widgets:
/// spring motion, press feedback, shape morphing, the type scale by role
/// name and icon lookup by name.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models/elpian_node.dart';
import 'elpian_icon.dart';

/// M3 Expressive motion: springs for spatial changes (position, size,
/// shape), the emphasized easing for the rest.
abstract final class ElpianMotion {
  /// Fast spatial spring: presses, toggles, small components.
  static const Curve fastSpatial = SpringCurve(ratio: 0.6, stiffness: 1400);

  /// Default spatial spring: cards, sheets, larger moves.
  static const Curve spatial = SpringCurve(ratio: 0.8, stiffness: 380);

  /// Effects (color, opacity): no overshoot.
  static const Curve effects = Curves.easeInOutCubicEmphasized;

  static const Duration fast = Duration(milliseconds: 220);
  static const Duration medium = Duration(milliseconds: 400);
}

/// A spring (damping [ratio], [stiffness]) as a [Curve] from 0 to 1: it
/// overshoots when underdamped and ends exactly at 1.
class SpringCurve extends Curve {
  const SpringCurve({this.ratio = 0.8, this.stiffness = 380});

  final double ratio;
  final double stiffness;

  @override
  double transformInternal(double t) {
    final spring = SpringSimulation(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: stiffness,
        ratio: ratio,
      ),
      0,
      1,
      0,
    );
    // Time for the envelope to settle within ~0.2%.
    final omega = math.sqrt(stiffness);
    final settle = 6.2 / (ratio.clamp(0.05, 1.0) * omega);
    return spring.x(t * settle);
  }
}

/// Springy press feedback: the child scales down a little while pressed and
/// springs back on release. Pointer-only, so it never competes with the
/// child's own gestures.
class ExpressivePress extends StatefulWidget {
  const ExpressivePress({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = 0.96,
  });

  final Widget child;
  final bool enabled;
  final double scale;

  @override
  State<ExpressivePress> createState() => _ExpressivePressState();
}

class _ExpressivePressState extends State<ExpressivePress> {
  bool _down = false;

  void _set(bool down) {
    if (!widget.enabled || down == _down) return;
    setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: _down ? ElpianMotion.fast : ElpianMotion.medium,
        curve: _down ? Curves.easeOutCubic : ElpianMotion.fastSpatial,
        child: widget.child,
      ),
    );
  }
}

/// M3 Expressive sizes of buttons and icon buttons.
enum ExpressiveSize {
  xs(32, 12, 20, 14, 12, 8),
  s(40, 16, 20, 14, 12, 8),
  m(56, 24, 24, 16, 16, 12),
  l(96, 48, 32, 24, 28, 16),
  xl(136, 64, 40, 32, 28, 16);

  const ExpressiveSize(
    this.height,
    this.padding,
    this.icon,
    this.font,
    this.square,
    this.pressed,
  );

  final double height;
  final double padding;
  final double icon;
  final double font;

  /// Corner radius of the square shape, and of either shape while pressed.
  final double square;
  final double pressed;

  static ExpressiveSize parse(Object? v, [ExpressiveSize fallback = s]) =>
      switch ('${v ?? ''}'.toLowerCase()) {
        'xs' || 'extrasmall' || 'extra-small' || 'tiny' => xs,
        's' || 'small' || 'sm' => s,
        'm' || 'medium' || 'md' => m,
        'l' || 'large' || 'lg' => l,
        'xl' || 'extralarge' || 'extra-large' || 'huge' => xl,
        _ => fallback,
      };
}

/// The shape of a control: fully round, or square (rounded corners); both
/// morph to a tighter corner while pressed.
WidgetStateProperty<OutlinedBorder> morphingShape(
  ExpressiveSize size, {
  bool square = false,
  BorderSide? side,
}) {
  return WidgetStateProperty.resolveWith((states) {
    final pressed = states.contains(WidgetState.pressed);
    final radius = pressed
        ? size.pressed
        : square
        ? size.square
        : size.height / 2;
    return RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: side ?? BorderSide.none,
    );
  });
}

/// Text styles of the M3 type scale by role name (`displayLarge` …
/// `labelSmall`); an `Emphasized` suffix (`headlineMediumEmphasized`) takes
/// the bolder weight of M3 Expressive. Aliases: `display`, `headline`,
/// `title`, `body`, `label` (their medium size), `h1`…`h6`, `caption`,
/// `overline`.
TextStyle? typeRole(BuildContext context, Object? role) {
  if (role is! String || role.isEmpty) return null;
  final theme = Theme.of(context).textTheme;
  var name = role.trim();
  var emphasized = false;
  for (final suffix in const ['Emphasized', '-emphasized', '_emphasized']) {
    if (name.endsWith(suffix)) {
      emphasized = true;
      name = name.substring(0, name.length - suffix.length);
    }
  }
  name = name.replaceAll('-', '').replaceAll('_', '').toLowerCase();
  final style = switch (name) {
    'displaylarge' => theme.displayLarge,
    'displaymedium' || 'display' => theme.displayMedium,
    'displaysmall' || 'h1' => theme.displaySmall,
    'headlinelarge' || 'h2' => theme.headlineLarge,
    'headlinemedium' || 'headline' => theme.headlineMedium,
    'headlinesmall' || 'h3' => theme.headlineSmall,
    'titlelarge' || 'h4' => theme.titleLarge,
    'titlemedium' || 'title' || 'h5' => theme.titleMedium,
    'titlesmall' || 'h6' => theme.titleSmall,
    'bodylarge' => theme.bodyLarge,
    'bodymedium' || 'body' => theme.bodyMedium,
    'bodysmall' || 'caption' => theme.bodySmall,
    'labellarge' => theme.labelLarge,
    'labelmedium' || 'label' => theme.labelMedium,
    'labelsmall' || 'overline' => theme.labelSmall,
    _ => null,
  };
  if (style == null) return null;
  // Large figures read tighter, as the expressive type scale sets them.
  final display = name.startsWith('display') || name == 'h1';
  final out = style.copyWith(
    letterSpacing: display ? -0.5 : style.letterSpacing,
  );
  if (!emphasized) return out;
  final w = out.fontWeight ?? FontWeight.w400;
  return out.copyWith(
    fontWeight: w.index >= FontWeight.w500.index
        ? FontWeight.w800
        : FontWeight.w600,
  );
}

/// The icon [name] names (Material icon names, snake_case or camelCase), or
/// null.
IconData? iconNamed(Object? name) =>
    name is String && name.isNotEmpty ? ElpianIcon.iconData(name) : null;

/// An [Icon] for [name], or null when the name is empty or unknown.
Widget? iconWidget(Object? name, {double? size, Color? color}) {
  final data = iconNamed(name);
  return data == null ? null : Icon(data, size: size, color: color);
}

/// A prop as a double.
double? numProp(ElpianNode node, String key) {
  final v = node.props[key];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// A prop as a size: a finite, non-negative double, else null (Flutter
/// asserts on negative sizes and factors).
double? sizeProp(ElpianNode node, String key) {
  final v = numProp(node, key);
  return v == null || v < 0 || !v.isFinite ? null : v;
}

/// A `flex` prop: a positive int, else [fallback].
int flexProp(ElpianNode node, [int fallback = 1]) {
  final v = numProp(node, 'flex');
  return v == null || !v.isFinite || v < 1 ? fallback : v.round();
}

/// A prop as a bool (`true`, `"true"`), or null when absent.
bool? boolProp(ElpianNode node, String key) {
  final v = node.props[key];
  if (v is bool) return v;
  if (v == 'true') return true;
  if (v == 'false') return false;
  return null;
}

/// A prop as text, or null when absent or empty.
String? textProp(ElpianNode node, String key) {
  final v = node.props[key];
  if (v == null) return null;
  final s = '$v';
  return s.isEmpty ? null : s;
}

/// The node's CSS classes (`props.className` / `props.class`).
List<String> classesOf(ElpianNode node) {
  final v = node.props['className'] ?? node.props['class'];
  if (v is List) return [for (final c in v) '$c'];
  if (v is! String) return const [];
  return v.split(RegExp(r'\s+')).where((c) => c.isNotEmpty).toList();
}
