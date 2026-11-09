import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../assistant/assistant_common.dart';
import '../../assistant/governance_views.dart';
import 'admin_widgets.dart';

/// The admin console's governance, connection and enterprise pages. Each is
/// self-contained: it loads its own settings and saves them with the node's
/// admin actions.

Widget adminPolicyPage(AppDependencies deps) =>
    _Padded(PolicyEditor(dependencies: deps));

Widget adminAuditPage(AppDependencies deps) =>
    _Padded(AuditView(dependencies: deps));

Widget adminHostAccessPage(AppDependencies deps) =>
    _Padded(_HostAccessAdmin(deps));

/// Connector apps: apps whose people connect an account of their own
/// (Google, through this node's OAuth client; Composio and Arcade, through
/// a connector hub). Set up here, they are listed in the Apps catalog like
/// any app, and people add and connect them from Apps.
Widget adminConnectorAppsPage(AppDependencies deps) => _Padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _GoogleAdmin(deps),
          const SizedBox(height: 16),
          _BrokersAdmin(deps),
        ],
      ),
    );

Widget adminChannelsPage(AppDependencies deps) => _Padded(_ChannelsAdmin(deps));

Widget adminSsoPage(AppDependencies deps) => _Padded(_SsoAdmin(deps));

Widget adminDirectoryPage(AppDependencies deps) =>
    _Padded(_DirectoryAdmin(deps));

class _Padded extends StatelessWidget {
  const _Padded(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gutter = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 28.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 48),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: child,
        ),
      ],
    );
  }
}

/// A settings form that loads once and saves with one action.
abstract class _Form extends StatefulWidget {
  const _Form(this.deps);
  final AppDependencies deps;
}

abstract class _FormState<T extends _Form> extends State<T> {
  Map<String, dynamic>? data;
  String error = '';

  Future<Map<String, dynamic>> fetch();

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final out = await fetch();
      if (mounted) {
        setState(() {
          data = out;
          error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = errorText(e));
    }
  }

  Future<Map<String, dynamic>?> call(
    String ns,
    String action,
    Map<String, dynamic> body, [
    String? done,
  ]) async {
    final out = await runAction(context, widget.deps, ns, action, body, done);
    if (out != null) await reload();
    return out;
  }

  Widget body(Map<String, dynamic> data);

  @override
  Widget build(BuildContext context) {
    if (error.isNotEmpty && data == null) {
      return AdminEmptyState(
        'Could not load',
        error,
        icon: Icons.cloud_off_rounded,
      );
    }
    if (data == null) return const SkeletonList(itemCount: 4);
    return body(data!);
  }
}

Widget _field(
  TextEditingController c,
  String label, {
  String? help,
  bool secret = false,
  int lines = 1,
}) =>
    Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: secret,
        minLines: secret ? 1 : lines,
        maxLines: secret ? 1 : lines,
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          alignLabelWithHint: lines > 1,
        ),
      ),
    );

Widget _copyable(BuildContext context, String label, String value) {
  final scheme = Theme.of(context).colorScheme;
  final text = value.trim().isEmpty ? '—' : value;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GlassSurface(
      borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            if (value.trim().isNotEmpty)
              IconButton(
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
          ],
        ),
      ),
    ),
  );
}

List<String> _list(String text) => text
    .split(RegExp(r'[\s,]+'))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// The node's switch for agents on people's own computers: the highest
/// access the node can give, off by default.
class _HostAccessAdmin extends _Form {
  const _HostAccessAdmin(super.deps);
  @override
  State<_HostAccessAdmin> createState() => _HostAccessAdminState();
}

class _HostAccessAdminState extends _FormState<_HostAccessAdmin> {
  @override
  Future<Map<String, dynamic>> fetch() async => jsonMap(
        await widget.deps.service.invokeAction('hostaccess', 'admin_get'),
      );

  Future<void> _set(bool on) async {
    if (on) {
      final sure = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Let agents use people\'s own computers?'),
          content: const Text(
            'People could then connect their computer through the desktop app and let their '
            'agents run commands and change files in folders they share there. Every command and write is still '
            'decided by the policy and confirmed on the computer, but this reaches outside the project computers. '
            'Turn it on only if your organization accepts that.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Turn on'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }
    await call(
      'hostaccess',
      'admin_set',
      {'host_enabled': on},
      on ? 'Host access on' : 'Host access off: every computer is disconnected',
    );
  }

  @override
  Widget body(Map<String, dynamic> d) {
    final on = jsonMap(d['settings'])['host_enabled'] == true;
    final connected = d['connected_hosts'] ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionCard(
          title: 'Host access',
          icon: Icons.computer_rounded,
          subtitle:
              'By default agents work only on project computers. Letting them reach people’s own computers through the desktop app is the highest access this node can give.',
          child: Column(
            children: [
              AppSwitchCard(
                icon: on
                    ? Icons.warning_amber_rounded
                    : Icons.shield_outlined,
                title: 'Agents may use people’s own computers',
                subtitle: on
                    ? 'On · $connected computers connected. Turning it off disconnects them all.'
                    : 'Off (the default). Agents stay on project computers only.',
                value: on,
                onChanged: _set,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GoogleAdmin extends _Form {
  const _GoogleAdmin(super.deps);
  @override
  State<_GoogleAdmin> createState() => _GoogleAdminState();
}

class _GoogleAdminState extends _FormState<_GoogleAdmin> {
  final clientId = TextEditingController();
  final secret = TextEditingController();
  bool enabled = false;

  @override
  Future<Map<String, dynamic>> fetch() async {
    final out = jsonMap(
      await widget.deps.service.invokeAction('google', 'admin_get'),
    );
    clientId.text = '${out['client_id'] ?? ''}';
    enabled = out['enabled'] == true;
    return out;
  }

  @override
  void dispose() {
    clientId.dispose();
    secret.dispose();
    super.dispose();
  }

  @override
  Widget body(Map<String, dynamic> d) => AdminSectionCard(
        title: 'Google',
        icon: Icons.mail_outline_rounded,
        subtitle:
            'People connect their own Gmail and Calendar with this OAuth client. Their agents read for triage and the morning brief, draft replies and ask before sending.',
        trailing: enabled
            ? const AdminStatusPill('live')
            : const AdminStatusPill('disabled'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (d['fake'] == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GlassSurface(
                  color: ThemeRoles.selectedFill(context),
                  borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Talking to a fake Google (DECILLION_FAKE_GOOGLE_URL): for development only.',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              ),
            _copyable(
              context,
              'Authorized redirect URI (add it to the OAuth client)',
              '${d['redirect_uri'] ?? ''}',
            ),
            _copyable(
              context,
              'Scopes',
              jsonStrings(d['scopes']).join('\n'),
            ),
            const SizedBox(height: 4),
            AppSwitchCard(
              icon: Icons.hub_rounded,
              title: 'Offer Google to people',
              subtitle: enabled
                  ? 'Shown in Apps so people can connect their account.'
                  : 'Hidden until you turn it on and save a client.',
              value: enabled,
              onChanged: (v) => setState(() => enabled = v),
            ),
            const SizedBox(height: 14),
            _field(clientId, 'Client ID'),
            _field(
              secret,
              'Client secret',
              secret: true,
              help: d['has_secret'] == true
                  ? 'Saved. Leave empty to keep it.'
                  : null,
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => call('google', 'admin_set', {
                  'enabled': enabled,
                  'client_id': clientId.text.trim(),
                  if (secret.text.isNotEmpty) 'client_secret': secret.text,
                }, 'Saved').then((_) => secret.clear()),
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Save Google'),
              ),
            ),
          ],
        ),
      );
}

class _ChannelsAdmin extends _Form {
  const _ChannelsAdmin(super.deps);
  @override
  State<_ChannelsAdmin> createState() => _ChannelsAdminState();
}

class _ChannelsAdminState extends _FormState<_ChannelsAdmin> {
  // Per provider: which fields it takes, with their labels.
  static const _providers = {
    'slack': (
      'Slack',
      Icons.tag_rounded,
      [
        ('app_id', 'App ID', false, null),
        ('secret', 'Signing secret', true, null),
        ('token', 'Bot token (xoxb-…)', true, null),
      ],
    ),
    'teams': (
      'Microsoft Teams',
      Icons.groups_rounded,
      [
        ('app_id', 'Bot app ID', false, null),
        ('tenant', 'Tenant ID', false, 'Empty for any tenant'),
        ('secret', 'App password', true, null),
      ],
    ),
    'twilio': (
      'SMS (Twilio)',
      Icons.sms_rounded,
      [
        ('app_id', 'Account SID', false, null),
        ('from', 'From number (+1…)', false, null),
        ('token', 'Auth token', true, null),
      ],
    ),
  };

  final controllers = <String, TextEditingController>{};
  final enabled = <String, bool>{};

  TextEditingController _c(String provider, String field) =>
      controllers.putIfAbsent('$provider.$field', TextEditingController.new);

  @override
  Future<Map<String, dynamic>> fetch() async {
    final out = jsonMap(
      await widget.deps.service.invokeAction('channels', 'admin_get'),
    );
    for (final p in _providers.keys) {
      final st = jsonMap(out[p]);
      enabled[p] = st['enabled'] == true;
      for (final f in const ['app_id', 'from', 'tenant']) {
        _c(p, f).text = '${st[f] ?? ''}';
      }
    }
    return out;
  }

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget body(Map<String, dynamic> d) {
    final endpoints = jsonMap(d['endpoints']);
    final base = widget.deps.service.client.baseUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'People link their Telegram, Slack, Teams or phone number in Settings → Connections, then talk to their agents, answer approvals and get their brief there.',
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Telegram',
          icon: Icons.send_rounded,
          trailing: jsonMap(d['telegram'])['enabled'] == true
              ? const AdminStatusPill('live')
              : const AdminStatusPill('disabled'),
          child: Text(
            jsonMap(d['telegram'])['enabled'] == true
                ? 'The bot @${jsonMap(d['telegram'])['app_id']} is set up in the node\'s environment.'
                : 'Set DECILLION_TELEGRAM_BOT_TOKEN, DECILLION_TELEGRAM_BOT_USERNAME and DECILLION_TELEGRAM_WEBHOOK_SECRET on the node to offer Telegram.',
          ),
        ),
        const SizedBox(height: 12),
        for (final p in _providers.entries) ...[
          AdminSectionCard(
            title: p.value.$1,
            icon: p.value.$2,
            trailing: (enabled[p.key] ?? false)
                ? const AdminStatusPill('live')
                : const AdminStatusPill('disabled'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSwitchCard(
                  icon: p.value.$2,
                  title: 'On',
                  subtitle: (enabled[p.key] ?? false)
                      ? 'People can link this channel.'
                      : 'Not offered until you turn it on and save.',
                  value: enabled[p.key] ?? false,
                  onChanged: (v) => setState(() => enabled[p.key] = v),
                ),
                const SizedBox(height: 14),
                for (final f in p.value.$3)
                  _field(
                    _c(p.key, f.$1),
                    f.$2,
                    secret: f.$3,
                    help: f.$3 &&
                            (jsonMap(d[p.key])[f.$1 == 'secret'
                                    ? 'has_secret'
                                    : 'has_token'] ==
                                true)
                        ? 'Saved. Leave empty to keep it.'
                        : f.$4,
                  ),
                if (p.key == 'slack') ...[
                  _copyable(
                    context,
                    'Event subscriptions URL',
                    '$base${endpoints['slack'] ?? ''}',
                  ),
                  _copyable(
                    context,
                    'Interactivity URL',
                    '$base${endpoints['slack_actions'] ?? ''}',
                  ),
                ] else
                  _copyable(
                    context,
                    p.key == 'teams'
                        ? 'Messaging endpoint'
                        : 'Incoming message webhook',
                    '$base${endpoints[p.key] ?? ''}',
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () {
                      final body = <String, dynamic>{
                        'provider': p.key,
                        'enabled': enabled[p.key] ?? false,
                      };
                      for (final f in p.value.$3) {
                        final v = _c(p.key, f.$1).text.trim();
                        if (!f.$3 || v.isNotEmpty) body[f.$1] = v;
                      }
                      call('channels', 'admin_set', body, 'Saved').then((_) {
                        for (final f in p.value.$3.where((f) => f.$3)) {
                          _c(p.key, f.$1).clear();
                        }
                      });
                    },
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: Text('Save ${p.value.$1}'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _BrokersAdmin extends _Form {
  const _BrokersAdmin(super.deps);
  @override
  State<_BrokersAdmin> createState() => _BrokersAdminState();
}

class _BrokersAdminState extends _FormState<_BrokersAdmin> {
  @override
  Future<Map<String, dynamic>> fetch() async => jsonMap(
        await widget.deps.service.invokeAction('tools', 'broker_presets'),
      );

  Future<void> _add(Map<String, dynamic> b) async {
    final url = await askText(
      context,
      '${b['name']} MCP address',
      hint: '${b['url_hint']}',
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    final key = await askText(context, '${b['name']} API key', obscure: true);
    if (key == null || key.isEmpty || !mounted) return;
    await call(
      'tools',
      'broker_add',
      {'broker': b['id'], 'url': url.trim(), 'api_key': key},
      '${b['name']} added: its tools appear under Apps, each person connecting their own accounts there',
    );
  }

  @override
  Widget body(Map<String, dynamic> d) {
    final brokers = jsonList(d['brokers']);
    return AdminSectionCard(
      title: 'Composio and Arcade',
      icon: Icons.extension_rounded,
      subtitle:
          'Connector hubs bring hundreds of apps through one MCP server. The node’s key is sent with every call, and each person’s id, so everyone uses their own connected accounts.',
      child: brokers.isEmpty
          ? const AdminEmptyState(
              'No connector hubs',
              'Presets from the node appear here when available.',
              icon: Icons.extension_outlined,
            )
          : Column(
              children: [
                for (final b in brokers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassSurface(
                      borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: ShapeDecoration(
                                color: ThemeRoles.wellFill(context),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Icon(
                                Icons.hub_rounded,
                                color: ThemeRoles.selectedInk(context),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${b['name']}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${b['site']}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '${b['description']}',
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.35,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                                  ),
                                  if ('${b['docs'] ?? ''}'.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Docs: ${b['docs']}',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () => _add(b),
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SsoAdmin extends _Form {
  const _SsoAdmin(super.deps);
  @override
  State<_SsoAdmin> createState() => _SsoAdminState();
}

class _SsoAdminState extends _FormState<_SsoAdmin> {
  @override
  Future<Map<String, dynamic>> fetch() async => jsonMap(
        await widget.deps.service.invokeAction('enterprise', 'providers_list'),
      );

  Future<void> _edit([Map<String, dynamic> p = const {}]) async {
    final body = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ProviderDialog(p),
    );
    if (body != null) await call('enterprise', 'provider_save', body, 'Saved');
  }

  @override
  Widget body(Map<String, dynamic> d) {
    final providers = jsonList(d['providers']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionCard(
          title: 'Single sign-on',
          icon: Icons.verified_user_rounded,
          subtitle:
              'OpenID Connect providers (Okta, Entra ID, Google Workspace, Keycloak…). People of a provider’s email domains sign in through it; with “Required”, only through it.',
          trailing: FilledButton.tonalIcon(
            onPressed: _edit,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _copyable(
                context,
                'Redirect URI (register it with the provider)',
                '${d['redirect_uri'] ?? ''}',
              ),
              if (providers.isEmpty)
                const AdminEmptyState(
                  'No providers yet',
                  'Add an OpenID Connect provider so people can sign in with your directory.',
                  icon: Icons.verified_user_outlined,
                )
              else
                for (final p in providers)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: AdminAvatar(
                      '${p['name'] ?? p['slug'] ?? 'SSO'}',
                      icon: p['enabled'] == true
                          ? Icons.verified_user_rounded
                          : Icons.pause_circle_outline_rounded,
                    ),
                    title: Text(
                      '${p['name']} (${p['slug']})',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        jsonStrings(p['domains']).join(', '),
                        if (p['required'] == true) 'required',
                        '${p['issuer']}',
                      ].where((x) => x.isNotEmpty).join(' · '),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AdminStatusPill(
                          p['enabled'] == true ? 'active' : 'disabled',
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => call(
                            'enterprise',
                            'provider_delete',
                            {'slug': p['slug']},
                            'Removed',
                          ),
                        ),
                      ],
                    ),
                    onTap: () => _edit(p),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog(this.p);
  final Map<String, dynamic> p;
  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final slug = TextEditingController(text: '${widget.p['slug'] ?? ''}');
  late final name = TextEditingController(text: '${widget.p['name'] ?? ''}');
  late final issuer = TextEditingController(
    text: '${widget.p['issuer'] ?? ''}',
  );
  late final clientId = TextEditingController(
    text: '${widget.p['client_id'] ?? ''}',
  );
  final secret = TextEditingController();
  late final domains = TextEditingController(
    text: jsonStrings(widget.p['domains']).join(', '),
  );
  late final groupsClaim = TextEditingController(
    text: '${widget.p['groups_claim'] ?? 'groups'}',
  );
  late final adminGroups = TextEditingController(
    text: jsonStrings(widget.p['admin_groups']).join(', '),
  );
  late bool required = widget.p['required'] == true;
  late bool enabled = widget.p['enabled'] != false;

  @override
  void dispose() {
    for (final c in [
      slug,
      name,
      issuer,
      clientId,
      secret,
      domains,
      groupsClaim,
      adminGroups,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.p.isEmpty ? 'Add a provider' : 'Edit ${widget.p['name']}',
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _field(slug, 'Slug', help: 'Short id, e.g. okta'),
                _field(name, 'Name shown on the sign-in button'),
                _field(issuer, 'Issuer URL', help: 'e.g. https://acme.okta.com'),
                _field(clientId, 'Client ID'),
                _field(
                  secret,
                  'Client secret',
                  secret: true,
                  help: widget.p.isEmpty ? null : 'Leave empty to keep it',
                ),
                _field(domains, 'Email domains', help: 'Comma separated'),
                _field(groupsClaim, 'Groups claim'),
                _field(
                  adminGroups,
                  'Administrator groups',
                  help: 'Members become administrators',
                ),
                const SizedBox(height: 4),
                AppSwitchCard(
                  title: 'Required for these domains',
                  subtitle: 'People on these domains can only sign in this way.',
                  value: required,
                  onChanged: (v) => setState(() => required = v),
                ),
                const SizedBox(height: 8),
                AppSwitchCard(
                  title: 'On',
                  subtitle: 'Offer this provider on the sign-in screen.',
                  value: enabled,
                  onChanged: (v) => setState(() => enabled = v),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              if (widget.p['id'] != null) 'id': widget.p['id'],
              'slug': slug.text.trim(),
              'name': name.text.trim(),
              'issuer': issuer.text.trim(),
              'client_id': clientId.text.trim(),
              if (secret.text.isNotEmpty) 'client_secret': secret.text,
              'domains': _list(domains.text),
              'groups_claim': groupsClaim.text.trim(),
              'admin_groups': _list(adminGroups.text),
              'required': required,
              'enabled': enabled,
            }),
            child: const Text('Save'),
          ),
        ],
      );
}

class _DirectoryAdmin extends _Form {
  const _DirectoryAdmin(super.deps);
  @override
  State<_DirectoryAdmin> createState() => _DirectoryAdminState();
}

class _DirectoryAdminState extends _FormState<_DirectoryAdmin> {
  final adminGroups = TextEditingController();
  final trustDomain = TextEditingController();
  final bundleUrl = TextEditingController();
  final audience = TextEditingController();
  bool spiffeRequired = false;

  @override
  Future<Map<String, dynamic>> fetch() async {
    final service = widget.deps.service;
    final results = await Future.wait([
      service.invokeAction('enterprise', 'settings_get'),
      service.invokeAction('enterprise', 'organizations_list'),
      service.invokeAction('enterprise', 'directory_list'),
    ]);
    final settings = jsonMap(results[0]);
    final st = jsonMap(settings['settings']);
    adminGroups.text = jsonStrings(st['scim_admin_groups']).join(', ');
    trustDomain.text = '${st['spiffe_trust_domain'] ?? ''}';
    bundleUrl.text = '${st['spiffe_bundle_url'] ?? ''}';
    audience.text = '${st['spiffe_audience'] ?? ''}';
    spiffeRequired = st['spiffe_required'] == true;
    return {
      ...settings,
      'organizations': jsonMap(results[1])['organizations'],
      'people': jsonMap(results[2])['people'],
    };
  }

  @override
  void dispose() {
    for (final c in [adminGroups, trustDomain, bundleUrl, audience]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _newToken() async {
    final out = await call('enterprise', 'scim_token_new', const {});
    if (out == null || !mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SCIM token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _copyable(context, 'Base URL', '${out['base_url']}'),
            _copyable(
              context,
              'Bearer token (shown once; the old one stops working)',
              '${out['token']}',
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
  }

  Future<void> _org([Map<String, dynamic> o = const {}]) async {
    final name = await askText(
      context,
      'Organization name',
      initial: '${o['name'] ?? ''}',
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final domains = await askText(
      context,
      'Email domains (comma separated)',
      initial: jsonStrings(o['domains']).join(', '),
    );
    if (domains == null || !mounted) return;
    await call('enterprise', 'organization_save', {
      if (o['id'] != null) 'id': o['id'],
      'name': name.trim(),
      'domains': _list(domains),
      if (o['space_id'] != null) 'space_id': o['space_id'],
    }, 'Saved');
  }

  @override
  Widget body(Map<String, dynamic> d) {
    final people = jsonList(d['people']);
    final orgs = jsonList(d['organizations']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdminSectionCard(
          title: 'Directory (SCIM 2.0)',
          icon: Icons.sync_alt_rounded,
          subtitle:
              'Your identity provider creates, updates and offboards people here. Offboarding disables the account, ends its sessions, revokes its connections and stops its computers.',
          trailing: OutlinedButton.icon(
            onPressed: _newToken,
            icon: const Icon(Icons.key_rounded, size: 18),
            label: const Text('New token'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _copyable(context, 'Base URL', '${d['scim_base_url'] ?? ''}'),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AdminStatusPill(
                  d['scim_configured'] == true ? 'active' : 'needs setup',
                ),
              ),
              _field(
                adminGroups,
                'Administrator groups',
                help: 'Directory groups whose members are administrators',
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Organizations',
          icon: Icons.apartment_rounded,
          subtitle:
              'People are placed in their organization by email domain, sharing its project.',
          trailing: TextButton.icon(
            onPressed: _org,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add'),
          ),
          child: orgs.isEmpty
              ? const AdminEmptyState(
                  'No organizations',
                  'Add one so people land in a shared project by email domain.',
                  icon: Icons.apartment_outlined,
                )
              : Column(
                  children: [
                    for (final o in orgs)
                      ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 2),
                        leading: AdminAvatar(
                          '${o['name'] ?? 'Org'}',
                          icon: Icons.apartment_rounded,
                        ),
                        title: Text(
                          '${o['name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(jsonStrings(o['domains']).join(', ')),
                        onTap: () => _org(o),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => call(
                            'enterprise',
                            'organization_delete',
                            {'id': o['id']},
                            'Removed',
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Workload identity (SPIFFE)',
          icon: Icons.fingerprint_rounded,
          subtitle:
              'The agent runtime proves who it is with a JWT-SVID before the node runs its calls.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field(trustDomain, 'Trust domain', help: 'e.g. aseman.internal'),
              _field(
                bundleUrl,
                'JWKS bundle URL',
                help: 'e.g. http://spire-oidc:8008/keys',
              ),
              _field(audience, 'Audience'),
              AppSwitchCard(
                icon: Icons.verified_outlined,
                title: 'Require it',
                subtitle: spiffeRequired
                    ? 'Calls without a valid SVID are refused.'
                    : 'Optional for now.',
                value: spiffeRequired,
                onChanged: (v) => setState(() => spiffeRequired = v),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: () => call('enterprise', 'settings_set', {
                    'scim_admin_groups': _list(adminGroups.text),
                    'spiffe_trust_domain': trustDomain.text.trim(),
                    'spiffe_bundle_url': bundleUrl.text.trim(),
                    'spiffe_audience': audience.text.trim(),
                    'spiffe_required': spiffeRequired,
                  }, 'Saved'),
                  icon: const Icon(Icons.save_rounded, size: 18),
                  label: const Text('Save directory settings'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'People from the directory',
          icon: Icons.people_rounded,
          subtitle: '${people.length} provisioned accounts',
          child: people.isEmpty
              ? const AdminEmptyState(
                  'No directory people yet',
                  'Accounts appear here once your identity provider syncs them.',
                  icon: Icons.person_off_outlined,
                )
              : Column(
                  children: [
                    for (final p in people)
                      ListTile(
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 2),
                        leading: AdminAvatar(
                          '${p['user_name'] ?? p['email'] ?? 'User'}',
                          icon: p['active'] == true
                              ? Icons.person_rounded
                              : Icons.person_off_outlined,
                        ),
                        title: Text(
                          '${p['user_name']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          [
                            p['email'],
                            jsonStrings(p['groups']).join(', '),
                          ].where((x) => '$x'.isNotEmpty).join(' · '),
                        ),
                        trailing: p['active'] == true
                            ? TextButton(
                                onPressed: () async {
                                  final ok = await showAppDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title:
                                          Text('Offboard ${p['user_name']}?'),
                                      content: const Text(
                                        'Disables the account now, ends its sessions, revokes its connections and stops its computers.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Offboard'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await call('enterprise', 'deprovision', {
                                      'account': p['id'],
                                    }, 'Offboarded');
                                  }
                                },
                                child: const Text('Offboard'),
                              )
                            : const AdminStatusPill('disabled'),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}
