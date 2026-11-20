import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../shared/widgets/glass_surface.dart';
import 'assistant_common.dart';
import 'tasks_panel.dart';

/// The person's assistant at the top of their home feed: a live tasks pulse
/// card, today's brief, approvals waiting on them, and the tasks that need
/// them. Setup lives in Settings → Your assistant.
class HomeAssistant extends StatefulWidget {
  const HomeAssistant({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<HomeAssistant> createState() => _HomeAssistantState();
}

class _HomeAssistantState extends State<HomeAssistant>
    with SingleTickerProviderStateMixin {
  static const _refresh = Duration(minutes: 1);

  Map<String, dynamic> brief = const {};
  List<Map<String, dynamic>> tasks = const [];
  List<Map<String, dynamic>> approvals = const [];
  bool available = false;
  bool loaded = false;
  bool briefOpen = true;
  Timer? timer;
  late final AnimationController pulse =
      AnimationController(vsync: this, duration: const Duration(seconds: 2));

  AppDependencies get deps => widget.dependencies;

  @override
  void initState() {
    super.initState();
    _load();
    timer = Timer.periodic(_refresh, (_) => _load());
  }

  @override
  void dispose() {
    timer?.cancel();
    pulse.dispose();
    super.dispose();
  }

  /// The ring only breathes while agents are working, so quiet screens settle.
  void _syncPulse(bool working) {
    if (working) {
      if (!pulse.isAnimating) pulse.repeat(reverse: true);
    } else if (pulse.isAnimating || pulse.value != 0) {
      pulse
        ..stop()
        ..value = 0;
    }
  }

  Future<Map<String, dynamic>?> _try(
    String ns,
    String action, [
    Map<String, dynamic> body = const {},
  ]) async {
    try {
      return jsonMap(await deps.service.invokeAction(ns, action, body: body));
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final results = await Future.wait([
      _try('proactive', 'tasks_list'),
      _try('proactive', 'brief_today'),
      _try('governance', 'approval_list', {'status': 'pending'}),
    ]);
    if (!mounted) return;
    final nextTasks = jsonList(results[0]?['tasks']);
    setState(() {
      loaded = true;
      // No proactive namespace on this node: nothing to show.
      available = results[0] != null;
      tasks = nextTasks;
      brief = jsonMap(results[1]?['brief']);
      approvals = jsonList(results[2]?['approvals']);
    });
    _syncPulse(nextTasks.any((t) => t['status'] == 'working'));
  }

  Future<void> _openTasks() async {
    await showTasksPanel(context, deps);
    if (mounted) await _load();
  }

  Future<void> _answer(Map<String, dynamic> a, String answer) async {
    final out = await runAction(
      context,
      deps,
      'governance',
      'approval_answer',
      {'id': a['id'], 'answer': answer},
    );
    if (out != null) await _load();
  }

  _TaskPulse get _pulse {
    final needsYou = tasks
        .where(
          (t) => const {
            'needs_input',
            'ready_for_review',
            'failed',
          }.contains(t['status']),
        )
        .toList();
    final suggested = tasks.where((t) => t['status'] == 'suggested').toList();
    final working = tasks.where((t) => t['status'] == 'working').length;
    final resolved = tasks.where((t) => t['status'] == 'resolved').length;
    return _TaskPulse(
      needsYou: needsYou.length,
      working: working,
      suggested: suggested.length,
      done: resolved,
      needsYouTasks: needsYou,
      suggestedTasks: suggested,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded || !available) return const SizedBox.shrink();
    final pulseData = _pulse;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TasksPulseCard(
          pulse: pulseData,
          animation: pulse,
          onOpen: _openTasks,
        ),
        if (brief.isNotEmpty) ...[
          const SizedBox(height: 10),
          // Same frosted glass as the tasks pulse and feed post cards.
          GlassSurface(
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: briefOpen,
                onExpansionChanged: (v) => briefOpen = v,
                leading: ThemeChrome.isKashi(context)
                    // Kashi: the sun sits in a saffron tile.
                    ? Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: Color.alphaBlend(
                            AppColors.warningOf(context).withValues(alpha: .16),
                            scheme.surface,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          Icons.wb_sunny_outlined,
                          size: 19,
                          color: AppColors.warningOf(context),
                        ),
                      )
                    : Icon(
                        Icons.wb_sunny_outlined,
                        color: scheme.onSurfaceVariant,
                      ),
                title: Text(
                  'Today\'s brief',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                iconColor: scheme.onSurfaceVariant,
                collapsedIconColor: scheme.onSurfaceVariant,
                childrenPadding: EdgeInsets.zero,
                children: [
                  BriefCard(
                    brief: brief,
                    margin: EdgeInsets.zero,
                    embedded: true,
                  ),
                ],
              ),
            ),
          ),
        ],
        for (final a in approvals) ...[
          const SizedBox(height: 8),
          _approval(context, a),
        ],
        for (final t in [
          ...pulseData.needsYouTasks,
          ...pulseData.suggestedTasks,
        ])
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TaskTile(task: t, dependencies: deps, reload: _load),
          ),
      ],
    );
  }

  Widget _approval(BuildContext context, Map<String, dynamic> a) {
    final scheme = Theme.of(context).colorScheme;
    final recipients = jsonStrings(a['recipients']);
    return GlassSurface(
      color: ThemeRoles.wellFill(context),
      alpha: .82,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 18,
                  color: ThemeRoles.wellInk(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${a['summary']}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              [
                if ('${a['agent_name'] ?? ''}'.isNotEmpty) '${a['agent_name']}',
                if (recipients.isNotEmpty) 'to ${recipients.join(', ')}',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            if ('${a['text'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${a['text']}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            Wrap(
              spacing: 4,
              children: [
                FilledButton(
                  onPressed: () => _answer(a, 'once'),
                  child: const Text('Allow once'),
                ),
                OutlinedButton(
                  onPressed: () => _answer(a, 'always'),
                  child: const Text('Always allow'),
                ),
                TextButton(
                  onPressed: () => _answer(a, 'refuse'),
                  child: const Text('Refuse'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TaskPulse {
  const _TaskPulse({
    required this.needsYou,
    required this.working,
    required this.suggested,
    required this.done,
    required this.needsYouTasks,
    required this.suggestedTasks,
  });

  final int needsYou;
  final int working;
  final int suggested;
  final int done;
  final List<Map<String, dynamic>> needsYouTasks;
  final List<Map<String, dynamic>> suggestedTasks;

  int get active => needsYou + working + suggested;
  int get total => active + done;
  bool get quiet => active == 0;
}

/// Live tasks pulse: a tappable card with a ring chart and status legend.
class _TasksPulseCard extends StatelessWidget {
  const _TasksPulseCard({
    required this.pulse,
    required this.animation,
    required this.onOpen,
  });

  final _TaskPulse pulse;
  final Animation<double> animation;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final headline = pulse.quiet
        ? 'All clear'
        : pulse.needsYou > 0
            ? '${pulse.needsYou} need${pulse.needsYou == 1 ? 's' : ''} you'
            : pulse.working > 0
                ? '${pulse.working} in motion'
                : '${pulse.suggested} suggested';
    final subtitle = pulse.quiet
        ? 'Nothing waiting · tap for your board'
        : [
            if (pulse.working > 0) '${pulse.working} working',
            if (pulse.suggested > 0) '${pulse.suggested} suggested',
            if (pulse.done > 0) '${pulse.done} done',
          ].join(' · ');

    final needsColor = AppColors.warningOf(context);
    final workingColor = AppColors.successOf(context);
    // The waiting tasks are listed under this card; keep the summary here.
    final line = subtitle;
    return GlassSurface(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AnimatedBuilder(
                  animation: animation,
                  builder: (context, _) => _PulseRing(
                    pulse: pulse,
                    breath: animation.value,
                    size: 84,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_awesome_rounded,
                              size: 16, color: scheme.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Your assistant',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded,
                              color: scheme.onSurfaceVariant),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 21,
                          letterSpacing: -.3,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (line.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          line,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (pulse.needsYou > 0) ...[
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: onOpen,
                          style: FilledButton.styleFrom(
                            backgroundColor: scheme.onSurface,
                            foregroundColor: scheme.surface,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                            ),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Review'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final (i, (label, count, color)) in [
                  ('Needs you', pulse.needsYou, needsColor),
                  ('Working', pulse.working, workingColor),
                  ('Suggested', pulse.suggested, scheme.primary),
                  ('Done', pulse.done, scheme.outline),
                ].indexed) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _CountTile(
                      label: label,
                      count: count,
                      color: color,
                      highlight: i == 0 && count > 0,
                      live: i == 1 && count > 0,
                      breath: animation,
                      onTap: onOpen,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One status count under the assistant ring: number in the numeric face,
/// a dot in the status colour, the tile tinted when it waits on you.
class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.label,
    required this.count,
    required this.color,
    required this.onTap,
    this.highlight = false,
    this.live = false,
    this.breath,
  });

  final String label;
  final int count;
  final Color color;
  final VoidCallback onTap;
  final bool highlight;
  final bool live;
  final Animation<double>? breath;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: count > 0 ? color : scheme.outlineVariant,
        shape: BoxShape.circle,
      ),
    );
    if (live && breath != null) {
      dot = AnimatedBuilder(
        animation: breath!,
        builder: (context, child) =>
            Opacity(opacity: .55 + .45 * breath!.value, child: child),
        child: dot,
      );
    }
    return Semantics(
      button: true,
      label: '$count $label',
      excludeSemantics: true,
      child: Material(
        color: highlight
            ? Color.alphaBlend(color.withValues(alpha: .16), scheme.surface)
            : scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: highlight
              ? BorderSide.none
              : BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count',
                  style: ThemeChrome.numeric(context).copyWith(
                    fontSize: 16,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                Row(
                  children: [
                    dot,
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PulseRing extends StatelessWidget {
  const _PulseRing({
    required this.pulse,
    required this.breath,
    required this.size,
  });

  final _TaskPulse pulse;
  final double breath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _PulseRingPainter(
          needsYou: pulse.needsYou,
          working: pulse.working,
          suggested: pulse.suggested,
          done: pulse.done,
          breath: breath,
          track: scheme.surfaceContainerHighest,
          needsColor: AppColors.warningOf(context),
          workingColor: AppColors.successOf(context),
          suggestedColor: scheme.primary,
          doneColor: scheme.outline,
          centerFill: scheme.surface.withValues(alpha: .55),
          labelColor: scheme.onSurface,
          mutedColor: scheme.onSurfaceVariant,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${pulse.active}',
                style: ThemeChrome.numeric(context).copyWith(
                  fontSize: 24,
                  height: 1,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                pulse.quiet ? 'idle' : 'live',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: .6,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PulseRingPainter extends CustomPainter {
  _PulseRingPainter({
    required this.needsYou,
    required this.working,
    required this.suggested,
    required this.done,
    required this.breath,
    required this.track,
    required this.needsColor,
    required this.workingColor,
    required this.suggestedColor,
    required this.doneColor,
    required this.centerFill,
    required this.labelColor,
    required this.mutedColor,
  });

  final int needsYou, working, suggested, done;
  final double breath;
  final Color track,
      needsColor,
      workingColor,
      suggestedColor,
      doneColor,
      centerFill,
      labelColor,
      mutedColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;
    final stroke = 9.0;
    final rect = Rect.fromCircle(center: center, radius: radius - stroke / 2);

    canvas.drawCircle(
      center,
      radius - stroke - 2,
      Paint()..color = centerFill,
    );

    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, trackPaint);

    final segments = <(int, Color)>[
      (needsYou, needsColor),
      (working, workingColor),
      (suggested, suggestedColor),
      (done, doneColor),
    ].where((s) => s.$1 > 0).toList();
    final total = segments.fold<int>(0, (n, s) => n + s.$1);
    if (total == 0) {
      // Soft idle arc that breathes.
      final idle = Paint()
        ..color = workingColor.withValues(alpha: .25 + .2 * breath)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, -math.pi / 2, math.pi * 1.35, false, idle);
      return;
    }

    var start = -math.pi / 2;
    final gap = segments.length > 1 ? 0.08 : 0.0;
    for (final (count, color) in segments) {
      final sweep = (count / total) * (math.pi * 2 - gap * segments.length);
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth =
            color == workingColor ? stroke + 1.5 * breath : stroke
        ..strokeCap = StrokeCap.round;
      if (color == workingColor) {
        paint.color = Color.lerp(
              color,
              color.withValues(alpha: .65),
              breath,
            ) ??
            color;
      }
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _PulseRingPainter old) =>
      old.needsYou != needsYou ||
      old.working != working ||
      old.suggested != suggested ||
      old.done != done ||
      old.breath != breath ||
      old.track != track ||
      old.needsColor != needsColor ||
      old.workingColor != workingColor ||
      old.suggestedColor != suggestedColor ||
      old.doneColor != doneColor;
}
