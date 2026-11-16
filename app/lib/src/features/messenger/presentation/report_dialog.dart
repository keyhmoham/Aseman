import 'package:flutter/material.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/overlay_panels.dart';

/// Why something is reported (`spaces.message_report` / `users.dm_report`).
/// Expo DM reasons: spam|harassment|inappropriate|scam|other (no abuse).
const reportReasons = <(String, String)>[
  ('spam', 'Spam'),
  ('harassment', 'Harassment or bullying'),
  ('scam', 'Scam or fraud'),
  ('inappropriate', 'Inappropriate content'),
  ('other', 'Something else')
];

/// Asks why a message (or a whole chat, when [messageId] is empty) is being
/// reported and sends the report to the node's admins. Returns whether a
/// report was sent. Direct chats use [peer] → `users.dm_report`.
Future<bool> reportToAdmins(BuildContext context, AsemanService service,
    {String spaceId = '',
    String roomId = '',
    String peer = '',
    String messageId = ''}) async {
  final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
  final result = wide
      ? await showDockedPanel<(String, String)>(
          context: context,
          width: 420,
          barrierLabel: 'Close report',
          builder: (_) => _ReportDialog(chat: messageId.isEmpty, docked: true),
        )
      : await showAppDialog<(String, String)>(
          context: context,
          builder: (_) => _ReportDialog(chat: messageId.isEmpty),
        );
  if (result == null || !context.mounted) return false;
  try {
    if (peer.isNotEmpty) {
      await service.reportDirect(peer,
          messageId: messageId, reason: result.$1, note: result.$2);
    } else {
      await service.reportChat(spaceId, roomId,
          messageId: messageId, reason: result.$1, note: result.$2);
    }
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
  const _ReportDialog({required this.chat, this.docked = false});

  /// A whole chat rather than one message.
  final bool chat;

  /// Full-height drawer from the right, used on a desktop window.
  final bool docked;

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
    final form = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              widget.chat
                  ? 'The node\'s admins will see the latest messages of this chat.'
                  : 'The node\'s admins will see this message and the ones before it.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
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
        ]);
    final actions = [
      TextButton(
          onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
          onPressed: _reason == null
              ? null
              : () => Navigator.pop(context, (_reason!, _note.text)),
          child: const Text('Report'))
    ];
    if (widget.docked) {
      return Material(
        color: scheme.surface,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.flag_outlined, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.chat ? 'Report this chat' : 'Report this message',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Expanded(child: SingleChildScrollView(child: form)),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
              ],
            ),
          ),
        ),
      );
    }
    return AlertDialog(
        icon: const Icon(Icons.flag_outlined),
        title: Text(widget.chat ? 'Report this chat' : 'Report this message'),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: form)),
        actions: actions);
  }
}
