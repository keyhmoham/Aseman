import 'package:flutter/material.dart';

import '../../../../core/theme/theme_roles.dart';

/// A room to create: its name and, optionally, what it is for with an icon
/// and a colour. A room made for something is greeted by the lead, who
/// offers three things to start on; its agents are told what it is for.
typedef NewRoom = ({String name, String purpose, String icon, String color});

/// The icons a room can wear, by the names the node stores.
const roomIcons = <String, IconData>{
  'chat': Icons.chat_bubble_outline_rounded,
  'rocket': Icons.rocket_launch_outlined,
  'shopping_cart': Icons.shopping_cart_outlined,
  'campaign': Icons.campaign_outlined,
  'code': Icons.code_rounded,
  'design': Icons.palette_outlined,
  'finance': Icons.account_balance_outlined,
  'support': Icons.support_agent_rounded,
  'research': Icons.science_outlined,
  'calendar': Icons.event_outlined,
};

/// The colours a room can wear.
const roomColors = <String>[
  '#3b82f6',
  '#10b981',
  '#f59e0b',
  '#ef4444',
  '#8b5cf6',
  '#ec4899',
  '#14b8a6',
  '#64748b',
];

Color roomColor(String hex) =>
    Color(int.parse('ff${hex.substring(1)}', radix: 16));

class NewRoomDialog extends StatefulWidget {
  const NewRoomDialog({super.key});
  @override
  State<NewRoomDialog> createState() => _NewRoomDialogState();
}

class _NewRoomDialogState extends State<NewRoomDialog> {
  final name = TextEditingController();
  final purpose = TextEditingController();
  String icon = '';
  String color = '';

  @override
  void dispose() {
    name.dispose();
    purpose.dispose();
    super.dispose();
  }

  void _create() {
    final n = name.text.trim();
    if (n.isEmpty) return;
    Navigator.pop<NewRoom>(
        context, (name: n, purpose: purpose.text.trim(), icon: icon, color: color));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('New room'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: name,
              autofocus: true,
              onSubmitted: (_) => _create(),
              decoration: const InputDecoration(labelText: 'Room name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: purpose,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                  labelText: 'What is it for? (optional)',
                  hintText: 'e.g. Launch the spring sale'),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final e in roomIcons.entries)
                IconButton(
                  tooltip: e.key,
                  isSelected: icon == e.key,
                  style: IconButton.styleFrom(
                      backgroundColor: icon == e.key ? ThemeRoles.selectedFill(context) : null),
                  onPressed: () => setState(() => icon = icon == e.key ? '' : e.key),
                  icon: Icon(e.value, size: 20),
                ),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in roomColors)
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => color = color == c ? '' : c),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: roomColor(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: color == c ? scheme.onSurface : Colors.transparent, width: 2),
                    ),
                  ),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _create, child: const Text('Create')),
      ],
    );
  }
}
