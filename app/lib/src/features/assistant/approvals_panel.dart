import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// Approvals waiting on the person, and the standing "always allow" grants
/// they gave (each revocable).
class ApprovalsPanel extends StatelessWidget {
  const ApprovalsPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

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

      return ListView(
        children: [
          PanelSection(
            title: 'Waiting on you',
            subtitle:
                'Agents ask before they send, pay, sign or delete, or as your policy says.',
            children: [
              if (approvals.isEmpty) const Text('Nothing is waiting.'),
              for (final a in approvals)
                Card(
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
                          Text(
                            'To: ${jsonStrings(a['recipients']).join(', ')}',
                          ),
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
            subtitle:
                'What you let an agent do without asking again, and where.',
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
        ],
      );
    },
  );
}
