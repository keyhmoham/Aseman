/// Components new with Aseman's genui catalog: richer inputs
/// (SegmentedControl, Dropdown, RangeSlider, NumberStepper, SearchField),
/// navigation and actions (Link, IconButton, Menu, Steps, Carousel,
/// Accordion), feedback (EmptyState, Skeleton, Loading, Tooltip, Countdown),
/// AvatarGroup, long-form Markdown, and Show — conditional rendering on the
/// data model.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';

import '../../features/tools/ui_kit/kit.dart' as kit;
import '../runtime/dynamic_values.dart';
import '../runtime/format.dart';
import 'basic.dart' show GenUiMarkdown, ModalTrigger;
import 'item.dart';
import 'style.dart';

Map<String, Schema> _props(Map<String, String> props) => {
      for (final e in props.entries) e.key: P.any(e.value),
    };

final Schema _options = S.list(
    description: 'The options: [{label, value, icon?}].',
    items: S.object(additionalProperties: true));

/// Options as (value, label, icon).
List<({String value, String label, IconData? icon})> _optionList(Object? v) => [
      for (final o in v is List ? v : const <Object?>[])
        if (o is Map && o['value'] != null)
          (
            value: stringifyValue(o['value']),
            label: stringifyValue(o['label']).isEmpty
                ? stringifyValue(o['value'])
                : stringifyValue(o['label']),
            icon: genUiIcon(o['icon']),
          )
        else if (o is String || o is num)
          (value: stringifyValue(o), label: stringifyValue(o), icon: null),
    ];

/// A two-way bound value: [build] gets the current value and a setter
/// (writing the binding, or local state for a literal).
class _Bound extends StatefulWidget {
  const _Bound({required this.item, required this.prop, required this.build});
  final GenUiItem item;
  final String prop;
  final Widget Function(
      BuildContext context, Object? value, void Function(Object?) set) build;

  @override
  State<_Bound> createState() => _BoundState();
}

class _BoundState extends State<_Bound> {
  Object? _local;
  bool _hasLocal = false;

  @override
  Widget build(BuildContext context) {
    final binding = widget.item.raw[widget.prop];
    return Resolved(
      context: widget.item.dataContext,
      value: binding,
      builder: (context, value) => widget.build(
        context,
        isBinding(binding) || !_hasLocal ? value : _local,
        (v) {
          if (isBinding(binding)) {
            widget.item.write(binding, v);
          } else {
            setState(() {
              _local = v;
              _hasLocal = true;
            });
          }
          final action = widget.item.raw['action'];
          if (action != null) widget.item.fire(action, extra: {'value': v});
        },
      ),
    );
  }
}

Widget _label(BuildContext context, String text) => text.isEmpty
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: genUiTextStyle(context, 'caption')
                .copyWith(fontWeight: FontWeight.w600)),
      );

const _changeAction =
    'Fired after the value changes; its context also gets {"value"}.';

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

final segmentedControlItem = asemanItem(
  'SegmentedControl',
  description: 'A pill row of mutually exclusive choices (periods, views, '
      'buy / sell), bound to the chosen value.',
  properties: {
    'options': _options,
    'value': P.any('A {"path"} binding to the chosen value.'),
    'label': P.any('A label above.'),
    'action': P.action(_changeAction),
  },
  required: ['options', 'value'],
  raw: {'value'},
  build: (item, p) => _Bound(
    item: item,
    prop: 'value',
    build: (context, value, set) {
      final options = _optionList(p['options']);
      if (options.isEmpty) return const SizedBox.shrink();
      final selected = stringifyValue(value);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _label(context, stringifyValue(p['label'])),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              emptySelectionAllowed: true,
              segments: [
                for (final o in options)
                  ButtonSegment(
                      value: o.value,
                      label: Text(o.label),
                      icon: o.icon == null ? null : Icon(o.icon, size: 18)),
              ],
              selected: {if (options.any((o) => o.value == selected)) selected},
              onSelectionChanged: (s) {
                if (s.isNotEmpty) set(s.first);
              },
            ),
          ),
        ],
      );
    },
  ),
);

final dropdownItem = asemanItem(
  'Dropdown',
  description: 'A select menu bound to the chosen value.',
  properties: {
    'options': _options,
    'value': P.any('A {"path"} binding to the chosen value.'),
    'label': P.any('The field label.'),
    'placeholder': P.any('Shown when nothing is chosen.'),
    'action': P.action(_changeAction),
  },
  required: ['options', 'value'],
  raw: {'value'},
  implicitlyFlexible: true,
  build: (item, p) => _Bound(
    item: item,
    prop: 'value',
    build: (context, value, set) {
      final options = _optionList(p['options']);
      final selected = stringifyValue(value);
      final label = stringifyValue(p['label']);
      final placeholder = stringifyValue(p['placeholder']);
      return LayoutBuilder(
        builder: (context, box) => DropdownMenu<String>(
          key: ValueKey('${item.id}:$selected'),
          width: box.maxWidth.isFinite ? box.maxWidth : 280,
          initialSelection:
              options.any((o) => o.value == selected) ? selected : null,
          label: label.isEmpty ? null : Text(label),
          hintText: placeholder.isEmpty ? null : placeholder,
          requestFocusOnTap: false,
          dropdownMenuEntries: [
            for (final o in options)
              DropdownMenuEntry(
                  value: o.value,
                  label: o.label,
                  leadingIcon: o.icon == null ? null : Icon(o.icon, size: 18)),
          ],
          onSelected: (v) {
            if (v != null) set(v);
          },
        ),
      );
    },
  ),
);

final rangeSliderItem = asemanItem(
  'RangeSlider',
  description: 'Picks a low–high range, bound to [low, high].',
  properties: {
    ..._props({
      'label': 'The label.',
      'min': 'The lowest value (default 0).',
      'max': 'The highest value (default 100).',
      'step': 'Snap to multiples of this.',
      'format': 'How values are shown (number, percent, currency…).',
    }),
    'value': P.any('A {"path"} binding to [low, high].'),
    'action': P.action(_changeAction),
  },
  required: ['value'],
  raw: {'value'},
  build: (item, p) => _Bound(
    item: item,
    prop: 'value',
    build: (context, value, set) {
      final min = toNum(p['min']) ?? 0;
      final rawMax = toNum(p['max']);
      final max = rawMax != null && rawMax > min ? rawMax : min + 100;
      final step = toNum(p['step']);
      final pair = value is List ? value : const <Object?>[];
      var lo = (toNum(pair.isNotEmpty ? pair[0] : null) ?? min).clamp(min, max);
      var hi = (toNum(pair.length > 1 ? pair[1] : null) ?? max).clamp(min, max);
      if (lo > hi) (lo, hi) = (hi, lo);
      String show(num v) => p['format'] is String
          ? kit.formatValue(v, p['format'] as String)
          : numberToString(v == v.roundToDouble() ? v.round() : v);
      num tidy(double v) => v == v.roundToDouble() ? v.round() : v;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
                child: Text(stringifyValue(p['label']),
                    style: genUiTextStyle(context, 'caption'))),
            Text('${show(lo)} – ${show(hi)}',
                style: genUiTextStyle(context, 'body')
                    .copyWith(fontWeight: FontWeight.w700)),
          ]),
          RangeSlider(
            min: min.toDouble(),
            max: max.toDouble(),
            divisions:
                step != null && step > 0 ? ((max - min) / step).round() : null,
            values: RangeValues(lo.toDouble(), hi.toDouble()),
            onChanged: (r) => set([tidy(r.start), tidy(r.end)]),
          ),
        ],
      );
    },
  ),
);

final numberStepperItem = asemanItem(
  'NumberStepper',
  description: 'A number with − / + buttons (quantities, order sizes), '
      'bound to the number.',
  properties: {
    ..._props({
      'label': 'The label.',
      'min': 'The lowest value.',
      'max': 'The highest value.',
      'step': 'The increment (default 1).',
      'format': 'How the value is shown.',
    }),
    'value': P.any('A {"path"} binding to the number.'),
    'action': P.action(_changeAction),
  },
  required: ['value'],
  raw: {'value'},
  build: (item, p) => _Bound(
    item: item,
    prop: 'value',
    build: (context, value, set) {
      final scheme = Theme.of(context).colorScheme;
      final min = toNum(p['min']);
      final max = toNum(p['max']);
      final step = toNum(p['step']) ?? 1;
      final n = toNum(value) ?? min ?? 0;
      num tidy(num v) {
        final r = double.parse(v.toStringAsFixed(10));
        return r == r.roundToDouble() ? r.round() : r;
      }

      final canDown = min == null || n - step >= min;
      final canUp = max == null || n + step <= max;
      final shown = p['format'] is String
          ? kit.formatValue(n, p['format'] as String)
          : numberToString(n);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _label(context, stringifyValue(p['label'])),
          Container(
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: .55),
                borderRadius: BorderRadius.circular(999)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Decrease',
                icon: const Icon(Icons.remove_rounded),
                onPressed: canDown ? () => set(tidy(n - step)) : null,
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 56),
                child: Text(shown,
                    textAlign: TextAlign.center,
                    style: genUiTextStyle(context, 'body').copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
              IconButton(
                tooltip: 'Increase',
                icon: const Icon(Icons.add_rounded),
                onPressed: canUp ? () => set(tidy(n + step)) : null,
              ),
            ]),
          ),
        ],
      );
    },
  ),
);

final searchFieldItem = asemanItem(
  'SearchField',
  description: 'A search box bound to its text; "action" fires on submit '
      'with {"value": text}.',
  properties: {
    'value': P.any('A {"path"} binding to the query.'),
    'placeholder': P.any('The hint (default "Search").'),
    'action': P.action('Fired on submit; its context also gets {"value"}.'),
  },
  required: ['value'],
  raw: {'value'},
  implicitlyFlexible: true,
  build: (item, p) => _SearchField(item: item, hint: stringifyValue(p['placeholder'])),
);

class _SearchField extends StatefulWidget {
  const _SearchField({required this.item, required this.hint});
  final GenUiItem item;
  final String hint;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final binding = item.raw['value'];
    return Resolved(
      context: item.dataContext,
      value: binding,
      builder: (context, value) {
        final text = isBinding(binding) ? stringifyValue(value) : _controller.text;
        if (_controller.text != text) {
          _controller.value = TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length));
        }
        return TextField(
          controller: _controller,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: widget.hint.isEmpty ? 'Search' : widget.hint,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _controller.clear();
                      item.write(binding, '');
                      setState(() {});
                    }),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none),
          ),
          onChanged: (v) {
            item.write(binding, v);
            if (!isBinding(binding)) setState(() {});
          },
          onSubmitted: (v) {
            final action = item.raw['action'];
            if (action != null) item.fire(action, extra: {'value': v});
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Actions and navigation
// ---------------------------------------------------------------------------

final linkItem = asemanItem(
  'Link',
  description: 'Inline link text: opens "url", or fires "action".',
  properties: {
    ..._props({'text': 'The link text.', 'url': 'An http(s) URL to open.'}),
    'action': P.action(),
  },
  required: ['text'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final url = stringifyValue(p['url']);
    final action = item.raw['action'] ??
        (url.isEmpty
            ? null
            : {
                'functionCall': {
                  'call': 'openUrl',
                  'args': {'url': url}
                }
              });
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: action == null ? null : () => item.fire(action),
          child: Semantics(
            link: true,
            child: Text(stringifyValue(p['text']),
                style: genUiTextStyle(context, 'body').copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: scheme.primary.withValues(alpha: .5))),
          ),
        ),
      ),
    );
  }),
);

final iconButtonItem = asemanItem(
  'IconButton',
  description: 'A round icon button with a tooltip.',
  properties: {
    ..._props({
      'icon': 'The icon name.',
      'tooltip': 'What it does (also its accessible name).',
      'variant': 'standard, filled, tonal or outlined.',
    }),
    'action': P.action(),
  },
  required: ['icon', 'action'],
  build: (item, p) => Builder(builder: (context) {
    final icon = Icon(genUiIcon(p['icon']) ?? Icons.circle_outlined);
    final tooltip = stringifyValue(p['tooltip']);
    void press() {
      final trigger = ModalTrigger.maybeOf(context);
      if (trigger != null) return trigger.open();
      item.fire(item.raw['action']);
    }

    return switch (p['variant']) {
      'filled' => IconButton.filled(
          tooltip: tooltip.isEmpty ? null : tooltip,
          onPressed: press,
          icon: icon),
      'tonal' => IconButton.filledTonal(
          tooltip: tooltip.isEmpty ? null : tooltip,
          onPressed: press,
          icon: icon),
      'outlined' => IconButton.outlined(
          tooltip: tooltip.isEmpty ? null : tooltip,
          onPressed: press,
          icon: icon),
      _ => IconButton(
          tooltip: tooltip.isEmpty ? null : tooltip,
          onPressed: press,
          icon: icon),
    };
  }),
);

final menuItem = asemanItem(
  'Menu',
  description: 'An overflow menu (⋮) of actions.',
  properties: {
    'items': S.list(
        description: 'The entries: [{label, icon?, action, destructive?}].',
        items: S.object(additionalProperties: true)),
    'icon': P.any('The button icon (default moreVert).'),
    'tooltip': P.any('The button tooltip (default "More").'),
  },
  required: ['items'],
  raw: {'items'},
  build: (item, p) => Resolved(
    context: item.dataContext,
    // Labels may be bound; actions stay as written (fired on choice).
    value: [
      for (final e in item.raw['items'] is List
          ? item.raw['items'] as List
          : const <Object?>[])
        if (e is Map) {'label': e['label'], 'icon': e['icon']}
    ],
    builder: (context, resolved) {
      final raw = [
        for (final e in item.raw['items'] is List
            ? item.raw['items'] as List
            : const <Object?>[])
          if (e is Map) e
      ];
      final labels = resolved is List ? resolved : const <Object?>[];
      final scheme = Theme.of(context).colorScheme;
      final tooltip = stringifyValue(p['tooltip']);
      return PopupMenuButton<int>(
        tooltip: tooltip.isEmpty ? 'More' : tooltip,
        icon: Icon(genUiIcon(p['icon']) ?? Icons.more_vert_rounded),
        onSelected: (i) => item.fire(raw[i]['action']),
        itemBuilder: (_) => [
          for (var i = 0; i < raw.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Row(children: [
                if (genUiIcon((labels[i] as Map?)?['icon']) case final icon?)
                  Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(icon,
                          size: 20,
                          color: toBool(raw[i]['destructive'])
                              ? scheme.error
                              : null)),
                Text(stringifyValue((labels[i] as Map?)?['label']),
                    style: TextStyle(
                        color: toBool(raw[i]['destructive'])
                            ? scheme.error
                            : null)),
              ]),
            ),
        ],
      );
    },
  ),
);

final stepsItem = asemanItem(
  'Steps',
  description: 'Progress through ordered steps (an order\'s lifecycle, an '
      'onboarding flow).',
  properties: {
    'steps': S.list(
        description: '[{title, description?, status?: done|current|todo|'
            'error}].',
        items: S.object(additionalProperties: true)),
    'current': P.any('The index of the current step (when steps carry no '
        'status).'),
    'direction': P.str('Layout.', ['vertical', 'horizontal']),
  },
  required: ['steps'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final steps = [
      for (final s in p['steps'] is List ? p['steps'] as List : const [])
        if (s is Map) s
    ];
    final current = toNum(p['current'])?.toInt();
    String status(int i) {
      final s = steps[i]['status'];
      if (s is String && s.isNotEmpty) return s;
      if (current == null) return 'todo';
      return i < current
          ? 'done'
          : i == current
              ? 'current'
              : 'todo';
    }

    Widget dot(int i) {
      final s = status(i);
      final (Color bg, Color fg, Widget? inner) = switch (s) {
        'done' => (scheme.primary, scheme.onPrimary,
            const Icon(Icons.check_rounded, size: 16)),
        'error' => (scheme.error, scheme.onError,
            const Icon(Icons.close_rounded, size: 16)),
        'current' => (scheme.primaryContainer, scheme.onPrimaryContainer, null),
        _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, null),
      };
      return Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: s == 'current'
                ? Border.all(color: scheme.primary, width: 2)
                : null),
        child: IconTheme(
          data: IconThemeData(color: fg),
          child: inner ??
              Text('${i + 1}',
                  style: TextStyle(
                      color: fg, fontSize: 12, fontWeight: FontWeight.w800)),
        ),
      );
    }

    Widget text(int i) {
      final description = stringifyValue(steps[i]['description']);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(stringifyValue(steps[i]['title']),
              style: genUiTextStyle(context, 'body').copyWith(
                  fontWeight: status(i) == 'current'
                      ? FontWeight.w800
                      : FontWeight.w600,
                  color: status(i) == 'todo' ? scheme.onSurfaceVariant : null)),
          if (description.isNotEmpty)
            Text(description, style: genUiTextStyle(context, 'caption')),
        ],
      );
    }

    if (p['direction'] == 'horizontal') {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0)
              Container(
                  width: 32,
                  height: 2,
                  margin: const EdgeInsets.only(top: 13),
                  color: status(i - 1) == 'done'
                      ? scheme.primary
                      : scheme.outlineVariant),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [dot(i), text(i)]),
            ),
          ],
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < steps.length; i++)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Column(children: [
                dot(i),
                if (i < steps.length - 1)
                  Expanded(
                      child: Container(
                          width: 2,
                          constraints: const BoxConstraints(minHeight: 14),
                          color: status(i) == 'done'
                              ? scheme.primary
                              : scheme.outlineVariant)),
              ]),
              const SizedBox(width: 12),
              Expanded(
                  child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 14),
                      child: text(i))),
            ]),
          ),
      ],
    );
  }),
);

final carouselItem = asemanItem(
  'Carousel',
  description: 'Children as swipeable pages with dots.',
  properties: {
    'children': P.children(),
    'height': P.any('Page height in pixels (default 240).'),
  },
  required: ['children'],
  build: (item, p) => item.children(
    item.raw['children'],
    (children) => _Carousel(
        height: toNum(p['height'])?.toDouble() ?? 240, children: children),
  ),
);

class _Carousel extends StatefulWidget {
  const _Carousel({required this.height, required this.children});
  final double height;
  final List<Widget> children;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  final _controller = PageController(viewportFraction: .92);
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = widget.children.length;
    if (n == 0) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: widget.height,
        child: PageView(
          controller: _controller,
          onPageChanged: (i) => setState(() => _page = i),
          children: [
            for (final c in widget.children)
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6), child: c),
          ],
        ),
      ),
      if (n > 1)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < n; i++)
              GestureDetector(
                onTap: () => _controller.animateToPage(i,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: i == _page ? 18 : 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                      color: i == _page
                          ? scheme.primary
                          : scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(99)),
                ),
              ),
          ]),
        ),
    ]);
  }
}

final accordionItem = asemanItem(
  'Accordion',
  description: 'Collapsible sections, one open at a time (FAQs, details).',
  properties: {
    'items': S.list(
        description: '[{title, subtitle?, child}].',
        items: S.object(additionalProperties: true)),
    'multiple': P.any('Allow several open at once.'),
    'expanded': P.any('The index open at first.'),
  },
  required: ['items'],
  build: (item, p) => _Accordion(item: item, props: p),
);

class _Accordion extends StatefulWidget {
  const _Accordion({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_Accordion> createState() => _AccordionState();
}

class _AccordionState extends State<_Accordion> {
  late Set<int> _open = {
    if (toNum(widget.props['expanded']) case final num n) n.toInt()
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = [
      for (final s
          in widget.props['items'] is List ? widget.props['items'] as List : const [])
        if (s is Map) s
    ];
    return Container(
      decoration: genUiCard(context),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Divider(height: 1, color: scheme.outlineVariant),
          InkWell(
            onTap: () => setState(() {
              if (_open.contains(i)) {
                _open.remove(i);
              } else {
                if (!toBool(widget.props['multiple'])) _open = {};
                _open.add(i);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              child: Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(stringifyValue(items[i]['title']),
                          style: genUiTextStyle(context, 'body')
                              .copyWith(fontWeight: FontWeight.w700)),
                      if (stringifyValue(items[i]['subtitle']).isNotEmpty)
                        Text(stringifyValue(items[i]['subtitle']),
                            style: genUiTextStyle(context, 'caption')),
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: _open.contains(i) ? .5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more_rounded,
                      color: scheme.onSurfaceVariant),
                ),
              ]),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: _open.contains(i)
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: widget.item.child(items[i]['child']))
                : const SizedBox(width: double.infinity),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Feedback and display
// ---------------------------------------------------------------------------

final emptyStateItem = asemanItem(
  'EmptyState',
  description: 'What to show when there is nothing yet: icon, title, text '
      'and an optional action component.',
  properties: {
    ..._props({
      'icon': 'An icon name.',
      'title': 'The headline.',
      'text': 'An explanation.',
    }),
    'child': P.child('An optional action (usually a Button).'),
  },
  required: ['title'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final text = stringifyValue(p['text']);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: .6),
              shape: BoxShape.circle),
          child: Icon(genUiIcon(p['icon']) ?? Icons.inbox_rounded,
              color: scheme.primary, size: 28),
        ),
        Text(stringifyValue(p['title']),
            textAlign: TextAlign.center, style: genUiTextStyle(context, 'h5')),
        if (text.isNotEmpty)
          Text(text,
              textAlign: TextAlign.center,
              style: genUiTextStyle(context, 'caption')),
        if (item.raw['child'] is String)
          Padding(
              padding: const EdgeInsets.only(top: 4),
              child: item.child(item.raw['child'])),
      ]),
    );
  }),
);

final skeletonItem = asemanItem(
  'Skeleton',
  description: 'A shimmering placeholder while data loads.',
  properties: _props({
    'variant': 'lines, card, chart or table.',
    'lines': 'Number of lines (lines variant).',
    'height': 'Height in pixels.',
  }),
  build: (item, p) => _Skeleton(
    variant: stringifyValue(p['variant']),
    lines: toNum(p['lines'])?.toInt() ?? 3,
    height: toNum(p['height'])?.toDouble(),
  ),
);

class _Skeleton extends StatefulWidget {
  const _Skeleton({required this.variant, required this.lines, this.height});
  final String variant;
  final int lines;
  final double? height;

  @override
  State<_Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<_Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat();

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
              color: base, borderRadius: BorderRadius.circular(8)),
        );
    final Widget shape = switch (widget.variant) {
      'card' || 'chart' => Container(
          height: widget.height ?? (widget.variant == 'chart' ? 240 : 140),
          decoration: BoxDecoration(
              color: base, borderRadius: BorderRadius.circular(AppShape.inner)),
        ),
      'table' => Column(spacing: 10, children: [
          for (var i = 0; i < math.max(widget.lines, 4); i++)
            bar(double.infinity, i == 0 ? 18 : 14),
        ]),
      _ => LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth.isFinite ? box.maxWidth : 320.0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 10,
              children: [
                for (var i = 0; i < widget.lines; i++)
                  bar(i == widget.lines - 1 && widget.lines > 1 ? w * .6 : w,
                      14),
              ],
            );
          },
        ),
    };
    return Semantics(
      label: 'Loading',
      child: AnimatedBuilder(
        animation: _shimmer,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            final t = _shimmer.value * 3 - 1;
            return LinearGradient(
              colors: [
                base,
                scheme.surface.withValues(alpha: .7),
                base,
              ],
              stops: [
                (t - .3).clamp(0.0, 1.0),
                t.clamp(0.0, 1.0),
                (t + .3).clamp(0.0, 1.0)
              ],
            ).createShader(rect);
          },
          child: child,
        ),
        child: shape,
      ),
    );
  }
}

final loadingItem = asemanItem(
  'Loading',
  description: 'A spinner with optional text.',
  properties: _props({'text': 'What is loading.'}),
  build: (item, p) => Builder(builder: (context) {
    final text = stringifyValue(p['text']);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.4)),
      if (text.isNotEmpty) ...[
        const SizedBox(width: 10),
        Flexible(child: Text(text, style: genUiTextStyle(context, 'caption'))),
      ],
    ]);
  }),
);

final tooltipItem = asemanItem(
  'Tooltip',
  description: 'Explains its child on hover or long-press.',
  properties: {
    ..._props({'message': 'The explanation.'}),
    'child': P.child(),
  },
  required: ['message', 'child'],
  build: (item, p) => Tooltip(
      message: stringifyValue(p['message']),
      child: item.child(item.raw['child'])),
);

final avatarGroupItem = asemanItem(
  'AvatarGroup',
  description: 'Overlapping avatars of several people, "+n" beyond max.',
  properties: _props({
    'people': '[{name, url?}] (or names).',
    'max': 'Avatars shown (default 5).',
    'size': 'Diameter (default 32).',
  }),
  required: ['people'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final people = p['people'] is List ? p['people'] as List : const <Object?>[];
    final max = toNum(p['max'])?.toInt() ?? 5;
    final size = toNum(p['size'])?.toDouble() ?? 32;
    final shown = people.take(max).toList();
    final more = people.length - shown.length;
    final count = shown.length + (more > 0 ? 1 : 0);
    Widget ring(Widget child) => Container(
        padding: const EdgeInsets.all(2),
        decoration:
            BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
        child: child);
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: SizedBox(
        height: size + 4,
        width: count == 0 ? 0 : (size + 4) + (count - 1) * size * .7,
        child: Stack(children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * .7,
              child: Tooltip(
                message: stringifyValue(
                    shown[i] is Map ? (shown[i] as Map)['name'] : shown[i]),
                child: ring(kit.KitAvatar(
                  name: stringifyValue(
                      shown[i] is Map ? (shown[i] as Map)['name'] : shown[i]),
                  url: shown[i] is Map
                      ? (shown[i] as Map)['url'] as String?
                      : null,
                  size: size,
                )),
              ),
            ),
          if (more > 0)
            Positioned(
              left: shown.length * size * .7,
              child: ring(Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: BoxShape.circle),
                child: Text('+$more',
                    style: TextStyle(
                        fontSize: size * .36,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              )),
            ),
        ]),
      ),
    );
  }),
);

final markdownItem = asemanItem(
  'Markdown',
  description: 'Long-form Markdown: headings, lists, tables, quotes, code '
      'blocks, links.',
  properties: _props({'text': 'The Markdown.'}),
  required: ['text'],
  build: (item, p) => GenUiMarkdown(text: stringifyValue(p['text'])),
);

/// A condition's value as a boolean: true, "true", a non-zero number, a
/// non-empty text (but "false"), list or map.
bool truthy(Object? v) => switch (v) {
      bool b => b,
      num n => n != 0,
      String s => s.isNotEmpty && s != 'false' && s != '0',
      List<Object?> l => l.isNotEmpty,
      Map<Object?, Object?> m => m.isNotEmpty,
      _ => false,
    };

final showItem = asemanItem(
  'Show',
  description: 'Shows its child only while "when" is true (else "fallback"): '
      'conditional UI on the data model, e.g. {"call": "equals", "args": '
      '{"a": {"path": "/tab"}, "b": "orders"}}.',
  properties: {
    'when': P.any('A boolean, {"path"} or function call.'),
    'child': P.child('Shown while true.'),
    'fallback': P.child('Shown while false.'),
  },
  required: ['when', 'child'],
  raw: {'fallback'},
  build: (item, p) {
    final on = truthy(p['when']);
    final id = on ? item.raw['child'] : item.raw['fallback'];
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      child: id is String
          ? KeyedSubtree(key: ValueKey(id), child: item.child(id))
          : const SizedBox(width: double.infinity),
    );
  },
);

final countdownItem = asemanItem(
  'Countdown',
  description: 'Time left until "target" (an ISO date-time), ticking every '
      'second; "doneText" after.',
  properties: _props({
    'target': 'When it ends (ISO date-time or epoch ms).',
    'label': 'What ends ("Market closes in").',
    'doneText': 'Shown once reached.',
    'size': 'small or large.',
  }),
  required: ['target'],
  build: (item, p) => _Countdown(
    target: parseDate(p['target']),
    label: stringifyValue(p['label']),
    done: stringifyValue(p['doneText']),
    large: p['size'] == 'large',
  ),
);

class _Countdown extends StatefulWidget {
  const _Countdown(
      {required this.target,
      required this.label,
      required this.done,
      required this.large});
  final DateTime? target;
  final String label;
  final String done;
  final bool large;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = widget.target;
    final left = target?.difference(DateTime.now());
    String two(int n) => n.toString().padLeft(2, '0');
    final String text;
    if (left == null) {
      text = '—';
    } else if (left.isNegative || left == Duration.zero) {
      _timer?.cancel();
      text = widget.done.isEmpty ? '00:00:00' : widget.done;
    } else {
      final days = left.inDays;
      text = '${days > 0 ? '${days}d ' : ''}'
          '${two(left.inHours % 24)}:${two(left.inMinutes % 60)}:'
          '${two(left.inSeconds % 60)}';
    }
    final valueStyle = genUiTextStyle(context, widget.large ? 'h3' : 'body')
        .copyWith(
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label.isNotEmpty)
          Text(widget.label, style: genUiTextStyle(context, 'caption')),
        Text(text, style: valueStyle),
      ],
    );
  }
}

/// The components new in this catalog.
final List<CatalogItem> extendedItems = [
  segmentedControlItem, dropdownItem, rangeSliderItem, numberStepperItem, //
  searchFieldItem, linkItem, iconButtonItem, menuItem, stepsItem,
  carouselItem, accordionItem, emptyStateItem, skeletonItem, loadingItem,
  tooltipItem, avatarGroupItem, markdownItem, showItem, countdownItem,
];
