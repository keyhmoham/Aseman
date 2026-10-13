import 'package:flutter/material.dart';

import '../../../rooms/presentation/widgets/workspace_links.dart';
import '../../../search_feed/presentation/rich_post_content.dart';
import '../../domain/workflow.dart';
import '../workflow_view_model.dart';
import 'workflow_execution_dialog.dart';
import 'workflow_files.dart';

class WorkflowRunCard extends StatefulWidget {
  const WorkflowRunCard(
      {super.key,
      required this.run,
      required this.model,
      required this.canManage});
  final WorkflowRun run;
  final WorkflowViewModel model;
  final bool canManage;
  @override
  State<WorkflowRunCard> createState() => _WorkflowRunCardState();
}

class _WorkflowRunCardState extends State<WorkflowRunCard> {
  final answer = TextEditingController();
  @override
  void didUpdateWidget(covariant WorkflowRunCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.run.questionId != widget.run.questionId) answer.clear();
  }

  @override
  void dispose() {
    answer.dispose();
    super.dispose();
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Cancel this task?'),
              content: const Text('Completed files will remain available.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep running')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Cancel task'))
              ],
            ));
    if (confirmed == true && mounted) await widget.model.cancel(widget.run);
  }

  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    final model = widget.model;
    final service = model.repository.service;
    final mine = service.session?.accountId == run.ownerId;
    final manager = widget.canManage;
    final color = switch (run.status) {
      WorkflowStatus.done => Colors.green,
      WorkflowStatus.failed ||
      WorkflowStatus.budgetExhausted =>
        Theme.of(context).colorScheme.error,
      WorkflowStatus.partial ||
      WorkflowStatus.blocked ||
      WorkflowStatus.awaitingInput =>
        Colors.orange,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(14),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(run.task,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 12, runSpacing: 6, children: [
                Text(run.statusLabel,
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w700)),
                if (run.steps.isNotEmpty)
                  Text(
                      '${run.completedSteps}/${run.steps.length} stages completed'),
                if (run.outcome.totalTokens > 0)
                  Text('${run.outcome.totalTokens} tokens'),
              ]),
              if (run.status.isExecuting)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: LinearProgressIndicator()),
              if (run.status == WorkflowStatus.done && !run.outcome.finalized)
                const Text('Preparing the final report…'),
              if (run.outcome.error.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(run.outcome.error)),
              if (run.status == WorkflowStatus.blocked)
                const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                        'Execution was interrupted. Review any uncertain operations before resuming.')),
              if (run.question.isNotEmpty &&
                  run.status == WorkflowStatus.awaitingInput) ...[
                const SizedBox(height: 8),
                Text(run.question),
                if (mine && run.canAnswer) ...[
                  TextField(
                      controller: answer,
                      minLines: 1,
                      maxLines: 4,
                      enabled: !model.busy(run.id, 'resume'),
                      decoration:
                          const InputDecoration(labelText: 'Your answer')),
                  FilledButton(
                      onPressed: model.busy(run.id, 'resume')
                          ? null
                          : () async {
                              if (await model.resume(run,
                                      answer: answer.text) &&
                                  mounted) answer.clear();
                            },
                      child: Text(model.busy(run.id, 'resume')
                          ? 'Submitting answer…'
                          : 'Submit answer')),
                ],
              ],
              if (run.steps.isNotEmpty)
                ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Stages and verification'),
                    children: [
                      for (final step in run.steps) _StepView(step: step),
                    ]),
              if (run.artifactIds.isNotEmpty)
                WorkflowFiles(run: run, model: model),
              if (run.result.isNotEmpty)
                ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Final report'),
                    children: [
                      Align(
                          alignment: Alignment.centerLeft,
                          child: RichPostContent(run.result,
                              onLinkTap: (link) =>
                                  openWorkspaceLink(context, service, link)))
                    ]),
              Wrap(spacing: 8, children: [
                if ((mine || manager) && run.status.canCancel)
                  TextButton(
                      onPressed: model.busy(run.id, 'cancel') ? null : _cancel,
                      child: const Text('Cancel task')),
                if (mine && run.canResume)
                  FilledButton(
                      onPressed: model.busy(run.id, 'resume')
                          ? null
                          : () => model.resume(run),
                      child: const Text('Resume task')),
                TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => WorkflowExecutionDialog(
                            run: run,
                            model: model,
                            canManage: mine || manager)),
                    child: const Text('Execution history')),
              ]),
            ])));
  }
}

class _StepView extends StatelessWidget {
  const _StepView({required this.step});
  final WorkflowStep step;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
          alignment: Alignment.centerLeft,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${step.index + 1}. ${step.name}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(step.statusLabel),
            if (step.attempt > 0)
              Text(
                  'Attempt ${step.attempt} · ${step.retries} corrective retries · '
                  '${step.continuations} resource continuations',
                  style: const TextStyle(fontSize: 11)),
            if (step.scope.isNotEmpty) Text(step.scope),
            if (step.dependencies.isNotEmpty)
              Text(
                  'After stages ${step.dependencies.map((i) => i + 1).join(', ')}'),
            if (step.skills.isNotEmpty)
              Wrap(spacing: 4, children: [
                for (final skill in step.skills)
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: Chip(
                          label: Text(skill,
                              maxLines: 1, overflow: TextOverflow.ellipsis))),
              ]),
            for (final criterion in step.acceptance) Text('• $criterion'),
            if (step.verificationFeedback.isNotEmpty)
              Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Inspection: ${step.verificationFeedback}')),
          ])));
}
