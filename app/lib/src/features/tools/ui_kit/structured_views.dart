/// Hierarchies and raw structure: an expandable tree, a JSON inspector and
/// a code block.
library;

import 'package:aseman/src/elpian/core/lenient.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'palette.dart';
import 'values.dart';

/// An expandable tree of `{label, children, value?, icon?}` nodes.
class TreeView extends StatefulWidget {
  const TreeView({super.key, required this.props, this.onSelect});
  final Map<String, dynamic> props;
  final void Function(Map<String, dynamic> detail)? onSelect;

  @override
  State<TreeView> createState() => _TreeViewState();
}

class _TreeViewState extends State<TreeView> {
  final Map<String, bool> _open = {};
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final data = widget.props['data'] ?? widget.props['nodes'];
    final roots = data is List ? data : [data];
    final depth = asInt(widget.props['expanded'], 1);
    final labelField = '${widget.props['labelField'] ?? 'label'}';
    final childrenField = '${widget.props['childrenField'] ?? 'children'}';
    final format = looseStr(widget.props['format']);
    final rows = <Widget>[];

    void walk(Object? node, String path, int level) {
      if (node == null) return;
      final m = node is Map ? asMap(node) : {'label': node};
      final kids = asList(m[childrenField]);
      final open = _open[path] ?? level < depth;
      final icon = iconFor(m['icon']);
      rows.add(InkWell(
        onTap: () {
          setState(() {
            if (kids.isNotEmpty) _open[path] = !open;
            _selected = path;
          });
          widget.onSelect?.call({'path': path, 'node': m});
        },
        child: Container(
          color: _selected == path ? p.hover : null,
          padding: EdgeInsets.only(
              left: 4 + level * 18.0, top: 6, bottom: 6, right: 8),
          child: Row(children: [
            SizedBox(
              width: 20,
              child: kids.isEmpty
                  ? null
                  : Icon(open ? Icons.expand_more : Icons.chevron_right,
                      size: 18, color: p.textSecondary),
            ),
            if (icon != null) ...[
              Icon(icon, size: 16, color: p.textSecondary),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(asText(m[labelField] ?? m['name'] ?? m['id']),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13.5, color: p.textPrimary)),
            ),
            if (m['value'] != null)
              Text(formatValue(m['value'], format), style: VizText.value(p)),
          ]),
        ),
      ));
      if (open) {
        for (var i = 0; i < kids.length; i++) {
          walk(kids[i], '$path/$i', level + 1);
        }
      }
    }

    for (var i = 0; i < roots.length; i++) {
      walk(roots[i], '$i', 0);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// A collapsible JSON inspector.
class JsonView extends StatefulWidget {
  const JsonView({super.key, required this.value, this.expanded = 2});
  final Object? value;
  final int expanded;

  @override
  State<JsonView> createState() => _JsonViewState();
}

class _JsonViewState extends State<JsonView> {
  final Map<String, bool> _open = {};

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final mono = TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        color: p.textPrimary,
        height: 1.45);
    final rows = <Widget>[];

    TextSpan scalar(Object? v) {
      if (v is String) {
        return TextSpan(
            text: '"$v"',
            style: mono.copyWith(
                color: p.dark
                    ? const Color(0xFF7FC8A9)
                    : const Color(0xFF1B7F5A)));
      }
      if (v is num) {
        return TextSpan(text: '$v', style: mono.copyWith(color: p.series(0)));
      }
      return TextSpan(text: '$v', style: mono.copyWith(color: p.series(6)));
    }

    void walk(String? key, Object? v, String path, int level) {
      final keySpan = key == null
          ? const TextSpan()
          : TextSpan(
              text: '$key: ', style: mono.copyWith(color: p.textSecondary));
      final indent = EdgeInsets.only(left: level * 16.0);
      if (v is Map || v is List) {
        final entries = v is Map
            ? [for (final e in v.entries) ('${e.key}', e.value)]
            : [for (var i = 0; i < (v as List).length; i++) ('$i', v[i])];
        final open = _open[path] ?? level < widget.expanded;
        final brackets = v is Map ? ('{', '}') : ('[', ']');
        rows.add(InkWell(
          onTap: () => setState(() => _open[path] = !open),
          child: Padding(
            padding: indent,
            // Inside a horizontal scroll: rows size to their content.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(open ? Icons.arrow_drop_down : Icons.arrow_right,
                  size: 16, color: p.textSecondary),
              Text.rich(TextSpan(children: [
                keySpan,
                TextSpan(
                    text: open
                        ? brackets.$1
                        : '${brackets.$1} ${entries.length} ${v is Map ? 'keys' : 'items'} ${brackets.$2}',
                    style: mono.copyWith(color: p.textMuted)),
              ])),
            ]),
          ),
        ));
        if (open) {
          for (final (k, child) in entries) {
            walk(v is Map ? k : null, child, '$path/$k', level + 1);
          }
          rows.add(Padding(
            padding: indent.add(const EdgeInsets.only(left: 16)),
            child: Text(brackets.$2, style: mono.copyWith(color: p.textMuted)),
          ));
        }
        return;
      }
      rows.add(Padding(
        padding: indent.add(const EdgeInsets.only(left: 16)),
        child: Text.rich(TextSpan(children: [keySpan, scalar(v)])),
      ));
    }

    walk(null, widget.value, '', 0);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: p.hover,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: rows,
        ),
      ),
    );
  }
}

/// Monospaced code with an optional language label, line numbers and a
/// copy button.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.props});
  final Map<String, dynamic> props;

  @override
  Widget build(BuildContext context) {
    final p = VizPalette.of(context);
    final code = asText(props['code'] ?? props['text']);
    final language = looseStr(props['language']);
    final lines = code.split('\n');
    final numbers = asBool(props['lineNumbers']);
    final mono = TextStyle(
        fontFamily: 'monospace',
        fontSize: 12.5,
        height: 1.5,
        color: p.textPrimary);
    Widget body = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (numbers)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                [for (var i = 1; i <= lines.length; i++) '$i'].join('\n'),
                textAlign: TextAlign.right,
                style: mono.copyWith(color: p.textMuted),
              ),
            ),
          SelectableText(code, style: mono),
        ],
      ),
    );
    final maxHeight = asSizeOrNull(props['maxHeight']);
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(child: body),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: p.dark ? const Color(0xFF151514) : const Color(0xFFF5F4F1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: p.grid),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.grid))),
            child: Row(children: [
              Expanded(
                child: Text(language ?? '',
                    style: VizText.label(p).copyWith(fontSize: 12)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              ),
            ]),
          ),
          body,
        ],
      ),
    );
  }
}
