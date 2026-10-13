import 'package:flutter/material.dart';

import '../../../rooms/presentation/widgets/attachment_bubble.dart';
import '../../domain/workflow.dart';
import '../workflow_view_model.dart';

class WorkflowFiles extends StatelessWidget {
  const WorkflowFiles({required this.run, required this.model});
  final WorkflowRun run;
  final WorkflowViewModel model;
  @override
  Widget build(BuildContext context) => ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Delivered files (${run.artifactIds.length})'),
          children: [
            // Files remain available for partial/failed outcomes; delivery does not
            // imply that every acceptance criterion passed.
            for (final id in run.artifactIds)
              _DeliveredFile(key: ValueKey(id), id: id, model: model),
          ]);
}

class _DeliveredFile extends StatefulWidget {
  const _DeliveredFile({super.key, required this.id, required this.model});
  final String id;
  final WorkflowViewModel model;
  @override
  State<_DeliveredFile> createState() => _DeliveredFileState();
}

class _DeliveredFileState extends State<_DeliveredFile> {
  late var file = widget.model.file(widget.id);
  @override
  Widget build(BuildContext context) => FutureBuilder(
      future: file,
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return TextButton(
              onPressed: () => setState(() {
                    file = widget.model.file(widget.id, retry: true);
                  }),
              child: const Text('Could not load file. Retry'));
        final value = snapshot.data;
        if (value == null)
          return const Padding(
              padding: EdgeInsets.all(8), child: Text('Loading file…'));
        final service = widget.model.repository.service;
        return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: AttachmentBubble(
                file: value,
                headers: service.authHeaders(),
                resolveUrl: (file) => service.fileContentUrl(file.id),
                fetchBytes: (file) => service.downloadFile(file.id)));
      });
}
