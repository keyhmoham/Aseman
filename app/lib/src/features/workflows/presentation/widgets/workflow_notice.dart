import 'package:flutter/material.dart';

class WorkflowNotice extends StatelessWidget {
  const WorkflowNotice(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(12),
      child: Text(message,
          style: TextStyle(color: Theme.of(context).colorScheme.error)));
}
