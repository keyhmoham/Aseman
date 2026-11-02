import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_shape.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/overlay_panels.dart';
import '../../shared/widgets/panel_header.dart';
import '../../shared/widgets/skeleton.dart';
import 'assistant_common.dart';

/// Opens tasks as a bottom sheet on phones and a floating modal on desktop.
Future<void> showTasksPanel(
  BuildContext context,
  AppDependencies dependencies,
) =>
    showFloatingPanel(
      context,
      TasksPanel(dependencies: dependencies),
      maxWidth: 820,
      barrierLabel: 'Close tasks',
    );

/// A person's Tasks: what their agents suggested, are working on, need from
/// them or finished, with today's morning brief on top. Start hands a
/// suggestion to the lead; a task that needs input takes an answer; a
/// finished one is resolved or reopened.
class TasksPanel extends StatefulWidget {
  const TasksPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

class _TasksPanelState extends State<TasksPanel> {
  static const _filters = <(String?, String)>[
    (null, 'All'),
    ('needs_you', 'Needs you'),
    ('working', 'Working'),
    ('suggested', 'Suggested'),
    ('resolved', 'Done'),
  ];

  Map<String, dynamic>? _data;
  String _error = '';
  String? _filter;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final service = widget.dependencies.service;
      final results = await Future.wait([
        service.invokeAction('proactive', 'tasks_list'),
        service
            .invokeAction('proactive', 'brief_today')
            .catchError((_) => <String, dynamic>{}),
      ]);
      if (!mounted) return;
      setState(() {
        _data = {
          'tasks': jsonMap(results[0])['tasks'],
          'brief': jsonMap(results[1]),
        };
        _error = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = errorText(e));
    }
  }

  List<Map<String, dynamic>> get _tasks => jsonList(_data?['tasks']);

  bool _matches(Map<String, dynamic> task, String? filter) {
    final status = '${task['status']}';
    return switch (filter) {
      null => true,
      'needs_you' => const {
          'needs_input',
          'ready_for_review',
          'failed',
        }.contains(status),
      _ => status == filter,
    };
  }

  int _count(String? filter) =>
      _tasks.where((t) => _matches(t, filter)).length;

  Future<void> _research() => runAction(
        context,
        widget.dependencies,
        'proactive',
        'research_now',
        const {},
        'Looking: suggestions arrive in your home chat.',
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final gutter = compact ? 16.0 : 26.0;
    final tasks = _tasks.where((t) => _matches(t, _filter)).toList();
    final brief = jsonMap(jsonMap(_data?['brief'])['brief']);
    final needsYou = _count('needs_you');
    final working = _count('working');
    final suggested = _count('suggested');

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 16 : 22, gutter, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelHeader(
              icon: Icons.task_alt_rounded,
              title: 'Tasks',
              subtitle: needsYou > 0
                  ? '$needsYou need${needsYou == 1 ? 's' : ''} you · $working working'
                  : working > 0
                      ? '$working in motion · $suggested suggested'
                      : 'What your agents are doing and what needs you',
              onClose: () => Navigator.of(context).maybePop(),
              actions: [
                IconButton.filledTonal(
                  tooltip: 'Refresh',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                FilledButton.tonalIcon(
                  onPressed: _research,
                  icon: const Icon(Icons.travel_explore_rounded, size: 18),
                  label: Text(compact ? 'Look' : 'Look now'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (_data != null) ...[
              _PulseStrip(
                needsYou: needsYou,
                working: working,
                suggested: suggested,
                done: _count('resolved'),
                selected: _filter,
                onSelect: (value) => setState(() => _filter = value),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (value, label) in _filters) ...[
                      if (value != _filters.first.$1) const SizedBox(width: 8),
                      _FilterChip(
                        label: label,
                        count: _count(value),
                        selected: _filter == value,
                        onTap: () => setState(() => _filter = value),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            Expanded(
              child: _error.isNotEmpty && _data == null
                  ? Center(
                      child: Text(_error,
                          style: TextStyle(color: scheme.error)))
                  : _data == null
                      ? const SkeletonList(
                          item: SkeletonCard(mediaHeight: 0), spacing: 10)
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 28),
                            children: [
                              if (brief.isNotEmpty)
                                BriefCard(
                                  brief: brief,
                                  margin: const EdgeInsets.only(bottom: 12),
                                ),
                              if (tasks.isEmpty)
                                _EmptyTasks(filtered: _filter != null)
                              else
                                for (final t in tasks)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 10),
                                    child: TaskTile(
                                      task: t,
                                      dependencies: widget.dependencies,
                                      reload: _reload,
                                    ),
                                  ),
                            ],
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseStrip extends StatelessWidget {
  const _PulseStrip({
    required this.needsYou,
    required this.working,
    required this.suggested,
    required this.done,
    required this.selected,
    required this.onSelect,
  });

  final int needsYou, working, suggested, done;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = needsYou + working + suggested + done;
    return GlassSurface(
      alpha: .7,
      borderRadius: BorderRadius.circular(AppShape.inner),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  total == 0 ? 'Quiet board' : '$total on the board',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 14),
                ),
                const Spacer(),
                Text(
                  'Live',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .4,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 10,
                child: total == 0
                    ? ColoredBox(color: scheme.surfaceContainerHighest)
                    : Row(
                        children: [
                          if (needsYou > 0)
                            Expanded(
                              flex: needsYou,
                              child: ColoredBox(color: scheme.error),
                            ),
                          if (working > 0)
                            Expanded(
                              flex: working,
                              child: ColoredBox(color: scheme.primary),
                            ),
                          if (suggested > 0)
                            Expanded(
                              flex: suggested,
                              child: ColoredBox(color: scheme.tertiary),
                            ),
                          if (done > 0)
                            Expanded(
                              flex: done,
                              child: ColoredBox(color: scheme.outline),
                            ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniStat(
                  label: 'Needs you',
                  count: needsYou,
                  color: scheme.error,
                  selected: selected == 'needs_you',
                  onTap: () => onSelect(
                      selected == 'needs_you' ? null : 'needs_you'),
                ),
                _MiniStat(
                  label: 'Working',
                  count: working,
                  color: scheme.primary,
                  selected: selected == 'working',
                  onTap: () =>
                      onSelect(selected == 'working' ? null : 'working'),
                ),
                _MiniStat(
                  label: 'Suggested',
                  count: suggested,
                  color: scheme.tertiary,
                  selected: selected == 'suggested',
                  onTap: () => onSelect(
                      selected == 'suggested' ? null : 'suggested'),
                ),
                _MiniStat(
                  label: 'Done',
                  count: done,
                  color: scheme.outline,
                  selected: selected == 'resolved',
                  onTap: () =>
                      onSelect(selected == 'resolved' ? null : 'resolved'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? color.withValues(alpha: .18)
          : scheme.surface.withValues(alpha: .4),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Text(
                '$count',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      label: Text(
        '$label · $count',
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: selected ? scheme.onSecondaryContainer : null,
        ),
      ),
      onSelected: (_) => onTap(),
    );
  }
}

class _EmptyTasks extends StatelessWidget {
  const _EmptyTasks({required this.filtered});
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 48, 12, 32),
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primaryContainer.withValues(alpha: .55),
            ),
            child: Icon(Icons.auto_awesome_rounded,
                size: 34, color: scheme.primary),
          ),
          const SizedBox(height: 16),
          Text(
            filtered ? 'Nothing in this view' : 'A clear board',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            filtered
                ? 'Try another filter, or look for new suggestions.'
                : 'Your agents suggest tasks here as they notice things, and every task you start shows its progress.',
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class BriefCard extends StatelessWidget {
  const BriefCard({
    super.key,
    required this.brief,
    this.margin = const EdgeInsets.fromLTRB(0, 0, 0, 0),
    /// When true, no fill of its own — sits on a parent surface (e.g. the
    /// feed's collapsible brief) so solid and accent never stack.
    this.embedded = false,
  });
  final Map<String, dynamic> brief;
  final EdgeInsetsGeometry margin;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = jsonMap(brief['content']);
    final needs = jsonList(content['needs_you']);
    final calendar = jsonList(content['calendar']);
    final tasks = jsonList(content['tasks']);
    final fg =
        embedded ? scheme.onSurface : scheme.onSecondaryContainer;
    String time(dynamic iso) {
      final t = DateTime.tryParse('$iso')?.toLocal();
      return t == null
          ? ''
          : '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    }

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: embedded
            ? Colors.transparent
            : scheme.secondaryContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wb_sunny_outlined, size: 20, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Your brief · ${content['day'] ?? brief['day'] ?? ''}',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          if (needs.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Needs you',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            for (final n in needs)
              _line(
                '${n['subject']}',
                [
                  n['from'],
                  n['reason'],
                ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                fg,
              ),
          ],
          if (calendar.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Today',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            for (final e in calendar)
              _line(
                '${e['summary']}',
                e['all_day'] == true ? 'All day' : time(e['start']),
                fg,
              ),
          ],
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Tasks',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            for (final t in tasks)
              _line('${t['subject']}', '${t['reason'] ?? ''}', fg),
          ],
          if (needs.isEmpty && calendar.isEmpty && tasks.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'A quiet day: nothing needs you.',
                style: TextStyle(color: fg),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(String title, String detail, Color color) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                  text: title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
              if (detail.isNotEmpty)
                TextSpan(
                  text: '  $detail',
                  style: TextStyle(
                      fontSize: 12, color: color.withValues(alpha: .8)),
                ),
            ],
          ),
        ),
      );
}

class TaskTile extends StatelessWidget {
  const TaskTile({
    super.key,
    required this.task,
    required this.dependencies,
    required this.reload,
  });
  final Map<String, dynamic> task;
  final AppDependencies dependencies;
  final Future<void> Function() reload;

  Future<void> _do(
    BuildContext context,
    String action, [
    Map<String, dynamic> extra = const {},
  ]) async {
    final out = await runAction(context, dependencies, 'proactive', action, {
      'id': task['id'],
      ...extra,
    });
    if (out != null) await reload();
  }

  (String, Color, IconData) _statusMeta(ColorScheme scheme) {
    return switch ('${task['status']}') {
      'needs_input' => ('Needs input', scheme.error, Icons.priority_high_rounded),
      'ready_for_review' => (
          'Ready for review',
          scheme.tertiary,
          Icons.rate_review_outlined
        ),
      'failed' => ('Failed', scheme.error, Icons.error_outline_rounded),
      'working' => ('Working', scheme.primary, Icons.autorenew_rounded),
      'suggested' => (
          'Suggested',
          scheme.tertiary,
          Icons.lightbulb_outline_rounded
        ),
      'resolved' => ('Done', scheme.outline, Icons.check_circle_outline_rounded),
      _ => ('Task', scheme.onSurfaceVariant, Icons.task_alt_rounded),
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = '${task['status']}';
    final (label, color, icon) = _statusMeta(scheme);
    final detail =
        [task['summary'], task['detail'], task['reason'], task['error']]
            .map((x) => '${x ?? ''}')
            .firstWhere((x) => x.isNotEmpty, orElse: () => '');

    return GlassSurface(
      alpha: .7,
      borderRadius: BorderRadius.circular(AppShape.inner),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: .14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 14, color: color),
                      const SizedBox(width: 5),
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${task['title']}',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 15,
                height: 1.25,
              ),
            ),
            if (detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  detail,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                        if (status == 'suggested') ...[
                          FilledButton(
                            onPressed: () => _do(context, 'task_start'),
                            child: const Text('Start'),
                          ),
                          TextButton(
                            onPressed: () => _do(context, 'task_hide'),
                            child: const Text('Hide'),
                          ),
                        ],
                        if (status == 'needs_input')
                          FilledButton(
                            onPressed: () async {
                              final text =
                                  await askText(context, 'Answer', lines: 3);
                              if (text != null &&
                                  text.trim().isNotEmpty &&
                                  context.mounted) {
                                await _do(context, 'task_answer', {
                                  'text': text.trim(),
                                });
                              }
                            },
                            child: const Text('Answer'),
                          ),
                        if (status == 'ready_for_review' ||
                            status == 'failed' ||
                            status == 'needs_input')
                          FilledButton.tonal(
                            onPressed: () => _do(context, 'task_resolve'),
                            child: const Text('Resolve'),
                          ),
                        if (status == 'failed' && task['retryable'] == true)
                          OutlinedButton(
                            onPressed: () => _do(context, 'task_start'),
                            child: const Text('Try again'),
                          ),
                        if (status == 'resolved')
                          TextButton(
                            onPressed: () => _do(context, 'task_reopen'),
                            child: const Text('Reopen'),
                          ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The latest suggestion, shown above the home chat's composer until it is
/// started or hidden.
class SuggestionBanner extends StatefulWidget {
  const SuggestionBanner({
    super.key,
    required this.dependencies,
    this.onOpenTasks,
  });
  final AppDependencies dependencies;
  final VoidCallback? onOpenTasks;

  @override
  State<SuggestionBanner> createState() => _SuggestionBannerState();
}

class _SuggestionBannerState extends State<SuggestionBanner> {
  Map<String, dynamic> task = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final out = jsonMap(
        await widget.dependencies.service.invokeAction(
          'proactive',
          'suggestion_latest',
        ),
      );
      if (mounted) setState(() => task = jsonMap(out['task']));
    } catch (_) {
      // No proactive namespace on this node: no banner.
    }
  }

  Future<void> _do(String action) async {
    final out = await runAction(
      context,
      widget.dependencies,
      'proactive',
      action,
      {'id': task['id']},
    );
    if (out != null && mounted) setState(() => task = const {});
  }

  @override
  Widget build(BuildContext context) {
    if (task.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              Icons.lightbulb_outline_rounded,
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: widget.onOpenTasks ??
                    () => showTasksPanel(context, widget.dependencies),
                child: Text(
                  '${task['title']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            ),
            TextButton(
              onPressed: () => _do('task_start'),
              child: const Text('Start'),
            ),
            IconButton(
              tooltip: 'Hide',
              onPressed: () => _do('task_hide'),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
