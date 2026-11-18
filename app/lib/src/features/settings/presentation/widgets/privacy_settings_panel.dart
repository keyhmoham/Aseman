import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/widgets/app_inputs.dart' show AppChoice;
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/panel_header.dart';
import '../../../../shared/widgets/panel_scaffold.dart';
import '../../../../shared/widgets/settings_kit.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/sky_ui.dart';

const _audiences = [
  ('everyone', 'Everyone'),
  ('contacts', 'Contacts'),
  ('nobody', 'Nobody'),
];

const _audienceChoices = [
  AppChoice('everyone', 'Everyone', icon: Icons.public_rounded),
  AppChoice('contacts', 'Contacts only', icon: Icons.people_outline_rounded),
  AppChoice('nobody', 'Nobody', icon: Icons.block_rounded),
];

const _fields = [
  ('messages', 'Who may message you', Icons.chat_bubble_outline_rounded),
  ('calls_voice', 'Who may voice-call you', Icons.call_outlined),
  ('calls_video', 'Who may video-call you', Icons.videocam_outlined),
  ('invites', 'Who may invite you', Icons.mail_outline_rounded),
];

/// Who may message / call / invite the signed-in person.
Future<void> showPrivacySettings(
  BuildContext context,
  AppDependencies dependencies,
) => showFloatingPanel(
  context,
  PrivacySettingsPanel(dependencies: dependencies),
  maxWidth: 520,
);

class PrivacySettingsPanel extends StatefulWidget {
  const PrivacySettingsPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the choices in the settings page instead of a floating panel.
  final bool embedded;

  @override
  State<PrivacySettingsPanel> createState() => _PrivacySettingsPanelState();
}

class _PrivacySettingsPanelState extends State<PrivacySettingsPanel> {
  bool _loading = true;
  String? _error;
  final Map<String, String> _prefs = {
    for (final f in _fields) f.$1: 'everyone',
  };

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
      final got = await widget.dependencies.service.privacyGet();
      if (!mounted) return;
      setState(() {
        for (final f in _fields) {
          final v = '${got[f.$1] ?? ''}';
          if (_audiences.any((a) => a.$1 == v)) _prefs[f.$1] = v;
        }
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

  Future<void> _set(String key, String value) async {
    final previous = _prefs[key];
    setState(() => _prefs[key] = value);
    try {
      await widget.dependencies.service.privacySet({key: value});
    } catch (e) {
      if (!mounted) return;
      setState(() => _prefs[key] = previous ?? 'everyone');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  Widget _embeddedBody() => SettingsRefreshHook(
    onRefresh: _load,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) SettingsError(_error!, onRetry: _load),
        SettingsGroup(
          caption: 'Who can reach you',
          footer: 'Applies to everyone who is not already in your contacts.',
          children: _loading
              ? const [SettingsLoading()]
              : [
                  for (final f in _fields)
                    SettingsChoiceRow<String>(
                      icon: f.$3,
                      label: f.$2,
                      choices: _audienceChoices,
                      value: _prefs[f.$1]!,
                      onChanged: (v) => _set(f.$1, v),
                    ),
                ],
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _embeddedBody();
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
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              for (final f in _fields) ...[
                SoftCard(
                  showOrb: false,
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QuietTile(
                        icon: f.$3,
                        label: f.$2,
                        trailing: const SizedBox.shrink(),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.sm,
                          0,
                          AppSpacing.sm,
                          0,
                        ),
                        child: SegmentedButton<String>(
                          segments: [
                            for (final a in _audiences)
                              ButtonSegment(value: a.$1, label: Text(a.$2)),
                          ],
                          selected: {_prefs[f.$1]!},
                          onSelectionChanged: (v) => _set(f.$1, v.first),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            ],
          );
    return PanelScaffold(
      header: const PanelHeader(
        title: 'Privacy',
        subtitle: 'Who may reach you',
        icon: Icons.lock_outline_rounded,
      ),
      body: _loading
          ? const SkeletonPage()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
              children: [body],
            ),
    );
  }
}
