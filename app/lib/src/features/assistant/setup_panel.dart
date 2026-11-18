import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/widgets/settings_kit.dart';
import '../../shared/widgets/sky_ui.dart';
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
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the checklist in the settings page instead of its own screen.
  final bool embedded;

  /// What this device says of its notification permission: granted,
  /// denied, or empty when not asked.
  final String notifications;

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Setup',
    embedded: embedded,
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
      if (embedded) {
        return _embeddedBody(context, required, optional, ready);
      }
      final children = <Widget>[
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
      ];
      return ListView(children: children);
    },
  );

  Widget _embeddedBody(
    BuildContext context,
    List<Map<String, dynamic>> required,
    List<Map<String, dynamic>> optional,
    int ready,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final done = required.isEmpty || ready == required.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: SoftCard(
            radius: AppShape.card,
            wash: true,
            padding: const EdgeInsets.all(AppSpacing.md + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  done ? 'All set' : '$ready of ${required.length} ready',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  done
                      ? 'Everything your assistant depends on is working.'
                      : 'Finish these so your assistant can do its job.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: required.isEmpty ? 1 : ready / required.length,
                  ),
                ),
              ],
            ),
          ),
        ),
        SettingsGroup(
          caption: 'Required',
          children: required.isEmpty
              ? const [
                  SettingsEmpty(
                    icon: Icons.checklist_rounded,
                    title: 'Nothing to set up',
                  ),
                ]
              : [for (final i in required) _SetupTile(item: i, quiet: true)],
        ),
        if (optional.isNotEmpty)
          SettingsGroup(
            caption: 'Optional',
            children: [
              for (final i in optional) _SetupTile(item: i, quiet: true),
            ],
          ),
      ],
    );
  }
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({required this.item, this.quiet = false});
  final Map<String, dynamic> item;

  /// Settings style: an icon well tinted by status instead of a bare icon.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch ('${item['status']}') {
      'ready' => (Icons.check_circle_rounded, AppColors.successOf(context)),
      'needs_setup' => (Icons.error_outline_rounded, scheme.error),
      _ => (Icons.radio_button_unchecked_rounded, scheme.onSurfaceVariant),
    };
    final fix = '${item['fix'] ?? ''}';
    if (quiet) {
      final ready = item['status'] == 'ready';
      return QuietTile(
        icon: icon,
        accent: color,
        label: '${item['label']}',
        subtitle: [
          item['detail'],
          if (fix.isNotEmpty && !ready) 'Fix: $fix',
        ].where((x) => '${x ?? ''}'.isNotEmpty).join('\n'),
        trailing: const SizedBox.shrink(),
      );
    }
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
