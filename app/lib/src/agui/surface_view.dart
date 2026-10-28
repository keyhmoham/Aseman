import 'package:flutter/material.dart';

import '../features/tools/ui_kit/kit.dart';
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
  });

  final AgUiSurface surface;
  final AgUiReply? onReply;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final root = surface.root;
    if (root == null) {
      return Text('Empty AG-UI surface',
          style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12));
    }
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
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
        return Card(
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
      case 'Markdown':
        return Text('${props['content'] ?? props['text'] ?? props['value'] ?? ''}',
            style: const TextStyle(fontSize: 13, height: 1.35));
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
        if (kitBuilders.containsKey(type)) {
          return _kit(type, props, kids);
        }
        return Text('Unknown AG-UI node: $type',
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic));
    }
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
