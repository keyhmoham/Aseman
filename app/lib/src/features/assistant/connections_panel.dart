import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../shared/widgets/app_inputs.dart' show AppChoice;
import '../../shared/widgets/overlay_panels.dart';
import '../../shared/widgets/settings_kit.dart';
import '../../shared/widgets/sky_ui.dart';
import 'assistant_common.dart';

/// Where the person reaches their assistant and what it does on its own:
/// Slack, Teams and SMS, background research and the morning brief. Accounts
/// like Google are apps: they are added and connected in Apps.
class ConnectionsPanel extends StatelessWidget {
  const ConnectionsPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the channels in the settings page instead of their own screen.
  final bool embedded;

  static const _channelNames = {
    'telegram': 'Telegram',
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
    embedded: embedded,
    load: _load,
    build: (context, data, reload) {
      final channels = jsonMap(data['channels']);
      final settings = jsonMap(jsonMap(data['proactive'])['settings']);
      if (embedded) {
        return _embeddedBody(context, channels, settings, reload);
      }
      final children = <Widget>[
        const PanelSection(
          title: 'Gmail, Calendar and other accounts',
          children: [
            Text(
              'Accounts are apps: add Google (or another app) to a project from its Apps, '
              'and connect your own account there. Connecting Google adds it to your home project.',
            ),
          ],
        ),
        if (channels['missing'] != true) _channels(context, channels, reload),
        if (settings.isNotEmpty) _proactive(context, settings, reload),
        const SizedBox(height: 32),
      ];
      return ListView(children: children);
    },
  );

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
      title: 'Telegram, Slack, Teams and SMS',
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
              '${_channelNames[b['provider']] ?? b['provider']} · ${'${b['name'] ?? ''}'.isNotEmpty ? b['name'] : b['external']}',
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
              onPressed: () => _linkAccount(context, available, reload),
            ),
          ),
      ],
    );
  }

  Widget _embeddedBody(
    BuildContext context,
    Map<String, dynamic> channels,
    Map<String, dynamic> proactive,
    Future<void> Function() reload,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final offered = jsonMap(channels['offered']);
    final bindings = jsonList(channels['bindings']);
    final available = _channelNames.keys
        .where((k) => offered[k] == true)
        .toList();
    String nameOf(Map<String, dynamic> b) =>
        _channelNames[b['provider']] ?? '${b['provider']}';
    final hasChannels = channels['missing'] != true;

    Future<void> saveProactive(Map<String, dynamic> change) async {
      final out =
          await runAction(context, dependencies, 'proactive', 'settings_set', {
            'research': proactive['research'] == true,
            'interval_hours': proactive['interval_hours'] ?? 6,
            ...change,
          });
      if (out != null) await reload();
    }

    final hours = (proactive['interval_hours'] as num?)?.toInt() ?? 6;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          caption: 'Gmail, Calendar and other accounts',
          child: Text(
            'Accounts are apps: add Google (or another app) to a project from '
            'its Apps, and connect your own account there. Connecting Google '
            'adds it to your home project.',
            style: TextStyle(height: 1.45, color: scheme.onSurfaceVariant),
          ),
        ),
        if (hasChannels)
          SettingsGroup(
            caption: 'Telegram, Slack, Teams and SMS',
            footer: bindings.isEmpty && available.isNotEmpty
                ? 'Talk to your agents, answer approvals and get your brief '
                      'where you already are.'
                : null,
            children: [
              if (available.isEmpty && bindings.isEmpty)
                const SettingsEmpty(
                  icon: Icons.forum_outlined,
                  title: 'No channels on this node',
                  message: 'An administrator adds them under Admin → Channels.',
                ),
              for (final b in bindings) ...[
                QuietSwitchTile(
                  icon: Icons.forum_outlined,
                  label:
                      '${nameOf(b)} · ${'${b['name'] ?? ''}'.isNotEmpty ? b['name'] : b['external']}',
                  subtitle: 'Send me briefs and finished tasks here',
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
                QuietTile(
                  icon: Icons.link_off_rounded,
                  danger: true,
                  label: 'Unlink ${nameOf(b)}',
                  onTap: () async {
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
                ),
              ],
              if (available.isNotEmpty)
                QuietTile(
                  icon: Icons.add_link_rounded,
                  label: 'Link an account',
                  subtitle: available.map((k) => _channelNames[k]).join(', '),
                  onTap: () => _linkAccount(context, available, reload),
                ),
            ],
          ),
        if (proactive.isNotEmpty)
          SettingsGroup(
            caption: 'On its own',
            footer:
                '${'${proactive['last_result'] ?? ''}'.isNotEmpty ? 'Last look: ${proactive['last_result']}\n' : ''}'
                'What your assistant does while you are away. It only reads: '
                'anything else waits for you.',
            children: [
              QuietSwitchTile(
                icon: Icons.wb_twilight_rounded,
                label: 'Morning brief',
                subtitle:
                    'Once a day: what needs you, today’s calendar and your tasks',
                value: proactive['brief_off'] != true,
                onChanged: (v) => saveProactive({'brief_off': !v}),
              ),
              QuietSwitchTile(
                icon: Icons.travel_explore_rounded,
                label: 'Background research',
                subtitle: 'Look for things worth doing and suggest them',
                value: proactive['research'] == true,
                onChanged: (v) => saveProactive({'research': v}),
              ),
              if (proactive['research'] == true)
                SettingsChoiceRow<int>(
                  icon: Icons.schedule_rounded,
                  label: 'Look every',
                  value: hours,
                  choices: const [
                    AppChoice(3, '3 hours'),
                    AppChoice(6, '6 hours'),
                    AppChoice(12, '12 hours'),
                    AppChoice(24, 'Once a day'),
                  ],
                  onChanged: (h) => saveProactive({'interval_hours': h}),
                ),
            ],
          ),
      ],
    );
  }

  Future<void> _linkAccount(
    BuildContext context,
    List<String> available,
    Future<void> Function() reload,
  ) async {
    final out = await runAction(context, dependencies, 'channels', 'link_code');
    if (out == null || !context.mounted) return;
    await showAppDialog<void>(
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
            if ('${out['url'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Or, for Telegram, open this link and press Start:'),
              const SizedBox(height: 4),
              SelectableText('${out['url']}'),
            ],
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
