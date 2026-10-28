import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';
import 'governance_views.dart';

/// A project's agents settings: what they own (responsibilities), what they
/// were shown (demonstrations), who holds the computer, where it may
/// connect, the credentials they use, the project's policy and its audit.
class ProjectAgentsPanel extends StatelessWidget {
  const ProjectAgentsPanel({
    super.key,
    required this.dependencies,
    required this.space,
    this.title = '',
  });
  final AppDependencies dependencies;
  final String space;
  final String title;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      'Responsibilities',
      'Demonstrations',
      'Computer',
      'Network',
      'Credentials',
      'Policy',
      'Audit',
    ];
    Widget pad(Widget child) =>
        ListView(padding: const EdgeInsets.all(16), children: [child]);
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title.isEmpty ? 'Agents' : '$title · Agents'),
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final t in tabs) Tab(text: t)],
          ),
        ),
        body: TabBarView(
          children: [
            pad(ResponsibilitiesView(dependencies: dependencies, space: space)),
            pad(DemonstrationsView(dependencies: dependencies, space: space)),
            pad(ComputerControlView(dependencies: dependencies, space: space)),
            pad(EgressEditor(dependencies: dependencies, space: space)),
            pad(SecretsView(dependencies: dependencies, space: space)),
            pad(PolicyEditor(dependencies: dependencies, space: space)),
            pad(AuditView(dependencies: dependencies, space: space)),
          ],
        ),
      ),
    );
  }
}

/// Standing responsibilities: an instruction an agent runs when an email,
/// GitHub event, Slack message or webhook matches.
class ResponsibilitiesView extends StatefulWidget {
  const ResponsibilitiesView({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<ResponsibilitiesView> createState() => _ResponsibilitiesViewState();
}

class _ResponsibilitiesViewState extends State<ResponsibilitiesView> {
  static const _triggers = {
    'email': 'An email arrives',
    'github': 'A GitHub event',
    'slack': 'A Slack message',
    'webhook': 'A webhook is called',
  };

  List<Map<String, dynamic>> rows = const [];
  String hookPath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'responsibilities',
      'list',
      {'space': widget.space},
    );
    if (out == null || !mounted) return;
    setState(() {
      rows = jsonList(out['responsibilities']);
      hookPath = '${out['hook_path'] ?? ''}';
    });
  }

  Future<void> _create() async {
    final input = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _ResponsibilityDialog(triggers: _triggers),
    );
    if (input == null || !mounted) return;
    final out = await runAction(
      context,
      widget.dependencies,
      'responsibilities',
      'create',
      {'space': widget.space, ...input},
    );
    if (out == null || !mounted) return;
    // Hooks show their address and signing secret once.
    final extra = Map<String, dynamic>.from(out)..remove('responsibility');
    if (extra.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Connect the source'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in extra.entries) ...[
                Text(
                  e.key,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                SelectableText('${e.value}'),
                const SizedBox(height: 8),
              ],
              const Text('The secret is shown only now.'),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
    await _load();
  }

  Future<void> _act(
    Map<String, dynamic> r,
    String action, [
    String? done,
  ]) async {
    final out = await runAction(
      context,
      widget.dependencies,
      'responsibilities',
      action,
      {'id': r['id']},
      done,
    );
    if (out != null) await _load();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Give an agent an area it owns: when something matches, it acts on your instruction, under the project\'s policy.',
      ),
      const SizedBox(height: 8),
      for (final r in rows)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${r['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Switch(
                      value: r['enabled'] == true,
                      onChanged: (v) => _act(r, v ? 'resume' : 'pause'),
                    ),
                  ],
                ),
                Text(
                  '${_triggers[r['trigger']] ?? r['trigger']}: ${r['instruction']}',
                ),
                Text(
                  'Fired ${r['fired'] ?? 0} times${'${r['last_result'] ?? ''}'.isEmpty ? '' : ' · ${r['last_result']}'}',
                  style: const TextStyle(fontSize: 12),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () =>
                          _act(r, 'test', 'Fired with a sample event'),
                      child: const Text('Test'),
                    ),
                    TextButton(
                      onPressed: () => _act(r, 'delete', 'Deleted'),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_rounded),
          label: const Text('New responsibility'),
        ),
      ),
    ],
  );
}

class _ResponsibilityDialog extends StatefulWidget {
  const _ResponsibilityDialog({required this.triggers});
  final Map<String, String> triggers;

  @override
  State<_ResponsibilityDialog> createState() => _ResponsibilityDialogState();
}

class _ResponsibilityDialogState extends State<_ResponsibilityDialog> {
  final name = TextEditingController();
  final instruction = TextEditingController();
  final filter = TextEditingController();
  final second = TextEditingController();
  String trigger = 'email';

  @override
  void dispose() {
    for (final c in [name, instruction, filter, second]) {
      c.dispose();
    }
    super.dispose();
  }

  (String, String, String, String) get _filters => switch (trigger) {
    'email' => ('from', 'From contains', 'subject', 'Subject contains'),
    'github' => (
      'repo',
      'Repository (owner/name)',
      'events',
      'Events (comma separated)',
    ),
    'slack' => ('channel', 'Channel ID', 'keyword', 'Keyword'),
    _ => ('keyword', 'Keyword in the payload', '', ''),
  };

  @override
  Widget build(BuildContext context) {
    final (k1, l1, k2, l2) = _filters;
    return AlertDialog(
      title: const Text('New responsibility'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            DropdownButtonFormField<String>(
              initialValue: trigger,
              decoration: const InputDecoration(labelText: 'When'),
              items: [
                for (final t in widget.triggers.entries)
                  DropdownMenuItem(value: t.key, child: Text(t.value)),
              ],
              onChanged: (v) => setState(() => trigger = v ?? trigger),
            ),
            TextField(
              controller: filter,
              decoration: InputDecoration(labelText: l1),
            ),
            if (k2.isNotEmpty)
              TextField(
                controller: second,
                decoration: InputDecoration(labelText: l2),
              ),
            TextField(
              controller: instruction,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'What the agent does',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty || instruction.text.trim().isEmpty)
              return;
            Navigator.pop(context, {
              'name': name.text.trim(),
              'instruction': instruction.text.trim(),
              'trigger': trigger,
              if (filter.text.trim().isNotEmpty) k1: filter.text.trim(),
              if (k2.isNotEmpty && second.text.trim().isNotEmpty)
                k2: k2 == 'events'
                    ? second.text
                          .split(',')
                          .map((e) => e.trim())
                          .where((e) => e.isNotEmpty)
                          .toList()
                    : second.text.trim(),
            });
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Show an agent how: record yourself on the project computer, review the
/// skill drafted from it, and keep it (with a daily time, as a routine).
class DemonstrationsView extends StatefulWidget {
  const DemonstrationsView({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<DemonstrationsView> createState() => _DemonstrationsViewState();
}

class _DemonstrationsViewState extends State<DemonstrationsView> {
  List<Map<String, dynamic>> demos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'routines',
      'demo_list',
      {'space': widget.space},
    );
    if (out != null && mounted) {
      setState(() => demos = jsonList(out['demonstrations']));
    }
  }

  Future<void> _do(
    String action,
    Map<String, dynamic> body, [
    String? done,
  ]) async {
    final out = await runAction(
      context,
      widget.dependencies,
      'routines',
      action,
      {'space': widget.space, ...body},
      done,
    );
    if (out != null) await _load();
  }

  Future<void> _save(Map<String, dynamic> d) async {
    final title = TextEditingController(text: '${d['title'] ?? ''}');
    final instructions = TextEditingController(
      text: '${d['instructions'] ?? ''}',
    );
    final at = TextEditingController();
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep this skill'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              TextField(
                controller: instructions,
                minLines: 6,
                maxLines: 14,
                decoration: const InputDecoration(
                  labelText: 'Steps the agent follows',
                ),
              ),
              TextField(
                controller: at,
                decoration: const InputDecoration(
                  labelText: 'Run daily at (HH:MM, optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Keep'),
          ),
        ],
      ),
    );
    if (keep == true) {
      await _do('demo_save', {
        'id': d['id'],
        'title': title.text.trim(),
        'instructions': instructions.text.trim(),
        if (at.text.trim().isNotEmpty) 'at': at.text.trim(),
      }, 'Saved as a skill');
    }
    title.dispose();
    instructions.dispose();
    at.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recording = demos.where((d) => d['status'] == 'recording').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Do a task once on the project computer while Aseman records it; an agent drafts a skill you review, then does it for you.',
        ),
        const SizedBox(height: 8),
        if (recording.isEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _do(
                'demo_start',
                const {},
                'Recording: work on the project computer, then stop here',
              ),
              icon: const Icon(Icons.fiber_manual_record_rounded),
              label: const Text('Start recording'),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _do('demo_stop', {
                'id': recording.first['id'],
              }, 'Drafting a skill from it'),
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Stop and draft a skill'),
            ),
          ),
        const SizedBox(height: 8),
        for (final d in demos.where((d) => d['status'] != 'recording'))
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${d['title'] ?? ''}'.isEmpty
                        ? 'Demonstration'
                        : '${d['title']}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${d['status']}${'${d['error'] ?? ''}'.isEmpty ? '' : ' · ${d['error']}'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if ('${d['instructions'] ?? ''}'.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '${d['instructions']}',
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  Wrap(
                    children: [
                      if (d['status'] == 'drafted')
                        TextButton(
                          onPressed: () => _save(d),
                          child: const Text('Review and keep'),
                        ),
                      if (d['status'] != 'saved')
                        TextButton(
                          onPressed: () =>
                              _do('demo_discard', {'id': d['id']}, 'Discarded'),
                          child: const Text('Discard'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Who holds the project computer: its agents, or a person. Taking control
/// pauses the agents until it is handed back.
class ComputerControlView extends StatefulWidget {
  const ComputerControlView({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<ComputerControlView> createState() => _ComputerControlViewState();
}

class _ComputerControlViewState extends State<ComputerControlView> {
  Map<String, dynamic> state = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'control_state',
      {'space': widget.space},
    );
    if (out != null && mounted) setState(() => state = out);
  }

  Future<void> _do(String action) async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      action,
      {'space': widget.space},
    );
    if (out != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final status = '${state['status'] ?? ''}';
    final h = jsonMap(state['handover']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(switch (status) {
          'controlled' =>
            'You (or a teammate) hold the computer: the agents wait.',
          'requested' => 'An agent asked for a person: ${h['reason'] ?? ''}',
          '' => '',
          _ => 'The agents hold the computer.',
        }),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: status == 'controlled'
              ? FilledButton.icon(
                  onPressed: () => _do('control_release'),
                  icon: const Icon(Icons.smart_toy_outlined),
                  label: const Text('Hand back to the agents'),
                )
              : FilledButton.icon(
                  onPressed: status.isEmpty ? null : () => _do('control_take'),
                  icon: const Icon(Icons.mouse_outlined),
                  label: const Text('Take control'),
                ),
        ),
      ],
    );
  }
}
