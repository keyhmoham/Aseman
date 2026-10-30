import 'package:flutter/material.dart';
import '../../shared/widgets/overlay_panels.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';
import 'governance_views.dart';
import 'responsibilities_view.dart';
import '../../shared/widgets/glass_surface.dart';

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
    final keep = await showAppDialog<bool>(
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
          AppCard(
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
