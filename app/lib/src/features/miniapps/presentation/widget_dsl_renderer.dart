import 'package:flutter/material.dart';

import '../domain/widget_dsl.dart';

/// Renders a miniapp [DeskWidgetDsl] inside a room-desk tile. Rows are laid
/// out vertically and are kept compact to fit small mosaic tiles. Actions are
/// executed through [onAction], which returns the backend reply string shown
/// as a snackbar.
class WidgetDslRenderer extends StatefulWidget {
  const WidgetDslRenderer({
    super.key,
    required this.dsl,
    required this.onAction,
    this.accent = Colors.cyanAccent,
    this.dense = false,
  });

  final DeskWidgetDsl dsl;
  final Future<String> Function(DslAction action, Map<String, dynamic> inline)
      onAction;
  final Color accent;
  final bool dense;

  @override
  State<WidgetDslRenderer> createState() => _WidgetDslRendererState();
}

class _WidgetDslRendererState extends State<WidgetDslRenderer> {
  final _fields = <String, TextEditingController>{};
  final _toggles = <String, bool>{};
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.dsl.rows;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < rows.length; i++) ...[
        _buildRow(rows[i]),
        if (i < rows.length - 1 && !widget.dense) const SizedBox(height: 7),
      ],
    ]);
  }

  Widget _buildRow(DslRow row) {
    final color = _colorFor(row.color);
    switch (row.type) {
      case 'divider':
        return const Divider(height: 10);
      case 'metric':
        return _Metric(
            label: row.label,
            value: row.value?.toString() ?? '',
            delta: row.delta,
            color: color,
            accent: widget.accent);
      case 'sparkline':
        return _Sparkline(data: row.data, delta: row.delta, color: color);
      case 'gauge':
        return _Gauge(
            value: _num(row.value),
            max: row.max,
            label: row.label,
            color: color);
      case 'progress':
        return _Progress(
            label: row.label, value: _num(row.value), color: color);
      case 'status':
        return _Status(
            label: row.label, value: row.value?.toString() ?? '', color: color);
      case 'list':
        return _ListBlock(
            items: row.items, color: color, accent: widget.accent);
      case 'button':
        final action = row.action;
        if (action == null) return const SizedBox.shrink();
        return _ActionButton(
            label: row.text.isEmpty ? row.label : row.text,
            accent: widget.accent,
            onTap: () => _run(action, const {}));
      case 'toggle':
        final action = row.action;
        if (action == null) return const SizedBox.shrink();
        return _ToggleRow(
            label: row.label,
            value: _toggles[row.label] ?? row.toggle,
            accent: widget.accent,
            onChanged: (value) {
              setState(() => _toggles[row.label] = value);
              _run(action, {'value': value, 'enabled': value});
            });
      case 'text_field':
        final submit = row.submit;
        final controller =
            _fields[row.label] ??= TextEditingController(text: row.text);
        return _FieldRow(
            label: row.label,
            controller: controller,
            submit: submit,
            accent: widget.accent,
            onSubmit: (value) {
              if (submit == null) return;
              _run(submit, {'value': value});
            });
      case 'markdown':
      case 'label':
      default:
        return Text(row.text.isEmpty ? row.label : row.text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: widget.dense ? 9 : 11,
                height: 1.35,
                color: _colorFor(row.color)));
    }
  }

  Future<void> _run(DslAction action, Map<String, dynamic> inline) async {
    if (action.op.isEmpty) return;
    if (action.confirm.isNotEmpty && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm action'),
          content: Text(action.confirm),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Run')),
          ],
        ),
      );
      if (ok != true) return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final reply = await widget.onAction(action, inline);
      if (!mounted) return;
      if (reply.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(reply)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Action failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static double _num(Object? value) => value is num
      ? value.toDouble()
      : value is String
          ? double.tryParse(value) ?? 0
          : 0;

  Color _colorFor(String token) => switch (token) {
        'success' => Colors.greenAccent,
        'danger' => Colors.redAccent,
        'warning' => Colors.orangeAccent,
        'info' => Colors.cyanAccent,
        'muted' => Theme.of(context).colorScheme.onSurfaceVariant,
        'accent' => widget.accent,
        _ => widget.accent,
      };
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.label,
      required this.value,
      required this.delta,
      required this.color,
      required this.accent});
  final String label, value, delta;
  final Color color, accent;
  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 8,
                        letterSpacing: .6,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: color)),
              ])),
          if (delta.isNotEmpty)
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: color.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(8)),
                child: Text(delta,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: color))),
        ],
      );
}

class _Sparkline extends StatelessWidget {
  const _Sparkline(
      {required this.data, required this.delta, required this.color});
  final List<double> data;
  final String delta;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final points = data.isEmpty ? <double>[0, 1] : data;
    return SizedBox(
        height: 44,
        child: Stack(children: [
          Positioned.fill(
              child: CustomPaint(painter: _DataSparkPainter(points, color))),
          if (delta.isNotEmpty)
            Positioned(
                left: 0,
                bottom: 0,
                child: Text(delta,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: color))),
        ]));
  }
}

class _DataSparkPainter extends CustomPainter {
  const _DataSparkPainter(this.data, this.color);
  final List<double> data;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final min = data.reduce((a, b) => a < b ? a : b);
    final max = data.reduce((a, b) => a > b ? a : b);
    final span = (max - min).abs() < 1e-9 ? 1 : max - min;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final dx = size.width * i / (data.length - 1);
      final dy = size.height * (1 - (data[i] - min) / span);
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    canvas.drawPath(path, paint);
    final fill = Paint()
      ..shader = LinearGradient(colors: [
        color.withValues(alpha: .22),
        color.withValues(alpha: 0),
      ]).createShader(Offset.zero & size);
    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fillPath, fill);
  }

  @override
  bool shouldRepaint(covariant _DataSparkPainter old) =>
      old.data != data || old.color != color;
}

class _Gauge extends StatelessWidget {
  const _Gauge(
      {required this.value,
      required this.max,
      required this.label,
      required this.color});
  final double value, max;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final ratio = max > 0 ? (value / max).clamp(0.0, 1.0) : 0.0;
    return Column(children: [
      SizedBox(
          height: 34,
          width: 34,
          child: Stack(alignment: Alignment.center, children: [
            CircularProgressIndicator(
                value: ratio, strokeWidth: 4, color: color),
            Text('${value.round()}',
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w900, color: color)),
          ])),
      if (label.isNotEmpty)
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 8,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
  }
}

class _Progress extends StatelessWidget {
  const _Progress(
      {required this.label, required this.value, required this.color});
  final String label;
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty)
            Text(label,
                style:
                    const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: LinearProgressIndicator(
                  value: value.clamp(0.0, 1.0), minHeight: 7, color: color)),
        ],
      );
}

class _Status extends StatelessWidget {
  const _Status(
      {required this.label, required this.value, required this.color});
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(children: [
        if (label.isNotEmpty)
          Text(label,
              style: TextStyle(
                  fontSize: 9,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        if (label.isNotEmpty) const SizedBox(width: 6),
        Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
                color: color.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text(value,
                  style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w800, color: color)),
            ])),
      ]);
}

class _ListBlock extends StatelessWidget {
  const _ListBlock(
      {required this.items, required this.color, required this.accent});
  final List<DslRow> items;
  final Color color, accent;
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < items.length; i++)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(
                    child: Text(
                        items[i].label.isEmpty ? items[i].text : items[i].label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9))),
                const SizedBox(width: 6),
                Text(items[i].value?.toString() ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                        color: _itemColor(items[i]))),
              ])),
      ]);

  Color _itemColor(DslRow item) {
    if (item.color == 'success') return Colors.greenAccent;
    if (item.color == 'danger') return Colors.redAccent;
    if (item.color == 'warning') return Colors.orangeAccent;
    return item.color == 'accent' ? accent : color;
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton(
      {required this.label, required this.accent, required this.onTap});
  final String label;
  final Color accent;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => FilledButton.tonal(
      onPressed: onTap,
      style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          visualDensity: VisualDensity.compact,
          minimumSize: const Size(0, 30)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.bolt_rounded, size: 13, color: accent),
        const SizedBox(width: 5),
        Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10, fontWeight: FontWeight.w800))),
      ]));
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow(
      {required this.label,
      required this.value,
      required this.accent,
      required this.onChanged});
  final String label;
  final bool value;
  final Color accent;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: Text(label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10))),
        Transform.scale(
            scale: .72,
            child: Switch(
                value: value, activeThumbColor: accent, onChanged: onChanged)),
      ]);
}

class _FieldRow extends StatelessWidget {
  const _FieldRow(
      {required this.label,
      required this.controller,
      required this.submit,
      required this.accent,
      required this.onSubmit});
  final String label;
  final TextEditingController controller;
  final DslAction? submit;
  final Color accent;
  final ValueChanged<String> onSubmit;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
            child: TextField(
                controller: controller,
                onSubmitted: submit == null ? null : onSubmit,
                style: const TextStyle(fontSize: 10),
                decoration: InputDecoration(
                    isDense: true,
                    labelText: label.isEmpty ? null : label,
                    labelStyle: const TextStyle(fontSize: 9),
                    border: const OutlineInputBorder()))),
        if (submit != null)
          IconButton(
              onPressed: () => onSubmit(controller.text),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.send_rounded, size: 15, color: accent)),
      ]);
}
