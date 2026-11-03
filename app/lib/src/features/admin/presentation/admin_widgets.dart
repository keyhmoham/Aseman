import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/sky_ui.dart';

/// Building blocks of the admin console, drawn in the Material 3 Expressive
/// style: tonal surfaces instead of outlines, generous corner radii, bold
/// display numbers and charts that ease in when their data arrives.

const _ok = {
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
  'active',
  'done',
  'completed',
  'succeeded',
};
const _warn = {
  'pending',
  'queued',
  'installing',
  'provisioning',
  'waiting',
  'working',
  'warn',
  'sandbox',
  'asleep',
  'needs setup',
  'review',
};
const _bad = {
  'denied',
  'failed',
  'rejected',
  'reversed',
  'error',
  'fail',
  'disabled',
  'unreachable',
};

/// The semantic tone of a backend status word.
enum AdminTone { ok, warn, bad, neutral }

AdminTone adminTone(String status) {
  final s = status.toLowerCase().trim();
  if (_ok.contains(s)) return AdminTone.ok;
  if (_warn.contains(s)) return AdminTone.warn;
  if (_bad.contains(s)) return AdminTone.bad;
  return AdminTone.neutral;
}

Color adminToneColor(BuildContext context, AdminTone tone) => switch (tone) {
      AdminTone.ok => AppColors.successOf(context),
      AdminTone.warn => AppColors.warningOf(context),
      AdminTone.bad => AppColors.dangerOf(context),
      AdminTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
    };

IconData adminToneIcon(AdminTone tone) => switch (tone) {
      AdminTone.ok => Icons.check_circle_rounded,
      AdminTone.warn => Icons.error_rounded,
      AdminTone.bad => Icons.cancel_rounded,
      AdminTone.neutral => Icons.radio_button_unchecked_rounded,
    };

/// Categorical colours for chart series, in a fixed order so the same slot
/// always means the same colour on a page.
List<Color> adminPalette(BuildContext context) =>
    ThemeRoles.identityPool(context);

/// A key figure. [progress] adds a thin meter under the value, [footer] any
/// small visual (a sparkline, a stacked bar).
class AdminStatCard extends StatelessWidget {
  const AdminStatCard({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.icon,
    this.onTap,
    this.tone,
    this.progress,
    this.footer,
  });

  final String label;
  final String value;
  final String? hint;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? tone;
  final double? progress;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = tone ?? scheme.primary;
    final body = Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[
            Container(
              width: 36,
              height: 36,
              decoration: ShapeDecoration(
                color: accent.withValues(alpha: .16),
                shape: RoundedRectangleBorder(
                    borderRadius: AppShape.borderRadius(context, 12)),
              ),
              child: Icon(icon, size: 19, color: accent),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant)),
          ),
          if (onTap != null)
            Icon(Icons.arrow_outward_rounded,
                size: 17, color: scheme.onSurfaceVariant),
        ]),
        const SizedBox(height: 12),
        // Live values cross-fade in place instead of re-rendering the card.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
                position: Tween(begin: const Offset(0, .25), end: Offset.zero)
                    .animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                child: child),
          ),
          layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, if (current != null) current]),
          child: Text(value,
              key: ValueKey(value),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 30,
                  height: 1.05,
                  letterSpacing: -.6,
                  color: tone ?? scheme.onSurface,
                  fontWeight: FontWeight.w800)),
        ),
        if (progress != null) ...[
          const SizedBox(height: 12),
          AppMeter(value: progress!, color: accent),
        ],
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(hint!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  height: 1.3, fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
        if (footer != null) ...[const SizedBox(height: 12), footer!],
      ]),
    );
    return GlassSurface(
      borderRadius: BorderRadius.circular(AppShape.innerOf(context)+ 4),
      onTap: onTap,
      child: body,
    );
  }
}

/// A titled tonal surface grouping related content.
class AdminSectionCard extends StatelessWidget {
  const AdminSectionCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.icon,
    this.padding = const EdgeInsets.all(18),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final IconData? icon;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Glass Material so list tiles inside the card paint ink on the frost.
    return GlassSurface(
      borderRadius: BorderRadius.circular(AppShape.cardOf(context)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 14, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            color: scheme.onSurface,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.1)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(subtitle!,
                          style: TextStyle(
                              color: scheme.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.3)),
                    ],
                  ]),
            ),
            if (trailing != null) trailing!,
          ]),
        ),
        SizedBox(height: trailing == null ? 10 : 4),
        SizedBox(
          width: double.infinity,
          child: Padding(padding: padding, child: child),
        ),
      ]),
    );
  }
}

/// A prominent banner in the primary container colour.
class AdminHeroCard extends StatelessWidget {
  const AdminHeroCard({
    super.key,
    required this.title,
    required this.message,
    this.icon,
    this.visual,
    this.actions = const [],
    this.tone,
  });
  final String title;
  final String message;
  final IconData? icon;
  final Widget? visual;
  final List<Widget> actions;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = tone == null
        ? ThemeRoles.selectedFill(context)
        : Color.alphaBlend(tone!.withValues(alpha: .16), scheme.surface);
    final foreground =
        tone == null ? ThemeRoles.selectedInk(context) : scheme.onSurface;
    final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: foreground, size: 28),
            const SizedBox(height: 10),
          ],
          Text(title,
              style: TextStyle(
                  color: foreground,
                  fontSize: 26,
                  height: 1.1,
                  letterSpacing: -.5,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(message,
              style: TextStyle(
                  color: foreground.withValues(alpha: .82),
                  fontSize: 14,
                  height: 1.35)),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ]);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppShape.cardOf(context)+ 4),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        if (visual == null) return text;
        if (constraints.maxWidth < 520) {
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 18), visual!]);
        }
        return Row(children: [
          Expanded(child: text),
          const SizedBox(width: 24),
          visual!,
        ]);
      }),
    );
  }
}

class AdminStatusPill extends StatelessWidget {
  const AdminStatusPill(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final normalized = status.toLowerCase().trim();
    final color = adminToneColor(context, adminTone(normalized));
    final label = normalized.isEmpty ? 'unknown' : normalized;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text('${label[0].toUpperCase()}${label.substring(1)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// A round avatar with initials in a colour derived from [name], so the same
/// person always gets the same colour.
class AdminAvatar extends StatelessWidget {
  const AdminAvatar(this.name,
      {super.key, this.size = 36, this.icon, this.avatar});
  final String name;
  final double size;
  final IconData? icon;

  /// The picture shown over the initials or [icon], when there is one.
  final String? avatar;

  @override
  Widget build(BuildContext context) {
    final palette = adminPalette(context);
    final clean = name.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), ' ').trim();
    final words = clean.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final initials = words.isEmpty
        ? '?'
        : words.take(2).map((w) => w[0].toUpperCase()).join();
    final color = palette[name.hashCode.abs() % palette.length];
    final corners = context.avatarBorderRadius(size);
    final fallback = AvatarFace(
      size: size,
      borderRadius: corners,
      backgroundColor: color.withValues(alpha: .2),
      child: icon != null
          ? Icon(icon, size: size * .5, color: color)
          : Text(initials,
              style: TextStyle(
                  color: color,
                  fontSize: size * .36,
                  fontWeight: FontWeight.w800)),
    );
    return HaloRing(
      accent: color,
      borderRadius: corners,
      child: AvatarPicture(
        avatar: avatar,
        size: size,
        borderRadius: corners,
        fallback: fallback,
      ),
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(children: [
      Expanded(
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            filled: true,
            fillColor: scheme.surfaceContainerHigh,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
            prefixIcon: const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.search_rounded, size: 21),
            ),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    onPressed: () {
                      controller.clear();
                      onChanged?.call('');
                    },
                    icon: const Icon(Icons.close_rounded, size: 18)),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(999),
                borderSide: BorderSide(color: scheme.primary, width: 2)),
          ),
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 10), trailing!],
    ]);
  }
}

/// One option of an [AdminFilterChips] row.
class AdminFilterOption<T> {
  const AdminFilterOption(this.value, this.label, {this.count, this.icon});
  final T value;
  final String label;
  final int? count;
  final IconData? icon;
}

/// A single-choice set of filter chips with optional counts. Wraps onto
/// more rows when the chips do not fit on one line.
class AdminFilterChips<T> extends StatelessWidget {
  const AdminFilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
  final List<AdminFilterOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          ChoiceChip(
            selected: option.value == selected,
            showCheckmark: false,
            avatar: option.icon == null
                ? null
                : Icon(option.icon,
                    size: 17,
                    color: option.value == selected
                        ? scheme.onSecondaryContainer
                        : scheme.onSurfaceVariant),
            // A long label shortens instead of overflowing a narrow screen.
            label: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                  child: Text(option.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
              if (option.count != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: option.value == selected
                          ? scheme.onSecondaryContainer.withValues(alpha: .14)
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(999)),
                  child: Text('${option.count}',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
            onSelected: (_) => onSelected(option.value),
          ),
      ],
    );
  }
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
    // Rows have 16 px horizontal padding on both sides. Include it in the
    // scroll extent so fixed-width cells never overflow the row itself.
    final natural = columns.fold<double>(0, (sum, col) => sum + col.width) + 32;
    // Column widths are minimums: on wide screens they grow proportionally so
    // the table fills the page; on narrow ones the table scrolls sideways.
    return LayoutBuilder(builder: (context, constraints) {
      final available =
          constraints.hasBoundedWidth ? constraints.maxWidth : natural;
      final scale =
          available > natural ? (available - 33) / (natural - 32) : 1.0;
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
                fontSize: header ? 12 : 13,
                fontWeight: header ? FontWeight.w700 : FontWeight.w500),
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

    return Material(
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.cardOf(context)- 4)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(children: [
            Container(
              color: scheme.surfaceContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(children: [
                for (final col in columns)
                  cell(Text(col.label), col, header: true),
              ]),
            ),
            if (rows.isEmpty)
              SizedBox(
                height: 120,
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.inbox_outlined,
                        size: 26, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 8),
                    Text(empty,
                        style: TextStyle(color: scheme.onSurfaceVariant)),
                  ]),
                ),
              ),
            for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
              Material(
                color: selected?.call(rowIndex) == true
                    ? ThemeRoles.selectedFill(context)
                    : Colors.transparent,
                child: InkWell(
                  onTap: onRowTap == null ? null : () => onRowTap!(rowIndex),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 60),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      border: rowIndex == 0
                          ? null
                          : Border(
                              top: BorderSide(
                                  color: scheme.outlineVariant
                                      .withValues(alpha: .35)),
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
    this.color,
  });
  final String label;
  final String value;
  final String? subtitle;
  final List<double> samples;
  final double max;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tone = color ?? AppColors.cyanOf(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppShape.cardOf(context)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface)),
          ),
          Text(value,
              style: TextStyle(
                  color: tone,
                  fontSize: 26,
                  letterSpacing: -.5,
                  fontWeight: FontWeight.w800)),
        ]),
        // On its own line so long readings wrap instead of overflowing.
        if (subtitle != null)
          Text(subtitle!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 14),
        SizedBox(
          height: 110,
          width: double.infinity,
          child: samples.isEmpty
              ? Center(
                  child: Text('Waiting for samples…',
                      style: TextStyle(color: scheme.onSurfaceVariant)))
              : CustomPaint(
                  painter: _LineChartPainter(
                      samples: samples,
                      max: max,
                      color: tone,
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
      ..color = grid.withValues(alpha: .4)
      ..strokeWidth = 1;
    for (final fraction in const [.25, .5, .75]) {
      final y = size.height * fraction;
      for (double x = 0; x < size.width; x += 8) {
        canvas.drawLine(
            Offset(x, y), Offset(math.min(x + 3, size.width), y), gridPaint);
      }
    }
    final ceiling = math.max(1.0, max);
    Offset point(int i) => Offset(
        samples.length == 1
            ? size.width
            : i / (samples.length - 1) * size.width,
        size.height - (samples[i].clamp(0, ceiling) / ceiling) * size.height);
    // A smooth curve through the samples rather than sharp segments.
    final path = Path()..moveTo(point(0).dx, point(0).dy);
    for (var i = 1; i < samples.length; i++) {
      final a = point(i - 1);
      final b = point(i);
      final mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(samples.length == 1 ? size.width : 0, size.height)
      ..close();
    canvas.drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [color.withValues(alpha: .32), color.withValues(alpha: 0)],
          ).createShader(Offset.zero & size));
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
    final last = point(samples.length - 1);
    canvas.drawCircle(last, 7, Paint()..color = color.withValues(alpha: .25));
    canvas.drawCircle(last, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.max != max ||
      oldDelegate.color != color;
}

/// A labelled share of a chart.
class AdminChartSlice {
  const AdminChartSlice(this.label, this.value, this.color, {this.display});
  final String label;
  final double value;
  final Color color;

  /// How the value is written in legends; defaults to the rounded number.
  final String? display;
}

/// A ring chart with a figure in its centre. Segments sweep in on first
/// paint and glide to new proportions when the data changes.
class AdminDonutChart extends StatelessWidget {
  const AdminDonutChart({
    super.key,
    required this.slices,
    this.center,
    this.caption,
    this.size = 168,
    this.thickness = 22,
  });
  final List<AdminChartSlice> slices;
  final String? center;
  final String? caption;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        slices.fold<double>(0, (sum, s) => sum + math.max(0, s.value));
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => CustomPaint(
          painter: _DonutPainter(
            slices: slices,
            total: total,
            progress: t,
            track: scheme.surfaceContainerHighest,
            thickness: thickness,
          ),
          child: child,
        ),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(thickness + 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (center != null)
                FittedBox(
                  child: Text(center!,
                      style: TextStyle(
                          fontSize: size * .17,
                          letterSpacing: -.5,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurface)),
                ),
              if (caption != null)
                Text(caption!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.total,
    required this.progress,
    required this.track,
    required this.thickness,
  });
  final List<AdminChartSlice> slices;
  final double total;
  final double progress;
  final Color track;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: (math.min(size.width, size.height) - thickness) / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    if (total <= 0) return;
    final visible = slices.where((s) => s.value > 0).toList();
    // Round caps overlap neighbours; leave a gap so each segment stays
    // distinct, as the expressive spec draws them.
    final gap = visible.length > 1 ? thickness / rect.width * 1.6 : 0.0;
    var start = -math.pi / 2;
    for (final slice in visible) {
      final sweep = slice.value / total * math.pi * 2 * progress;
      final drawn = math.max(0.0, sweep - gap);
      if (drawn > 0) {
        canvas.drawArc(
            rect, start + gap / 2, drawn, false, paint..color = slice.color);
      } else if (sweep > 0) {
        canvas.drawArc(
            rect, start + sweep / 2, .0001, false, paint..color = slice.color);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.progress != progress ||
      old.total != total ||
      old.slices != slices ||
      old.track != track;
}

/// The colour key for a chart, with each value and its share.
class AdminLegend extends StatelessWidget {
  const AdminLegend({super.key, required this.slices, this.showShare = true});
  final List<AdminChartSlice> slices;
  final bool showShare;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total =
        slices.fold<double>(0, (sum, s) => sum + math.max(0, s.value));
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final s in slices)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                    color: s.color, borderRadius: BorderRadius.circular(4))),
            const SizedBox(width: 10),
            Expanded(
                child: Text(s.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 8),
            Text(s.display ?? _plain(s.value),
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            if (showShare)
              SizedBox(
                width: 46,
                child: Text(
                    total <= 0 ? '0%' : '${(s.value / total * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
          ]),
        ),
    ]);
  }
}

/// A donut beside its legend; stacks them on narrow widths.
class AdminDonutPanel extends StatelessWidget {
  const AdminDonutPanel({
    super.key,
    required this.slices,
    this.center,
    this.caption,
    this.size = 156,
    this.emptyLabel = 'No data yet',
  });
  final List<AdminChartSlice> slices;
  final String? center;
  final String? caption;
  final double size;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final hasData = slices.any((s) => s.value > 0);
    final donut = AdminDonutChart(
        slices: slices,
        center: center,
        caption: hasData ? caption : emptyLabel,
        size: size);
    final legend = AdminLegend(slices: slices);
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 380) {
        return Column(children: [donut, const SizedBox(height: 14), legend]);
      }
      return Row(children: [
        donut,
        const SizedBox(width: 24),
        Expanded(child: legend),
      ]);
    });
  }
}

/// Ranked horizontal bars, largest first.
class AdminBarList extends StatelessWidget {
  const AdminBarList({
    super.key,
    required this.items,
    this.maxItems = 6,
    this.empty = 'Nothing to rank yet.',
  });
  final List<AdminChartSlice> items;
  final int maxItems;
  final String empty;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sorted = [...items]..sort((a, b) => b.value.compareTo(a.value));
    final shown = sorted.take(maxItems).toList();
    final top = shown.isEmpty ? 0.0 : math.max(shown.first.value, 0.0);
    if (shown.isEmpty || top <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(empty, style: TextStyle(color: scheme.onSurfaceVariant)),
      );
    }
    return Column(children: [
      for (final item in shown)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Text(item.display ?? _plain(item.value),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
            ]),
            const SizedBox(height: 6),
            AppMeter(value: item.value / top, color: item.color, height: 10),
          ]),
        ),
    ]);
  }
}

/// One proportional bar split into coloured parts, with a legend.
class AdminStackedBar extends StatelessWidget {
  const AdminStackedBar(
      {super.key, required this.slices, this.height = 16, this.legend = true});
  final List<AdminChartSlice> slices;
  final double height;
  final bool legend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = slices.where((s) => s.value > 0).toList();
    final total = visible.fold<double>(0, (sum, s) => sum + s.value);
    final bar = ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: total <= 0
            ? Container(color: scheme.surfaceContainerHighest)
            : TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => Row(children: [
                  for (var i = 0; i < visible.length; i++) ...[
                    if (i > 0) const SizedBox(width: 3),
                    Expanded(
                      flex: math.max(
                          1, (visible[i].value / total * 1000 * t).round()),
                      child: Container(
                        decoration: BoxDecoration(
                            color: visible[i].color,
                            borderRadius: BorderRadius.circular(4)),
                      ),
                    ),
                  ],
                  if (t < 1)
                    Expanded(
                        flex: math.max(1, ((1 - t) * 1000).round()),
                        child: const SizedBox()),
                ]),
              ),
      ),
    );
    if (!legend) return bar;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      bar,
      const SizedBox(height: 12),
      Wrap(spacing: 16, runSpacing: 8, children: [
        for (final s in slices)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: s.color, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 6),
            Text('${s.label} ',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
            Text(s.display ?? _plain(s.value),
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
      ]),
    ]);
  }
}

/// A 270° arc gauge for a ratio such as usage or a health score.
class AdminGauge extends StatelessWidget {
  const AdminGauge({
    super.key,
    required this.value,
    required this.label,
    this.display,
    this.color,
    this.size = 132,
    this.thickness = 14,
  });

  /// 0–1.
  final double value;
  final String label;
  final String? display;
  final Color? color;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final v = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
    final tint = color ??
        (v >= .9
            ? AppColors.dangerOf(context)
            : v >= .75
                ? AppColors.warningOf(context)
                : scheme.primary);
    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: v),
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => CustomPaint(
          painter: _GaugePainter(
              value: t,
              color: tint,
              track: scheme.surfaceContainerHighest,
              thickness: thickness),
          child: child,
        ),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(thickness + 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                child: Text(display ?? '${(v * 100).round()}%',
                    style: TextStyle(
                        fontSize: size * .2,
                        letterSpacing: -.5,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
              ),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(
      {required this.value,
      required this.color,
      required this.track,
      required this.thickness});
  final double value;
  final Color color;
  final Color track;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: (math.min(size.width, size.height) - thickness) / 2);
    const start = math.pi * .75;
    const sweep = math.pi * 1.5;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, paint..color = track);
    if (value > 0) {
      canvas.drawArc(rect, start, sweep * value, false, paint..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// One bar of an [AdminColumnChart], split into stacked parts.
class AdminColumn {
  const AdminColumn(this.label, this.parts);
  final String label;
  final List<AdminChartSlice> parts;
  double get total => parts.fold(0, (sum, p) => sum + math.max(0, p.value));
}

/// Vertical stacked columns, for counts over time.
class AdminColumnChart extends StatelessWidget {
  const AdminColumnChart({super.key, required this.columns, this.height = 120});
  final List<AdminColumn> columns;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final top = columns.fold<double>(0, (m, c) => math.max(m, c.total));
    return SizedBox(
      height: height + 22,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < columns.length; i++)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Tooltip(
                          message:
                              '${columns[i].label}: ${columns[i].parts.map((p) => '${p.label} ${_plain(p.value)}').join(', ')}',
                          child: Container(
                            height: math.max(
                                4,
                                top <= 0
                                    ? 4
                                    : columns[i].total / top * height * t),
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(children: [
                              for (final part in columns[i].parts.reversed)
                                if (part.value > 0)
                                  Expanded(
                                    flex: math.max(1, part.value.round()),
                                    child: Container(color: part.color),
                                  ),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 16,
                          child: (i == 0 ||
                                  i == columns.length - 1 ||
                                  i == columns.length ~/ 2)
                              ? FittedBox(
                                  child: Text(columns[i].label,
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: scheme.onSurfaceVariant)))
                              : null,
                        ),
                      ]),
                ),
              ),
          ],
        ),
      ),
    );
  }
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
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 20),
      child: Center(
        child: Column(children: [
          Container(
            width: 64,
            height: 64,
            decoration: ShapeDecoration(
                color: ThemeRoles.wellFill(context),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(22))),
            child: Icon(icon ?? Icons.inbox_outlined,
                size: 30, color: ThemeRoles.wellInk(context)),
          ),
          const SizedBox(height: 14),
          Text(title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class AdminKeyValue extends StatelessWidget {
  const AdminKeyValue(this.label, this.value,
      {super.key, this.mono = false, this.color});
  final String label;
  final String value;
  final bool mono;
  final Color? color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (color != null) ...[
            Container(
                margin: const EdgeInsets.only(top: 4, right: 10),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(3))),
          ],
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          const SizedBox(width: 16),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              // Its own storage key: inside an ExpansionTile the text's
              // scroll offset would otherwise share the tile's saved state.
              child: KeyedSubtree(
                key: PageStorageKey<String>('kv:$label'),
                child: SelectableText(value.isEmpty ? '—' : value,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        fontSize: 13,
                        fontFamily: mono ? 'monospace' : null,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ]),
      );
}

/// Lays [children] out in equal columns: [maxColumns] on wide screens, fewer
/// as the width shrinks, one per row on a phone.
class AdminGrid extends StatelessWidget {
  const AdminGrid({
    super.key,
    required this.children,
    this.maxColumns = 4,
    this.minTileWidth = 220,
    this.spacing = 12,
  });
  final List<Widget> children;
  final int maxColumns;
  final double minTileWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final fit =
            ((constraints.maxWidth + spacing) / (minTileWidth + spacing))
                .floor();
        final count =
            math.max(1, math.min(children.length, math.min(maxColumns, fit)));
        final width = (constraints.maxWidth - spacing * (count - 1)) / count;
        return Wrap(spacing: spacing, runSpacing: spacing, children: [
          for (final child in children) SizedBox(width: width, child: child)
        ]);
      });
}

String _plain(double value) {
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
  if (value >= 10000) return '${(value / 1000).toStringAsFixed(1)}K';
  return value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(1);
}
