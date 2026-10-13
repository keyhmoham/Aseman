import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/notifications/push_notification_service.dart';
import '../../../shared/widgets/backend_action_ui.dart';
import '../../../shared/widgets/panel_header.dart';
import 'account_hub_content.dart';

class _Endpoint {
  const _Endpoint(this.namespace, this.action, [this.body = const {}]);
  final String namespace;
  final String action;
  final Map<String, dynamic> body;
  String get label => '$namespace.$action';
}

class _Area {
  const _Area(this.label, this.icon, this.description,
      {required this.loads, this.actions = const []});
  final String label;
  final IconData icon;
  final String description;
  final List<_Endpoint> loads;
  final List<_Endpoint> actions;
}

/// Account, communication and money features that sit outside a project.
/// Each area is backed directly by the platform action contract.
class AccountHubScreen extends StatefulWidget {
  const AccountHubScreen(
      {super.key, required this.dependencies, this.initialIndex = 0});
  final AppDependencies dependencies;
  final int initialIndex;

  @override
  State<AccountHubScreen> createState() => _AccountHubScreenState();
}

class _AccountHubScreenState extends State<AccountHubScreen> {
  static const areas = <_Area>[
    _Area('Invitations', Icons.mark_email_unread_outlined,
        'Project invitations waiting for you',
        loads: [
          _Endpoint('spaces', 'invitations_list')
        ],
        actions: [
          _Endpoint('spaces', 'invitation_accept'),
          _Endpoint('spaces', 'invitation_decline'),
        ]),
    _Area('Messages', Icons.forum_outlined,
        'Direct conversations with people and agents',
        loads: [
          _Endpoint('users', 'dm_threads')
        ],
        actions: [
          _Endpoint('users', 'dm_list'),
          _Endpoint('users', 'dm_send'),
        ]),
    _Area('Billing', Icons.account_balance_wallet_outlined,
        'Balance, activity, top-ups and purchases',
        loads: [
          _Endpoint('finance', 'account'),
          _Endpoint('finance', 'wallet_get'),
          _Endpoint('finance', 'ledger_list', {'limit': 100}),
          _Endpoint('finance', 'purchases_mine'),
        ],
        actions: [
          _Endpoint('finance', 'purchase_confirm'),
        ]),
    _Area('Payout', Icons.payments_outlined,
        'Withdraw earnings and review payout requests',
        loads: [_Endpoint('finance', 'account')],
        actions: [_Endpoint('finance', 'payout_request')]),
    _Area('Usage', Icons.query_stats_outlined,
        'Project spend, events and model token accounting',
        loads: [
          _Endpoint('usage', 'projects'),
        ],
        actions: [
          _Endpoint('usage', 'summary'),
          _Endpoint('usage', 'list'),
          _Endpoint('usage', 'model_summary'),
        ]),
    _Area('Profile', Icons.person_outline_rounded,
        'Public identity, posts, followers and profile files',
        loads: [
          _Endpoint('auth', 'me'),
        ],
        actions: [
          _Endpoint('auth', 'profile_update'),
          _Endpoint('users', 'metadata_public'),
          _Endpoint('users', 'file_delete'),
        ]),
    _Area('Account', Icons.security_outlined,
        'Sign-in identity, password and account controls',
        loads: [
          _Endpoint('auth', 'me'),
          _Endpoint('auth', 'config')
        ],
        actions: [
          _Endpoint('auth', 'profile_update'),
          _Endpoint('auth', 'send_verification'),
          _Endpoint('auth', 'resend_verification'),
          _Endpoint('auth', 'verify_email'),
          _Endpoint('auth', 'account_delete', {'confirmation': 'DELETE'}),
        ]),
  ];

  late int selected = widget.initialIndex.clamp(0, areas.length - 1);
  bool loading = false;
  Map<String, dynamic> results = const {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final area = areas[selected];
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
    if (!mounted || !identical(area, areas[selected])) return;
    setState(() {
      results = Map.fromEntries(values);
      loading = false;
    });
  }

  void choose(int index) {
    setState(() => selected = index);
    load();
  }

  Future<void> run(_Endpoint endpoint) async {
    final request = await showBackendActionForm(
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

  Future<void> uploadProfileFile() async {
    try {
      final file = await openFile();
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || !mounted) return;
      final options = await showDialog<_UploadOptions>(
        context: context,
        builder: (_) => _UploadOptionsDialog(fileName: file.name),
      );
      if (options == null || !mounted) return;
      final value = await widget.dependencies.service.invokeAction(
        'users',
        'file_upload',
        body: {
          'name': file.name,
          'mime': _mimeFromName(file.name),
          'meta_path': options.metaPath,
          'data': base64Encode(bytes),
          'public': options.isPublic,
        },
        timeout: const Duration(minutes: 10),
      );
      if (!mounted) return;
      setState(() => results = {...results, 'users.file_upload': value});
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('File uploaded')));
      await load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File upload failed: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final area = areas[selected];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 14 : 24, compact ? 14 : 20, compact ? 14 : 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PanelHeader(
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
        const SizedBox(height: 12),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: areas.length,
            separatorBuilder: (_, __) => const SizedBox(width: 7),
            itemBuilder: (context, index) => ChoiceChip(
              selected: selected == index,
              avatar: Icon(areas[index].icon, size: 17),
              label: Text(areas[index].label),
              onSelected: (_) => choose(index),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : AccountHubContent(
                    key: ValueKey(area.label),
                    area: area.label,
                    results: results,
                    onAction: (namespace, action, body) =>
                        run(_Endpoint(namespace, action, body)),
                    onUpload: uploadProfileFile,
                    onNotifications: setNotifications,
                    notificationsSupported: PushNotificationService.supported,
                  )),
      ]),
    );
  }
}

class _UploadOptions {
  const _UploadOptions(this.metaPath, this.isPublic);
  final String metaPath;
  final bool isPublic;
}

class _UploadOptionsDialog extends StatefulWidget {
  const _UploadOptionsDialog({required this.fileName});
  final String fileName;

  @override
  State<_UploadOptionsDialog> createState() => _UploadOptionsDialogState();
}

class _UploadOptionsDialogState extends State<_UploadOptionsDialog> {
  late final path =
      TextEditingController(text: 'profile.files.${widget.fileName}');
  bool isPublic = false;

  @override
  void dispose() {
    path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Upload profile file'),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: path,
              decoration: const InputDecoration(
                labelText: 'Metadata path',
                helperText: 'Where this file is linked in your profile',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: isPublic,
              onChanged: (value) => setState(() => isPublic = value ?? false),
              title: const Text('Public file'),
              subtitle:
                  const Text('Allow people viewing your profile to read it'),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              _UploadOptions(path.text.trim(), isPublic),
            ),
            child: const Text('Upload'),
          ),
        ],
      );
}

String _mimeFromName(String name) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'svg' => 'image/svg+xml',
    'pdf' => 'application/pdf',
    'json' => 'application/json',
    'txt' || 'md' || 'csv' || 'log' => 'text/plain',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    _ => 'application/octet-stream',
  };
}
