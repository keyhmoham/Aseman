import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/bot.dart';
import '../../../../shared/widgets/app_form.dart';
import '../../../../shared/widgets/app_inputs.dart';
import '../../../../shared/widgets/mini_tag.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/panel_header.dart';

/// Opens the per-room routines manager as a sheet/modal. Lists, creates,
/// edits, pauses and deletes delayed / periodic routines for the room.
Future<void> showRoutinesSheet(
  BuildContext context,
  AppDependencies dependencies,
  String spaceId,
  String roomId,
  String roomName,
) {
  final panel = RoutinesPanel(
    dependencies: dependencies,
    spaceId: spaceId,
    roomId: roomId,
    roomName: roomName,
  );
  return showAdaptivePanel<void>(context, panel, breakpoint: 820);
}

class RoutinesPanel extends StatefulWidget {
  const RoutinesPanel({
    super.key,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.roomName,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final String roomName;

  @override
  State<RoutinesPanel> createState() => _RoutinesPanelState();
}

class _RoutinesPanelState extends State<RoutinesPanel> {
  List<Map<String, dynamic>> _routines = const [];
  bool _loading = true;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.dependencies.service
          .fetchRoutines(widget.spaceId, roomId: widget.roomId);
      if (!mounted) return;
      setState(() {
        _routines = list;
        _now = DateTime.now();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final result = await showAppForm<Map<String, dynamic>>(
        context, _RoutineFormDialog(agents: _agents()));
    if (result == null || !mounted) return;
    try {
      await widget.dependencies.service.createRoutine(widget.spaceId,
          roomId: widget.roomId,
          name: result['name'] as String? ?? '',
          type: result['type'] as String,
          target: result['target'] as String? ?? '',
          task: result['task'] as String,
          delaySec: (result['delay_sec'] as num?)?.toInt() ?? 0,
          intervalSec: (result['interval_sec'] as num?)?.toInt() ?? 0);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  Future<void> _edit(Map<String, dynamic> r) async {
    final result = await showAppForm<Map<String, dynamic>>(
        context, _RoutineFormDialog(existing: r, agents: _agents()));
    if (result == null || !mounted) return;
    try {
      await widget.dependencies.service.updateRoutine(r['id'] as String? ?? '',
          name: result['name'] as String? ?? '',
          target: result['target'] as String? ?? '',
          task: result['task'] as String? ?? '',
          delaySec: (result['delay_sec'] as num?)?.toInt() ?? 0,
          intervalSec: (result['interval_sec'] as num?)?.toInt() ?? 0);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Update failed: $e')));
    }
  }

  Future<void> _toggle(Map<String, dynamic> r) async {
    final id = r['id'] as String? ?? '';
    final paused = r['status'] == 'paused';
    try {
      await widget.dependencies.service.setRoutineStatus(id, !paused);
      await _load();
    } catch (_) {}
  }

  /// The workspace's agents a routine can hand its task to.
  Future<List<Bot>> _agents() async {
    try {
      final bots =
          await widget.dependencies.service.fetchSpaceBots(widget.spaceId);
      return bots.where((b) => b.kind == 'agent').toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _delete(Map<String, dynamic> r) async {
    final confirmed = await confirmAppAction(context,
        icon: Icons.delete_outline_rounded,
        title: 'Delete "${r['name'] ?? 'routine'}"?',
        message: 'It stops firing and its run history is removed.',
        action: 'Delete',
        destructive: true);
    if (!confirmed || !mounted) return;
    try {
      await widget.dependencies.service.deleteRoutine(r['id'] as String? ?? '');
      await _load();
    } catch (_) {}
  }

  // ── derived stats for the overview strip ────────────────────────────────
  (int, int, int, int) get _stats {
    var active = 0, paused = 0, done = 0, failed = 0;
    for (final r in _routines) {
      switch (r['status'] as String? ?? 'active') {
        case 'paused':
          paused++;
        case 'done':
          done++;
        case 'failed':
          failed++;
        default:
          active++;
      }
    }
    return (active, paused, done, failed);
  }

  Map<String, dynamic>? get _dueSoon {
    Map<String, dynamic>? best;
    for (final r in _routines) {
      if ((r['status'] as String? ?? 'active') != 'active') continue;
      final n = _parseT(r['next_run_at']);
      if (n == null) continue;
      if (best == null || n.isBefore(_parseT(best['next_run_at']) ?? n)) {
        best = r;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final (active, paused, done, failed) = _stats;
    final next = _dueSoon;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 18, 4),
        child: PanelHeader(
          icon: Icons.schedule_rounded,
          title: 'Routines',
          subtitle:
              '${widget.roomName} · ${_routines.length} scheduled task${_routines.length == 1 ? '' : 's'}',
          onClose: () => Navigator.pop(context),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded)),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
              onPressed: _create,
              icon: const Icon(Icons.add_rounded, size: 20),
              label: const Text('New routine'),
            ),
          ],
        ),
      ),
      // ── overview strip ──────────────────────────────────────────────────
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 10),
        child: Row(children: [
          Expanded(
              child: _StatTile(
                  icon: Icons.bolt_rounded,
                  label: 'Active',
                  value: '$active',
                  color: AppColors.primary)),
          const SizedBox(width: 8),
          Expanded(
              child: _StatTile(
                  icon: Icons.pause_rounded,
                  label: 'Paused',
                  value: '$paused',
                  color: AppColors.warning)),
          const SizedBox(width: 8),
          Expanded(
              child: _StatTile(
                  icon: Icons.check_circle_outline_rounded,
                  label: 'Done',
                  value: '$done',
                  color: AppColors.success)),
          const SizedBox(width: 8),
          Expanded(
              child: _StatTile(
                  icon: Icons.error_outline_rounded,
                  label: 'Failed',
                  value: '$failed',
                  color: AppColors.danger)),
        ]),
      ),
      // ── next-run teaser ─────────────────────────────────────────────────
      if (next != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
          child: _NextRunBanner(routine: next, now: _now),
        ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 22),
        child: Divider(height: 1),
      ),
      const SizedBox(height: 10),
      // ── list ────────────────────────────────────────────────────────────
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _routines.isEmpty
                ? _EmptyState(onCreate: _create)
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
                      itemCount: _routines.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, i) => _RoutineCard(
                          routine: _routines[i],
                          now: _now,
                          onEdit: () => _edit(_routines[i]),
                          onToggle: () => _toggle(_routines[i]),
                          onDelete: () => _delete(_routines[i])),
                    ),
                  ),
      ),
    ]);
  }
}

/// Small stat tile for the overview strip.
class _StatTile extends StatelessWidget {
  const _StatTile(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .4),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Row(children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text('$value',
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14)),
        const SizedBox(width: 4),
        Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 9,
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

/// Banner highlighting the soonest upcoming run.
class _NextRunBanner extends StatelessWidget {
  const _NextRunBanner({required this.routine, required this.now});
  final Map<String, dynamic> routine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = routine['name'] as String? ?? 'routine';
    final next = _parseT(routine['next_run_at']);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          AppColors.primary.withValues(alpha: .18),
          scheme.surfaceContainerHighest.withValues(alpha: .3),
        ]),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: .35)),
      ),
      child: Row(children: [
        const Icon(Icons.notifications_active_rounded,
            size: 17, color: AppColors.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(
                text: 'Next run · ',
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            TextSpan(
                text: name,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Theme.of(context).colorScheme.onSurface)),
            TextSpan(
                text: '  ${next == null ? '—' : fmtRel(next, now)}',
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary)),
          ])),
        ),
      ]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: .12),
          ),
          child: const Icon(Icons.schedule_rounded,
              size: 34, color: AppColors.primary),
        ),
        const SizedBox(height: 14),
        const Text('No routines yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 6),
        Text(
          'Schedule a delayed or periodic task: it fires by itself,\npasses to an agent, or runs inline.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          onPressed: onCreate,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Create first routine'),
        ),
      ]),
    );
  }
}

class _RoutineCard extends StatelessWidget {
  const _RoutineCard({
    required this.routine,
    required this.now,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });
  final Map<String, dynamic> routine;
  final DateTime now;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  Color get _statusColor {
    switch (routine['status'] as String? ?? 'active') {
      case 'paused':
        return AppColors.warning;
      case 'done':
        return AppColors.success;
      case 'failed':
        return AppColors.danger;
      default:
        return AppColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typ = routine['type'] as String? ?? 'delayed';
    final periodic = typ == 'periodic';
    final status = routine['status'] as String? ?? 'active';
    final color = _statusColor;
    final paused = status == 'paused';
    final next = _parseT(routine['next_run_at']);
    final last = _parseT(routine['last_run_at']);
    final lastResult = (routine['last_result'] as String? ?? '').trim();
    final target = (routine['target'] as String? ?? '').trim();
    final interval = (routine['interval_sec'] as num?)?.toInt() ?? 0;
    final delay = (routine['delay_sec'] as num?)?.toInt() ?? 0;

    // Progress for active periodic routines between the anchor and next run.
    final anchor = (last ?? _parseT(routine['created_at'])) ??
        now.subtract(Duration(seconds: interval > 0 ? interval : 3600));
    final progress = periodic &&
            !paused &&
            status != 'failed' &&
            next != null &&
            next.isAfter(anchor)
        ? ((now.difference(anchor).inMilliseconds /
                math.max(1, next.difference(anchor).inMilliseconds)))
            .clamp(0.0, 1.0)
        : null;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // Type tile
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: .35),
                  color.withValues(alpha: .12)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(periodic ? Icons.loop_rounded : Icons.timer_rounded,
                size: 22, color: color),
          ),
          const SizedBox(width: 11),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(routine['name'] as String? ?? 'Untitled routine',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 14)),
              const SizedBox(height: 3),
              Wrap(spacing: 6, runSpacing: 4, children: [
                MiniTag(typ.toUpperCase(), color),
                MiniTag(status.toUpperCase(),
                    paused ? AppColors.warning : AppColors.success),
              ]),
            ]),
          ),
          // Actions
          Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              _CardAction(
                  tooltip: paused ? 'Resume' : 'Pause',
                  icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  onTap: onToggle),
              _CardAction(
                  tooltip: 'Edit', icon: Icons.edit_outlined, onTap: onEdit),
              _CardAction(
                  tooltip: 'Delete',
                  icon: Icons.delete_outline_rounded,
                  color: AppColors.danger,
                  onTap: onDelete),
            ]),
          ]),
        ]),
        if ((routine['task'] as String? ?? '').isNotEmpty) ...[
          const SizedBox(height: 9),
          Text(routine['task'] as String? ?? '',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, height: 1.45, color: scheme.onSurfaceVariant)),
        ],
        if (target.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(children: [
              Icon(Icons.smart_toy_outlined,
                  size: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Flexible(
                  child: Text('Target agent $target',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 9.5,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))),
            ]),
          ),
        const SizedBox(height: 9),
        // Timing meta row
        Wrap(spacing: 16, runSpacing: 6, children: [
          _MetaChip(
            icon: periodic ? Icons.loop_rounded : Icons.timer_outlined,
            text: periodic
                ? 'every ${fmtDur(interval)}'
                : 'after ${fmtDur(delay)}',
          ),
          if (next != null)
            _MetaChip(
              icon: Icons.schedule_rounded,
              text: 'next ${fmtRel(next, now)}',
              emphasize: !paused,
            ),
          if (last != null)
            _MetaChip(
                icon: Icons.history_rounded, text: 'last ${fmtRel(last, now)}'),
        ]),
        if (progress != null) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 5,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
          const SizedBox(height: 4),
          Text('${(progress * 100).round()}% until next run',
              style: TextStyle(
                  fontSize: 9,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
        if (lastResult.isNotEmpty) ...[
          const SizedBox(height: 9),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: .35),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                  status == 'failed'
                      ? Icons.error_outline_rounded
                      : Icons.receipt_long_rounded,
                  size: 14,
                  color: status == 'failed'
                      ? AppColors.danger
                      : Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 7),
              Expanded(
                  child: Text(lastResult,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 9.5,
                          height: 1.35,
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant))),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction(
      {required this.tooltip,
      required this.icon,
      required this.onTap,
      this.color});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: color ?? scheme.onSurfaceVariant),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip(
      {required this.icon, required this.text, this.emphasize = false});
  final IconData icon;
  final String text;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final color = emphasize
        ? AppColors.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 13, color: color),
      const SizedBox(width: 4),
      Text(text,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w700)),
    ]);
  }
}

// ── form dialog ────────────────────────────────────────────────────────────

class _RoutineFormDialog extends StatefulWidget {
  const _RoutineFormDialog({this.existing, required this.agents});
  final Map<String, dynamic>? existing;
  final Future<List<Bot>> agents;

  @override
  State<_RoutineFormDialog> createState() => _RoutineFormDialogState();
}

class _RoutineFormDialogState extends State<_RoutineFormDialog> {
  late final name =
      TextEditingController(text: widget.existing?['name'] as String? ?? '');
  late final task =
      TextEditingController(text: widget.existing?['task'] as String? ?? '');
  late int delay = (widget.existing?['delay_sec'] as num?)?.toInt() ?? 300;
  late int interval =
      (widget.existing?['interval_sec'] as num?)?.toInt() ?? 3600;
  late String target = widget.existing?['target'] as String? ?? '';
  late String type = widget.existing?['type'] as String? ?? 'delayed';
  List<Bot> agents = const [];

  @override
  void initState() {
    super.initState();
    widget.agents.then((value) {
      if (mounted) setState(() => agents = value);
    });
    task.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    task.removeListener(_changed);
    name.dispose();
    task.dispose();
    super.dispose();
  }

  String get _preview => type == 'periodic'
      ? 'every ${fmtDur(interval)}'
      : 'once, ${fmtDur(delay)} from now';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.existing != null;
    final known = agents.any((a) => a.id == target);
    return AppFormFrame(
      icon: editing ? Icons.edit_calendar_rounded : Icons.add_alarm_rounded,
      title: editing ? 'Edit routine' : 'New routine',
      subtitle: 'A task that runs by itself, once or on a schedule.',
      submit: editing ? 'Save' : 'Create routine',
      onSubmit: task.text.trim().isEmpty
          ? null
          : () => Navigator.pop(context, {
                'name': name.text.trim(),
                'type': type,
                'target': target,
                'task': task.text.trim(),
                'delay_sec': type == 'delayed' ? delay : 0,
                'interval_sec': type == 'periodic' ? interval : 0,
              }),
      children: [
        TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Morning scan',
              prefixIcon: Icon(Icons.drive_file_rename_outline_rounded),
            )),
        AppSegmentedField<String>(
          label: 'When',
          value: type,
          onChanged: editing ? (_) {} : (v) => setState(() => type = v),
          choices: const [
            AppChoice('delayed', 'Once',
                icon: Icons.timer_outlined,
                hint: 'Runs a single time after the delay.'),
            AppChoice('periodic', 'Repeating',
                icon: Icons.loop_rounded,
                hint: 'Runs again and again on a fixed interval.'),
          ],
        ),
        if (type == 'delayed')
          AppDurationField(
              label: 'Run after',
              seconds: delay,
              presets: const [60, 300, 900, 3600, 21600, 86400],
              onChanged: (v) => setState(() => delay = v))
        else
          AppDurationField(
              label: 'Run every',
              seconds: interval,
              presets: const [300, 900, 3600, 21600, 86400, 604800],
              onChanged: (v) => setState(() => interval = v)),
        AppChoiceField<String>(
          label: 'Who does it',
          hint: target.isEmpty
              ? 'The routine runs the task itself.'
              : 'The task is handed to this agent.',
          value: target,
          onChanged: (v) => setState(() => target = v),
          choices: [
            const AppChoice('', 'Run inline', icon: Icons.bolt_rounded),
            for (final a in agents)
              AppChoice(a.id, a.name.isEmpty ? a.id : a.name,
                  icon: Icons.smart_toy_outlined),
            if (target.isNotEmpty && !known)
              AppChoice(target, 'Current agent',
                  icon: Icons.smart_toy_outlined),
          ],
        ),
        TextField(
            controller: task,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: 'Task',
              hintText: 'What should the routine do?',
              alignLabelWithHint: true,
            )),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(AppShape.control),
          ),
          child: Row(children: [
            Icon(Icons.schedule_rounded,
                size: 18, color: scheme.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Runs $_preview',
                  style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSecondaryContainer)),
            ),
          ]),
        ),
      ],
    );
  }
}

// ── formatting helpers ──────────────────────────────────────────────────────

DateTime? _parseT(Object? v) {
  if (v is String) return DateTime.tryParse(v);
  if (v is DateTime) return v;
  return null;
}

/// Renders a duration in seconds as a compact human string.
String fmtDur(int seconds) {
  if (seconds <= 0) return '0s';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s == 0 ? '${m}m' : '${m}m ${s}s';
  }
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Renders a time relative to [now] (e.g. "in 5m", "2m ago").
String fmtRel(DateTime t, DateTime now) {
  final d = t.difference(now);
  if (d.isNegative) {
    final ago = d.abs();
    if (ago.inSeconds < 5) return 'just now';
    if (ago.inSeconds < 60) return '${ago.inSeconds}s ago';
    if (ago.inMinutes < 60) return '${ago.inMinutes}m ago';
    if (ago.inHours < 24) return '${ago.inHours}h ago';
    final local = t.toLocal();
    return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
  }
  if (d.inSeconds < 60) return 'in ${math.max(0, d.inSeconds)}s';
  if (d.inMinutes < 60) return 'in ${d.inMinutes}m';
  if (d.inHours < 24) return 'in ${d.inHours}h';
  final local = t.toLocal();
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

String two(int n) => n.toString().padLeft(2, '0');
