import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

class AdminStatCard extends StatelessWidget {
  const AdminStatCard({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.icon,
    this.onTap,
    this.tone,
  });

  final String label;
  final String value;
  final String? hint;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = Container(
      constraints: const BoxConstraints(minWidth: 170, minHeight: 116),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 17, color: tone ?? scheme.primary),
            const SizedBox(width: 7),
          ],
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ),
          if (onTap != null)
            Icon(Icons.arrow_forward_rounded,
                size: 15, color: scheme.onSurfaceVariant),
        ]),
        const SizedBox(height: 8),
        // Live values cross-fade in place instead of re-rendering the card.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, if (current != null) current]),
          child: Text(value,
              key: ValueKey(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 24,
                  height: 1.05,
                  color: tone,
                  fontWeight: FontWeight.w900)),
        ),
        if (hint != null) ...[
          const SizedBox(height: 7),
          Text(hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  height: 1.25, fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ]),
    );
    return onTap == null
        ? card
        : InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: card,
          );
  }
}

class AdminSectionCard extends StatelessWidget {
  const AdminSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.all(16),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title.toUpperCase(),
                style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8)),
            if (subtitle != null) ...[
              const SizedBox(height: 3),
              Text(subtitle!,
                  style:
                      TextStyle(color: scheme.onSurfaceVariant, fontSize: 11)),
            ],
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
      const SizedBox(height: 9),
      // A Material (not a decorated Container) so list tiles inside the card
      // paint their ink and selection on the card itself.
      Material(
        color: scheme.surfaceContainerLow,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .65)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: SizedBox(
          width: double.infinity,
          child: Padding(padding: padding, child: child),
        ),
      ),
    ]);
  }
}

class AdminStatusPill extends StatelessWidget {
  const AdminStatusPill(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase().trim();
    final ok = const {
      'approved',
      'credited',
      'paid',
      'healthy',
      'running',
      'ready',
      'live',
      'started',
      'awake',
      'ok',
      'listed',
      'loaded',
      'initialized',
      'active'
    }.contains(normalized);
    final warn = const {
      'pending',
      'queued',
      'installing',
      'provisioning',
      'waiting',
      'working',
      'warn',
      'sandbox',
      'asleep',
      'needs setup'
    }.contains(normalized);
    final bad = const {
      'denied',
      'failed',
      'rejected',
      'reversed',
      'error',
      'fail',
      'disabled'
    }.contains(normalized);
    final color = ok
        ? AppColors.success
        : warn
            ? AppColors.warning
            : bad
                ? AppColors.danger
                : Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: .26))),
      child: Text(normalized.isEmpty ? 'unknown' : normalized,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }
}

class AdminSearchField extends StatelessWidget {
  const AdminSearchField({
    super.key,
    required this.controller,
    required this.hint,
    this.onChanged,
    this.trailing,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              prefixIcon: const Icon(Icons.search_rounded, size: 19),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () {
                        controller.clear();
                        onChanged?.call('');
                      },
                      icon: const Icon(Icons.close_rounded, size: 18)),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ]);
}

class AdminTableColumn {
  const AdminTableColumn(this.label,
      {this.width = 150, this.align = TextAlign.left});
  final String label;
  final double width;
  final TextAlign align;
}

class AdminDataTable extends StatelessWidget {
  const AdminDataTable({
    super.key,
    required this.columns,
    required this.rows,
    this.empty = 'Nothing to show.',
    this.onRowTap,
    this.selected,
  });

  final List<AdminTableColumn> columns;
  final List<List<Widget>> rows;
  final String empty;
  final ValueChanged<int>? onRowTap;
  final bool Function(int index)? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Rows have 14 px horizontal padding on both sides. Include it in the
    // scroll extent so fixed-width cells never overflow the row itself.
    final natural = columns.fold<double>(0, (sum, col) => sum + col.width) + 28;
    // Column widths are minimums: on wide screens they grow proportionally so
    // the table fills the page; on narrow ones the table scrolls sideways.
    return LayoutBuilder(builder: (context, constraints) {
      final available =
          constraints.hasBoundedWidth ? constraints.maxWidth - 2 : natural;
      final scale =
          available > natural ? (available - 29) / (natural - 28) : 1.0;
      final width = available > natural ? available : natural;
      return _table(context, scheme, width, scale);
    });
  }

  Widget _table(
      BuildContext context, ColorScheme scheme, double width, double scale) {
    Widget cell(Widget child, AdminTableColumn col, {bool header = false}) =>
        SizedBox(
          width: col.width * scale,
          child: DefaultTextStyle.merge(
            style: TextStyle(
                color: header ? scheme.onSurfaceVariant : scheme.onSurface,
                fontSize: header ? 11 : 12,
                fontWeight: header ? FontWeight.w800 : FontWeight.w500),
            textAlign: col.align,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Align(
                alignment: col.align == TextAlign.right
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: child,
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(children: [
            Container(
              color: scheme.surfaceContainerHighest.withValues(alpha: .6),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              child: Row(children: [
                for (final col in columns)
                  cell(Text(col.label), col, header: true),
              ]),
            ),
            if (rows.isEmpty)
              SizedBox(
                height: 96,
                child: Center(
                    child: Text(empty,
                        style: TextStyle(color: scheme.onSurfaceVariant))),
              ),
            for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
              Material(
                color: selected?.call(rowIndex) == true
                    ? scheme.primary.withValues(alpha: .08)
                    : Colors.transparent,
                child: InkWell(
                  onTap: onRowTap == null ? null : () => onRowTap!(rowIndex),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 54),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                            color:
                                scheme.outlineVariant.withValues(alpha: .45)),
                      ),
                    ),
                    child: Row(children: [
                      for (var i = 0; i < columns.length; i++)
                        cell(
                            i < rows[rowIndex].length
                                ? rows[rowIndex][i]
                                : const SizedBox.shrink(),
                            columns[i]),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class AdminLiveChart extends StatelessWidget {
  const AdminLiveChart({
    super.key,
    required this.label,
    required this.value,
    required this.samples,
    this.subtitle,
    this.max = 100,
    this.color = AppColors.cyan,
  });
  final String label;
  final String value;
  final String? subtitle;
  final List<double> samples;
  final double max;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .65)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(label.toUpperCase(),
                style: TextStyle(
                    fontSize: 11,
                    letterSpacing: .7,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurfaceVariant)),
          ),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 21, fontWeight: FontWeight.w900)),
        ]),
        // On its own line so long readings wrap instead of overflowing.
        if (subtitle != null)
          Text(subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 12),
        SizedBox(
          height: 96,
          width: double.infinity,
          child: samples.isEmpty
              ? Center(
                  child: Text('Waiting for samples…',
                      style: TextStyle(color: scheme.onSurfaceVariant)))
              : CustomPaint(
                  painter: _LineChartPainter(
                      samples: samples,
                      max: max,
                      color: color,
                      grid: scheme.outlineVariant),
                ),
        ),
      ]),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  const _LineChartPainter(
      {required this.samples,
      required this.max,
      required this.color,
      required this.grid});
  final List<double> samples;
  final double max;
  final Color color;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid.withValues(alpha: .55)
      ..strokeWidth = 1;
    for (final fraction in const [.25, .5, .75]) {
      final y = size.height * fraction;
      for (double x = 0; x < size.width; x += 8) {
        canvas.drawLine(
            Offset(x, y), Offset(math.min(x + 4, size.width), y), gridPaint);
      }
    }
    final path = Path();
    final ceiling = math.max(1.0, max);
    for (var i = 0; i < samples.length; i++) {
      final x = samples.length == 1
          ? size.width
          : i / (samples.length - 1) * size.width;
      final y =
          size.height - (samples[i].clamp(0, ceiling) / ceiling) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: .12));
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    final last = samples.last.clamp(0, ceiling).toDouble();
    canvas.drawCircle(
        Offset(size.width, size.height - last / ceiling * size.height),
        3.2,
        Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.max != max ||
      oldDelegate.color != color;
}

class AdminEmptyState extends StatelessWidget {
  const AdminEmptyState(this.title, this.body, {super.key, this.icon});
  final String title;
  final String body;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      child: Column(children: [
        Icon(icon ?? Icons.inbox_outlined,
            size: 34, color: scheme.onSurfaceVariant),
        const SizedBox(height: 10),
        Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

class AdminKeyValue extends StatelessWidget {
  const AdminKeyValue(this.label, this.value, {super.key, this.mono = false});
  final String label;
  final String value;
  final bool mono;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          const SizedBox(width: 16),
          Flexible(
            child: SelectableText(value.isEmpty ? '—' : value,
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontSize: 12,
                    fontFamily: mono ? 'monospace' : null,
                    fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}
