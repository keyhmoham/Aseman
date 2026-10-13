import 'package:flutter/material.dart';

import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../data/workflow_repository.dart';
import 'widgets/workflow_notice.dart';
import 'widgets/workflow_run_card.dart';
import 'workflow_view_model.dart';

Future<void> showWorkflowPanel(BuildContext context, TraderaService service,
    String spaceId, String roomId, String roomName,
    {bool canManage = false}) {
  final panel = WorkflowPanel(
      repository: WorkflowRepository(service),
      spaceId: spaceId,
      roomId: roomId,
      roomName: roomName,
      canManage: canManage);
  return showAdaptivePanel<void>(context, panel, breakpoint: 820);
}

class WorkflowPanel extends StatefulWidget {
  const WorkflowPanel(
      {super.key,
      required this.repository,
      required this.spaceId,
      required this.roomId,
      required this.roomName,
      this.canManage = false});
  final WorkflowRepository repository;
  final String spaceId, roomId, roomName;
  final bool canManage;
  @override
  State<WorkflowPanel> createState() => _WorkflowPanelState();
}

class _WorkflowPanelState extends State<WorkflowPanel>
    with WidgetsBindingObserver {
  late WorkflowViewModel model;

  void _createModel() {
    model = WorkflowViewModel(widget.repository,
        spaceId: widget.spaceId, roomId: widget.roomId);
    model.setPollingEnabled(true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _createModel();
  }

  @override
  void didUpdateWidget(covariant WorkflowPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spaceId != widget.spaceId ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.repository != widget.repository) {
      model.dispose();
      _createModel();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      model.setPollingEnabled(state == AppLifecycleState.resumed);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: model,
      builder: (context, _) => Column(children: [
            Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const Icon(Icons.account_tree_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text('Agent tasks',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(widget.roomName,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ])),
                  IconButton(
                      tooltip: 'Refresh tasks',
                      onPressed: () => model.refresh(),
                      icon: const Icon(Icons.refresh_rounded)),
                  IconButton(
                      tooltip: 'Close tasks',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded)),
                ])),
            if (model.loadError != null)
              WorkflowNotice('Could not refresh tasks. ${model.loadError}'),
            if (model.actionError != null) WorkflowNotice(model.actionError!),
            if (model.loading) const LinearProgressIndicator(),
            Expanded(
                child: !model.loading && model.runs.isEmpty
                    ? Center(
                        child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(model.loadError == null
                                ? 'No agent tasks in this room yet.'
                                : 'Task history is unavailable. Try refreshing.')))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                        itemCount: model.runs.length,
                        itemBuilder: (_, index) => WorkflowRunCard(
                            key: ValueKey(model.runs[index].id),
                            run: model.runs[index],
                            model: model,
                            canManage: widget.canManage))),
          ]));
}
