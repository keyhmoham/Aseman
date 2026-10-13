import 'package:flutter/material.dart';

import '../../domain/workflow.dart';
import '../workflow_view_model.dart';
import 'workflow_notice.dart';

class WorkflowExecutionDialog extends StatefulWidget {
  const WorkflowExecutionDialog(
      {required this.run, required this.model, required this.canManage});
  final WorkflowRun run;
  final WorkflowViewModel model;
  final bool canManage;
  @override
  State<WorkflowExecutionDialog> createState() =>
      _WorkflowExecutionDialogState();
}

class _WorkflowExecutionDialogState extends State<WorkflowExecutionDialog> {
  late var events = widget.model.execution(widget.run.id);
  String? error;
  bool saving = false;

  Future<void> _resolve(Map<String, dynamic> event) async {
    final result = await showDialog<(String, String)>(
        context: context, builder: (_) => const _ResolutionDialog());
    if (result == null || !mounted) return;
    setState(() => saving = true);
    final ok = await widget.model
        .reconcile(widget.run, event['id'] as String, result.$1, result.$2);
    if (!mounted) return;
    setState(() {
      saving = false;
      error = ok ? null : widget.model.actionError;
      events = widget.model.execution(widget.run.id);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Execution history'),
          content: SizedBox(
              width: 600,
              height: 440,
              child: Column(children: [
                if (error != null) WorkflowNotice(error!),
                Expanded(
                    child: FutureBuilder(
                        future: events,
                        builder: (context, snapshot) {
                          if (snapshot.hasError)
                            return TextButton(
                                onPressed: () => setState(() {
                                      events = widget.model.repository
                                          .execution(widget.run.id);
                                    }),
                                child: const Text(
                                    'Could not load execution history. Retry'));
                          if (!snapshot.hasData)
                            return const Center(
                                child: CircularProgressIndicator());
                          final rows = snapshot.data!;
                          if (rows.isEmpty)
                            return const Center(
                                child: Text('No recorded operations.'));
                          return ListView(children: [
                            for (final event in rows)
                              ExpansionTile(
                                title: Text(
                                    event['tool'] as String? ?? 'Operation'),
                                subtitle: Text(
                                    'Stage ${int.tryParse(event['step_id']?.toString() ?? '') == null ? '?' : int.parse(event['step_id'].toString()) + 1} · attempt ${event['attempt_id'] ?? '?'} · '
                                    '${event['resolution'] ?? event['status'] ?? 'unknown'}'),
                                children: [
                                  SelectableText(event['result'] as String? ??
                                      'No recorded result.'),
                                  if (widget.canManage &&
                                      widget.run.status ==
                                          WorkflowStatus.blocked &&
                                      event['resolution'] == null &&
                                      (event['status'] == 'running' ||
                                          event['status'] == 'failed'))
                                    TextButton(
                                        onPressed: saving
                                            ? null
                                            : () => _resolve(event),
                                        child: const Text(
                                            'Record observed outcome'))
                                ],
                              )
                          ]);
                        })),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'))
          ]);
}

class _ResolutionDialog extends StatefulWidget {
  const _ResolutionDialog();
  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  final result = TextEditingController();
  String? verdict;
  @override
  void dispose() {
    result.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Record observed outcome'),
          content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'Check the operation’s actual effects before choosing an outcome.'),
                DropdownButtonFormField<String>(
                    initialValue: verdict,
                    decoration:
                        const InputDecoration(labelText: 'Observed outcome'),
                    items: const [
                      DropdownMenuItem(
                          value: 'completed',
                          child: Text('Operation completed')),
                      DropdownMenuItem(
                          value: 'not_executed',
                          child: Text('Operation did not execute'))
                    ],
                    onChanged: (value) => setState(() => verdict = value)),
                TextField(
                    controller: result,
                    maxLength: 8192,
                    maxLines: 4,
                    decoration:
                        const InputDecoration(labelText: 'Evidence or result')),
              ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: verdict == null
                    ? null
                    : () => Navigator.pop(context, (verdict!, result.text)),
                child: const Text('Record outcome'))
          ]);
}
