import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// The setup checklist: what the person's assistant depends on, each Ready,
/// Not checked or Needs setup from the node's real answer, with how to fix
/// it. First-day onboarding ends here; Settings → Your assistant → Setup
/// checklist opens it again.
class SetupPanel extends StatelessWidget {
  const SetupPanel({
    super.key,
    required this.dependencies,
    this.notifications = '',
  });
  final AppDependencies dependencies;

  /// What this device says of its notification permission: granted,
  /// denied, or empty when not asked.
  final String notifications;

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Setup',
    load: () async => jsonMap(
      await dependencies.service.invokeAction(
        'proactive',
        'setup_check',
        body: {if (notifications.isNotEmpty) 'notifications': notifications},
      ),
    ),
    build: (context, data, reload) {
      final items = jsonList(data['items']);
      final required = items.where((i) => i['optional'] != true).toList();
      final optional = items.where((i) => i['optional'] == true).toList();
      final ready = required.where((i) => i['status'] == 'ready').length;
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: LinearProgressIndicator(
              value: required.isEmpty ? 1 : ready / required.length,
            ),
          ),
          PanelSection(
            title: '$ready of ${required.length} ready',
            children: [for (final i in required) _SetupTile(item: i)],
          ),
          if (optional.isNotEmpty)
            PanelSection(
              title: 'Optional',
              children: [for (final i in optional) _SetupTile(item: i)],
            ),
          const SizedBox(height: 32),
        ],
      );
    },
  );
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({required this.item});
  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch ('${item['status']}') {
      'ready' => (Icons.check_circle_rounded, Colors.green),
      'needs_setup' => (Icons.error_outline_rounded, scheme.error),
      _ => (Icons.radio_button_unchecked_rounded, scheme.onSurfaceVariant),
    };
    final fix = '${item['fix'] ?? ''}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text('${item['label']}'),
      subtitle: Text(
        [
          item['detail'],
          if (fix.isNotEmpty && item['status'] != 'ready') 'Fix: $fix',
        ].where((x) => '${x ?? ''}'.isNotEmpty).join('\n'),
      ),
      isThreeLine: fix.isNotEmpty && item['status'] != 'ready',
    );
  }
}
