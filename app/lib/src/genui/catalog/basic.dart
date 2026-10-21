/// The A2UI basic catalog in Aseman's design language: Text (with
/// Markdown), Image, Icon, Video, AudioPlayer, Row, Column, List, Card, Tabs,
/// Modal, Divider, Button, TextField, CheckBox, ChoicePicker, Slider and
/// DateTimeInput — every property of the spec, plus a few extras each
/// (marked "Aseman:" in their schemas).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../elpian/core/media.dart';
import '../../elpian/html_widgets/html_audio.dart';
import '../../elpian/html_widgets/html_video.dart';
import '../../elpian/models/elpian_node.dart';
import '../../elpian/widgets/svg_path.dart';
import '../../features/tools/ui_kit/values.dart' as kit;
import '../../shared/widgets/segmented_tab_bar.dart';
import '../runtime/dynamic_values.dart';
import '../runtime/format.dart';
import '../runtime/host.dart';
import 'item.dart';
import 'style.dart';

const _variants = ['h1', 'h2', 'h3', 'h4', 'h5', 'caption', 'body'];
const _justify = [
  'start', 'center', 'end', 'spaceBetween', 'spaceAround', 'spaceEvenly', //
  'stretch',
];
const _align = ['start', 'center', 'end', 'stretch'];

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

final _markdownSyntax = RegExp(
    r'(\*\*|__|`|~~|\[[^\]]+\]\([^)]+\)|^\s{0,3}(#{1,6}\s|[-*+]\s|\d+[.)]\s|>\s)|(^|[\s(])[*_][^\s*_][^*_]*[*_]($|[\s).,:;!?]))',
    multiLine: true);

/// Whether [text] uses Markdown (plain text renders as a plain [Text]).
bool hasMarkdown(String text) => _markdownSyntax.hasMatch(text);

final textItem = asemanItem(
  'Text',
  description: 'A block of text; simple Markdown (bold, italic, code, links, '
      'lists, headings) is rendered.',
  properties: {
    'text': P.any('The text: a literal, {"path"} or a formatString call.'),
    'variant': P.str('Typography.', _variants),
    'align': P.str('Aseman: horizontal alignment.', ['start', 'center', 'end']),
    'maxLines': P.any('Aseman: clamp to this many lines (ellipsis).'),
    'color': P.any('Aseman: a color token, status or #hex.'),
  },
  required: ['text'],
  build: (item, p) => Builder(builder: (context) {
    final text = stringifyValue(p['text']);
    var style = genUiTextStyle(context, p['variant'] as String?);
    final color = genUiColor(context, p['color']);
    if (color != null) style = style.copyWith(color: color);
    final align = switch (p['align']) {
      'center' => TextAlign.center,
      'end' => TextAlign.end,
      _ => TextAlign.start,
    };
    final maxLines = (p['maxLines'] as num?)?.toInt();
    if (!hasMarkdown(text)) {
      return Text(text,
          style: style,
          textAlign: align,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis);
    }
    return GenUiMarkdown(text: text, style: style, align: align);
  }),
);

/// Markdown in the surface's typography; links open in the browser.
class GenUiMarkdown extends StatelessWidget {
  const GenUiMarkdown(
      {super.key, required this.text, this.style, this.align = TextAlign.start});

  final String text;
  final TextStyle? style;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = style ?? genUiTextStyle(context, 'body');
    final textAlign = switch (align) {
      TextAlign.center => WrapAlignment.center,
      TextAlign.end => WrapAlignment.end,
      _ => WrapAlignment.start,
    };
    return MarkdownBody(
      data: text,
      softLineBreak: true,
      onTapLink: (_, href, __) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: base,
        textAlign: textAlign,
        h1: genUiTextStyle(context, 'h3'),
        h2: genUiTextStyle(context, 'h4'),
        h3: genUiTextStyle(context, 'h5'),
        h4: genUiTextStyle(context, 'h5'),
        h5: genUiTextStyle(context, 'h5'),
        h6: genUiTextStyle(context, 'h5'),
        listBullet: base,
        a: base.copyWith(
            color: scheme.primary, decoration: TextDecoration.underline),
        code: base.copyWith(
            fontFamily: 'monospace',
            fontSize: (base.fontSize ?? 15) * .9,
            backgroundColor: scheme.surfaceContainerHighest),
        codeblockDecoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppShape.control)),
        blockquoteDecoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(AppShape.control)),
        tableBorder: TableBorder.all(color: scheme.outlineVariant),
        tableHead: base.copyWith(fontWeight: FontWeight.w700),
        tableBody: base,
      ),
    );
  }
}

const Map<String, (double?, double?, double?)> _imageSizes = {
  // width, height, maxWidth
  'icon': (24, 24, null),
  'avatar': (40, 40, null),
  'smallFeature': (100, 100, null),
  'mediumFeature': (null, 200, 300),
  'largeFeature': (double.infinity, 320, null),
  'header': (double.infinity, 200, null),
};

final imageItem = asemanItem(
  'Image',
  description: 'An image: an https URL, a data: URI or inline <svg>, a '
      'project file path, or a stored file.',
  properties: {
    'url': P.any('The image source.'),
    'description': P.any('Text describing the image (accessibility).'),
    'fit': P.str('How the image fills its box.',
        ['contain', 'cover', 'fill', 'none', 'scaleDown']),
    'variant': P.str('Size and shape.', _imageSizes.keys.toList()),
    'height': P.any('Aseman: height in pixels (overrides the variant).'),
  },
  required: ['url'],
  build: (item, p) {
    final variant =
        _imageSizes.containsKey(p['variant']) ? p['variant'] as String : 'mediumFeature';
    final (width, defaultHeight, maxWidth) = _imageSizes[variant]!;
    final height = (p['height'] as num?)?.toDouble() ?? defaultHeight;
    final fit = p['fit'] is String
        ? p['fit'] as String
        : variant == 'icon'
            ? 'contain'
            : 'cover';
    final description = stringifyValue(p['description']);
    Widget image = ElpianMediaImage(
      src: stringifyValue(p['url']),
      fit: _fit(fit),
      width: width,
      height: height,
      alt: description.isEmpty ? null : description,
    );
    final radius = switch (variant) {
      'avatar' => (height ?? 40) / 2,
      'icon' || 'header' => 0.0,
      _ => AppShape.control,
    };
    if (radius > 0) {
      image = ClipRRect(borderRadius: BorderRadius.circular(radius), child: image);
    }
    if (maxWidth != null) {
      image = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth), child: image);
    }
    image = Align(
        alignment: Alignment.centerLeft,
        widthFactor: width == double.infinity ? null : 1,
        child: image);
    return Semantics(
      image: true,
      label: description.isEmpty ? null : description,
      child: image,
    );
  },
);

BoxFit _fit(String fit) => switch (fit) {
      'contain' => BoxFit.contain,
      'fill' => BoxFit.fill,
      'none' => BoxFit.none,
      'scaleDown' => BoxFit.scaleDown,
      _ => BoxFit.cover,
    };

final iconItem = asemanItem(
  'Icon',
  description: 'An icon by name (Material / A2UI names such as search, '
      'trendingUp, accountCircle) or {"svgPath": "<24×24 path>"}.',
  properties: {
    'name': P.any('The icon name, or {"svgPath"}.'),
    'size': P.any('Aseman: size in pixels (default 24).'),
    'color': P.any('Aseman: a color token, status or #hex.'),
  },
  required: ['name'],
  build: (item, p) => Builder(builder: (context) {
    final size = (p['size'] as num?)?.toDouble() ?? 24;
    final color = genUiColor(context, p['color']) ??
        ContentColor.maybeOf(context)?.color ??
        Theme.of(context).colorScheme.onSurfaceVariant;
    final name = p['name'];
    if (name is Map && name['svgPath'] is String) {
      return SvgPathIcon(
          path: name['svgPath'] as String, size: size, color: color);
    }
    return Icon(genUiIcon(name) ?? Icons.help_outline_rounded,
        size: size, color: color);
  }),
);

Widget _media(String type, String src) {
  final node = ElpianNode(
      type: type, props: {'src': src, 'controls': true}, children: const []);
  return type == 'video' ? HtmlVideo.build(node, const []) : HtmlAudio.build(node, const []);
}

final videoItem = asemanItem(
  'Video',
  description: 'A video player.',
  properties: {'url': P.any('The video source.')},
  required: ['url'],
  build: (item, p) => ClipRRect(
    borderRadius: BorderRadius.circular(AppShape.control),
    child: _media('video', stringifyValue(p['url'])),
  ),
);

final audioItem = asemanItem(
  'AudioPlayer',
  description: 'An audio player with an optional description.',
  properties: {
    'url': P.any('The audio source.'),
    'description': P.any('A caption shown above the player.'),
  },
  required: ['url'],
  build: (item, p) => Builder(builder: (context) {
    final description = stringifyValue(p['description']);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      decoration: genUiCard(context, radius: AppShape.control),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description.isNotEmpty)
            Text(description, style: genUiTextStyle(context, 'caption')),
          SizedBox(height: 54, child: _media('audio', stringifyValue(p['url']))),
        ],
      ),
    );
  }),
);

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

MainAxisAlignment _main(Object? justify) => switch (justify) {
      'center' => MainAxisAlignment.center,
      'end' => MainAxisAlignment.end,
      'spaceBetween' => MainAxisAlignment.spaceBetween,
      'spaceAround' => MainAxisAlignment.spaceAround,
      'spaceEvenly' => MainAxisAlignment.spaceEvenly,
      _ => MainAxisAlignment.start,
    };

CrossAxisAlignment _cross(Object? align, CrossAxisAlignment fallback) =>
    switch (align) {
      'start' => CrossAxisAlignment.start,
      'center' => CrossAxisAlignment.center,
      'end' => CrossAxisAlignment.end,
      'stretch' => CrossAxisAlignment.stretch,
      _ => fallback,
    };

/// Components that keep their own size in a Row (others share its width).
const Set<String> _rigidInRow = {
  'Icon', 'Badge', 'Avatar', 'Spacer', 'Divider', 'IconButton', 'Rating', //
  'Switch', 'Menu', 'Tooltip', 'Loading',
};

Widget _flex(GenUiItem item, Map<String, dynamic> p, Axis axis) {
  final row = axis == Axis.horizontal;
  final justify = item.raw['justify'];
  final stretchMain = justify == 'stretch';
  final align = item.raw['align'];
  final gap = (p['gap'] as num?)?.toDouble() ?? (row ? 8 : genUiGap);
  return item.children(
    item.raw['children'],
    wrap: (id, child) {
      final weight = item.propOf(id, 'weight');
      if (weight is num && weight > 0) {
        return Expanded(flex: weight.round().clamp(1, 1000), child: child);
      }
      if (stretchMain) return Expanded(child: child);
      if (row && !_rigidInRow.contains(item.typeOf(id))) {
        return Flexible(child: child);
      }
      return child;
    },
    (children) {
      final flex = Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: _main(justify),
        crossAxisAlignment: _cross(
            align,
            row ? CrossAxisAlignment.center : CrossAxisAlignment.stretch),
        spacing: gap,
        children: children,
      );
      return row && align == 'stretch' ? IntrinsicHeight(child: flex) : flex;
    },
  );
}

final columnItem = asemanItem(
  'Column',
  description: 'Children stacked vertically.',
  properties: {
    'children': P.children(),
    'justify': P.str('Main-axis distribution.', _justify),
    'align': P.str('Cross-axis alignment (default stretch).', _align),
    'gap': P.any('Aseman: space between children (default 12).'),
  },
  required: ['children'],
  build: (item, p) => _flex(item, p, Axis.vertical),
);

final rowItem = asemanItem(
  'Row',
  description: 'Children side by side; "weight" on a child takes shares of '
      'the width.',
  properties: {
    'children': P.children(),
    'justify': P.str('Main-axis distribution.', _justify),
    'align': P.str('Cross-axis alignment (default center).', _align),
    'gap': P.any('Aseman: space between children (default 8).'),
  },
  required: ['children'],
  build: (item, p) => _flex(item, p, Axis.horizontal),
);

final listItem = asemanItem(
  'List',
  description: 'A list of children — usually a template repeated for every '
      'item of a bound list: {componentId, path}; inside it paths are '
      'relative to the item.',
  properties: {
    'children': P.children(),
    'direction': P.str('Scroll direction.', ['vertical', 'horizontal']),
    'align': P.str('Cross-axis alignment.', _align),
    'gap': P.any('Aseman: space between items.'),
    'emptyText': P.any('Aseman: shown when the bound list is empty.'),
  },
  required: ['children'],
  build: (item, p) {
    final horizontal = p['direction'] == 'horizontal';
    final gap = (p['gap'] as num?)?.toDouble() ?? (horizontal ? genUiGap : 8);
    final empty = stringifyValue(p['emptyText']);
    return item.children(item.raw['children'], (children) {
      if (children.isEmpty && empty.isNotEmpty) {
        return Builder(
            builder: (c) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(empty, style: genUiTextStyle(c, 'caption'))));
      }
      if (horizontal) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: _cross(item.raw['align'], CrossAxisAlignment.start),
            spacing: gap,
            children: [
              for (final c in children)
                ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320), child: c),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment:
            _cross(item.raw['align'], CrossAxisAlignment.stretch),
        mainAxisSize: MainAxisSize.min,
        spacing: gap,
        children: children,
      );
    });
  },
);

final cardItem = asemanItem(
  'Card',
  description: 'A card around one child (an outlined surface).',
  properties: {
    'child': P.child(),
    'variant': P.str('Aseman: face.', ['outlined', 'filled', 'elevated']),
    'padding': P.any('Aseman: inner padding (default 16).'),
  },
  required: ['child'],
  build: (item, p) => Builder(builder: (context) {
    final scheme = Theme.of(context).colorScheme;
    final variant = p['variant'];
    final padding = (p['padding'] as num?)?.toDouble() ?? 16;
    final decoration = switch (variant) {
      'filled' => BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(AppShape.inner)),
      'elevated' => genUiCard(context).copyWith(boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: .12),
              blurRadius: 18,
              offset: const Offset(0, 6)),
        ]),
      _ => genUiCard(context),
    };
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: decoration,
      child: item.child(item.raw['child']),
    );
  }),
);

final tabsItem = asemanItem(
  'Tabs',
  description: 'Tabs, each showing one child.',
  properties: {
    'tabs': S.list(
        description: 'The tabs: [{title, child, icon?}].',
        items: S.object(additionalProperties: true)),
    'selected': P.any('Aseman: a {"path"} binding holding the open tab index.'),
  },
  required: ['tabs'],
  raw: {'selected'},
  build: (item, p) => _GenUiTabs(item: item, tabs: p['tabs']),
);

class _GenUiTabs extends StatefulWidget {
  const _GenUiTabs({required this.item, required this.tabs});
  final GenUiItem item;
  final Object? tabs;

  @override
  State<_GenUiTabs> createState() => _GenUiTabsState();
}

class _GenUiTabsState extends State<_GenUiTabs> {
  int _local = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      for (final t in widget.tabs is List ? widget.tabs as List : const [])
        if (t is Map) t,
    ];
    if (tabs.isEmpty) return const SizedBox.shrink();
    final binding = widget.item.raw['selected'];
    return Resolved(
      context: widget.item.dataContext,
      value: binding,
      builder: (context, bound) {
        final index = ((isBinding(binding) ? toNum(bound)?.toInt() : null) ??
                _local)
            .clamp(0, tabs.length - 1);
        final icons = [for (final t in tabs) genUiIcon(t['icon'])];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          spacing: genUiGap,
          children: [
            SegmentedTabBar(
              labels: [for (final t in tabs) stringifyValue(t['title'])],
              icons: icons.every((i) => i != null) ? icons.cast<IconData>() : null,
              alignment: Alignment.centerLeft,
              selectedIndex: index,
              onTap: (i) {
                setState(() => _local = i);
                widget.item.write(binding, i);
              },
            ),
            KeyedSubtree(
              key: ValueKey('tab$index'),
              child: widget.item.child(tabs[index]['child']),
            ),
          ],
        );
      },
    );
  }
}

/// Opens a Modal from inside its trigger: a Button there opens it instead
/// of firing its own action.
class ModalTrigger extends InheritedWidget {
  const ModalTrigger({super.key, required this.open, required super.child});
  final VoidCallback open;

  static ModalTrigger? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModalTrigger>();

  @override
  bool updateShouldNotify(ModalTrigger old) => false;
}

/// Re-provides what a surface's components read from above it (the theme,
/// the media resolver, the host's builders) to a route opened over the app.
Widget carryScope(BuildContext from, Widget child) {
  final host = GenUiHost.maybeOf(from);
  final media = ElpianMediaScope.maybeOf(from);
  final navigator = Navigator.maybeOf(from);
  Widget out = navigator == null
      ? child
      : InheritedTheme.capture(from: from, to: navigator.context).wrap(child);
  if (media != null) out = ElpianMediaScope(resolver: media, child: out);
  if (host != null) {
    out = GenUiHost(
        toolFrontend: host.toolFrontend,
        elpianServices: host.elpianServices,
        child: out);
  }
  return out;
}

final modalItem = asemanItem(
  'Modal',
  description: 'A trigger that opens content in a dialog (or a bottom sheet).',
  properties: {
    'trigger': P.child('The component that opens it (usually a Button).'),
    'content': P.child('The component shown in the dialog.'),
    'title': P.any('Aseman: the dialog title.'),
    'variant': P.str('Aseman: dialog or sheet.', ['dialog', 'sheet']),
  },
  required: ['trigger', 'content'],
  raw: {'trigger', 'content'},
  build: (item, p) => Builder(builder: (context) {
    final title = stringifyValue(p['title']);
    void open() {
      Widget body(BuildContext routeContext) => carryScope(
            context,
            _ModalBody(
                title: title,
                sheet: p['variant'] == 'sheet',
                child: item.child(item.raw['content'])),
          );
      if (p['variant'] == 'sheet') {
        showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: body);
      } else {
        showDialog<void>(
            context: context,
            builder: (c) => Dialog(
                insetPadding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: body(c))));
      }
    }

    final triggerId = item.raw['trigger'];
    final trigger = item.child(triggerId);
    final isButton = triggerId is String &&
        const {'Button', 'IconButton'}.contains(item.typeOf(triggerId));
    return Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: ModalTrigger(
        open: open,
        child: isButton
            ? trigger
            : MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: open,
                    child: trigger)),
      ),
    );
  }),
);

class _ModalBody extends StatelessWidget {
  const _ModalBody(
      {required this.title, required this.sheet, required this.child});
  final String title;
  final bool sheet;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, sheet ? 0 : 12, 12, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: genUiTextStyle(context, 'h5')
                        .copyWith(color: scheme.onSurface))),
            if (!sheet)
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
          ]),
          Padding(padding: const EdgeInsets.only(right: 12), child: child),
        ],
      ),
    );
  }
}

final dividerItem = asemanItem(
  'Divider',
  description: 'A thin rule between content.',
  properties: {'axis': P.str('Direction.', ['horizontal', 'vertical'])},
  build: (item, p) => Builder(builder: (context) {
    final color = Theme.of(context).colorScheme.outlineVariant;
    return p['axis'] == 'vertical'
        ? Container(
            width: 1,
            constraints: const BoxConstraints(minHeight: 24),
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: color)
        : Divider(height: 17, color: color);
  }),
);

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// The first failing check's message, kept current.
class _Checks extends StatelessWidget {
  const _Checks({required this.item, required this.builder});
  final GenUiItem item;
  final Widget Function(BuildContext context, String? failure) builder;

  @override
  Widget build(BuildContext context) {
    final checks = item.raw['checks'];
    if (checks is! List || checks.isEmpty) return builder(context, null);
    return StreamBuilder<String?>(
      stream: ValidationHelper.validateStream(
          [for (final c in checks) if (c is Map) c.cast<String, Object?>()],
          item.dataContext),
      builder: (context, snapshot) => builder(context, snapshot.data),
    );
  }
}

/// The label of a button: its accessibility label, or its child's text.
String _buttonLabel(GenUiItem item) {
  final a11y = item.raw['accessibility'];
  if (a11y is Map && a11y['label'] is String) return a11y['label'] as String;
  final child = item.raw['child'];
  if (child is String && item.typeOf(child) == 'Text') {
    final text = item.propOf(child, 'text');
    if (text is String) return text;
  }
  return '';
}

final buttonItem = asemanItem(
  'Button',
  description: 'A pill button; its action fires on tap, disabled while a '
      'check fails.',
  properties: {
    'child': P.child('Its content (usually a Text).'),
    'action': P.action(),
    'variant': P.str(
        'Style: primary (filled, the main action), default (outlined), '
        'borderless; Aseman: tonal, destructive.',
        ['default', 'primary', 'borderless', 'tonal', 'destructive']),
    'checks': P.checks(),
    'icon': P.any('Aseman: a leading icon name.'),
    'fullWidth': P.any('Aseman: span the available width.'),
  },
  required: ['child', 'action'],
  build: (item, p) => _GenUiButton(item: item, props: p),
);

class _GenUiButton extends StatefulWidget {
  const _GenUiButton({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_GenUiButton> createState() => _GenUiButtonState();
}

class _GenUiButtonState extends State<_GenUiButton> {
  bool _busy = false;

  Future<void> _press(BuildContext context) async {
    final trigger = ModalTrigger.maybeOf(context);
    if (trigger != null) return trigger.open();
    setState(() => _busy = true);
    try {
      await widget.item.fire(widget.item.raw['action']);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final variant = widget.props['variant'] ?? 'default';
    final icon = genUiIcon(widget.props['icon']);
    final label = _buttonLabel(widget.item);
    return _Checks(
      item: widget.item,
      builder: (context, failure) {
        final enabled = failure == null || ModalTrigger.maybeOf(context) != null;
        final onPressed = enabled && !_busy ? () => _press(context) : null;
        final fg = switch (variant) {
          'primary' => scheme.onPrimary,
          'tonal' => scheme.onSecondaryContainer,
          'destructive' => scheme.onError,
          _ => scheme.primary,
        };
        Widget content = ContentColor(
          color: onPressed == null ? null : fg,
          child: IconTheme.merge(
            data: IconThemeData(size: 18, color: onPressed == null ? null : fg),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon), const SizedBox(width: 8)],
              Flexible(child: widget.item.child(widget.item.raw['child'])),
            ]),
          ),
        );
        final Widget button = switch (variant) {
          'primary' => FilledButton(onPressed: onPressed, child: content),
          'tonal' => FilledButton.tonal(onPressed: onPressed, child: content),
          'destructive' => FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError),
              onPressed: onPressed,
              child: content),
          'borderless' => TextButton(onPressed: onPressed, child: content),
          _ => OutlinedButton(onPressed: onPressed, child: content),
        };
        Widget out = Semantics(
          button: true,
          label: label.isEmpty ? null : label,
          enabled: onPressed != null,
          child: button,
        );
        if (failure != null && ModalTrigger.maybeOf(context) == null) {
          out = Tooltip(message: failure, child: out);
        }
        return widget.props['fullWidth'] == true
            ? SizedBox(width: double.infinity, child: out)
            : Align(alignment: Alignment.centerLeft, widthFactor: 1, child: out);
      },
    );
  }
}

/// An input's value: bound to the data model, or local to the widget when
/// the component holds a literal.
mixin _BoundInput<T extends StatefulWidget> on State<T> {
  GenUiItem get item;
  Object? local;
  bool touched = false;

  Object? get binding => item.raw['value'];

  void set(Object? value) {
    touched = true;
    if (isBinding(binding)) {
      item.write(binding, value);
    } else {
      setState(() => local = value);
    }
  }

  Widget bound(Widget Function(BuildContext context, Object? value) builder) =>
      Resolved(
        context: item.dataContext,
        value: binding,
        builder: (context, v) =>
            builder(context, isBinding(binding) ? v : (local ?? v)),
      );
}

Widget _errorText(BuildContext context, String? message) => message == null
    ? const SizedBox.shrink()
    : Padding(
        padding: const EdgeInsets.only(top: 4, left: 12),
        child: Text(message,
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.error)),
      );

final textFieldItem = asemanItem(
  'TextField',
  description: 'A text input bound to the data model ({"path": "/form/x"}).',
  properties: {
    'label': P.any('The field label.'),
    'value': P.any('A {"path"} binding the text is written to.'),
    'variant': P.str('Kind of input.', ['shortText', 'longText', 'number', 'obscured']),
    'validationRegexp': P.str('A pattern the text must match.'),
    'checks': P.checks(),
    'placeholder': P.any('Aseman: hint text inside the field.'),
    'helper': P.any('Aseman: help text under the field.'),
    'icon': P.any('Aseman: a leading icon name.'),
    'action': P.action('Aseman: fired when the text is submitted (Enter); '
        'its context also gets {"value": text}.'),
  },
  required: ['label'],
  raw: {'value'},
  implicitlyFlexible: true,
  build: (item, p) => _GenUiTextField(item: item, props: p),
);

class _GenUiTextField extends StatefulWidget {
  const _GenUiTextField({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_GenUiTextField> createState() => _GenUiTextFieldState();
}

class _GenUiTextFieldState extends State<_GenUiTextField>
    with _BoundInput<_GenUiTextField> {
  final _controller = TextEditingController();
  bool _obscured = true;

  @override
  GenUiItem get item => widget.item;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final variant = p['variant'] ?? 'shortText';
    final label = stringifyValue(p['label']);
    final placeholder = stringifyValue(p['placeholder']);
    final helper = stringifyValue(p['helper']);
    final icon = genUiIcon(p['icon']);
    return bound((context, value) {
      final text = value == null ? '' : stringifyValue(value);
      if (_controller.text != text) {
        _controller.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length));
      }
      return _Checks(
        item: item,
        builder: (context, failure) {
          var error = failure;
          final pattern = p['validationRegexp'];
          if (error == null && pattern is String && text.isNotEmpty) {
            try {
              if (!RegExp(pattern).hasMatch(text)) error = 'Invalid format';
            } catch (_) {}
          }
          final showError = error != null && (touched || text.isNotEmpty);
          return TextField(
            controller: _controller,
            obscureText: variant == 'obscured' && _obscured,
            minLines: variant == 'longText' ? 3 : 1,
            maxLines: variant == 'longText' ? 6 : 1,
            keyboardType: switch (variant) {
              'number' => const TextInputType.numberWithOptions(
                  decimal: true, signed: true),
              'longText' => TextInputType.multiline,
              _ => TextInputType.text,
            },
            inputFormatters: variant == 'number'
                ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]'))]
                : null,
            decoration: InputDecoration(
              labelText: label.isEmpty ? null : label,
              hintText: placeholder.isEmpty ? null : placeholder,
              helperText: helper.isEmpty ? null : helper,
              errorText: showError ? error : null,
              prefixIcon: icon == null ? null : Icon(icon, size: 20),
              suffixIcon: variant == 'obscured'
                  ? IconButton(
                      tooltip: _obscured ? 'Show' : 'Hide',
                      icon: Icon(_obscured
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded),
                      onPressed: () => setState(() => _obscured = !_obscured))
                  : null,
            ),
            onChanged: (v) => set(variant == 'number' && toNum(v) != null
                ? toNum(v)
                : v),
            onSubmitted: item.raw['action'] == null
                ? null
                : (v) => item.fire(item.raw['action'], extra: {'value': v}),
          );
        },
      );
    });
  }
}

final checkBoxItem = asemanItem(
  'CheckBox',
  description: 'A checkbox with a label, bound to a boolean.',
  properties: {
    'label': P.any('The label.'),
    'value': P.any('A {"path"} binding to a boolean.'),
    'checks': P.checks(),
  },
  required: ['label', 'value'],
  raw: {'value'},
  build: (item, p) => _GenUiCheckBox(item: item, label: stringifyValue(p['label'])),
);

class _GenUiCheckBox extends StatefulWidget {
  const _GenUiCheckBox({required this.item, required this.label});
  final GenUiItem item;
  final String label;

  @override
  State<_GenUiCheckBox> createState() => _GenUiCheckBoxState();
}

class _GenUiCheckBoxState extends State<_GenUiCheckBox>
    with _BoundInput<_GenUiCheckBox> {
  @override
  GenUiItem get item => widget.item;

  @override
  Widget build(BuildContext context) => bound((context, value) {
        final checked = toBool(value);
        return _Checks(
          item: item,
          builder: (context, failure) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(AppShape.control),
                onTap: () => set(!checked),
                child: Row(children: [
                  Checkbox(value: checked, onChanged: (v) => set(v == true)),
                  Flexible(
                      child: Text(widget.label,
                          style: genUiTextStyle(context, 'body'))),
                ]),
              ),
              _errorText(context, touched ? failure : null),
            ],
          ),
        );
      });
}

final choicePickerItem = asemanItem(
  'ChoicePicker',
  description: 'Pick one or several options (radio / checkbox list, or chips).',
  properties: {
    'label': P.any('The label.'),
    'options': S.list(
        description: 'The options: [{label, value}].',
        items: S.object(additionalProperties: true)),
    'value': P.any('A {"path"} binding to the list of chosen values.'),
    'variant': P.str('One or many.', ['mutuallyExclusive', 'multipleSelection']),
    'displayStyle': P.str('Look.', ['checkbox', 'chips']),
    'filterable': P.any('Show a filter field over the options.'),
    'checks': P.checks(),
  },
  required: ['options', 'value'],
  raw: {'value'},
  build: (item, p) => _GenUiChoicePicker(item: item, props: p),
);

class _GenUiChoicePicker extends StatefulWidget {
  const _GenUiChoicePicker({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_GenUiChoicePicker> createState() => _GenUiChoicePickerState();
}

class _GenUiChoicePickerState extends State<_GenUiChoicePicker>
    with _BoundInput<_GenUiChoicePicker> {
  String _filter = '';

  @override
  GenUiItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final multiple = p['variant'] == 'multipleSelection';
    final chips = p['displayStyle'] == 'chips';
    final options = [
      for (final o in p['options'] is List ? p['options'] as List : const [])
        if (o is Map && o['value'] != null)
          (
            value: stringifyValue(o['value']),
            label: stringifyValue(o['label']).isEmpty
                ? stringifyValue(o['value'])
                : stringifyValue(o['label']),
          ),
    ];
    final label = stringifyValue(p['label']);
    return bound((context, current) {
      final selected = current is List
          ? current.map(stringifyValue).toList()
          : current is String && current.isNotEmpty
              ? [current]
              : <String>[];
      void choose(String v) => set(multiple
          ? (selected.contains(v)
              ? selected.where((s) => s != v).toList()
              : [...selected, v])
          : [v]);
      final visible = _filter.isEmpty
          ? options
          : options
              .where((o) => o.label.toLowerCase().contains(_filter.toLowerCase()))
              .toList();
      return _Checks(
        item: item,
        builder: (context, failure) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label,
                    style: genUiTextStyle(context, 'caption')
                        .copyWith(fontWeight: FontWeight.w600)),
              ),
            if (toBool(p['filterable']))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  decoration: const InputDecoration(
                      hintText: 'Filter options',
                      prefixIcon: Icon(Icons.search_rounded, size: 20),
                      isDense: true),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            if (chips)
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final o in visible)
                  FilterChip(
                    label: Text(o.label),
                    selected: selected.contains(o.value),
                    onSelected: (_) => choose(o.value),
                  ),
              ])
            else
              for (final o in visible)
                InkWell(
                  borderRadius: BorderRadius.circular(AppShape.control),
                  onTap: () => choose(o.value),
                  child: Row(children: [
                    if (multiple)
                      Checkbox(
                          value: selected.contains(o.value),
                          onChanged: (_) => choose(o.value))
                    else
                      // ignore: deprecated_member_use
                      Radio<String>(
                          value: o.value,
                          // ignore: deprecated_member_use
                          groupValue: selected.isEmpty ? null : selected.first,
                          // ignore: deprecated_member_use
                          onChanged: (_) => choose(o.value)),
                    Flexible(
                        child: Text(o.label,
                            style: genUiTextStyle(context, 'body'))),
                  ]),
                ),
            _errorText(context, touched ? failure : null),
          ],
        ),
      );
    });
  }
}

final sliderItem = asemanItem(
  'Slider',
  description: 'A slider for a number between min and max.',
  properties: {
    'label': P.any('The label.'),
    'value': P.any('A {"path"} binding to the number.'),
    'min': P.any('The lowest value (default 0).'),
    'max': P.any('The highest value.'),
    'checks': P.checks(),
    'step': P.any('Aseman: snap to multiples of this.'),
    'format': P.any('Aseman: how the value is shown (e.g. percent, '
        'currency).'),
  },
  required: ['value', 'max'],
  raw: {'value'},
  build: (item, p) => _GenUiSlider(item: item, props: p),
);

class _GenUiSlider extends StatefulWidget {
  const _GenUiSlider({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_GenUiSlider> createState() => _GenUiSliderState();
}

class _GenUiSliderState extends State<_GenUiSlider>
    with _BoundInput<_GenUiSlider> {
  @override
  GenUiItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    final p = widget.props;
    final min = toNum(p['min']) ?? 0;
    final rawMax = toNum(p['max']);
    final max = rawMax != null && rawMax > min ? rawMax : min + 100;
    final step = toNum(p['step']);
    final divisions =
        step != null && step > 0 ? ((max - min) / step).round() : null;
    final label = stringifyValue(p['label']);
    return bound((context, raw) {
      final n = toNum(raw) ?? toNum(item.raw['value']) ?? min;
      final value = n.clamp(min, max);
      final shown = p['format'] is String
          ? stringifyValue(_format(value, p['format'] as String))
          : value == value.roundToDouble()
              ? '${value.round()}'
              : value.toStringAsFixed((max - min).abs() <= 1 ? 2 : 1);
      return _Checks(
        item: item,
        builder: (context, failure) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                  child: Text(label, style: genUiTextStyle(context, 'caption'))),
              Text(shown,
                  style: genUiTextStyle(context, 'body')
                      .copyWith(fontWeight: FontWeight.w700)),
            ]),
            Slider(
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: divisions,
              value: value.toDouble(),
              onChanged: (v) => set(v == v.roundToDouble() ? v.round() : v),
            ),
            _errorText(context, failure),
          ],
        ),
      );
    });
  }
}

Object _format(num v, String format) => kit.formatValue(v, format);

final dateTimeInputItem = asemanItem(
  'DateTimeInput',
  description: 'A date and/or time picker writing ISO 8601 text.',
  properties: {
    'label': P.any('The label.'),
    'value': P.any('A {"path"} binding to the ISO date/time.'),
    'enableDate': P.any('Pick a date.'),
    'enableTime': P.any('Pick a time.'),
    'min': P.any('The earliest value (ISO).'),
    'max': P.any('The latest value (ISO).'),
    'checks': P.checks(),
  },
  required: ['value'],
  raw: {'value'},
  build: (item, p) => _GenUiDateTime(item: item, props: p),
);

class _GenUiDateTime extends StatefulWidget {
  const _GenUiDateTime({required this.item, required this.props});
  final GenUiItem item;
  final Map<String, dynamic> props;

  @override
  State<_GenUiDateTime> createState() => _GenUiDateTimeState();
}

class _GenUiDateTimeState extends State<_GenUiDateTime>
    with _BoundInput<_GenUiDateTime> {
  @override
  GenUiItem get item => widget.item;

  String get _mode {
    final date = toBool(widget.props['enableDate']);
    final time = toBool(widget.props['enableTime']);
    return date && !time
        ? 'date'
        : time && !date
            ? 'time'
            : 'datetime';
  }

  Future<void> _pick(BuildContext context, DateTime? current) async {
    final mode = _mode;
    final now = DateTime.now();
    final first = parseDate(widget.props['min']) ?? DateTime(1900);
    final last = parseDate(widget.props['max']) ?? DateTime(2200);
    var picked = current ?? now;
    if (mode != 'time') {
      final day = await showDatePicker(
        context: context,
        initialDate: picked.isBefore(first)
            ? first
            : picked.isAfter(last)
                ? last
                : picked,
        firstDate: first,
        lastDate: last,
      );
      if (day == null) return;
      picked = DateTime(day.year, day.month, day.day, picked.hour, picked.minute);
    }
    if (mode != 'date' && context.mounted) {
      final time = await showTimePicker(
          context: context, initialTime: TimeOfDay.fromDateTime(picked));
      if (time == null) return;
      picked = DateTime(
          picked.year, picked.month, picked.day, time.hour, time.minute);
    }
    String two(int n) => n.toString().padLeft(2, '0');
    final date = '${picked.year.toString().padLeft(4, '0')}-'
        '${two(picked.month)}-${two(picked.day)}';
    final time = '${two(picked.hour)}:${two(picked.minute)}:00';
    set(switch (mode) {
      'date' => date,
      'time' => time,
      _ => '${date}T$time',
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = stringifyValue(widget.props['label']);
    return bound((context, value) {
      final iso = stringifyValue(value);
      final date = parseDate(iso);
      final mode = _mode;
      final shown = date == null
          ? ''
          : formatDatePattern(
              date,
              switch (mode) {
                'date' => 'MMM d, yyyy',
                'time' => 'HH:mm',
                _ => 'MMM d, yyyy HH:mm',
              });
      return _Checks(
        item: item,
        builder: (context, failure) => InkWell(
          borderRadius: BorderRadius.circular(AppShape.control),
          onTap: () => _pick(context, date),
          child: InputDecorator(
            isEmpty: shown.isEmpty,
            decoration: InputDecoration(
              labelText: label.isEmpty ? null : label,
              errorText: touched ? failure : null,
              suffixIcon: Icon(
                  mode == 'time'
                      ? Icons.schedule_rounded
                      : Icons.calendar_today_rounded,
                  size: 20),
            ),
            child: Text(shown, style: genUiTextStyle(context, 'body')),
          ),
        ),
      );
    });
  }
}

/// The basic catalog's components.
final List<CatalogItem> basicItems = [
  textItem, imageItem, iconItem, videoItem, audioItem, rowItem, columnItem, //
  listItem, cardItem, tabsItem, modalItem, dividerItem, buttonItem,
  textFieldItem, checkBoxItem, choicePickerItem, sliderItem, dateTimeInputItem,
];
