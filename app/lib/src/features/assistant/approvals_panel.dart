import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/settings_kit.dart';
import '../../shared/widgets/sky_ui.dart';
import 'assistant_common.dart';

/// Approvals waiting on the person, and the standing "always allow" grants
/// they gave (each revocable).
class ApprovalsPanel extends StatelessWidget {
  const ApprovalsPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the grants in the settings page instead of their own screen.
  final bool embedded;

  Future<Map<String, dynamic>> _load() async {
    final service = dependencies.service;
    final results = await Future.wait([
      service.invokeAction(
        'governance',
        'approval_list',
        body: {'status': 'pending'},
      ),
      service.invokeAction('governance', 'grant_list'),
    ]);
    return {
      'approvals': jsonMap(results[0])['approvals'],
      'grants': jsonMap(results[1])['grants'],
    };
  }

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Approvals',
    embedded: embedded,
    load: _load,
    build: (context, data, reload) {
      final approvals = jsonList(data['approvals']);
      final grants = jsonList(data['grants']);
      Future<void> answer(Map<String, dynamic> a, String answer) async {
        final out = await runAction(
          context,
          dependencies,
          'governance',
          'approval_answer',
          {'id': a['id'], 'answer': answer},
        );
        if (out != null) await reload();
      }

      if (embedded) {
        return _embeddedBody(context, approvals, grants, answer, reload);
      }
      final children = <Widget>[
        PanelSection(
          title: 'Waiting on you',
          subtitle:
              'Agents ask before they send, pay, sign or delete, or as your policy says.',
          children: [
            if (approvals.isEmpty) const Text('Nothing is waiting.'),
            for (final a in approvals)
              AppCard(
                margin: const EdgeInsets.only(bottom: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${a['summary']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        [
                          a['agent_name'],
                          a['tool'],
                          a['effect'],
                        ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                      ),
                      if (jsonStrings(a['recipients']).isNotEmpty)
                        Text('To: ${jsonStrings(a['recipients']).join(', ')}'),
                      if ('${a['text'] ?? ''}'.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: SelectableText('${a['text']}'),
                        ),
                      Wrap(
                        spacing: 4,
                        children: [
                          FilledButton(
                            onPressed: () => answer(a, 'once'),
                            child: const Text('Allow once'),
                          ),
                          OutlinedButton(
                            onPressed: () => answer(a, 'always'),
                            child: const Text('Always allow'),
                          ),
                          TextButton(
                            onPressed: () => answer(a, 'refuse'),
                            child: const Text('Refuse'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        PanelSection(
          title: 'Always allowed',
          subtitle: 'What you let an agent do without asking again, and where.',
          children: [
            if (grants.isEmpty) const Text('No standing grants.'),
            for (final g in grants)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.verified_outlined),
                title: Text(
                  [
                    g['summary'],
                    g['agent_name'],
                    g['tool'],
                  ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                ),
                subtitle: Text(
                  [
                    g['effect'],
                    g['target'],
                    g['space_id'],
                  ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    final out = await runAction(
                      context,
                      dependencies,
                      'governance',
                      'grant_revoke',
                      {'id': g['id']},
                      'Revoked',
                    );
                    if (out != null) await reload();
                  },
                  child: const Text('Revoke'),
                ),
              ),
          ],
        ),
        const SizedBox(height: 32),
      ];
      return ListView(children: children);
    },
  );

  Widget _embeddedBody(
    BuildContext context,
    List<Map<String, dynamic>> approvals,
    List<Map<String, dynamic>> grants,
    Future<void> Function(Map<String, dynamic>, String) answer,
    Future<void> Function() reload,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final danger = AppColors.dangerOf(context);
    String join(Iterable<dynamic> parts) =>
        parts.where((x) => '${x ?? ''}'.isNotEmpty).join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (approvals.isEmpty)
          const SettingsGroup(
            caption: 'Waiting on you',
            footer:
                'Agents ask before they send, pay, sign or delete, or as your '
                'policy says.',
            children: [
              SettingsEmpty(
                icon: Icons.check_circle_outline_rounded,
                title: 'Nothing is waiting',
                message: 'You are all caught up.',
              ),
            ],
          )
        else ...[
          const SettingsCaption('Waiting on you'),
          for (final a in approvals)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SoftCard(
                radius: AppShape.card,
                showOrb: false,
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${a['summary']}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (join([
                      a['agent_name'],
                      a['tool'],
                      a['effect'],
                    ]).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          join([a['agent_name'], a['tool'], a['effect']]),
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (jsonStrings(a['recipients']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'To: ${jsonStrings(a['recipients']).join(', ')}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    if ('${a['text'] ?? ''}'.isNotEmpty)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: AppSpacing.sm),
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withValues(
                            alpha: .5,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          '${a['text']}',
                          style: const TextStyle(fontSize: 13.5, height: 1.4),
                        ),
                      ),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => answer(a, 'refuse'),
                          child: Text(
                            'Refuse',
                            style: TextStyle(color: danger),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: () => answer(a, 'always'),
                          child: const Text('Always allow'),
                        ),
                        FilledButton(
                          onPressed: () => answer(a, 'once'),
                          child: const Text('Allow once'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SettingsFooter(
            'Agents ask before they send, pay, sign or delete, or as your '
            'policy says.',
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        SettingsGroup(
          caption: 'Always allowed',
          footer: 'What you let an agent do without asking again, and where.',
          children: grants.isEmpty
              ? const [
                  SettingsEmpty(
                    icon: Icons.verified_outlined,
                    title: 'No standing grants',
                  ),
                ]
              : [
                  for (final g in grants)
                    QuietTile(
                      icon: Icons.verified_outlined,
                      label: join([g['summary'], g['agent_name'], g['tool']]),
                      subtitle: join([g['effect'], g['target'], g['space_id']]),
                      trailing: TextButton(
                        onPressed: () async {
                          final out = await runAction(
                            context,
                            dependencies,
                            'governance',
                            'grant_revoke',
                            {'id': g['id']},
                            'Revoked',
                          );
                          if (out != null) await reload();
                        },
                        child: Text('Revoke', style: TextStyle(color: danger)),
                      ),
                    ),
                ],
        ),
      ],
    );
  }
}
