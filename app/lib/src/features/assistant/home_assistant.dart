import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';
import 'setup_panel.dart';
import 'tasks_panel.dart';

/// The person's assistant at the top of their home feed: today's brief, the
/// actions waiting on them (approvals, answered in place), the tasks that
/// need them and what their agents suggest, and how much is in progress.
/// With nothing set up yet it says how to start.
class HomeAssistant extends StatefulWidget {
  const HomeAssistant({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<HomeAssistant> createState() => _HomeAssistantState();
}

class _HomeAssistantState extends State<HomeAssistant> {
  static const _refresh = Duration(minutes: 1);

  Map<String, dynamic> brief = const {};
  List<Map<String, dynamic>> tasks = const [];
  List<Map<String, dynamic>> approvals = const [];
  bool available = false;
  bool loaded = false;
  bool briefOpen = true;
  Timer? timer;

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
    super.dispose();
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
    setState(() {
      loaded = true;
      // No proactive namespace on this node: nothing to show.
      available = results[0] != null;
      tasks = jsonList(results[0]?['tasks']);
      brief = jsonMap(results[1]?['brief']);
      approvals = jsonList(results[2]?['approvals']);
    });
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

  @override
  Widget build(BuildContext context) {
    if (!loaded || !available) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
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
    final quiet =
        brief.isEmpty &&
        approvals.isEmpty &&
        needsYou.isEmpty &&
        suggested.isEmpty &&
        working == 0;
    if (quiet) return _quiet(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 20, color: scheme.primary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Your assistant',
                style: TextStyle(
                  fontSize: 22,
                  letterSpacing: -.3,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => openPanel(
                context,
                TasksPanel(dependencies: deps),
              ).then((_) => _load()),
              icon: const Icon(Icons.task_alt_rounded, size: 18),
              label: Text(
                working > 0 ? 'Tasks · $working working' : 'All tasks',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (brief.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            clipBehavior: Clip.antiAlias,
            child: ExpansionTile(
              initiallyExpanded: briefOpen,
              onExpansionChanged: (v) => briefOpen = v,
              leading: const Icon(Icons.wb_sunny_outlined),
              title: const Text(
                'Today\'s brief',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              childrenPadding: EdgeInsets.zero,
              children: [BriefCard(brief: brief, margin: EdgeInsets.zero)],
            ),
          ),
        for (final a in approvals) _approval(context, a),
        for (final t in [...needsYou, ...suggested])
          TaskTile(task: t, dependencies: deps, reload: _load),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _approval(BuildContext context, Map<String, dynamic> a) {
    final scheme = Theme.of(context).colorScheme;
    final recipients = jsonStrings(a['recipients']);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: scheme.tertiaryContainer,
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
                  color: scheme.onTertiaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${a['summary']}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: scheme.onTertiaryContainer,
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
              style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
            ),
            if ('${a['text'] ?? ''}'.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${a['text']}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onTertiaryContainer),
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

  /// Nothing waits on the person: one line, so the feed stays in view.
  Widget _quiet(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your assistant · nothing needs you',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(
              onPressed: () => openPanel(
                context,
                TasksPanel(dependencies: deps),
              ).then((_) => _load()),
              child: const Text('Tasks'),
            ),
            TextButton(
              onPressed: () => openPanel(
                context,
                SetupPanel(dependencies: deps),
              ).then((_) => _load()),
              child: const Text('Setup'),
            ),
          ],
        ),
      ),
    );
  }
}
