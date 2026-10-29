import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// A person's Tasks: what their agents suggested, are working on, need from
/// them or finished, with today's morning brief on top. Start hands a
/// suggestion to the lead; a task that needs input takes an answer; a
/// finished one is resolved or reopened.
class TasksPanel extends StatelessWidget {
  const TasksPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  static const _order = [
    'needs_input',
    'ready_for_review',
    'failed',
    'working',
    'suggested',
    'resolved',
  ];

  static const _labels = {
    'needs_input': 'Needs you',
    'ready_for_review': 'Ready for review',
    'failed': 'Failed',
    'working': 'Working',
    'suggested': 'Suggested',
    'resolved': 'Done',
  };

  Future<Map<String, dynamic>> _load() async {
    final service = dependencies.service;
    final results = await Future.wait([
      service.invokeAction('proactive', 'tasks_list'),
      // The brief keeps the time zone saved with the person's settings.
      service
          .invokeAction('proactive', 'brief_today')
          .catchError((_) => <String, dynamic>{}),
    ]);
    return {
      'tasks': jsonMap(results[0])['tasks'],
      'brief': jsonMap(results[1]),
    };
  }

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Tasks',
    load: _load,
    actions: [
      IconButton(
        tooltip: 'Look for things to do now',
        icon: const Icon(Icons.travel_explore_rounded),
        onPressed: () => runAction(
          context,
          dependencies,
          'proactive',
          'research_now',
          const {},
          'Looking: suggestions arrive in your home chat.',
        ),
      ),
    ],
    build: (context, data, reload) {
      final tasks = jsonList(data['tasks']);
      final brief = jsonMap(jsonMap(data['brief'])['brief']);
      return ListView(
        children: [
          if (brief.isNotEmpty) BriefCard(brief: brief),
          if (tasks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nothing yet. Your agents suggest tasks here as they notice things, and every task you start shows its progress.',
              ),
            ),
          for (final status in _order)
            if (tasks.any((t) => t['status'] == status))
              PanelSection(
                title: _labels[status]!,
                children: [
                  for (final t in tasks.where((t) => t['status'] == status))
                    TaskTile(
                      task: t,
                      dependencies: dependencies,
                      reload: reload,
                    ),
                ],
              ),
          const SizedBox(height: 32),
        ],
      );
    },
  );
}

class BriefCard extends StatelessWidget {
  const BriefCard({
    super.key,
    required this.brief,
    this.margin = const EdgeInsets.fromLTRB(16, 16, 16, 0),
  });
  final Map<String, dynamic> brief;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final content = jsonMap(brief['content']);
    final needs = jsonList(content['needs_you']);
    final calendar = jsonList(content['calendar']);
    final tasks = jsonList(content['tasks']);
    String time(dynamic iso) {
      final t = DateTime.tryParse('$iso')?.toLocal();
      return t == null
          ? ''
          : '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    }

    return Card(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wb_sunny_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Your brief · ${content['day'] ?? brief['day'] ?? ''}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
            if (needs.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Needs you',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final n in needs)
                _line(
                  '${n['subject']}',
                  [
                    n['from'],
                    n['reason'],
                  ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                ),
            ],
            if (calendar.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Today',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final e in calendar)
                _line(
                  '${e['summary']}',
                  e['all_day'] == true ? 'All day' : time(e['start']),
                ),
            ],
            if (tasks.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Tasks',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              for (final t in tasks)
                _line('${t['subject']}', '${t['reason'] ?? ''}'),
            ],
            if (needs.isEmpty && calendar.isEmpty && tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('A quiet day: nothing needs you.'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _line(String title, String detail) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(text: title),
          if (detail.isNotEmpty)
            TextSpan(text: '  $detail', style: const TextStyle(fontSize: 12)),
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

  @override
  Widget build(BuildContext context) {
    final status = '${task['status']}';
    final detail =
        [task['summary'], task['detail'], task['reason'], task['error']]
            .map((x) => '${x ?? ''}')
            .firstWhere((x) => x.isNotEmpty, orElse: () => '');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${task['title']}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(detail),
              ),
            Wrap(
              spacing: 4,
              children: [
                if (status == 'suggested') ...[
                  TextButton(
                    onPressed: () => _do(context, 'task_start'),
                    child: const Text('Start'),
                  ),
                  TextButton(
                    onPressed: () => _do(context, 'task_hide'),
                    child: const Text('Hide'),
                  ),
                ],
                if (status == 'needs_input')
                  TextButton(
                    onPressed: () async {
                      final text = await askText(context, 'Answer', lines: 3);
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
                  TextButton(
                    onPressed: () => _do(context, 'task_resolve'),
                    child: const Text('Resolve'),
                  ),
                if (status == 'failed' && task['retryable'] == true)
                  TextButton(
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
                onTap: widget.onOpenTasks,
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
