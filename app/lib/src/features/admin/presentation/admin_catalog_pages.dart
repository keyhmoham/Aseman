part of 'admin_page_content.dart';

Widget _buildAgentsPage(_AppPageContentState state) {
    final bots = _listOfMaps(
      _map(state.widget.results['admin.bots_list'])['bots'],
    ).where((b) => '${b['kind'] ?? 'agent'}' == 'agent').toList();
    final listings = _listOfMaps(
      _map(state.widget.results['market.catalog'])['listings'],
    );
    final byBot = <String, Map<String, dynamic>>{
      for (final l in listings) '${l['bot_id'] ?? l['bot']}': l,
    };
    String status(Map<String, dynamic> b) =>
        '${byBot['${b['id']}']?['status'] ?? 'unlisted'}';
    final q = state.search.text.trim().toLowerCase();
    final rows = bots.where((b) {
      return (state.filter == 'all' || state.filter == status(b)) &&
          (q.isEmpty ||
              '${b['name']} ${b['handle']} ${b['owner_handle']} ${b['provider']} ${b['model']} ${b['fallback_models']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    int count(String s) => bots.where((b) => status(b) == s).length;
    final models = <String, double>{};
    for (final b in bots) {
      final key = '${b['model'] ?? 'Platform default'}';
      models[key] = (models[key] ?? 0) + 1;
    }
    final palette = adminPalette(state.context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        state._toolbar(
          Text(
            '${bots.length} agents on this node',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          [
            OutlinedButton.icon(
              onPressed: () => state.widget.onAction(
                'bots',
                'agent_import_samples',
                const <String, dynamic>{},
              ),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Import catalogue'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  state.widget.onAction('bots', 'bot_create', {'kind': 'agent'}),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add agent'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Marketplace',
              icon: Icons.storefront_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: '${bots.length}',
                caption: 'agents',
                slices: [
                  AdminChartSlice(
                    'Listed',
                    count('approved').toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'In review',
                    count('pending').toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                  AdminChartSlice(
                    'Denied',
                    count('denied').toDouble(),
                    AppColors.dangerOf(state.context),
                  ),
                  AdminChartSlice(
                    'Unlisted',
                    count('unlisted').toDouble(),
                    palette.first,
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Backbone models',
              icon: Icons.memory_rounded,
              child: AdminBarList(
                maxItems: 4,
                empty: 'No agents yet.',
                items: [
                  for (final (i, e) in models.entries.indexed)
                    AdminChartSlice(
                      e.key,
                      e.value,
                      palette[(i + 1) % palette.length],
                      display:
                          '${e.value.round()} ${e.value == 1 ? 'agent' : 'agents'}',
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search agent name, @handle, owner, model, or fallbacks…',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'All', count: bots.length),
            AdminFilterOption(
              'pending',
              'Review',
              count: count('pending'),
              icon: Icons.rate_review_outlined,
            ),
            AdminFilterOption(
              'approved',
              'Listed',
              count: count('approved'),
              icon: Icons.storefront_outlined,
            ),
            AdminFilterOption(
              'denied',
              'Denied',
              count: count('denied'),
              icon: Icons.block_rounded,
            ),
            AdminFilterOption(
              'unlisted',
              'Unlisted',
              count: count('unlisted'),
              icon: Icons.visibility_off_outlined,
            ),
          ],
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: bots.isEmpty
              ? 'No agents have been created on this node yet.'
              : 'No agents match this search or filter.',
          columns: const [
            AdminTableColumn('Agent', width: 240),
            AdminTableColumn('Owner', width: 140),
            AdminTableColumn('Backbone', width: 200),
            AdminTableColumn('Rate', width: 110, align: TextAlign.right),
            AdminTableColumn('Listing', width: 120),
            AdminTableColumn('Actions', width: 220, align: TextAlign.right),
          ],
          rows: [for (final b in rows) state._agentRow(b, byBot['${b['id']}'])],
        ),
      ],
    );
  }

List<Widget> _buildAgentRow(
  _AppPageContentState state,
    Map<String, dynamic> b,
    Map<String, dynamic>? listing,
  ) {
    final status = '${listing?['status'] ?? 'unlisted'}';
    final name = '${b['name'] ?? b['handle'] ?? 'Agent'}';
    return [
      state._personCell(
        name,
        '@${b['handle'] ?? _shortId(b['id'])}',
        icon: Icons.smart_toy_rounded,
        avatar: _avatarOf(b),
      ),
      Text('@${b['owner_handle'] ?? _shortId(b['owner_id'])}'),
      _primaryCell(
        '${b['model'] ?? 'Default'}',
        '${b['provider'] ?? 'platform'}',
      ),
      Text(
        _perMinute(b['per_minute'] ?? _map(b['cost'])['per_minute']),
        textAlign: TextAlign.right,
      ),
      AdminStatusPill(status == 'approved' ? 'listed' : status),
      Wrap(
        alignment: WrapAlignment.end,
        spacing: 4,
        children: [
          IconButton(
            tooltip: 'Edit agent',
            onPressed: () => state.widget.onAction('bots', 'bot_edit', {
              'bot': b['id'],
              'name': b['name'],
              'instructions': b['instructions'],
              'provider': b['provider'],
              'model': b['model'],
              'cost':
                  b['cost'] ??
                  {if (b['per_minute'] != null) 'per_minute': b['per_minute']},
              '_kind': 'agent',
            }),
            icon: const Icon(Icons.edit_outlined, size: 18),
          ),
          if (status == 'pending') ...[
            IconButton.filledTonal(
              tooltip: 'Approve listing',
              onPressed: () => state.widget.onDirectAction('market', 'approve', {
                'listing': listing?['id'],
                'bot': b['id'],
              }),
              icon: Icon(
                Icons.check_rounded,
                size: 18,
                color: AppColors.successOf(state.context),
              ),
            ),
            IconButton(
              tooltip: 'Deny listing',
              onPressed: () => state.widget.onAction('market', 'deny', {
                'listing': listing?['id'],
                'bot': b['id'],
                '_name': name,
              }),
              icon: Icon(
                Icons.block_rounded,
                size: 18,
                color: AppColors.dangerOf(state.context),
              ),
            ),
          ] else
            IconButton(
              tooltip: status == 'unlisted' ? 'List in market' : 'Unlist',
              onPressed: () => status == 'unlisted'
                  ? state.widget.onAction('market', 'publish', {
                      'bot': b['id'],
                      'type': 'agent',
                      'name': b['name'],
                      'description': b['description'],
                    })
                  : state.widget.onDirectAction('market', 'unpublish', {
                      'listing': listing?['id'],
                    }),
              icon: Icon(
                status == 'unlisted'
                    ? Icons.storefront_outlined
                    : Icons.visibility_off_outlined,
                size: 18,
              ),
            ),
          AppPopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) => state.widget.onAction('bots', 'bot_delete', {
              'bot': b['id'],
              '_name': name,
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('Delete agent'),
                ),
              ),
            ],
          ),
        ],
      ),
    ];
  }

Widget _buildAppsPage(_AppPageContentState state) {
    final bots = _listOfMaps(_map(state.widget.results['admin.bots_list'])['bots'])
        .where((b) {
          final kind = '${b['kind'] ?? ''}';
          return kind == 'tool' || kind == 'mcp';
        })
        .toList();
    // Servers rooms added from the MCP directory (Glama), shared by every room
    // that has one: who is signed in to each, and whether it has a sign-in app.
    final directory = _map(state.widget.results['tools.mcp_directory_list']);
    final fromDirectory = _listOfMaps(directory['servers']);
    final listings = _listOfMaps(
      _map(state.widget.results['market.catalog'])['listings'],
    );
    bool isServer(Map<String, dynamic> b) =>
        '${b['kind']}' == 'mcp' || _map(b['descriptor']).containsKey('url');
    final q = state.search.text.trim().toLowerCase();
    final rows = bots
        .where(
          (b) =>
              q.isEmpty ||
              '${b['name']} ${b['handle']} ${b['kind']} ${b['url']} ${b['description']}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
    final listedIds = listings
        .where((l) => '${l['status']}' == 'approved')
        .map((l) => '${l['bot_id'] ?? l['bot']}')
        .toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Apps',
              value: '${bots.length}',
              icon: Icons.apps_rounded,
            ),
            AdminStatCard(
              label: 'From MCP servers',
              value: '${bots.where(isServer).length}',
              icon: Icons.hub_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
            AdminStatCard(
              label: directory['enabled'] == false
                  ? 'MCP directory (off)'
                  : 'From the MCP directory',
              value: '${fromDirectory.length}',
              icon: Icons.travel_explore_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
            AdminStatCard(
              label: 'In the catalog',
              value:
                  '${bots.where((b) => listedIds.contains('${b['id']}')).length}',
              icon: Icons.storefront_rounded,
              tone: AppColors.successOf(state.context),
              progress: bots.isEmpty
                  ? 0
                  : bots.where((b) => listedIds.contains('${b['id']}')).length /
                        bots.length,
            ),
          ],
        ),
        const SizedBox(height: 18),
        state._toolbar(
          AdminSearchField(
            controller: state.search,
            hint: 'Search apps',
            onChanged: (_) => state.setState(() {}),
          ),
          [
            FilledButton.icon(
              onPressed: () =>
                  state.widget.onAction('tools', 'mcp_register', const {}),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add an app'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        state._appSection('Apps (${rows.length})', rows, listings, isServer),
      ],
    );
  }

Widget _buildAppSection(
  _AppPageContentState state,
    String title,
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> listings,
    bool Function(Map<String, dynamic>) isServer,
  ) {
    return AdminSectionCard(
      title: title,
      icon: Icons.apps_rounded,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: rows.isEmpty
          ? AdminEmptyState(
              'No apps',
              state.search.text.isEmpty
                  ? 'People add apps from the MCP directory in a room’s Apps; add one for everyone by its address.'
                  : 'No apps match your search.',
              icon: Icons.apps_outlined,
            )
          : Column(
              children: [
                for (final b in rows)
                  Builder(
                    builder: (context) {
                      final server = isServer(b);
                      final listing = listings
                          .cast<Map<String, dynamic>?>()
                          .firstWhere(
                            (l) =>
                                '${l?['bot_id'] ?? l?['bot']}' == '${b['id']}',
                            orElse: () => null,
                          );
                      final listed =
                          listing != null &&
                          '${listing['status']}' != 'unlisted';
                      final name = '${b['name'] ?? b['handle'] ?? b['id']}';
                      return state._adaptiveTile(
                        leading: AdminAvatar(
                          name,
                          size: 40,
                          avatar: _avatarOf(b),
                          icon: server ? Icons.hub_rounded : Icons.apps_rounded,
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          [
                            server ? 'MCP server' : 'app',
                            '${b['url'] ?? _map(b['descriptor'])['url'] ?? ''}',
                            _perMinute(
                              b['per_minute'] ?? _map(b['cost'])['per_minute'],
                            ),
                          ].where((v) => v.isNotEmpty && v != '—').join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        actions: [
                          AdminStatusPill(
                            listed ? 'listed' : '${b['status'] ?? 'unlisted'}',
                          ),
                          IconButton(
                            tooltip: 'Edit',
                            onPressed: () => server
                                ? state.widget.onAction('tools', 'mcp_update', {
                                    'bot': b['id'],
                                    'name': b['name'],
                                    'url':
                                        b['url'] ??
                                        _map(b['descriptor'])['url'],
                                    'auth':
                                        b['auth'] ??
                                        _map(b['descriptor'])['auth'],
                                  })
                                : state.widget.onAction('bots', 'bot_edit', {
                                    'bot': b['id'],
                                    'name': b['name'],
                                    'cost':
                                        b['cost'] ??
                                        {
                                          if (b['per_minute'] != null)
                                            'per_minute': b['per_minute'],
                                        },
                                    '_kind': '${b['kind'] ?? 'tool'}',
                                  }),
                            icon: const Icon(Icons.edit_outlined, size: 18),
                          ),
                          if (server)
                            IconButton(
                              tooltip: 'Sign-in client',
                              onPressed: () => state._mcpClient(b, name),
                              icon: const Icon(Icons.key_outlined, size: 18),
                            ),
                          IconButton(
                            tooltip: listed ? 'Unlist' : 'List',
                            onPressed: () => listed
                                ? state.widget.onDirectAction('market', 'unpublish', {
                                    'listing': listing['id'],
                                  })
                                : state.widget.onAction('market', 'publish', {
                                    'bot': b['id'],
                                    'type': '${b['kind'] ?? 'tool'}',
                                    'name': b['name'],
                                    'description': b['description'],
                                  }),
                            icon: Icon(
                              listed
                                  ? Icons.visibility_off_outlined
                                  : Icons.storefront_outlined,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            onPressed: () => state.widget.onAction(
                              server ? 'tools' : 'bots',
                              server ? 'mcp_delete' : 'bot_delete',
                              {'bot': b['id'], '_name': name},
                            ),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
              ],
            ),
    );
  }

Future<void> _buildMcpClient(_AppPageContentState state, Map<String, dynamic> server, String name) async {
    dynamic saved;
    try {
      saved = await state.widget.onDirectAction('tools', 'mcp_oauth_get', {
        'bot': server['id'],
      });
    } catch (_) {
      return; // The console reports the error.
    }
    if (!state.mounted) return;
    final s = _map(saved);
    final fields = {
      for (final k in const [
        'client_id',
        'client_secret',
        'authorization_endpoint',
        'token_endpoint',
        'scopes',
        'params',
      ])
        k: TextEditingController(
          text: k == 'client_secret' ? '' : '${s[k] ?? ''}',
        ),
    };
    const labels = {
      'client_id': 'Client id',
      'client_secret': 'Client secret',
      'authorization_endpoint': 'Authorization endpoint (optional)',
      'token_endpoint': 'Token endpoint (optional)',
      'scopes': 'Scopes (optional)',
      'params': 'Extra sign-in parameters (optional, name=value&…)',
    };
    final body = await showAppDialog<Map<String, dynamic>>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: Text('Sign-in client for $name'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'For a provider that will not register Aseman by itself: create an OAuth client there, then save it here. People sign in with it; its secret stays on the node.',
                ),
                if (state.widget.oauthRedirectUri.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  AdminKeyValue(
                    'Redirect address',
                    state.widget.oauthRedirectUri,
                    mono: true,
                  ),
                ],
                const SizedBox(height: 8),
                for (final e in fields.entries) ...[
                  TextField(
                    controller: e.value,
                    obscureText: e.key == 'client_secret',
                    decoration: InputDecoration(
                      labelText: labels[e.key],
                      hintText:
                          e.key == 'client_secret' && s['has_secret'] == true
                          ? 'Saved. Type a new one to replace it'
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if ('${s['client_id'] ?? ''}'.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(context, {
                'bot': server['id'],
                'client_id': '',
              }),
              child: const Text('Remove client'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'bot': server['id'],
              for (final e in fields.entries)
                if (e.key != 'client_secret' || e.value.text.trim().isNotEmpty)
                  e.key: e.value.text.trim(),
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    for (final c in fields.values) {
      c.dispose();
    }
    if (body == null) return;
    try {
      await state.widget.onDirectAction('tools', 'mcp_oauth_set', body);
    } catch (_) {
      // The console reports the error.
    }
  }

Widget _buildTalentPage(_AppPageContentState state) {
    final response = _map(state.widget.results['users.accounts_list']);
    final all = _listOfMaps(response['accounts'])
        .where((account) => _map(account['profile'])['hireable'] == true)
        .map((account) {
          final profile = _map(account['profile']);
          return <String, dynamic>{
            ...account,
            'name': profile['displayName'] ?? _displayName(account),
            'skills': profile['skills'] ?? const <String>[],
            'rate': profile['rate'] ?? profile['hourlyRate'],
            'status': '${profile['marketStatus'] ?? 'pending'}' == 'denied'
                ? 'rejected'
                : '${profile['marketStatus'] ?? 'pending'}',
          };
        })
        .toList();
    final q = state.search.text.toLowerCase().trim();
    final rows = all.where((t) {
      final status = '${t['status'] ?? 'pending'}';
      return (state.filter == 'all' || state.filter == status) &&
          (q.isEmpty ||
              '${t['name']} ${t['handle']} ${t['username']} ${t['skills']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    int count(String s) => all.where((t) => '${t['status']}' == s).length;
    final skills = <String, double>{};
    for (final t in all) {
      for (final skill in _stringList(t['skills'])) {
        skills[skill] = (skills[skill] ?? 0) + 1;
      }
    }
    final palette = adminPalette(state.context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Review status',
              icon: Icons.badge_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: '${all.length}',
                caption: 'people',
                slices: [
                  AdminChartSlice(
                    'Pending',
                    count('pending').toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                  AdminChartSlice(
                    'Approved',
                    count('approved').toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'Denied',
                    count('rejected').toDouble(),
                    AppColors.dangerOf(state.context),
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Most offered skills',
              icon: Icons.psychology_rounded,
              child: AdminBarList(
                maxItems: 4,
                empty: 'Nobody lists skills yet.',
                items: [
                  for (final e in skills.entries)
                    AdminChartSlice(
                      e.key,
                      e.value,
                      palette[2],
                      display: '${e.value.round()}',
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search name, username, or skills',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption(
              'pending',
              'Pending',
              count: count('pending'),
              icon: Icons.hourglass_empty_rounded,
            ),
            AdminFilterOption(
              'approved',
              'Approved',
              count: count('approved'),
              icon: Icons.verified_outlined,
            ),
            AdminFilterOption(
              'rejected',
              'Denied',
              count: count('rejected'),
              icon: Icons.block_rounded,
            ),
            AdminFilterOption('all', 'All', count: all.length),
          ],
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: all.isEmpty
              ? 'No hireable talent matches this status.'
              : 'No people match your search.',
          columns: const [
            AdminTableColumn('Person', width: 230),
            AdminTableColumn('Skills', width: 300),
            AdminTableColumn('Rate', width: 110, align: TextAlign.right),
            AdminTableColumn('Status', width: 110),
            AdminTableColumn('Actions', width: 200, align: TextAlign.right),
          ],
          rows: [
            for (final t in rows)
              [
                state._personCell(
                  '${t['name'] ?? t['display_name'] ?? 'Person'}',
                  '@${t['handle'] ?? t['username'] ?? 'unknown'}',
                  avatar: _avatarOf(t),
                ),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final skill in _stringList(t['skills']).take(3))
                      _Tag(skill),
                    if (_stringList(t['skills']).length > 3)
                      _Tag('+${_stringList(t['skills']).length - 3}'),
                  ],
                ),
                Text(
                  _credits(t['rate'] ?? t['hourly_rate']),
                  textAlign: TextAlign.right,
                ),
                AdminStatusPill('${t['status'] ?? 'pending'}'),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  children: [
                    if ('${t['status']}' != 'approved')
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            state.widget.onDirectAction('users', 'account_update', {
                              'account': t['id'],
                              'profile': {'marketStatus': 'approved'},
                            }),
                        icon: const Icon(Icons.check_rounded, size: 18),
                        label: const Text('Approve'),
                      ),
                    if ('${t['status']}' != 'rejected')
                      IconButton(
                        tooltip: 'Deny',
                        onPressed: () =>
                            state.widget.onDirectAction('users', 'account_update', {
                              'account': t['id'],
                              'profile': {'marketStatus': 'rejected'},
                            }),
                        icon: Icon(
                          Icons.block_rounded,
                          size: 18,
                          color: AppColors.dangerOf(state.context),
                        ),
                      ),
                  ],
                ),
              ],
          ],
        ),
      ],
    );
  }

Widget _buildTalentRequestsPage(_AppPageContentState state) {
    final scheme = Theme.of(state.context).colorScheme;
    final all = _listOfMaps(
      _map(state.widget.results['talent.admin_requests'])['requests'],
    );
    final keys = _listOfMaps(
      _map(state.widget.results['talent.partner_keys'])['keys'],
    );
    int count(String s) => all.where((r) => '${r['status']}' == s).length;
    final status =
        const ['open', 'closed', 'hidden', 'deleted', 'all'].contains(state.filter)
        ? state.filter
        : 'all';
    final q = state.search.text.toLowerCase().trim();
    final rows =
        all.where((r) {
          final s = '${r['status']}';
          return (status == 'all' ? s != 'deleted' : s == status) &&
              (q.isEmpty ||
                  '${r['title']} ${r['category']} ${r['company']} ${r['owner_handle']} ${_stringList(r['skills']).join(' ')}'
                      .toLowerCase()
                      .contains(q));
        }).toList()..sort(
          (a, b) =>
              '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}'),
        );
    String budget(Map<String, dynamic> r) {
      final amount = compactDecimal(_number(r['budget_amount']), decimals: 2);
      return switch ('${r['budget_type']}') {
        'hourly' => '\$$amount / hour',
        'monthly' => '\$$amount / month',
        _ => '\$$amount fixed',
      };
    }

    Future<void> setStatus(Map<String, dynamic> r, String to) async {
      try {
        await state.widget.onDirectAction('talent', 'admin_request_status', {
          'id': r['id'],
          'status': to,
        });
      } catch (_) {
        // The console reports the error.
      }
    }

    final activeKeys = keys.where((k) => '${k['status']}' == 'active').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 3,
          children: [
            AdminStatCard(
              label: 'Open requests',
              value: '${count('open')}',
              hint: 'What partners read now',
              icon: Icons.work_rounded,
              tone: AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Taken down',
              value: '${count('hidden')}',
              hint: 'Removed by an admin',
              icon: Icons.visibility_off_rounded,
              tone: count('hidden') == 0 ? null : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Partner keys',
              value: '$activeKeys',
              hint: '${keys.length - activeKeys} revoked',
              icon: Icons.key_rounded,
            ),
          ],
        ),
        const SizedBox(height: 18),
        state._toolbar(
          AdminSearchField(
            controller: state.search,
            hint: 'Search title, category, company or poster',
            onChanged: (_) => state.setState(() {}),
          ),
          const [],
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: status,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption(
              'all',
              'All',
              count: all.where((r) => '${r['status']}' != 'deleted').length,
            ),
            AdminFilterOption('open', 'Open', count: count('open')),
            AdminFilterOption('closed', 'Closed', count: count('closed')),
            AdminFilterOption('hidden', 'Taken down', count: count('hidden')),
            AdminFilterOption('deleted', 'Deleted', count: count('deleted')),
          ],
        ),
        const SizedBox(height: 12),
        AdminSectionCard(
          title: 'Requests',
          icon: Icons.work_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: rows.isEmpty
              ? const AdminEmptyState(
                  'No requests',
                  'Jobs people post for talent show up here.',
                  icon: Icons.work_outline_rounded,
                )
              : Column(
                  children: [
                    for (final r in rows)
                      ExpansionTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        collapsedShape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        leading: AdminAvatar(
                          '${r['title']}',
                          icon: Icons.work_rounded,
                          size: 40,
                        ),
                        title: Text(
                          '${r['title']}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${r['category']} · ${budget(r)} · @${r['owner_handle'] ?? '—'} · ${_date(r['created_at'])}',
                        ),
                        trailing: AdminStatusPill(
                          '${r['status']}' == 'hidden'
                              ? 'removed'
                              : '${r['status']}',
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          14,
                        ),
                        expandedCrossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AdminKeyValue('Company', '${r['company'] ?? '—'}'),
                          if ('${r['timeline'] ?? ''}'.isNotEmpty)
                            AdminKeyValue(
                              'Timeline',
                              _humanKey(
                                '${r['timeline']}'.replaceAll('lt_', 'under '),
                              ).toLowerCase(),
                            ),
                          if (_stringList(r['skills']).isNotEmpty)
                            AdminKeyValue(
                              'Skills',
                              _stringList(r['skills']).join(', '),
                            ),
                          const SizedBox(height: 6),
                          KeyedSubtree(
                            key: PageStorageKey<String>('request:${r['id']}'),
                            child: SelectableText(
                              '${r['description'] ?? ''}',
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if ('${r['status']}' != 'deleted') ...[
                            const SizedBox(height: 10),
                            Align(
                              alignment: Alignment.centerRight,
                              child: '${r['status']}' == 'hidden'
                                  ? OutlinedButton.icon(
                                      onPressed: () => setStatus(r, 'open'),
                                      icon: const Icon(
                                        Icons.undo_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('Restore'),
                                    )
                                  : OutlinedButton.icon(
                                      onPressed: () => setStatus(r, 'hidden'),
                                      icon: const Icon(
                                        Icons.visibility_off_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('Take down'),
                                    ),
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Partner keys',
          icon: Icons.key_rounded,
          subtitle:
              'Partners read the open requests on the developer host: GET /v1/partner/talent-requests with Authorization: Bearer pk_live_….',
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                child: FilledButton.icon(
                  onPressed: state._createPartnerKey,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('New partner key'),
                ),
              ),
              if (keys.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('No partner keys yet.', style: state._muted()),
                )
              else
                for (final k in keys)
                  state._adaptiveTile(
                    leading: AdminAvatar(
                      '${k['name']}',
                      icon: Icons.key_rounded,
                    ),
                    title: Text(
                      '${k['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: SelectableText(
                      '${k['prefix']}…${k['last4']} · ${_integer(k['requests'])} calls · last used ${_date(k['last_used_at'])}',
                    ),
                    actions: [
                      AdminStatusPill('${k['status']}'),
                      if ('${k['status']}' == 'active')
                        TextButton(
                          onPressed: () => state._revokePartnerKey(k),
                          child: const Text('Revoke'),
                        ),
                    ],
                  ),
            ],
          ),
        ),
      ],
    );
  }

Future<void> _buildCreatePartnerKey(_AppPageContentState state) async {
    final controller = TextEditingController();
    final name = await showAppDialog<String>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: const Text('New partner key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Partner name',
            hintText: 'Acme Recruiting',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !state.mounted) return;
    dynamic result;
    try {
      result = await state.widget.onDirectAction('talent', 'partner_key_create', {
        'name': name.trim(),
      });
    } catch (_) {
      return; // The console reports the error.
    }
    final secret = '${_map(result)['secret'] ?? ''}';
    if (secret.isEmpty || !state.mounted) return;
    await showAppDialog<void>(
      context: state.context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: const Text('Copy the key now'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'It is shown only this once. Give it to the partner; only its last four characters are kept.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              secret,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

Future<void> _buildRevokePartnerKey(_AppPageContentState state, Map<String, dynamic> key) async {
    final ok = await showAppDialog<bool>(
      context: state.context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_off_rounded),
        title: Text('Revoke ${key['name']}?'),
        content: const Text(
          'The partner can no longer read requests with it. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await state.widget.onDirectAction('talent', 'partner_key_revoke', {
        'id': key['id'],
      });
    } catch (_) {
      // The console reports the error.
    }
  }
