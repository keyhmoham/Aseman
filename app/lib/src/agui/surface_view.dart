import 'package:flutter/material.dart';

import '../features/search_feed/presentation/rich_post_content.dart';
import '../features/tools/ui_kit/kit.dart';
import '../shared/widgets/glass_surface.dart';
import '../shared/widgets/overlay_panels.dart';
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
  });

  final AgUiSurface surface;
  final AgUiReply? onReply;
  final bool compact;

  /// When true (or when built under [AppSheetScope]) the body stays clear so
  /// the host bottom sheet paints the glass.
  final bool inBottomSheet;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final body = _surface(context);
      if (constraints.maxWidth.isFinite) return body;
      // A chat column can pass an unbounded width. Cards, charts and the
      // kit's rows need a finite one or they fail to lay out.
      return SizedBox(width: 320, child: body);
    });
  }

  Widget _surface(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final root = surface.root;
    if (root == null) {
      return Text('Empty AG-UI surface',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12));
    }
    final embedded = inBottomSheet || AppSheetScope.inSheetOf(context);
    return GlassSurface(
      embedded: embedded,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: EdgeInsets.all(compact ? 10 : 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (surface.title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(surface.title,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        color: scheme.onSurface)),
              ),
            Theme(
              data: Theme.of(context).copyWith(
                visualDensity: VisualDensity.compact,
              ),
              child: _node(root),
            ),
          ],
        ),
      ),
    );
  }

  Widget _node(dynamic raw) {
    if (raw == null) return const SizedBox.shrink();
    if (raw is String) {
      return Text(raw, style: const TextStyle(fontSize: 13, height: 1.35));
    }
    if (raw is! Map) {
      return Text('$raw', style: const TextStyle(fontSize: 12));
    }
    final node = Map<String, dynamic>.from(raw);
    final type = typeOf(node);
    final props = propsOf(node);
    final kids = childrenOf(node);

    switch (type) {
      case 'Column':
      case 'Stack':
        final gap = _gap(props['gap']);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: _spaced(kids.map(_node).toList(), gap),
        );
      case 'Row':
        return Wrap(
          spacing: _gap(props['gap']).toDouble(),
          runSpacing: 6,
          children: kids.map(_node).toList(),
        );
      case 'Section':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if ('${props['title'] ?? ''}'.isNotEmpty)
              Text('${props['title']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13)),
            if ('${props['description'] ?? props['subtitle'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Text('${props['description'] ?? props['subtitle']}',
                    style: const TextStyle(fontSize: 12, height: 1.3)),
              ),
            ..._spaced(kids.map(_node).toList(), 8),
          ],
        );
      case 'Card':
        final subtitle = '${props['subtitle'] ?? props['description'] ?? ''}'.trim();
        final body = props['content'] ?? props['body'] ?? props['text'];
        final recordSource = props['items'] ??
            props['fields'] ??
            props['pairs'] ??
            props['entries'] ??
            props['facts'] ??
            props['metrics'] ??
            (props['data'] is Map || props['data'] is List ? props['data'] : null);
        final childIsRecord = kids.any((k) {
          if (k is! Map) return false;
          final t = typeOf(Map<String, dynamic>.from(k));
          return t == 'KeyValue' || t == 'Stat' || t == 'DataGrid' || t == 'Table';
        });
        final showRecord =
            !childIsRecord && recordPairs(recordSource).isNotEmpty;
        return AppCard(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if ('${props['title'] ?? ''}'.isNotEmpty)
                  Text('${props['title']}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: 6),
                    child: Text(subtitle,
                        style: const TextStyle(fontSize: 12, height: 1.3)),
                  ),
                if (body is String && body.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: RichPostContent(body),
                  ),
                if (showRecord)
                  KeyValueList(props: {
                    if (recordSource is List) 'items': recordSource,
                    if (recordSource is Map) 'data': recordSource,
                  }),
                ...kids.map(_node),
              ],
            ),
          ),
        );
      case 'Divider':
        return const Divider(height: 16);
      case 'Spacer':
        return SizedBox(height: _gap(props['size'] ?? props['gap'] ?? 8).toDouble());
      case 'Scroll':
        return ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: (props['maxHeight'] as num?)?.toDouble() ?? 220),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: kids.map(_node).toList(),
            ),
          ),
        );
      case 'Text':
        final text =
            '${props['content'] ?? props['text'] ?? props['value'] ?? props['body'] ?? props['message'] ?? ''}'
                .trim();
        if (text.isEmpty) return const SizedBox.shrink();
        return Text(text, style: const TextStyle(fontSize: 13, height: 1.35));
      case 'Markdown':
        return RichPostContent(
            '${props['content'] ?? props['text'] ?? props['value'] ?? ''}');
      case 'Empty':
        return Text('${props['text'] ?? props['title'] ?? 'Nothing here'}',
            style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic));
      case 'List':
        final items = props['items'] is List ? props['items'] as List : kids;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final it in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(child: _node(it is Map ? it : {'c': 'Text', 'p': {'content': '$it'}})),
                  ],
                ),
              ),
          ],
        );
      case 'Question':
        return AgUiQuestion(
          question: '${props['question'] ?? props['label'] ?? ''}',
          options: _strings(props['options']),
          allowFreeText: props['allowFreeText'] != false,
          onReply: onReply,
          dense: compact,
        );
      case 'Choices':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ('${props['label'] ?? props['question'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${props['label'] ?? props['question']}',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            AgUiChoices(
              options: _strings(props['options']),
              onSelect: onReply == null ? null : (v) => onReply!(v, meta: {'kind': 'choices'}),
            ),
          ],
        );
      case 'Confirm':
        return AgUiConfirm(
          label: '${props['label'] ?? props['question'] ?? 'Continue?'}',
          confirmLabel: '${props['confirmLabel'] ?? props['yes'] ?? 'Yes'}',
          cancelLabel: '${props['cancelLabel'] ?? props['no'] ?? 'No'}',
          onReply: onReply,
        );
      case 'Form':
        return AgUiForm(
          fields: [
            for (final f in (props['fields'] is List ? props['fields'] as List : const []))
              if (f is Map) Map<String, dynamic>.from(f),
          ],
          submitLabel: '${props['submitLabel'] ?? 'Submit'}',
          onReply: onReply,
        );
      case 'Approval':
        return AgUiApproval(props: props);
      case 'Secret':
        return AgUiSecret(props: props);
      case 'Handover':
        return AgUiHandover(props: props);
      case 'Suggestion':
        return AgUiSuggestion(props: props);
      case 'Table':
        // Alias → DataGrid (ui_kit).
        return _kit('DataGrid', {
          ...props,
          if (props['data'] == null && props['rows'] != null) 'data': props['rows'],
        }, kids);
      default:
        if (type == 'Chart') return _chartOrFacts(props, kids);
        if (kitBuilders.containsKey(type)) {
          final kitProps = switch (type) {
            'Sparkline' => chartPropsForKit(props),
            'Callout' => calloutPropsForKit(props),
            _ => props,
          };
          return _kit(type, kitProps, kids);
        }
        return Text('Unknown AG-UI node: $type',
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic));
    }
  }

  /// A chart with numbers draws. One whose fields are words (a conditions
  /// card handed over as a chart) shows those fields. One with nothing
  /// draws nothing, so the card is not a tall empty plot.
  Widget _chartOrFacts(Map<String, dynamic> props, List<dynamic> kids) {
    final kitProps = chartPropsForKit(props);
    return Builder(builder: (context) {
      final spec = ChartSpec.fromProps(kitProps, VizPalette.of(context));
      if (spec.rows.isNotEmpty && spec.series.isNotEmpty) {
        return _kit('Chart', kitProps, kids);
      }
      final data = kitProps['data'] ??
          kitProps['points'] ??
          kitProps['values'] ??
          kitProps['rows'];
      if (recordPairs(data).isEmpty) return const SizedBox.shrink();
      return KeyValueList(props: {
        if (data is List) 'items': data,
        if (data is Map) 'data': data,
      });
    });
  }

  Widget _kit(String type, Map<String, dynamic> props, List<dynamic> kids) {
    final build = kitBuilders[type]!;
    final childWidgets = kids.map(_node).toList();
    return build(props, childWidgets, (event) {
      if (onReply == null) return null;
      return (String e, Map<String, dynamic> data) {
        onReply!('$e', meta: {'kind': 'event', 'event': e, 'data': data});
      };
    });
  }
}

num _gap(dynamic v) {
  if (v is num) return v;
  switch ('$v') {
    case 'none':
      return 0;
    case 'xs':
      return 4;
    case 's':
      return 8;
    case 'm':
      return 12;
    case 'l':
      return 16;
    case 'xl':
      return 24;
  }
  return 8;
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
