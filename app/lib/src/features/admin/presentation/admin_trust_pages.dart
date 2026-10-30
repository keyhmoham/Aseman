import 'package:flutter/material.dart';
import '../../../shared/widgets/overlay_panels.dart';

import '../../../app_dependencies.dart';
import '../../assistant/assistant_common.dart';
import '../../assistant/governance_views.dart';
import '../../../shared/widgets/glass_surface.dart';

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
/// the broker). Set up here, they are listed in the Apps catalog like any
/// app, and people add and connect them from Apps.
Widget adminConnectorAppsPage(AppDependencies deps) => _Padded(
  Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Google',
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
      const SizedBox(height: 6),
      _GoogleAdmin(deps),
      const Divider(height: 40),
      const Text(
        'Composio and Arcade',
        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
      ),
      const SizedBox(height: 6),
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
      if (mounted) setState(() => data = out);
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
      return Text(
        error,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    if (data == null) return const LinearProgressIndicator();
    return body(data!);
  }
}

Widget _field(
  TextEditingController c,
  String label, {
  String? help,
  bool secret = false,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 10),
  child: TextField(
    controller: c,
    obscureText: secret,
    decoration: InputDecoration(
      labelText: label,
      helperText: help,
      border: const OutlineInputBorder(),
    ),
  ),
);

Widget _copyable(String label, String value) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
      ),
      SelectableText(value, style: const TextStyle(fontFamily: 'monospace')),
    ],
  ),
);

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
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'By default agents work only on project computers, and people share folders from those with '
          'their agents. Letting agents reach people\'s own computers through the desktop app is the highest access '
          'this node can give.',
        ),
        const SizedBox(height: 12),
        AppCard(
          color: on ? scheme.errorContainer : null,
          child: SwitchListTile(
            title: const Text('Agents may use people\'s own computers'),
            subtitle: Text(
              on
                  ? 'On · ${d['connected_hosts'] ?? 0} computers connected. Turning it off disconnects them all.'
                  : 'Off (the default).',
            ),
            value: on,
            onChanged: _set,
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
  Widget body(Map<String, dynamic> d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'People connect their own Gmail and Calendar with this OAuth client. Their agents read for '
        'triage and the morning brief, draft replies and ask before sending.',
      ),
      const SizedBox(height: 12),
      _copyable(
        'Authorized redirect URI (add it to the OAuth client)',
        '${d['redirect_uri'] ?? ''}',
      ),
      _copyable('Scopes', jsonStrings(d['scopes']).join('\n')),
      if (d['fake'] == true)
        const Text(
          'Talking to a fake Google (ASEMAN_GOOGLE_FAKE_URL): for development only.',
        ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Offer Google to people'),
        value: enabled,
        onChanged: (v) => setState(() => enabled = v),
      ),
      _field(clientId, 'Client ID'),
      _field(
        secret,
        'Client secret',
        secret: true,
        help: d['has_secret'] == true ? 'Saved. Leave empty to keep it.' : null,
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: () => call('google', 'admin_set', {
            'enabled': enabled,
            'client_id': clientId.text.trim(),
            if (secret.text.isNotEmpty) 'client_secret': secret.text,
          }, 'Saved').then((_) => secret.clear()),
          child: const Text('Save'),
        ),
      ),
    ],
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
      [
        ('app_id', 'App ID', false, null),
        ('secret', 'Signing secret', true, null),
        ('token', 'Bot token (xoxb-…)', true, null),
      ],
    ),
    'teams': (
      'Microsoft Teams',
      [
        ('app_id', 'Bot app ID', false, null),
        ('tenant', 'Tenant ID', false, 'Empty for any tenant'),
        ('secret', 'App password', true, null),
      ],
    ),
    'twilio': (
      'SMS (Twilio)',
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
        const Text(
          'People link their Slack, Teams or phone number in Settings → Connections, then talk to their '
          'agents, answer approvals and get their brief there.',
        ),
        for (final p in _providers.entries) ...[
          const Divider(height: 32),
          Text(
            p.value.$1,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('On'),
            value: enabled[p.key] ?? false,
            onChanged: (v) => setState(() => enabled[p.key] = v),
          ),
          for (final f in p.value.$2)
            _field(
              _c(p.key, f.$1),
              f.$2,
              secret: f.$3,
              help:
                  f.$3 &&
                      (jsonMap(d[p.key])[f.$1 == 'secret'
                              ? 'has_secret'
                              : 'has_token'] ==
                          true)
                  ? 'Saved. Leave empty to keep it.'
                  : f.$4,
            ),
          if (p.key == 'slack') ...[
            _copyable(
              'Event subscriptions URL',
              '$base${endpoints['slack'] ?? ''}',
            ),
            _copyable(
              'Interactivity URL',
              '$base${endpoints['slack_actions'] ?? ''}',
            ),
          ] else
            _copyable(
              p.key == 'teams'
                  ? 'Messaging endpoint'
                  : 'Incoming message webhook',
              '$base${endpoints[p.key] ?? ''}',
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: () {
                final body = <String, dynamic>{
                  'provider': p.key,
                  'enabled': enabled[p.key] ?? false,
                };
                for (final f in p.value.$2) {
                  final v = _c(p.key, f.$1).text.trim();
                  if (!f.$3 || v.isNotEmpty) body[f.$1] = v;
                }
                call('channels', 'admin_set', body, 'Saved').then((_) {
                  for (final f in p.value.$2.where((f) => f.$3)) {
                    _c(p.key, f.$1).clear();
                  }
                });
              },
              child: Text('Save ${p.value.$1}'),
            ),
          ),
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
  Widget body(Map<String, dynamic> d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Connector brokers bring hundreds of apps through one MCP server. The node\'s key is sent with '
        'every call, and each person\'s id, so everyone uses their own connected accounts.',
      ),
      const SizedBox(height: 12),
      for (final b in jsonList(d['brokers']))
        AppCard(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${b['name']} · ${b['site']}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text('${b['description']}'),
                const SizedBox(height: 4),
                Text(
                  'Docs: ${b['docs']}',
                  style: const TextStyle(fontSize: 12),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => _add(b),
                    child: const Text('Add'),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
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
  Widget body(Map<String, dynamic> d) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'OpenID Connect providers (Okta, Entra ID, Google Workspace, Keycloak…). People of a provider\'s '
        'email domains sign in through it; with "Required", only through it.',
      ),
      const SizedBox(height: 12),
      _copyable(
        'Redirect URI (register it with the provider)',
        '${d['redirect_uri'] ?? ''}',
      ),
      for (final p in jsonList(d['providers']))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            p['enabled'] == true
                ? Icons.verified_user_rounded
                : Icons.pause_circle_outline_rounded,
          ),
          title: Text('${p['name']} (${p['slug']})'),
          subtitle: Text(
            [
              jsonStrings(p['domains']).join(', '),
              if (p['required'] == true) 'required',
              '${p['issuer']}',
            ].where((x) => x.isNotEmpty).join(' · '),
          ),
          onTap: () => _edit(p),
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => call('enterprise', 'provider_delete', {
              'slug': p['slug'],
            }, 'Removed'),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: _edit,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add a provider'),
        ),
      ),
    ],
  );
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Required for these domains'),
              value: required,
              onChanged: (v) => setState(() => required = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('On'),
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
            _copyable('Base URL', '${out['base_url']}'),
            _copyable(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Directory (SCIM 2.0)',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const Text(
          'Your identity provider creates, updates and offboards people here. Offboarding disables the account, '
          'ends its sessions, revokes its connections and stops its computers.',
        ),
        const SizedBox(height: 8),
        _copyable('Base URL', '${d['scim_base_url'] ?? ''}'),
        Text(
          d['scim_configured'] == true ? 'A token is set.' : 'No token yet.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: _newToken,
            child: const Text('New token'),
          ),
        ),
        const SizedBox(height: 8),
        _field(
          adminGroups,
          'Administrator groups',
          help: 'Directory groups whose members are administrators',
        ),
        const Divider(height: 32),
        const Text(
          'Organizations',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const Text(
          'People are placed in their organization by email domain, sharing its project.',
        ),
        for (final o in jsonList(d['organizations']))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.apartment_rounded),
            title: Text('${o['name']}'),
            subtitle: Text(jsonStrings(o['domains']).join(', ')),
            onTap: () => _org(o),
            trailing: IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => call('enterprise', 'organization_delete', {
                'id': o['id'],
              }, 'Removed'),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _org,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add an organization'),
          ),
        ),
        const Divider(height: 32),
        const Text(
          'Workload identity (SPIFFE)',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        const Text(
          'The agent runtime proves who it is with a JWT-SVID before the node runs its calls.',
        ),
        const SizedBox(height: 8),
        _field(trustDomain, 'Trust domain', help: 'e.g. aseman.internal'),
        _field(
          bundleUrl,
          'JWKS bundle URL',
          help: 'e.g. http://spire-oidc:8008/keys',
        ),
        _field(audience, 'Audience'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Require it'),
          value: spiffeRequired,
          onChanged: (v) => setState(() => spiffeRequired = v),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: () => call('enterprise', 'settings_set', {
              'scim_admin_groups': _list(adminGroups.text),
              'spiffe_trust_domain': trustDomain.text.trim(),
              'spiffe_bundle_url': bundleUrl.text.trim(),
              'spiffe_audience': audience.text.trim(),
              'spiffe_required': spiffeRequired,
            }, 'Saved'),
            child: const Text('Save'),
          ),
        ),
        const Divider(height: 32),
        Text(
          'People from the directory (${people.length})',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
        ),
        for (final p in people)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              p['active'] == true
                  ? Icons.person_rounded
                  : Icons.person_off_outlined,
            ),
            title: Text('${p['user_name']}'),
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
                          title: Text('Offboard ${p['user_name']}?'),
                          content: const Text(
                            'Disables the account now, ends its sessions, revokes its connections and stops its computers.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text('Offboard'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true)
                        await call('enterprise', 'deprovision', {
                          'account': p['id'],
                        }, 'Offboarded');
                    },
                    child: const Text('Offboard'),
                  )
                : null,
          ),
      ],
    );
  }
}
