import 'package:flutter/material.dart';

import '../../../data/services/tradera_service.dart';

/// Why something is reported, as `spaces.message_report` takes it.
const reportReasons = <(String, String)>[
  ('spam', 'Spam'),
  ('harassment', 'Harassment or bullying'),
  ('abuse', 'Abuse or threats'),
  ('scam', 'Scam or fraud'),
  ('inappropriate', 'Inappropriate content'),
  ('other', 'Something else')
];

/// Asks why a message (or a whole chat, when [messageId] is empty) is being
/// reported and sends the report to the node's admins. Returns whether a
/// report was sent.
Future<bool> reportToAdmins(BuildContext context, TraderaService service,
    {required String spaceId,
    required String roomId,
    String messageId = ''}) async {
  final result = await showDialog<(String, String)>(
      context: context, builder: (_) => _ReportDialog(chat: messageId.isEmpty));
  if (result == null || !context.mounted) return false;
  try {
    await service.reportChat(spaceId, roomId,
        messageId: messageId, reason: result.$1, note: result.$2);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Reported. The admins will take a look.')));
    }
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not report: $e')));
    }
    return false;
  }
}

class _ReportDialog extends StatefulWidget {
  const _ReportDialog({required this.chat});

  /// A whole chat rather than one message.
  final bool chat;

  @override
  State<_ReportDialog> createState() => _ReportDialogState();
}

class _ReportDialogState extends State<_ReportDialog> {
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
        icon: const Icon(Icons.flag_outlined),
        title: Text(widget.chat ? 'Report this chat' : 'Report this message'),
        content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(
                      widget.chat
                          ? 'The node\'s admins will see the latest messages of this chat.'
                          : 'The node\'s admins will see this message and the ones before it.',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 8),
                  RadioGroup<String>(
                      groupValue: _reason,
                      onChanged: (v) => setState(() => _reason = v),
                      child: Column(children: [
                        for (final (value, label) in reportReasons)
                          RadioListTile<String>(
                              value: value,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(label))
                      ])),
                  const SizedBox(height: 8),
                  TextField(
                      controller: _note,
                      maxLength: 1000,
                      minLines: 2,
                      maxLines: 4,
                      decoration: const InputDecoration(
                          labelText: 'Anything to add (optional)',
                          border: OutlineInputBorder()))
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _reason == null
                  ? null
                  : () => Navigator.pop(context, (_reason!, _note.text)),
              child: const Text('Report'))
        ]);
  }
}
