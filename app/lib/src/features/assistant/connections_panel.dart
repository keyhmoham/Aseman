import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';

/// The person's connections and what their assistant does on its own:
/// Gmail and Calendar, Slack, Teams and SMS, background research and the
/// morning brief.
class ConnectionsPanel extends StatelessWidget {
  const ConnectionsPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  static const _channelNames = {
    'slack': 'Slack',
    'teams': 'Microsoft Teams',
    'twilio': 'SMS',
  };

  Future<Map<String, dynamic>> _load() async {
    final service = dependencies.service;
    Future<Map<String, dynamic>> safe(String ns, String action) => service
        .invokeAction(ns, action)
        .then(jsonMap)
        .catchError((_) => <String, dynamic>{'missing': true});
    final results = await Future.wait([
      safe('google', 'status'),
      safe('channels', 'status'),
      safe('proactive', 'settings_get'),
    ]);
    return {
      'google': results[0],
      'channels': results[1],
      'proactive': results[2],
    };
  }

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Connections',
    load: _load,
    build: (context, data, reload) {
      final google = jsonMap(data['google']);
      final channels = jsonMap(data['channels']);
      final settings = jsonMap(jsonMap(data['proactive'])['settings']);
      return ListView(
        children: [
          if (google['missing'] != true) _google(context, google, reload),
          if (channels['missing'] != true) _channels(context, channels, reload),
          if (settings.isNotEmpty) _proactive(context, settings, reload),
          const SizedBox(height: 32),
        ],
      );
    },
  );

  Widget _google(
    BuildContext context,
    Map<String, dynamic> g,
    Future<void> Function() reload,
  ) {
    final connected = g['connected'] == true;
    final connection = jsonMap(g['connection']);
    return PanelSection(
      title: 'Gmail and Calendar',
      subtitle:
          'Your agents read your mail and calendar for triage and the morning brief, draft replies, and ask before they send.',
      children: [
        if (g['offered'] != true)
          const Text(
            'Not offered on this node yet: an administrator adds Google under Admin → Connections.',
          )
        else if (connected)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.mark_email_read_outlined),
            title: Text('${connection['email'] ?? 'Connected'}'),
            subtitle: const Text('Connected'),
            trailing: TextButton(
              onPressed: () async {
                final out = await runAction(
                  context,
                  dependencies,
                  'google',
                  'disconnect',
                  const {},
                  'Disconnected',
                );
                if (out != null) await reload();
              },
              child: const Text('Disconnect'),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.link_rounded),
              label: const Text('Connect Google'),
              onPressed: () async {
                final out = await runAction(
                  context,
                  dependencies,
                  'google',
                  'connect_start',
                );
                final url = Uri.tryParse('${out?['url'] ?? ''}');
                if (url == null || !url.hasScheme) return;
                await launchUrl(url, mode: LaunchMode.externalApplication);
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Finish in your browser'),
                    content: const Text(
                      'Sign in to Google there, then come back.',
                    ),
                    actions: [
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                );
                await reload();
              },
            ),
          ),
      ],
    );
  }

  Widget _channels(
    BuildContext context,
    Map<String, dynamic> c,
    Future<void> Function() reload,
  ) {
    final offered = jsonMap(c['offered']);
    final bindings = jsonList(c['bindings']);
    final available = _channelNames.keys
        .where((k) => offered[k] == true)
        .toList();
    return PanelSection(
      title: 'Slack, Teams and SMS',
      subtitle:
          'Talk to your agents, answer approvals and get your brief where you already are.',
      children: [
        if (available.isEmpty)
          const Text(
            'None set up on this node: an administrator adds them under Admin → Channels.',
          ),
        for (final b in bindings)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.forum_outlined),
            title: Text(
              '${_channelNames[b['provider']] ?? b['provider']} · ${b['external']}',
            ),
            subtitle: const Text('Send me briefs and finished tasks here'),
            value: b['notify'] == true,
            onChanged: (v) async {
              final out = await runAction(
                context,
                dependencies,
                'channels',
                'binding_set',
                {'id': b['id'], 'notify': v},
              );
              if (out != null) await reload();
            },
          ),
        for (final b in bindings)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () async {
                final out = await runAction(
                  context,
                  dependencies,
                  'channels',
                  'unlink',
                  {'id': b['id']},
                  'Unlinked',
                );
                if (out != null) await reload();
              },
              child: Text(
                'Unlink ${_channelNames[b['provider']] ?? b['provider']}',
              ),
            ),
          ),
        if (available.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Link an account'),
              onPressed: () async {
                final out = await runAction(
                  context,
                  dependencies,
                  'channels',
                  'link_code',
                );
                if (out == null || !context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Link an account'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Send this to the Aseman app in ${available.map((k) => _channelNames[k]).join(', ')} '
                          'within ${out['expires_in_minutes'] ?? 10} minutes:',
                        ),
                        const SizedBox(height: 12),
                        SelectableText(
                          '${out['send']}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Done'),
                      ),
                    ],
                  ),
                );
                await reload();
              },
            ),
          ),
      ],
    );
  }

  Widget _proactive(
    BuildContext context,
    Map<String, dynamic> s,
    Future<void> Function() reload,
  ) {
    Future<void> save(Map<String, dynamic> change) async {
      final out =
          await runAction(context, dependencies, 'proactive', 'settings_set', {
            'research': s['research'] == true,
            'interval_hours': s['interval_hours'] ?? 6,
            ...change,
          });
      if (out != null) await reload();
    }

    final hours = (s['interval_hours'] as num?)?.toInt() ?? 6;
    return PanelSection(
      title: 'On its own',
      subtitle:
          'What your assistant does while you are away. It only reads: anything else waits for you.',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Morning brief'),
          subtitle: const Text(
            'Once a day: what needs you, today\'s calendar and your tasks',
          ),
          value: s['brief_off'] != true,
          onChanged: (v) => save({'brief_off': !v}),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Background research'),
          subtitle: Text(
            'Every $hours hours, look for things worth doing and suggest them',
          ),
          value: s['research'] == true,
          onChanged: (v) => save({'research': v}),
        ),
        if (s['research'] == true)
          Wrap(
            spacing: 6,
            children: [
              for (final h in const [3, 6, 12, 24])
                ChoiceChip(
                  label: Text('${h}h'),
                  selected: hours == h,
                  onSelected: (_) => save({'interval_hours': h}),
                ),
            ],
          ),
        if ('${s['last_result'] ?? ''}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Last look: ${s['last_result']}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
  }
}
