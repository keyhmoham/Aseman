import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/panel_header.dart';
import '../../../../shared/widgets/panel_scaffold.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/sky_ui.dart';

const _categories = [
  ('rooms', 'Rooms', 'Messages in project rooms', Icons.forum_outlined),
  ('chats', 'Chats', 'Direct messages', Icons.chat_outlined),
  ('calls', 'Calls', 'Incoming call alerts', Icons.call_outlined),
  ('invites', 'Invites', 'Project invitations', Icons.mail_outline_rounded),
];

/// Push categories the person wants, plus a note about muted chats.
Future<void> showNotifyPrefs(
  BuildContext context,
  AppDependencies dependencies,
) =>
    showFloatingPanel(
      context,
      NotifyPrefsPanel(dependencies: dependencies),
      maxWidth: 520,
    );

class NotifyPrefsPanel extends StatefulWidget {
  const NotifyPrefsPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the switches in the settings page instead of a floating panel.
  final bool embedded;

  @override
  State<NotifyPrefsPanel> createState() => _NotifyPrefsPanelState();
}

class _NotifyPrefsPanelState extends State<NotifyPrefsPanel> {
  bool _loading = true;
  String? _error;
  final Map<String, bool> _cats = {
    for (final c in _categories) c.$1: true,
  };
  int _mutedSpaces = 0;
  int _mutedPeers = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final got = await widget.dependencies.service.notifyPrefs();
      if (!mounted) return;
      final cats = got['categories'];
      setState(() {
        if (cats is Map) {
          for (final c in _categories) {
            _cats[c.$1] = cats[c.$1] != false;
          }
        }
        _mutedSpaces =
            (got['muted_spaces'] is List) ? (got['muted_spaces'] as List).length : 0;
        _mutedPeers =
            (got['muted_peers'] is List) ? (got['muted_peers'] as List).length : 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _toggle(String category, bool enabled) async {
    final previous = _cats[category] ?? true;
    setState(() => _cats[category] = enabled);
    try {
      await widget.dependencies.service
          .notifySet(category: category, enabled: enabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _cats[category] = previous);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = _loading
        ? const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              QuietList(
                children: [
                  for (final c in _categories)
                    QuietSwitchTile(
                      icon: c.$4,
                      label: c.$2,
                      subtitle: c.$3,
                      value: _cats[c.$1] ?? true,
                      onChanged: (v) => _toggle(c.$1, v),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              QuietList(
                children: [
                  QuietTile(
                    icon: Icons.volume_off_outlined,
                    label: 'Muted chats and rooms',
                    subtitle: _mutedSpaces + _mutedPeers == 0
                        ? 'Mute a chat or room from its menu. Muted threads stay quiet for push only.'
                        : '$_mutedSpaces rooms and $_mutedPeers chats are muted. Unmute them from each chat’s menu.',
                    trailing: const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          );
    if (widget.embedded) return body;
    return PanelScaffold(
      header: const PanelHeader(
        title: 'Notifications',
        subtitle: 'What Aseman may alert you about',
        icon: Icons.notifications_none_rounded,
      ),
      body: _loading
          ? const SkeletonPage()
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 28),
              children: [body],
            ),
    );
  }
}
