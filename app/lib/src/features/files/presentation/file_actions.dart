import 'package:flutter/material.dart';

import '../../../core/utils/context_extensions.dart';
import '../data/workspace_files.dart';

/// Makes a change to the workspace's files. It does not wake the computer:
/// only when the node says the change needs it (a very large file, or what
/// the provider cannot do while it sleeps) is the person asked, and the
/// change made again waking it. True when the change was made.
Future<bool> runWorkspaceChange(
  BuildContext context,
  Future<void> Function({required bool wake}) change, {
  String done = '',
}) async {
  try {
    await change(wake: false);
  } on WorkspaceNeedsComputer catch (e) {
    if (!context.mounted) return false;
    final wake = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.power_settings_new_rounded),
        title: const Text('Wake the computer?'),
        content: Text(
          '${e.message} The computer is asleep; other changes to its files '
          'do not need it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Wake and continue'),
          ),
        ],
      ),
    );
    if (wake != true || !context.mounted) return false;
    try {
      await change(wake: true);
    } catch (e) {
      if (context.mounted) context.showMessage('$e');
      return false;
    }
  } catch (e) {
    if (context.mounted) context.showMessage('$e');
    return false;
  }
  if (done.isNotEmpty && context.mounted) context.showMessage(done);
  return true;
}

/// Asks for a file or folder name; null when cancelled.
Future<String?> askFileName(
  BuildContext context, {
  required String title,
  required String action,
  String initial = '',
  String hint = '',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _NameDialog(title: title, action: action, initial: initial, hint: hint),
);

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.action,
    required this.initial,
    required this.hint,
  });
  final String title;
  final String action;
  final String initial;
  final String hint;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      // The name without its extension is selected, ready to type over.
      extentOffset: widget.initial.contains('.')
          ? widget.initial.lastIndexOf('.')
          : widget.initial.length,
    );
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final problem = name.isEmpty
        ? 'Give it a name.'
        : name.contains('/') || name.contains('\\')
        ? 'A name cannot contain a slash.'
        : name == '.' || name == '..'
        ? 'That name is reserved.'
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 340,
      child: TextField(
        controller: _name,
        autofocus: true,
        decoration: InputDecoration(
          labelText: 'Name',
          hintText: widget.hint,
          errorText: _error,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.action)),
    ],
  );
}

/// Asks before deleting; true to delete.
Future<bool> confirmFileDelete(
  BuildContext context,
  WorkspaceEntry entry,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text('Delete ${entry.name}?'),
        content: Text(
          entry.isDirectory
              ? 'The folder and everything in it are deleted for everyone in '
                    'this space.'
              : 'The file is deleted for everyone in this space.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
              foregroundColor: Theme.of(dialog).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ==
    true;
