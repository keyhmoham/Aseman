import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/notifications/push_notification_service.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/panel_scaffold.dart';
import '../../../shared/widgets/skeleton.dart';
import 'account_forms.dart';
import 'account_hub_content.dart';

class _Endpoint {
  const _Endpoint(this.namespace, this.action, [this.body = const {}]);
  final String namespace;
  final String action;
  final Map<String, dynamic> body;
  String get label => '$namespace.$action';
}

/// The account panels of the profile menu. Each opens on its own as a modal
/// panel (a bottom sheet on phones, a floating window on wider screens).
enum AccountArea {
  invitations(
      'Invitations',
      Icons.mark_email_unread_outlined,
      'Project invitations waiting for you',
      [_Endpoint('spaces', 'invitations_list')]),
  wallet('Wallet', Icons.account_balance_wallet_outlined,
      'Balance, activity, top-ups and project usage', [
    _Endpoint('finance', 'account'),
    _Endpoint('finance', 'wallet_get'),
    _Endpoint('finance', 'purchases_mine'),
    _Endpoint('finance', 'credit_requests_mine'),
    _Endpoint('usage', 'projects'),
  ]),
  usage('Usage', Icons.query_stats_outlined,
      'Project spend, events and model token accounting', [
    _Endpoint('usage', 'projects'),
  ]),
  account(
      'Account',
      Icons.security_outlined,
      'Sign-in identity, password and account controls',
      [_Endpoint('auth', 'me'), _Endpoint('auth', 'config')]);

  const AccountArea(this.label, this.icon, this.description, this.loads);
  final String label;
  final IconData icon;
  final String description;
  final List<_Endpoint> loads;
}

/// Opens one account area as a modal panel.
Future<void> showAccountPanel(
        BuildContext context, AppDependencies dependencies, AccountArea area) =>
    showFloatingPanel(
        context, AccountPanel(dependencies: dependencies, area: area),
        maxWidth: area == AccountArea.invitations ? 760 : 1000);

/// One account area (invitations, wallet, usage or account), backed directly
/// by the platform action contract.
class AccountPanel extends StatefulWidget {
  const AccountPanel({
    super.key,
    required this.dependencies,
    required this.area,
    this.embedded = false,
  });
  final AppDependencies dependencies;
  final AccountArea area;

  /// Draw the area in the settings page instead of a modal panel.
  final bool embedded;

  @override
  State<AccountPanel> createState() => _AccountPanelState();
}

class _AccountPanelState extends State<AccountPanel> {
  bool loading = false;
  Map<String, dynamic> results = const {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final area = widget.area;
    setState(() {
      loading = true;
      results = const {};
    });
    final values = await Future.wait(area.loads.map((endpoint) async {
      try {
        return MapEntry(
            endpoint.label,
            await widget.dependencies.service.invokeAction(
                endpoint.namespace, endpoint.action,
                body: endpoint.body, timeout: const Duration(minutes: 3)));
      } catch (error) {
        return MapEntry<String, dynamic>(endpoint.label, {'error': '$error'});
      }
    }));
    if (!mounted) return;
    setState(() {
      results = Map.fromEntries(values);
      loading = false;
    });
  }

  Future<void> run(_Endpoint endpoint) async {
    final request = await showAccountActionForm(
      context,
      namespace: endpoint.namespace,
      action: endpoint.action,
      initialBody: endpoint.body,
    );
    if (request == null || !mounted) return;
    try {
      final value = await widget.dependencies.service.invokeAction(
          endpoint.namespace, endpoint.action,
          body: request, timeout: const Duration(minutes: 10));
      if (!mounted) return;
      setState(() => results = {...results, endpoint.label: value});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${endpoint.label} completed')));
      await load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${endpoint.label}: $error')));
    }
  }

  Future<void> setNotifications(bool enabled) async {
    try {
      final notifications = widget.dependencies.sessionController.notifications;
      final bool changed;
      if (enabled) {
        changed = await notifications.enable();
      } else {
        await notifications.disable();
        changed = true;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(changed
              ? 'Notifications ${enabled ? 'enabled' : 'disabled'}'
              : 'Notification permission was not granted')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Notification update failed: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final area = widget.area;
    final body = loading
        ? (widget.embedded
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : const SkeletonPage(padding: EdgeInsets.zero))
        : AccountHubContent(
            key: ValueKey(area),
            area: area,
            results: results,
            shrinkWrap: widget.embedded,
            onAction: (namespace, action, body) =>
                run(_Endpoint(namespace, action, body)),
            onNotifications: setNotifications,
            notificationsSupported: PushNotificationService.supported,
          );
    if (widget.embedded) return body;
    return PanelScaffold(
      compact: compact,
      header: PanelHeader(
        icon: area.icon,
        title: area.label,
        subtitle: area.description,
        onClose: () => Navigator.pop(context),
        actions: [
          IconButton(
              onPressed: load,
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded))
        ],
      ),
      body: body,
    );
  }
}
