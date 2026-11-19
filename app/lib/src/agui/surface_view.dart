import 'package:flutter/material.dart';

import '../features/search_feed/presentation/rich_post_content.dart';
import '../features/tools/ui_kit/kit.dart';
import '../shared/widgets/glass_surface.dart';
import '../shared/widgets/overlay_panels.dart';
import 'card_frame.dart';
import 'governance_cards.dart';
import 'hitl.dart';
import 'surface.dart';

/// Renders an [AgUiSurface] in chat (or compact desk) by reusing the App UI
/// kit builders — one component vocabulary, no parallel widget set.
class AgUiSurfaceView extends StatelessWidget {
  const AgUiSurfaceView({
    super.key,
    required this.surface,
    this.onReply,
    this.compact = true,
    this.inBottomSheet = false,
    this.messageId = '',
  });

  final AgUiSurface surface;

  /// The message the surface is in: what was answered stays answered when
  /// the list redraws.
  final String messageId;
  final AgUiReply? onReply;
  final bool compact;

  /// When true (or when built under [AppSheetScope]) the body stays clear so
  /// the host bottom sheet paints the glass.
  final bool inBottomSheet;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final body = _surface(context);
        if (constraints.maxWidth.isFinite) return body;
        // A chat column can pass an unbounded width. Cards, charts and the
        // kit's rows need a finite one or they fail to lay out.
        return SizedBox(width: 320, child: body);
      },
    );
  }

  Widget _surface(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final root = surface.root;
    if (root == null) {
      return Text(
        'Nothing to show',
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    final title = visibleTitle(surface);
    // A card that brings its own frame stands alone; anything else sits in
    // one calm box.
    final bare = isFramedRoot(root) || typeOf(root) == 'Card';
    final body = Theme(
      data: Theme.of(context).copyWith(visualDensity: VisualDensity.compact),
      child: _node(root, '0'),
    );
    if (bare) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: scheme.onSurface,
                ),
              ),
            ),
          body,
        ],
      );
    }
    final embedded = inBottomSheet || AppSheetScope.inSheetOf(context);
    return GlassSurface(
      embedded: embedded,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            body,
          ],
        ),
      ),
    );
  }

  String _stateKey(String path) => messageId.isEmpty ? '' : '$messageId#$path';

  List<Widget> _kids(List<dynamic> kids, String path) => [
    for (var i = 0; i < kids.length; i++) _node(kids[i], '$path.$i'),
  ];

  Widget _node(dynamic raw, String path) {
    if (raw == null) return const SizedBox.shrink();
    if (raw is String) {
      return Text(raw, style: const TextStyle(fontSize: 13.5, height: 1.4));
    }
    if (raw is! Map) {
      return Text('$raw', style: const TextStyle(fontSize: 12.5));
    }
    final node = Map<String, dynamic>.from(raw);
    final type = typeOf(node);
    final props = propsOf(node);
    final kids = childrenOf(node);
    final key = _stateKey(path);

    switch (type) {
      case 'Column':
      case 'Stack':
        final gap = _gap(props['gap']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _spaced(_kids(kids, path), gap),
        );
      case 'Row':
        return _row(kids, path, _gap(props['gap']).toDouble());
      case 'Section':
        return Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final desc = '${props['description'] ?? props['subtitle'] ?? ''}'
                .trim();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if ('${props['title'] ?? ''}'.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${props['title']}'.toUpperCase(),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 11.5,
                        letterSpacing: .7,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (desc.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      desc,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.3,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ..._spaced(_kids(kids, path), _gap(props['gap'] ?? 8)),
              ],
            );
          },
        );
      case 'Card':
        final subtitle = '${props['subtitle'] ?? props['description'] ?? ''}'
            .trim();
        final body = props['content'] ?? props['body'] ?? props['text'];
        final recordSource =
            props['items'] ??
            props['fields'] ??
            props['pairs'] ??
            props['entries'] ??
            props['facts'] ??
            props['metrics'] ??
            (props['data'] is Map || props['data'] is List
                ? props['data']
                : null);
        final childIsRecord = kids.any((k) {
          if (k is! Map) return false;
          final t = typeOf(Map<String, dynamic>.from(k));
          return t == 'KeyValue' ||
              t == 'Stat' ||
              t == 'DataGrid' ||
              t == 'Table';
        });
        final showRecord =
            !childIsRecord && recordPairs(recordSource).isNotEmpty;
        return Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            final parts = <Widget>[
              if ('${props['title'] ?? ''}'.isNotEmpty || subtitle.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if ('${props['title'] ?? ''}'.isNotEmpty)
                      Text(
                        '${props['title']}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14.5,
                          height: 1.3,
                        ),
                      ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.3,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              if (body is String && body.trim().isNotEmpty)
                RichPostContent(body),
              if (showRecord)
                KeyValueList(
                  props: {
                    if (recordSource is List) 'items': recordSource,
                    if (recordSource is Map) 'data': recordSource,
                  },
                ),
              ..._kids(kids, path),
            ];
            return AppCard(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: _spaced(parts, 8),
                ),
              ),
            );
          },
        );
      case 'Divider':
        return const Divider(height: 16);
      case 'Spacer':
        return SizedBox(
          height: _gap(props['size'] ?? props['gap'] ?? 8).toDouble(),
        );
      case 'Scroll':
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: (props['maxHeight'] as num?)?.toDouble() ?? 220,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _spaced(_kids(kids, path), 8),
            ),
          ),
        );
      case 'Text':
        final text =
            '${props['content'] ?? props['text'] ?? props['value'] ?? props['body'] ?? props['message'] ?? ''}'
                .trim();
        if (text.isEmpty) return const SizedBox.shrink();
        return _text(text, props);
      case 'Markdown':
        return RichPostContent(
          '${props['content'] ?? props['text'] ?? props['value'] ?? ''}',
        );
      case 'Empty':
        return Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Text(
                  '${props['text'] ?? props['title'] ?? 'Nothing here'}',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            );
          },
        );
      case 'List':
        final items = props['items'] is List ? props['items'] as List : kids;
        final ordered =
            props['ordered'] == true ||
            props['style'] == 'ordered' ||
            props['type'] == 'ordered';
        return Builder(
          builder: (context) {
            final scheme = Theme.of(context).colorScheme;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 22,
                          child: Text(
                            ordered ? '${i + 1}.' : '•',
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 1.4,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: _node(
                            items[i] is Map
                                ? items[i]
                                : {
                                    'c': 'Text',
                                    'p': {'content': '${items[i]}'},
                                  },
                            '$path.$i',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      case 'Question':
        return AgUiQuestion(
          question:
              '${props['question'] ?? props['label'] ?? props['title'] ?? ''}',
          options: _strings(props['options']),
          allowFreeText: props['allowFreeText'] != false,
          onReply: onReply,
          dense: compact,
          stateKey: key,
        );
      case 'Choices':
        return AgUiChoicesCard(
          label:
              '${props['label'] ?? props['question'] ?? props['title'] ?? ''}',
          options: _strings(props['options']),
          onReply: onReply,
          stateKey: key,
        );
      case 'Confirm':
        return AgUiConfirm(
          label:
              '${props['label'] ?? props['question'] ?? props['title'] ?? 'Continue?'}',
          detail:
              '${props['detail'] ?? props['text'] ?? props['description'] ?? ''}',
          confirmLabel: '${props['confirmLabel'] ?? props['yes'] ?? 'Yes'}',
          cancelLabel: '${props['cancelLabel'] ?? props['no'] ?? 'No'}',
          onReply: onReply,
          stateKey: key,
        );
      case 'Form':
        return AgUiForm(
          fields: [
            for (final f
                in (props['fields'] is List
                    ? props['fields'] as List
                    : const []))
              if (f is Map)
                Map<String, dynamic>.from(f)
              else if (f is String)
                {'label': f},
          ],
          title: '${props['title'] ?? props['label'] ?? ''}',
          submitLabel: '${props['submitLabel'] ?? props['submit'] ?? 'Submit'}',
          onReply: onReply,
          stateKey: key,
        );
      case 'Approval':
        return AgUiApproval(props: props);
      case 'Secret':
        return AgUiSecret(props: props);
      case 'Handover':
        return AgUiHandover(props: props);
      case 'Suggestion':
        return AgUiSuggestion(props: props);
      case 'Connect':
        return AgUiConnect(props: props);
      case 'Table':
        // Alias → DataGrid (ui_kit).
        return _kit(
          'DataGrid',
          {
            ...props,
            if (props['data'] == null && props['rows'] != null)
              'data': props['rows'],
          },
          kids,
          path,
        );
      default:
        if (type == 'Chart') return _chartOrFacts(props, kids);
        if (kitBuilders.containsKey(type)) {
          final kitProps = switch (type) {
            'Sparkline' => chartPropsForKit(props),
            'Callout' => calloutPropsForKit(props),
            _ => props,
          };
          return _kit(type, kitProps, kids, path);
        }
        // A part this app has no widget for: what it holds is still shown,
        // never an error message.
        if (kids.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: _spaced(_kids(kids, path), 8),
          );
        }
        final words = _fallbackText(props);
        return words.isEmpty
            ? const SizedBox.shrink()
            : Text(words, style: const TextStyle(fontSize: 13.5, height: 1.4));
    }
  }

  /// A row: tiles (stats, cards, charts…) share the width in equal columns
  /// and wrap when they would be narrower than 140; small things (tags,
  /// buttons) flow and wrap.
  Widget _row(List<dynamic> kids, String path, double gap) {
    const tiles = {
      'Stat',
      'Card',
      'Chart',
      'Gauge',
      'Progress',
      'Sparkline',
      'Section',
      'Callout',
      'KeyValue',
    };
    final widgets = _kids(kids, path);
    final tiled =
        kids.isNotEmpty &&
        kids.every(
          (k) =>
              k is Map && tiles.contains(typeOf(Map<String, dynamic>.from(k))),
        );
    if (!tiled) {
      return Wrap(
        spacing: gap,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: widgets,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth.isFinite ? box.maxWidth : 320.0;
        final cols = ((width + gap) / (140 + gap)).floor().clamp(
          1,
          widgets.length,
        );
        final each = (width - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap < 8 ? 8 : gap,
          children: [for (final w in widgets) SizedBox(width: each, child: w)],
        );
      },
    );
  }

  Widget _text(String text, Map<String, dynamic> props) {
    return Builder(
      builder: (context) {
        final scheme = Theme.of(context).colorScheme;
        final variant =
            '${props['variant'] ?? props['role'] ?? props['size'] ?? ''}'
                .toLowerCase();
        final muted = props['style'] == 'muted' || props['tone'] == 'muted';
        final bold = props['weight'] == 'bold' || props['bold'] == true;
        final (double size, FontWeight weight) = switch (variant) {
          'title' || 'h1' || 'large' => (18, FontWeight.w700),
          'heading' || 'subtitle' || 'h2' || 'medium' => (15, FontWeight.w700),
          'caption' || 'small' => (12, FontWeight.w400),
          _ => (13.5, bold ? FontWeight.w700 : FontWeight.w400),
        };
        final toned = props['tone'] != null && props['tone'] != 'muted'
            ? agUiToneColor(context, agUiToneOf(props['tone']))
            : null;
        return SelectableText(
          text,
          textAlign: switch ('${props['align'] ?? ''}') {
            'center' => TextAlign.center,
            'right' => TextAlign.right,
            _ => TextAlign.start,
          },
          style: TextStyle(
            fontSize: size,
            fontWeight: weight,
            fontStyle: props['italic'] == true ? FontStyle.italic : null,
            height: 1.4,
            color:
                toned ??
                (muted || variant == 'caption' || variant == 'small'
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface),
          ),
        );
      },
    );
  }

  String _fallbackText(Map<String, dynamic> props) {
    for (final k in const [
      'content',
      'text',
      'label',
      'title',
      'message',
      'value',
      'body',
      'name',
    ]) {
      final v = props[k];
      if (v is String || v is num) return '$v';
    }
    return '';
  }

  /// A chart with numbers draws. One whose fields are words (a conditions
  /// card handed over as a chart) shows those fields. One with nothing
  /// draws nothing, so the card is not a tall empty plot.
  Widget _chartOrFacts(Map<String, dynamic> props, List<dynamic> kids) {
    final kitProps = chartPropsForKit(props);
    return Builder(
      builder: (context) {
        final spec = ChartSpec.fromProps(kitProps, VizPalette.of(context));
        if (spec.rows.isNotEmpty && spec.series.isNotEmpty) {
          return _kit('Chart', kitProps, kids);
        }
        final data =
            kitProps['data'] ??
            kitProps['points'] ??
            kitProps['values'] ??
            kitProps['rows'];
        if (recordPairs(data).isEmpty) return const SizedBox.shrink();
        return KeyValueList(
          props: {
            if (data is List) 'items': data,
            if (data is Map) 'data': data,
          },
        );
      },
    );
  }

  Widget _kit(
    String type,
    Map<String, dynamic> props,
    List<dynamic> kids, [
    String path = '0',
  ]) {
    final build = kitBuilders[type]!;
    final childWidgets = _kids(kids, path);
    return build(props, childWidgets, (event) {
      if (onReply == null) return null;
      return (String e, Map<String, dynamic> data) {
        onReply!('$e', meta: {'kind': 'event', 'event': e, 'data': data});
      };
    });
  }
}

num _gap(dynamic v) {
  if (v is num) return v < 0 ? 0 : v;
  switch ('$v') {
    case 'none':
      return 0;
    case 'xs':
      return 4;
    case 's':
    case 'sm':
      return 8;
    case 'm':
    case 'md':
      return 12;
    case 'l':
    case 'lg':
      return 16;
    case 'xl':
      return 24;
  }
  // A number written as a string ("12") is still a number.
  final n = num.tryParse('$v');
  return n == null ? 8 : (n < 0 ? 0 : n);
}

List<Widget> _spaced(List<Widget> kids, num gap) {
  if (kids.isEmpty) return kids;
  final out = <Widget>[kids.first];
  for (var i = 1; i < kids.length; i++) {
    out.add(SizedBox(height: gap.toDouble()));
    out.add(kids[i]);
  }
  return out;
}

List<String> _strings(dynamic v) {
  if (v is! List) return const [];
  return [for (final o in v) '$o'.trim()].where((s) => s.isNotEmpty).toList();
}
