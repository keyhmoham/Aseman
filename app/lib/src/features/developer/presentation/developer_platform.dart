part of 'developer_console.dart';

// ── platforms: the organization's product environments ──────────────────────

class _Platforms extends _Loaded {
  const _Platforms({super.key, required super.service, required super.org});
  @override
  State<_Platforms> createState() => _PlatformsState();
}

class _PlatformsState extends _LoadedState<_Platforms> {
  /// The id of the platform shown (null: the first).
  String? selected;

  @override
  Future<_Json> fetch() async {
    final platforms = _maps((await call('platforms_list'))['platforms']);
    if (platforms.isEmpty) return {'platforms': platforms};
    final p = platforms.firstWhere((p) => p['id'] == selected,
        orElse: () => platforms.first);
    selected = '${p['id']}';
    final _Json ref = {'platform': selected};
    final stats = await call('platform_stats', ref);
    final users = await call('platform_users', {...ref, 'limit': 50});
    final frontend = _map(p['frontend']);
    _Json build = const {};
    if (frontend.isNotEmpty && frontend['ui'] != 'web') {
      try {
        build = _map((await call('platform_client_status', ref))['build']);
      } catch (_) {
        // An older node: no platform apps.
      }
    }
    return {
      'platform': p,
      ...stats,
      'platforms': platforms,
      'users': users['users'],
      'clientBuild': build,
    };
  }

  /// Shows platform [id].
  Future<void> _select(String id) async {
    if (id == selected) return;
    selected = id;
    _godot = null;
    await reload();
  }

  Future<void> _rename(_Json platform) async {
    final name = await _ask(context, 'Rename platform', 'Name',
        initial: '${platform['name']}');
    if (name == null || name.trim().isEmpty) return;
    await change(() => call('platform_rename',
        {'platform': '${platform['id']}', 'name': name.trim()}));
  }

  Future<void> _delete(_Json platform) async {
    final ok = await _confirm(
        context,
        'Delete ${platform['name']}?',
        'New sign-ups to @${platform['slug']} stop and its frontend goes '
            'away. Accounts, spaces and agents already on it stay.',
        action: 'Delete');
    if (!ok) return;
    selected = null;
    await change(
        () => call('platform_delete', {'platform': '${platform['id']}'}));
  }

  /// Picks an app the space agents built and publishes it as the platform's
  /// frontend.
  Future<void> _publishFrontend() async {
    final List<_Json> apps;
    try {
      apps = _maps((await call('platform_frontend_apps'))['apps']);
    } catch (e) {
      if (mounted) _snack(context, '$e');
      return;
    }
    if (!mounted) return;
    final picked = await showAppDialog<_Json>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Publish a frontend'),
        content: SizedBox(
          width: 460,
          child: apps.isEmpty
              ? const Text(
                  'No apps to publish yet. In a space you belong to, ask its agents '
                  'to build your platform\'s frontend (an app for the platform\'s '
                  'people, wired to the space\'s agents and apps), then come back.')
              : ListView(shrinkWrap: true, children: [
                  for (final a in apps)
                    QuietTile(
                      icon: a['ui'] == 'web'
                          ? Icons.web_rounded
                          : Icons.widgets_rounded,
                      label: '${a['title']}',
                      subtitle: _frontendSubtitle(a),
                      trailing: a['audience'] == 'platform'
                          ? const Chip(label: Text('Built for platforms'))
                          : null,
                      onTap: () => Navigator.pop(context, a),
                    ),
                ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final ok = await _confirm(
        context,
        'Publish “${picked['title']}”?',
        'The platform\'s people will open it as the platform\'s frontend. '
            'Its use of the space\'s agents and apps runs as you and is billed '
            'to you, and reaches only what the app is wired to.',
        action: 'Publish');
    if (!ok) return;
    await change(() => call('platform_frontend_publish',
        {'platform': selected, 'proxy': '${picked['proxy_id']}'}));
  }

  /// Opens the published frontend as the platform's people see it: an
  /// Elpian app runs here natively; a web app opens in the browser (signed
  /// out, as a visitor, until signed in on the page).
  Future<void> _openFrontend(_Json frontend) async {
    final url = '${frontend['url']}';
    if (frontend['ui'] == 'web') {
      final base = widget.service.client.baseUrl.replaceFirst(RegExp(r'/+$'), '');
      final ok = await launchUrl(Uri.parse('$base$url'),
          mode: LaunchMode.externalApplication);
      if (!ok && mounted) _snack(context, 'Could not open $base$url');
      return;
    }
    final title = '${frontend['title']}';
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ElpianAppView(
          service: widget.service,
          page: url,
          entry: '${frontend['entry'] ?? ''}'.isEmpty
              ? 'elpian/app.js'
              : '${frontend['entry']}',
          title: title,
        ),
      ),
    ));
  }

  Future<void> _unpublishFrontend() async {
    final ok = await _confirm(context, 'Take the frontend down?',
        'The platform\'s people will no longer be able to open it.',
        action: 'Take down');
    if (!ok) return;
    await change(
        () => call('platform_frontend_unpublish', {'platform': selected}));
  }

  Widget _frontendCard(BuildContext context, _Json platform) {
    final scheme = Theme.of(context).colorScheme;
    final frontend = _map(platform['frontend']);
    if (frontend.isEmpty) {
      return _Card(
        title: 'Frontend',
        icon: Icons.web_asset_rounded,
        trailing: FilledButton.icon(
            onPressed: _publishFrontend,
            icon: const Icon(Icons.publish_rounded, size: 18),
            label: const Text('Publish')),
        child: Text(
            'Publish an app the agents of one of your spaces built — Elpian or '
            'web, with its own backend — as what this platform\'s people open. '
            'Its server and page keep using that space\'s agents and apps.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
      );
    }
    final wiring = _map(frontend['wiring']);
    final agents = _maps(wiring['agents']);
    final tools = _maps(wiring['apps']);
    return _Card(
      title: 'Frontend',
      icon: Icons.web_asset_rounded,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
            tooltip: 'Open',
            onPressed: () => _openFrontend(frontend),
            icon: const Icon(Icons.open_in_new_rounded)),
        IconButton(
            tooltip: 'Publish another app',
            onPressed: _publishFrontend,
            icon: const Icon(Icons.swap_horiz_rounded)),
        IconButton(
            tooltip: 'Take down',
            onPressed: _unpublishFrontend,
            icon: const Icon(Icons.unpublished_outlined)),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        QuietTile(
          icon: frontend['ui'] == 'web'
              ? Icons.web_rounded
              : Icons.widgets_rounded,
          label: '${frontend['title']}',
          subtitle: frontend['ui'] == 'web'
              ? 'Web app'
              : 'Elpian app · runs natively in Aseman clients',
          trailing: IconButton(
            tooltip: 'Copy address',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: '${frontend['url']}')),
            icon: const Icon(Icons.copy_rounded, size: 18),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SelectableText('${frontend['url']}',
            style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: scheme.onSurface)),
        const SizedBox(height: AppSpacing.sm),
        Text('In the loop', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.xs),
        if (agents.isEmpty && tools.isEmpty)
          Text('This app uses no agents or apps of its space.',
              style: TextStyle(color: scheme.onSurfaceVariant))
        else
          Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
            for (final a in agents)
              Chip(
                  avatar: const Icon(Icons.smart_toy_outlined, size: 16),
                  label: Text('${a['name']}')),
            for (final t in tools)
              Chip(
                  avatar: const Icon(Icons.extension_outlined, size: 16),
                  label: Text('${t['display_name'] ?? t['name']}')),
          ]),
        const SizedBox(height: AppSpacing.sm),
        Text(
            'People of this platform reach only these. Their use runs as the '
            'person who published the frontend and is billed to them.',
            style: TextStyle(
                fontSize: 12.5, color: scheme.onSurfaceVariant, height: 1.35)),
      ]),
    );
  }

  /// Whether the next build carries the Godot engine (null: as the last
  /// build had it, off for the first).
  bool? _godot;

  Future<void> _buildClient(bool godot) async {
    await change(() => call(
        'platform_client_build', {'platform': selected, 'godot': godot}));
    _godot = null;
  }

  /// The platform's own Android app: the lightweight Elpian client built
  /// for its published Elpian frontend, which anyone can install.
  Widget? _clientCard(BuildContext context, _Json platform) {
    final frontend = _map(platform['frontend']);
    if (frontend.isEmpty || frontend['ui'] == 'web') return null;
    final scheme = Theme.of(context).colorScheme;
    final client = _map(platform['client']);
    final build = _map(data['clientBuild']);
    final state = '${build['state'] ?? 'none'}';
    final base =
        widget.service.client.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final link = client.isEmpty ? '' : '$base${client['url']}';
    final building = state == 'building';
    final godot = _godot ?? client['godot'] == true;
    return _Card(
      title: 'Android app',
      icon: Icons.android_rounded,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (building)
          IconButton(
              tooltip: 'Refresh',
              onPressed: reload,
              icon: const Icon(Icons.refresh_rounded)),
        FilledButton.icon(
            onPressed: building ? null : () => _buildClient(godot),
            icon: const Icon(Icons.build_rounded, size: 18),
            label: Text(client.isEmpty ? 'Build' : 'Build again')),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'A lightweight app of this platform: the Elpian engine and its '
            'frontend, nothing else of Aseman. People sign in with their '
            'platform accounts, and opening it wakes the platform\'s computer '
            'wherever they are.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        SwitchListTile(
          key: const ValueKey('client-godot'),
          contentPadding: EdgeInsets.zero,
          value: godot,
          onChanged: building ? null : (v) => setState(() => _godot = v),
          title: const Text('3D scenes (Godot engine)'),
          subtitle: Text(
              godot
                  ? 'The next build carries the Godot engine: Scene3D runs '
                      'live. The app is much larger (arm64 only).'
                  : 'Off: a Scene3D shows its placeholder and the app stays '
                      'small.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (client.isNotEmpty) ...[
          QuietTile(
            icon: Icons.download_rounded,
            label: 'Version ${client['version']}'
                '${client['godot'] == true ? ' · with Godot' : ''}',
            subtitle:
                '${((client['size'] as num? ?? 0) / (1 << 20)).toStringAsFixed(1)} MB · ${client['appId']}',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: 'Copy download address',
                onPressed: () => Clipboard.setData(ClipboardData(text: link)),
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
              IconButton(
                tooltip: 'Download',
                onPressed: () => launchUrl(Uri.parse(link),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
              ),
            ]),
          ),
          SelectableText(link,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: scheme.onSurface)),
          const SizedBox(height: AppSpacing.xs),
        ],
        if (building)
          Row(children: [
            const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
                child: Text('Building ${build['version'] ?? ''}: '
                    '${build['step'] ?? 'starting'}…')),
          ])
        else if (state == 'failed') ...[
          Text('The last build failed: ${build['error'] ?? ''}',
              style: TextStyle(color: scheme.error)),
          if ('${build['log'] ?? ''}'.isNotEmpty)
            SelectableText('${build['log']}',
                maxLines: 8,
                style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant)),
        ] else if (client.isEmpty)
          Text('Not built yet.',
              style: TextStyle(color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Future<void> _create() async {
    final name = await _ask(context, 'New platform', 'Name',
        hint: 'Acme', action: 'Next');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final slug = await _ask(context, 'Slug', 'URL slug',
        hint: 'acme', action: 'Create');
    if (slug == null || slug.trim().isEmpty) return;
    await change(() async {
      final made = await call(
          'platform_create', {'name': name.trim(), 'slug': slug.trim()});
      final id = _map(made['platform'])['id'];
      if (id != null) selected = '$id';
    });
  }

  /// The organization's platforms, one chosen, and a way to add another.
  Widget _picker(BuildContext context, List<_Json> platforms) {
    final scheme = Theme.of(context).colorScheme;
    return _Card(
      title: 'Platforms',
      icon: Icons.layers_outlined,
      trailing: FilledButton.icon(
          onPressed: _create,
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('New platform')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            'Each platform is an isolated product of this organization, with '
            'its own accounts, spaces, agents and frontend.',
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        const SizedBox(height: AppSpacing.sm),
        Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
          for (final p in platforms)
            ChoiceChip(
                label: Text('${p['name']}'),
                selected: p['id'] == selected,
                onSelected: (_) => _select('${p['id']}')),
        ]),
      ]),
    );
  }

  @override
  Widget content(BuildContext context) {
    final platform = _map(data['platform']);
    final platforms = _maps(data['platforms']);
    final scheme = Theme.of(context).colorScheme;
    if (platform.isEmpty) {
      return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: [
        _Card(
          title: 'No platform yet',
          icon: Icons.layers_outlined,
          trailing: FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create')),
          child: Text(
              'Create an isolated product environment for this organization '
              '(it can have several). Its users, spaces and agents stay private '
              'unless the node admin bridges it to main Aseman. Auth (password, '
              'Google, Apple) is the same system — pass the platform slug when '
              'signing people up.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        ),
      ]);
    }
    final users = _maps(data['users']);
    return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: [
      _picker(context, platforms),
      _Card(
        title: '${platform['name']}',
        icon: Icons.layers_rounded,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('@${platform['slug']}',
              style: TextStyle(
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
          IconButton(
              tooltip: 'Rename',
              onPressed: () => _rename(platform),
              icon: const Icon(Icons.edit_outlined, size: 18)),
          IconButton(
              tooltip: 'Delete',
              onPressed: () => _delete(platform),
              icon: const Icon(Icons.delete_outline_rounded, size: 18)),
        ]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 24, runSpacing: 16, children: [
            _Figure('Users', _count(data['users'] is num ? data['users'] : users.length)),
            _Figure('Spaces', _count(data['spaces'])),
            _Figure('Agents & apps', _count(data['bots'])),
          ]),
          const SizedBox(height: AppSpacing.sm),
          Text(
              platform['mainAccess'] == true
                  ? 'Bridged to main Aseman: your users and Aseman users can see each other.'
                  : 'Isolated: only this platform’s accounts see its spaces and agents.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: AppSpacing.xs),
          SelectableText(
              'Auth: register / login / oauth_* with { "platform": "${platform['slug']}" }',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: scheme.onSurface)),
        ]),
      ),
      _frontendCard(context, platform),
      ?_clientCard(context, platform),
      _Card(
        title: 'Local users',
        icon: Icons.people_outline_rounded,
        child: users.isEmpty
            ? _empty(context,
                'No platform-local accounts yet. They appear when people sign up with this platform slug.')
            : Column(children: [
                for (final u in users)
                  QuietTile(
                    icon: Icons.person_outline_rounded,
                    label: '@${u['handle']}',
                    subtitle: '${u['email']} · ${u['status']}',
                  ),
              ]),
      ),
    ]);
  }
}

String _frontendSubtitle(_Json a) {
  final wiring = _map(a['wiring']);
  final names = [
    for (final x in _maps(wiring['agents'])) '${x['name']}',
    for (final x in _maps(wiring['apps'])) '${x['display_name'] ?? x['name']}',
  ];
  return [
    if ('${a['space_name'] ?? ''}'.isNotEmpty) '${a['space_name']}',
    a['ui'] == 'web' ? 'Web' : 'Elpian',
    if (names.isNotEmpty) 'uses ${names.join(', ')}',
  ].join(' · ');
}

// ── platform API collection ──────────────────────────────────────────────────

class _Platform extends _Loaded {
  const _Platform({required super.service});
  @override
  State<_Platform> createState() => _PlatformState();
}

class _PlatformState extends _LoadedState<_Platform> {
  final search = TextEditingController();
  String ns = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  /// Expo has no developer.platform_catalog; list actions via admin.actions_list.
  Future<_Json> fetch() async {
    final raw = await widget.service.invokeAction('admin', 'actions_list');
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final namespaces = <Map<String, dynamic>>[];
    for (final n in (map['namespaces'] as List? ?? const [])) {
      if (n is! Map) continue;
      final name = '${n['namespace'] ?? n['name'] ?? ''}';
      final actions = <Map<String, dynamic>>[];
      for (final a in (n['actions'] as List? ?? const [])) {
        if (a is! Map) continue;
        actions.add({
          'name': '${a['name'] ?? ''}',
          'summary': '${a['summary'] ?? ''}',
          'path': '/v1/$name/${a['name'] ?? ''}',
        });
      }
      namespaces.add({'name': name, 'actions': actions});
    }
    return {'namespaces': namespaces};
  }

  @override
  Widget content(BuildContext context) {
    final namespaces = _maps(data['namespaces']);
    final names = [for (final n in namespaces) '${n['name']}']..sort();
    final q = search.text.toLowerCase().trim();
    final shown = namespaces.where((n) {
      if (ns != 'all' && n['name'] != ns) return false;
      if (q.isEmpty) return true;
      final hay = StringBuffer('${n['name']}');
      for (final a in _maps(n['actions'])) {
        hay.write(' ${a['name']} ${a['summary']} ${a['path']}');
      }
      return hay.toString().toLowerCase().contains(q);
    }).toList();
    final total = namespaces.fold<int>(
        0, (sum, n) => sum + _maps(n['actions']).length);
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: [
      _Card(
        title: 'Platform collection',
        icon: Icons.hub_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              'Every non-admin product action on this node — the same surface the Aseman client uses — callable with a developer key that has Platform access.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: AppSpacing.sm),
          SelectableText(
              'POST ${kDeveloperApiBase.isEmpty ? '/v1/platform' : '$kDeveloperApiBase/platform'}/{namespace}/{action}\n'
              'Authorization: Bearer dk_live_…\n'
              'Content-Type: application/json',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  color: scheme.onSurface,
                  height: 1.45)),
          const SizedBox(height: AppSpacing.sm),
          Text(
              '${_count(total)} actions across ${namespaces.length} namespaces. Node administration (admin.*, admin_*, and the developer console namespace) stays off this door.',
              style: TextStyle(
                  fontSize: 12.5, color: scheme.onSurfaceVariant)),
        ]),
      ),
      TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search namespace or action')),
      const SizedBox(height: AppSpacing.sm),
      Wrap(spacing: AppSpacing.xs, runSpacing: AppSpacing.xs, children: [
        for (final t in ['all', ...names])
          ChoiceChip(
              label: Text(t),
              selected: ns == t,
              onSelected: (_) => setState(() => ns = t)),
      ]),
      const SizedBox(height: AppSpacing.md),
      if (shown.isEmpty) _empty(context, 'No actions match.'),
      for (final n in shown)
        _Card(
          title: '${n['name']}',
          icon: Icons.folder_open_outlined,
          trailing: Text('${_maps(n['actions']).length}',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
          child: Column(
            children: [
              for (final a in _maps(n['actions']))
                if (q.isEmpty ||
                    '${a['name']} ${a['summary']} ${a['path']}'
                        .toLowerCase()
                        .contains(q))
                  QuietTile(
                    icon: Icons.bolt_outlined,
                    label: '${a['name']}',
                    subtitle: [
                      if ('${a['summary'] ?? ''}'.isNotEmpty) '${a['summary']}',
                      '${a['path']}',
                    ].join(' · '),
                    trailing: IconButton(
                      tooltip: 'Copy path',
                      onPressed: () => Clipboard.setData(
                          ClipboardData(text: '${a['path']}')),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                    ),
                  ),
            ],
          ),
        ),
    ]);
  }
}
