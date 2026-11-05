part of 'developer_console.dart';

// ── sub-platform product environment ─────────────────────────────────────────

class _SubPlatform extends _Loaded {
  const _SubPlatform(
      {super.key, required super.service, required super.org});
  @override
  State<_SubPlatform> createState() => _SubPlatformState();
}

class _SubPlatformState extends _LoadedState<_SubPlatform> {
  @override
  Future<_Json> fetch() async {
    final p = await call('platform_get');
    if (p['platform'] == null) return p;
    final stats = await call('platform_stats');
    final users = await call('platform_users', {'limit': 50});
    return {...p, ...stats, 'users': users['users']};
  }

  Future<void> _create() async {
    final name = await _ask(context, 'New sub-platform', 'Name',
        hint: 'Acme', action: 'Next');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final slug = await _ask(context, 'Slug', 'URL slug',
        hint: 'acme', action: 'Create');
    if (slug == null || slug.trim().isEmpty) return;
    await change(() => call(
        'platform_create', {'name': name.trim(), 'slug': slug.trim()}));
  }

  @override
  Widget content(BuildContext context) {
    final platform = _map(data['platform']);
    final scheme = Theme.of(context).colorScheme;
    if (platform.isEmpty) {
      return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: [
        _Card(
          title: 'No sub-platform yet',
          icon: Icons.layers_outlined,
          trailing: FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create')),
          child: Text(
              'Create an isolated product environment for this organization. '
              'Its users, spaces and agents stay private unless the node admin '
              'bridges it to main Aseman. Auth (password, Google, Apple) is the '
              'same system — pass a platform slug when signing people up.',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
        ),
      ]);
    }
    final users = _maps(data['users']);
    return ListView(padding: const EdgeInsets.all(AppSpacing.md), children: [
      _Card(
        title: '${platform['name']}',
        icon: Icons.layers_rounded,
        trailing: Text('@${platform['slug']}',
            style: TextStyle(
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600)),
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
  Future<_Json> fetch() => widget.service.developer('platform_catalog');

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
