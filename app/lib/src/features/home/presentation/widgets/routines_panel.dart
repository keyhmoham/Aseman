import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../data/models/bot.dart';
import '../../../../shared/widgets/app_form.dart';
import '../../../../shared/widgets/app_inputs.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/panel_header.dart';
import '../../../../shared/widgets/segmented_tab_bar.dart';
import '../../../../shared/widgets/skeleton.dart';

/// Opens the per-room routines manager as a floating panel (a bottom sheet on
/// compact widths), the same as the messenger and requests panels. Lists,
/// creates, edits, pauses and deletes delayed / periodic routines for the room.
Future<void> showRoutinesSheet(
  BuildContext context,
  AppDependencies dependencies,
  String spaceId,
  String roomId,
  String roomName,
) =>
    showFloatingPanel(
        context,
        RoutinesPanel(
          dependencies: dependencies,
          spaceId: spaceId,
          roomId: roomId,
          roomName: roomName,
        ),
        maxWidth: 760);

/// The filter tabs above the list, in display order.
const _filters = ['all', 'active', 'paused', 'done', 'failed'];

String _statusOf(Map<String, dynamic> r) => r['status'] as String? ?? 'active';

/// Label, colour and icon for a routine status, shared by the filter tabs and
/// the status pill on each card.
(String, Color, IconData) _statusStyle(String status, ColorScheme scheme) =>
    switch (status) {
      'paused' => ('Paused', AppColors.warning, Icons.pause_circle_outline),
      'done' => ('Done', AppColors.success, Icons.check_circle_outline),
      'failed' => ('Failed', AppColors.danger, Icons.error_outline_rounded),
      _ => ('Active', scheme.primary, Icons.bolt_rounded),
    };

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
  String? _error;
  int _filter = 0;
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
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      _toast('Create failed: $e');
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
      _toast('Update failed: $e');
    }
  }

  Future<void> _toggle(Map<String, dynamic> r) async {
    final id = r['id'] as String? ?? '';
    final paused = _statusOf(r) == 'paused';
    try {
      await widget.dependencies.service.setRoutineStatus(id, !paused);
      await _load();
    } catch (e) {
      _toast('${paused ? 'Resume' : 'Pause'} failed: $e');
    }
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
    } catch (e) {
      _toast('Delete failed: $e');
    }
  }

  int _count(String filter) => filter == 'all'
      ? _routines.length
      : _routines.where((r) => _statusOf(r) == filter).length;

  List<Map<String, dynamic>> get _shown {
    final filter = _filters[_filter];
    if (filter == 'all') return _routines;
    return _routines.where((r) => _statusOf(r) == filter).toList();
  }

  /// The active routine that fires next, if any.
  Map<String, dynamic>? get _dueSoon {
    Map<String, dynamic>? best;
    DateTime? bestAt;
    for (final r in _routines) {
      if (_statusOf(r) != 'active') continue;
      final n = _parseT(r['next_run_at']);
      if (n == null) continue;
      if (bestAt == null || n.isBefore(bestAt)) {
        best = r;
        bestAt = n;
      }
    }
    return best;
  }

  String _filterLabel(String filter, ColorScheme scheme) {
    final name = filter == 'all' ? 'All' : _statusStyle(filter, scheme).$1;
    final n = _count(filter);
    return n > 0 ? '$name · $n' : name;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final gutter = compact ? 16.0 : 26.0;
    final next = _dueSoon;
    final shown = _shown;
    final count = _routines.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, compact ? 16 : 22, gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.schedule_rounded,
          title: 'Routines',
          subtitle:
              '${widget.roomName} · $count scheduled task${count == 1 ? '' : 's'}',
          onClose: () => Navigator.pop(context),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded)),
            FilledButton.icon(
                onPressed: _create,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New routine')),
          ],
        ),
        const SizedBox(height: 14),
        SegmentedTabBar(
          alignment: Alignment.centerLeft,
          compact: compact,
          width: 620,
          selectedIndex: _filter,
          onTap: (i) => setState(() => _filter = i),
          labels: [for (final f in _filters) _filterLabel(f, scheme)],
          icons: const [
            Icons.all_inbox_rounded,
            Icons.bolt_rounded,
            Icons.pause_circle_outline,
            Icons.check_circle_outline,
            Icons.error_outline_rounded,
          ],
        ),
        if (next != null) ...[
          const SizedBox(height: 10),
          _NextRunBanner(routine: next, now: _now, onTap: () => _edit(next)),
        ],
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const SkeletonList(
                  item: SkeletonCard(mediaHeight: 0), spacing: 10)
              : _error != null && _routines.isEmpty
                  ? _Empty(
                      icon: Icons.cloud_off_rounded,
                      title: 'Could not load routines',
                      body: _error!)
                  : _routines.isEmpty
                      ? _Empty(
                          icon: Icons.schedule_rounded,
                          title: 'No routines yet',
                          body:
                              'Schedule a delayed or periodic task: it fires by itself, passes to an agent, or runs inline.',
                          action: FilledButton.tonalIcon(
                              onPressed: _create,
                              icon: const Icon(Icons.add_rounded, size: 18),
                              label: const Text('Create first routine')))
                      : shown.isEmpty
                          ? _Empty(
                              icon: _statusStyle(_filters[_filter], scheme).$3,
                              title: 'No ${_filters[_filter]} routines',
                              body: 'Routines show up here when they are '
                                  '${_filters[_filter]}.')
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding:
                                    const EdgeInsets.only(top: 4, bottom: 24),
                                itemCount: shown.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, i) => _RoutineCard(
                                    routine: shown[i],
                                    now: _now,
                                    onEdit: () => _edit(shown[i]),
                                    onToggle: () => _toggle(shown[i]),
                                    onDelete: () => _delete(shown[i])),
                              ),
                            ),
        ),
      ]),
    );
  }
}

/// Tappable banner for the soonest upcoming run, styled like the messenger's
/// requests banner.
class _NextRunBanner extends StatelessWidget {
  const _NextRunBanner(
      {required this.routine, required this.now, required this.onTap});
  final Map<String, dynamic> routine;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = routine['name'] as String? ?? '';
    final next = _parseT(routine['next_run_at']);
    return Material(
      color: scheme.primaryContainer.withValues(alpha: .55),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            Icon(Icons.notifications_active_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  const TextSpan(text: 'Next run · '),
                  TextSpan(
                      text: name.isEmpty ? 'Untitled routine' : name,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 8),
            Text(next == null ? '—' : fmtRel(next, now),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

/// Centered empty / error state, matching the messenger panel's.
class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon,
      required this.title,
      required this.body,
      this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
                color: scheme.secondaryContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24))),
            child: Icon(icon, size: 34, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
          if (action != null) ...[
            const SizedBox(height: 18),
            action!,
          ],
        ]),
      ),
    );
  }
}

enum _CardMenu { toggle, edit, delete }

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final periodic = (routine['type'] as String? ?? 'delayed') == 'periodic';
    final status = _statusOf(routine);
    final (label, color, icon) = _statusStyle(status, scheme);
    final paused = status == 'paused';
    final finished = status == 'done' || status == 'failed';
    final name = (routine['name'] as String? ?? '').trim();
    final task = (routine['task'] as String? ?? '').trim();
    final next = _parseT(routine['next_run_at']);
    final last = _parseT(routine['last_run_at']);
    final lastResult = (routine['last_result'] as String? ?? '').trim();
    final target = (routine['target'] as String? ?? '').trim();
    final interval = (routine['interval_sec'] as num?)?.toInt() ?? 0;
    final delay = (routine['delay_sec'] as num?)?.toInt() ?? 0;

    // Progress for active periodic routines between the anchor and next run.
    final anchor = (last ?? _parseT(routine['created_at'])) ??
        now.subtract(Duration(seconds: interval > 0 ? interval : 3600));
    final progress =
        periodic && status == 'active' && next != null && next.isAfter(anchor)
            ? (now.difference(anchor).inMilliseconds /
                    math.max(1, next.difference(anchor).inMilliseconds))
                .clamp(0.0, 1.0)
            : null;

    final meta = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    Widget metaItem(IconData i, String text, {bool emphasize = false}) =>
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i,
              size: 15,
              color: emphasize ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(text,
              style: emphasize
                  ? meta.copyWith(
                      color: scheme.primary, fontWeight: FontWeight.w700)
                  : meta),
        ]);

    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner + 2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                  color: scheme.secondaryContainer,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppShape.control))),
              child: Icon(periodic ? Icons.loop_rounded : Icons.timer_outlined,
                  size: 22, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(name.isEmpty ? 'Untitled routine' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 8),
                      _StatusPill(label: label, color: color, icon: icon),
                    ]),
                    if (task.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(task,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 14,
                              height: 1.4,
                              color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 10),
                    Wrap(spacing: 14, runSpacing: 6, children: [
                      metaItem(
                          periodic ? Icons.loop_rounded : Icons.timer_outlined,
                          periodic
                              ? 'Every ${fmtDur(interval)}'
                              : 'Once, after ${fmtDur(delay)}'),
                      metaItem(
                          target.isEmpty
                              ? Icons.bolt_rounded
                              : Icons.smart_toy_outlined,
                          target.isEmpty ? 'Runs inline' : 'Agent $target'),
                      if (next != null && !finished)
                        metaItem(
                            Icons.schedule_rounded, 'Next ${fmtRel(next, now)}',
                            emphasize: !paused),
                      if (last != null)
                        metaItem(
                            Icons.history_rounded, 'Last ${fmtRel(last, now)}'),
                    ]),
                    if (progress != null) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: progress,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      const SizedBox(height: 4),
                      Text('${(progress * 100).round()}% until next run',
                          style: meta.copyWith(fontSize: 11)),
                    ],
                    if (lastResult.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: status == 'failed'
                              ? AppColors.danger.withValues(alpha: .12)
                              : scheme.surfaceContainerHighest
                                  .withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(AppShape.control),
                        ),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                  status == 'failed'
                                      ? Icons.error_outline_rounded
                                      : Icons.receipt_long_outlined,
                                  size: 16,
                                  color: status == 'failed'
                                      ? AppColors.danger
                                      : scheme.onSurfaceVariant),
                              const SizedBox(width: 8),
                              Expanded(
                                  child: Text(lastResult,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: meta.copyWith(height: 1.35))),
                            ]),
                      ),
                    ],
                  ]),
            ),
            PopupMenuButton<_CardMenu>(
              tooltip: 'Routine actions',
              icon:
                  Icon(Icons.more_vert_rounded, color: scheme.onSurfaceVariant),
              onSelected: (choice) {
                switch (choice) {
                  case _CardMenu.toggle:
                    onToggle();
                  case _CardMenu.edit:
                    onEdit();
                  case _CardMenu.delete:
                    onDelete();
                }
              },
              itemBuilder: (context) => [
                if (!finished)
                  PopupMenuItem(
                    value: _CardMenu.toggle,
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(paused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded),
                      title: Text(paused ? 'Resume' : 'Pause'),
                    ),
                  ),
                const PopupMenuItem(
                  value: _CardMenu.edit,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Edit'),
                  ),
                ),
                PopupMenuItem(
                  value: _CardMenu.delete,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    iconColor: scheme.error,
                    textColor: scheme.error,
                    leading: const Icon(Icons.delete_outline_rounded),
                    title: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

/// Rounded status pill (icon + label), the same as the requests panel's.
class _StatusPill extends StatelessWidget {
  const _StatusPill(
      {required this.label, required this.color, required this.icon});
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
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
