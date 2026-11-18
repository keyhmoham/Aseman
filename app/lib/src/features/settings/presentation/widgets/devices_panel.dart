import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/network/device_meta.dart';
import '../../../../core/network/session_store.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../shared/widgets/app_form.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/panel_header.dart';
import '../../../../shared/widgets/panel_scaffold.dart';
import '../../../../shared/widgets/settings_kit.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/sky_ui.dart';

/// Settings → Active sessions: every place this account is signed in.
Future<void> showDevicesPanel(
  BuildContext context,
  AppDependencies dependencies,
) => showFloatingPanel(
  context,
  DevicesPanel(dependencies: dependencies),
  maxWidth: 560,
);

class DevicesPanel extends StatefulWidget {
  const DevicesPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
  });
  final AppDependencies dependencies;

  /// Draw the sessions in the settings page instead of a floating panel.
  final bool embedded;

  @override
  State<DevicesPanel> createState() => _DevicesPanelState();
}

class _DevicesPanelState extends State<DevicesPanel> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<DeviceSession> _sessions = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await widget.dependencies.service.sessionUpdate(meta: thisDeviceMeta());
    } catch (_) {}
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.dependencies.service.sessionsList();
      if (!mounted) return;
      setState(() {
        _sessions = result.sessions;
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

  Future<void> _revoke({String? session, bool others = false}) async {
    setState(() => _busy = true);
    try {
      await widget.dependencies.service.sessionRevoke(
        session: session,
        others: others,
      );
      final revokedSelf =
          session != null && _sessions.any((s) => s.id == session && s.current);
      if (revokedSelf) {
        await widget.dependencies.sessionController.logout();
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn’t update devices: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRevoke(DeviceSession session) async {
    final ok = await confirmAppAction(
      context,
      icon: Icons.logout_rounded,
      title: 'Sign out “${session.title}”?',
      message: 'That device will need to sign in again.',
      action: 'Sign out',
      destructive: true,
    );
    if (ok) await _revoke(session: session.id);
  }

  Future<void> _confirmRevokeOthers() async {
    final ok = await confirmAppAction(
      context,
      icon: Icons.devices_other_outlined,
      title: 'Sign out every other device?',
      message:
          'This device stays signed in. The others will need your password again.',
      action: 'Sign out others',
      destructive: true,
    );
    if (ok) await _revoke(others: true);
  }

  Widget _embeddedBody() {
    final others = _sessions.where((s) => !s.current).length;
    return SettingsRefreshHook(
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) SettingsError(_error!, onRetry: _load),
          SettingsGroup(
            caption: _loading ? 'Signed in' : 'Signed in (${_sessions.length})',
            footer: 'Each device has its own key. Signing one out does not '
                'affect the others.',
            children: _loading
                ? const [SettingsLoading()]
                : _sessions.isEmpty
                ? const [
                    SettingsEmpty(
                      icon: Icons.devices_outlined,
                      title: 'No active sessions',
                      message:
                          'Sign in on a phone or browser and it will show up here.',
                    ),
                  ]
                : [
                    for (final s in _sessions)
                      _SessionTile(
                        session: s,
                        busy: _busy,
                        onSignOut: s.current ? null : () => _confirmRevoke(s),
                      ),
                  ],
          ),
          if (others > 0)
            SettingsGroup(
              children: [
                QuietTile(
                  icon: Icons.devices_other_outlined,
                  label: 'Sign out other devices',
                  subtitle: 'Keep only this device signed in',
                  danger: true,
                  onTap: _busy ? null : _confirmRevokeOthers,
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _embeddedBody();
    final scheme = Theme.of(context).colorScheme;
    final others = _sessions.where((s) => !s.current).length;
    final sessions = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(_error!, style: TextStyle(color: scheme.error)),
          ),
        if (!widget.embedded) ...[
          SectionLabel('Signed in (${_sessions.length})'),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (_loading)
          widget.embedded
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : const SkeletonList(itemCount: 3)
        else if (_sessions.isEmpty)
          SoftCard(
            child: Text(
              'Sign in on a phone or browser and it will show up here.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          )
        else
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < _sessions.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _DeviceRow(
                    session: _sessions[i],
                    busy: _busy,
                    onSignOut: _sessions[i].current
                        ? null
                        : () => _confirmRevoke(_sessions[i]),
                  ),
                ],
              ],
            ),
          ),
        if (others > 0) ...[
          const SizedBox(height: AppSpacing.md),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : _confirmRevokeOthers,
              child: const Text('Sign out other devices'),
            ),
          ),
        ],
      ],
    );
    return PanelScaffold(
      header: const PanelHeader(
        title: 'Devices',
        subtitle:
            'Every place this account is signed in. Each device has its own key and look.',
        icon: Icons.devices_outlined,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [sessions],
        ),
      ),
    );
  }
}

/// One signed-in device in settings: icon well, name, last seen, and either
/// a "This device" pill or a Sign out action.
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.busy, this.onSignOut});

  final DeviceSession session;
  final bool busy;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final danger = AppColors.dangerOf(context);
    return QuietTile(
      icon: session.current
          ? Icons.phone_android_rounded
          : Icons.devices_outlined,
      label: session.title,
      subtitle: session.subtitle,
      trailing: session.current
          ? SettingsPill('This device', color: scheme.primary)
          : TextButton(
              onPressed: busy ? null : onSignOut,
              child: Text('Sign out', style: TextStyle(color: danger)),
            ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.session, required this.busy, this.onSignOut});

  final DeviceSession session;
  final bool busy;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      leading: Icon(
        session.current ? Icons.phone_android_rounded : Icons.devices_outlined,
        color: scheme.primary,
      ),
      title: Text(
        session.title,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(session.subtitle),
      trailing: session.current
          ? Chip(
              label: const Text('This device'),
              visualDensity: VisualDensity.compact,
              backgroundColor: scheme.primaryContainer,
              labelStyle: TextStyle(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
              side: BorderSide.none,
            )
          : TextButton(
              onPressed: busy ? null : onSignOut,
              child: Text('Sign out', style: TextStyle(color: scheme.error)),
            ),
    );
  }
}
