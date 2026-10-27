/// Material 3 Expressive components without a single Flutter-widget
/// counterpart in the older node set: icon buttons, connected button
/// groups, list items and grouped lists, the navigation bar, the search
/// bar and the shape-morphing loading indicator.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/elpian_services.dart';
import '../core/event_dispatcher.dart';
import '../core/node_events.dart';
import '../css/css_properties.dart';
import '../models/elpian_node.dart';
import 'elpian_expressive.dart';

Widget _styled(ElpianNode node, Widget w) =>
    node.style == null ? w : CSSProperties.applyStyle(w, node.style);

/// `IconButton`: an icon-only button.
///
/// Props: `icon` (a Material icon name); `variant` — `standard` (default),
/// `filled`, `tonal`, `outlined`; `size` `xs` `s` (default) `m` `l` `xl`;
/// `shape` `round` / `square`; `selected` (a toggle: `selectedIcon` shows
/// when on, and the shape squares); `tooltip`; `disabled`. Events: `tap`,
/// `longpress`.
class ElpianIconButton {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final size = ExpressiveSize.parse(node.props['size']);
    final selected = boolProp(node, 'selected');
    final disabled = boolProp(node, 'disabled') == true;
    final variant = textProp(node, 'variant') ?? 'standard';
    final square = node.props['shape'] == 'square' || selected == true;
    final iconName = selected == true
        ? (node.props['selectedIcon'] ?? node.props['icon'])
        : node.props['icon'];
    final icon = children.isNotEmpty
        ? children.first
        : Icon(
            iconNamed(iconName) ?? Icons.circle_outlined,
            size: node.style?.fontSize ?? size.icon,
          );
    return _styled(
      node,
      Builder(
        builder: (context) {
          final scheme = Theme.of(context).colorScheme;
          final on = selected ?? false;
          final (Color? bg, Color? fg) = switch (variant) {
            'filled' =>
              selected == null || on
                  ? (scheme.primary, scheme.onPrimary)
                  : (scheme.surfaceContainerHighest, scheme.primary),
            'tonal' =>
              on
                  ? (scheme.secondary, scheme.onSecondary)
                  : (scheme.secondaryContainer, scheme.onSecondaryContainer),
            'outlined' =>
              on
                  ? (scheme.inverseSurface, scheme.onInverseSurface)
                  : (null, scheme.onSurfaceVariant),
            _ => (null, on ? scheme.primary : scheme.onSurfaceVariant),
          };
          final side = variant == 'outlined' && !on
              ? BorderSide(color: scheme.outlineVariant)
              : null;
          final dim = size.height;
          Widget button = IconButton(
            onPressed: disabled ? null : e.activate,
            onLongPress: disabled || !e.has('longpress')
                ? null
                : () => e.emit('longpress'),
            tooltip: textProp(node, 'tooltip'),
            isSelected: selected,
            icon: icon,
            style: ButtonStyle(
              fixedSize: WidgetStatePropertyAll(Size(dim, dim)),
              minimumSize: WidgetStatePropertyAll(Size(dim, dim)),
              padding: const WidgetStatePropertyAll(EdgeInsets.zero),
              iconSize: WidgetStatePropertyAll(size.icon),
              shape: morphingShape(size, square: square, side: side),
              backgroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.disabled) && bg != null
                    ? scheme.onSurface.withValues(alpha: 0.1)
                    : (node.style?.backgroundColor ?? bg),
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.disabled)
                    ? scheme.onSurface.withValues(alpha: 0.38)
                    : (node.style?.color ?? fg),
              ),
              animationDuration: ElpianMotion.fast,
            ),
          );
          return ExpressivePress(
            enabled: !disabled,
            scale: 0.92,
            child: button,
          );
        },
      ),
    );
  }
}

/// `SegmentedButton`: a connected group of options (M3 Expressive
/// connected button group).
///
/// Props: `segments: [{value, label, icon}]` (or plain strings);
/// `selected` (a value, or a list with `multi`); `multi`; `emptyAllowed`;
/// `showIcon` (default true: a check on the selected segment when it has
/// no icon of its own); `size` `s` / `m`. Event: `change` with `{value}` (a
/// value, or the list with `multi`).
class ElpianSegmentedButton {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final multi = boolProp(node, 'multi') == true;
    final raw = node.props['segments'] ?? node.props['items'] ?? const [];
    final segments = <ButtonSegment<String>>[];
    if (raw is List) {
      for (final s in raw) {
        final m = s is Map ? s : {'value': s, 'label': s};
        final value = '${m['value'] ?? m['label'] ?? segments.length}';
        final label = m['label'] ?? (m['icon'] == null ? value : null);
        segments.add(
          ButtonSegment<String>(
            value: value,
            label: label == null ? null : Text('$label'),
            icon: iconWidget(m['icon']),
            tooltip: m['tooltip'] == null ? null : '${m['tooltip']}',
          ),
        );
      }
    }
    if (segments.isEmpty) return const SizedBox.shrink();
    final sel = node.props['selected'] ?? node.props['value'];
    final selected = <String>{
      if (sel is List)
        for (final v in sel) '$v'
      else if (sel != null)
        '$sel',
    };
    final emptyAllowed = boolProp(node, 'emptyAllowed') ?? multi;
    if (selected.isEmpty && !emptyAllowed) selected.add(segments.first.value);
    final medium = ExpressiveSize.parse(node.props['size']) == ExpressiveSize.m;
    return _styled(
      node,
      SegmentedButton<String>(
        segments: segments,
        selected: selected,
        multiSelectionEnabled: multi,
        emptySelectionAllowed: emptyAllowed,
        showSelectedIcon: boolProp(node, 'showIcon') ?? true,
        style: medium
            ? const ButtonStyle(
                minimumSize: WidgetStatePropertyAll(Size(0, 56)),
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 20),
                ),
              )
            : null,
        onSelectionChanged: boolProp(node, 'disabled') == true
            ? null
            : (values) => e.emit(
                'change',
                data: {
                  'value': multi
                      ? [
                          for (final s in segments)
                            if (values.contains(s.value)) s.value,
                        ]
                      : (values.isEmpty ? null : values.first),
                },
              ),
      ),
    );
  }
}

/// `ListTile`: a list item.
///
/// Props: `title`, `subtitle`, `overline`; `leading` / `trailing` — a
/// Material icon name, or `leadingAvatar` (a name: initials) /
/// `leadingImage` (a URL); `trailingText` (meta text such as a time or an
/// amount); `selected`; `dense`; `disabled`; `lines` (3 lets the subtitle
/// wrap). Children with `props.slot` `leading` / `trailing` / `title` /
/// `subtitle` fill those slots. Events: `tap`, `longpress`.
class ElpianListTile {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final slots = <String, Widget>{};
    for (var i = 0; i < node.children.length && i < children.length; i++) {
      final slot = node.children[i].props['slot'];
      if (slot is String) slots[slot] = children[i];
    }
    final tappable = e.hasAny(const ['tap', 'click', 'longpress']);
    final disabled = boolProp(node, 'disabled') == true;
    return _styled(
      node,
      Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          Widget? leading = slots['leading'];
          final avatar = textProp(node, 'leadingAvatar');
          final image = textProp(node, 'leadingImage');
          if (leading == null && image != null) {
            leading = CircleAvatar(
              radius: 20,
              backgroundImage: NetworkImage(image),
              backgroundColor: scheme.primaryContainer,
            );
          } else if (leading == null && avatar != null) {
            final initials = avatar
                .trim()
                .split(RegExp(r'\s+'))
                .where((w) => w.isNotEmpty)
                .take(2)
                .map((w) => w.characters.first.toUpperCase())
                .join();
            leading = CircleAvatar(
              radius: 20,
              backgroundColor: scheme.primaryContainer,
              foregroundColor: scheme.onPrimaryContainer,
              child: Text(
                initials,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            );
          } else if (leading == null && node.props['leading'] != null) {
            final icon = iconNamed(node.props['leading']);
            if (icon != null) {
              // An icon in a tonal rounded square, as M3E lists set them.
              leading = Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 22, color: scheme.onSecondaryContainer),
              );
            }
          }
          Widget? trailing = slots['trailing'];
          final meta = textProp(node, 'trailingText');
          final trailingIcon = iconWidget(
            node.props['trailing'],
            color: scheme.onSurfaceVariant,
          );
          if (trailing == null && (meta != null || trailingIcon != null)) {
            trailing = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (meta != null)
                  Text(
                    meta,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (meta != null && trailingIcon != null)
                  const SizedBox(width: 8),
                if (trailingIcon != null) trailingIcon,
              ],
            );
          }
          final overline = textProp(node, 'overline');
          final subtitle = textProp(node, 'subtitle');
          final three = numProp(node, 'lines') == 3;
          Widget? title =
              slots['title'] ??
              (node.props['title'] == null
                  ? null
                  : Text(
                      '${node.props['title']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ));
          if (overline != null) {
            title = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  overline,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                if (title != null) title,
              ],
            );
          }
          return ListTile(
            leading: leading,
            trailing: trailing,
            title: title,
            subtitle:
                slots['subtitle'] ??
                (subtitle == null
                    ? null
                    : Text(
                        subtitle,
                        maxLines: three ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                      )),
            isThreeLine: three && subtitle != null,
            dense: boolProp(node, 'dense'),
            enabled: !disabled,
            selected: boolProp(node, 'selected') ?? false,
            selectedTileColor: scheme.secondaryContainer,
            selectedColor: scheme.onSecondaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            titleTextStyle: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
            ),
            subtitleTextStyle: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            onTap: tappable && !disabled && (e.has('tap') || e.has('click'))
                ? e.activate
                : null,
            onLongPress: e.has('longpress') && !disabled
                ? () => e.emit('longpress')
                : null,
          );
        },
      ),
    );
  }
}

/// `ListGroup`: children (usually `ListTile`s) as one segmented group —
/// tonal tiles 2px apart, the group's outer corners large and the inner
/// ones small (the M3 Expressive list look).
///
/// Props: `title` (a label above the group), `radius` (outer, default 24),
/// `innerRadius` (default 6), `gap` (default 2), `variant` — `tonal`
/// (default) or `outlined`.
class ElpianListGroup {
  static Widget build(ElpianNode node, List<Widget> children) {
    final outer = numProp(node, 'radius') ?? 24;
    final inner = numProp(node, 'innerRadius') ?? 6;
    final gap = numProp(node, 'gap') ?? 2;
    final title = textProp(node, 'title');
    final outlined = node.props['variant'] == 'outlined';
    return _styled(
      node,
      Builder(
        builder: (context) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          final n = children.length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              for (var i = 0; i < n; i++) ...[
                if (i > 0) SizedBox(height: gap),
                ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(i == 0 ? outer : inner),
                    bottom: Radius.circular(i == n - 1 ? outer : inner),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: outlined
                          ? scheme.surface
                          : node.style?.backgroundColor ??
                                scheme.surfaceContainer,
                      border: outlined
                          ? Border.all(color: scheme.outlineVariant)
                          : null,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(i == 0 ? outer : inner),
                        bottom: Radius.circular(i == n - 1 ? outer : inner),
                      ),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: children[i],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// `NavigationBar`: the bottom navigation bar (3–5 destinations).
///
/// Props: `items: [{icon, selectedIcon, label, badge}]`; `selected` (index);
/// `labels` — `always` (default), `selected`, `never`. Event: `change` with
/// `{value: index}`. In a `Scaffold` it takes the bottom bar slot.
class ElpianNavigationBar {
  static Widget build(ElpianNode node, List<Widget> children) {
    final e = NodeEvents(node);
    final raw = node.props['items'] ?? node.props['destinations'] ?? const [];
    final items = raw is List ? raw : const [];
    if (items.length < 2) return const SizedBox.shrink();
    final selected = (numProp(node, 'selected') ?? numProp(node, 'value') ?? 0)
        .toInt()
        .clamp(0, items.length - 1);
    Widget iconOf(Object? name, Object? badge) {
      Widget icon = Icon(iconNamed(name) ?? Icons.circle_outlined);
      if (badge != null && '$badge'.isNotEmpty && badge != false) {
        icon = Badge(label: badge == true ? null : Text('$badge'), child: icon);
      }
      return icon;
    }

    return NavigationBar(
      selectedIndex: selected,
      backgroundColor: node.style?.backgroundColor,
      height: node.style?.height,
      labelBehavior: switch (node.props['labels']) {
        'selected' => NavigationDestinationLabelBehavior.onlyShowSelected,
        'never' || false => NavigationDestinationLabelBehavior.alwaysHide,
        _ => NavigationDestinationLabelBehavior.alwaysShow,
      },
      onDestinationSelected: (i) => e.emit('change', data: {'value': i}),
      destinations: [
        for (final item in items)
          if (item is Map)
            NavigationDestination(
              icon: iconOf(item['icon'], item['badge']),
              selectedIcon: item['selectedIcon'] == null
                  ? null
                  : iconOf(item['selectedIcon'], item['badge']),
              label: '${item['label'] ?? ''}',
            )
          else
            NavigationDestination(
              icon: const Icon(Icons.circle_outlined),
              label: '$item',
            ),
      ],
    );
  }
}

/// `SearchBar`: a pill search field.
///
/// Props: `hint`, `value` (controlled, like `TextField`), `icon` (leading,
/// default `search`), `trailingIcon`, `elevation` (default 0). Events:
/// `input` (each change) with `{value}`, `submit`.
class ElpianSearchBar {
  static Widget build(ElpianNode node, List<Widget> children) {
    return _styled(
      node,
      _SearchBarView(
        node: node,
        elementId: elementIdOf(node),
        dispatcher: ElpianServices.current.events,
      ),
    );
  }
}

class _SearchBarView extends StatefulWidget {
  const _SearchBarView({
    required this.node,
    required this.elementId,
    required this.dispatcher,
  });

  final ElpianNode node;
  final String elementId;
  final EventDispatcher dispatcher;

  @override
  State<_SearchBarView> createState() => _SearchBarViewState();
}

class _SearchBarViewState extends State<_SearchBarView> {
  late final TextEditingController _controller = TextEditingController(
    text: _value ?? '',
  );

  String? get _value {
    final v = widget.node.props['value'];
    return v == null ? null : '$v';
  }

  @override
  void didUpdateWidget(_SearchBarView old) {
    super.didUpdateWidget(old);
    final value = _value;
    if (value != null && value != _controller.text) {
      _controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final props = widget.node.props;
    final elevation = numProp(widget.node, 'elevation') ?? 0;
    final trailing = iconWidget(props['trailingIcon']);
    return SearchBar(
      controller: _controller,
      hintText: props['hint'] == null ? 'Search' : '${props['hint']}',
      elevation: WidgetStatePropertyAll(elevation),
      backgroundColor: WidgetStatePropertyAll(
        widget.node.style?.backgroundColor ?? scheme.surfaceContainerHigh,
      ),
      constraints: const BoxConstraints(minHeight: 56),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 16),
      ),
      leading: Icon(iconNamed(props['icon'] ?? 'search') ?? Icons.search),
      trailing: [if (trailing != null) trailing],
      onChanged: (v) => widget.dispatcher.dispatchInput(widget.elementId, v),
      onSubmitted: (_) => widget.dispatcher.dispatchSubmit(widget.elementId),
    );
  }
}

/// `LoadingIndicator`: the M3 Expressive loading indicator — a rounded
/// shape that morphs between soft polygons while it spins.
///
/// Props: `size` (default 48), `contained` (on a tonal circle), `color`
/// via `style.color`. Use it for waits under ~5 s; a `Progress` for
/// measurable work.
class ElpianLoadingIndicator {
  static Widget build(ElpianNode node, List<Widget> children) {
    return _styled(
      node,
      ExpressiveLoadingIndicator(
        size: numProp(node, 'size') ?? 48,
        contained: boolProp(node, 'contained') == true,
        color: node.style?.color,
      ),
    );
  }
}

class ExpressiveLoadingIndicator extends StatefulWidget {
  const ExpressiveLoadingIndicator({
    super.key,
    this.size = 48,
    this.contained = false,
    this.color,
  });

  final double size;
  final bool contained;
  final Color? color;

  @override
  State<ExpressiveLoadingIndicator> createState() =>
      _ExpressiveLoadingIndicatorState();
}

class _ExpressiveLoadingIndicatorState extends State<ExpressiveLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4550),
  )..repeat();

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        widget.color ??
        (widget.contained ? scheme.onPrimaryContainer : scheme.primary);
    Widget out = SizedBox.square(
      dimension: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _MorphPainter(_t, color, widget.contained ? 0.62 : 0.84),
        ),
      ),
    );
    if (widget.contained) {
      out = DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: out,
      );
    }
    return Semantics(label: 'Loading', child: out);
  }
}

class _MorphPainter extends CustomPainter {
  _MorphPainter(this.t, this.color, this.scale) : super(repaint: t);

  final Animation<double> t;
  final Color color;
  final double scale;

  // (lobes, depth): the soft shapes it morphs through.
  static const _shapes = [
    (7, 0.11),
    (4, 0.16),
    (5, 0.12),
    (9, 0.08),
    (3, 0.14),
    (6, 0.13),
    (2, 0.1),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final phase = t.value * _shapes.length;
    final i = phase.floor() % _shapes.length;
    final next = (i + 1) % _shapes.length;
    // Hold each shape, then morph to the next with a springy ease.
    final local = (phase - phase.floor());
    final m = Curves.easeInOutCubicEmphasized.transform(
      ((local - 0.35) / 0.65).clamp(0.0, 1.0),
    );
    final rotation = t.value * math.pi * 2 * 3 + m * math.pi / 2;
    final r = size.shortestSide / 2 * scale;
    final c = size.center(Offset.zero);
    final path = Path();
    const steps = 96;
    for (var k = 0; k <= steps; k++) {
      final a = k / steps * math.pi * 2;
      double radius((int, double) s) => 1 - s.$2 + s.$2 * math.cos(s.$1 * a);
      final rr = r * (radius(_shapes[i]) * (1 - m) + radius(_shapes[next]) * m);
      final p = c + Offset(math.cos(a + rotation), math.sin(a + rotation)) * rr;
      k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_MorphPainter old) =>
      old.color != color || old.scale != scale;
}
