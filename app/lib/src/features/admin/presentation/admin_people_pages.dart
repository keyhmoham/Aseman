part of 'admin_page_content.dart';


Widget _buildOverviewPage(_AppPageContentState state) {
    final scheme = Theme.of(state.context).colorScheme;
    final stats = _map(state.widget.results['admin.stats']);
    final counters = _map(stats['counters']).isNotEmpty
        ? _map(stats['counters'])
        : stats;
    final health = _map(state.widget.results['admin.health']);
    final counts = _map(health['counts']);
    final runs = _listOfMaps(_map(state.widget.results['admin.runs_list'])['runs']);
    final payouts = _listOfMaps(
      _map(state.widget.results['finance.payouts_list'])['payouts'] ??
          _map(state.widget.results['finance.payouts_list'])['requests'],
    );
    final listings = _listOfMaps(
      _map(state.widget.results['market.catalog'])['listings'],
    );
    final resources = _map(
      _map(state.widget.results['admin.node_stats'])['resources'],
    );
    final pendingPayouts = payouts
        .where((p) => '${p['status']}' == 'pending')
        .toList();
    final pendingListings = listings
        .where((l) => '${l['status']}' == 'pending')
        .length;
    final fail = _integer(counts['fail']);
    final warn = _integer(counts['warn']);
    final ok = _integer(counts['ok']);
    final runTones = <AdminTone, int>{};
    for (final r in runs) {
      final tone = adminTone('${r['status']}');
      runTones[tone] = (runTones[tone] ?? 0) + 1;
    }
    final failedRuns = runTones[AdminTone.bad] ?? 0;
    final needs = <({String text, String target, Color tone, IconData icon})>[
      if (fail > 0)
        (
          text:
              '$fail deploy ${fail == 1 ? 'check needs' : 'checks need'} fixing',
          target: 'Health',
          tone: AppColors.dangerOf(state.context),
          icon: Icons.gpp_maybe_rounded,
        ),
      if (pendingPayouts.isNotEmpty)
        (
          text:
              '${pendingPayouts.length} payout ${pendingPayouts.length == 1 ? 'request' : 'requests'} · ${_money(_sum(pendingPayouts, 'amount'))}',
          target: 'Finance · Payouts',
          tone: AppColors.warningOf(state.context),
          icon: Icons.payments_rounded,
        ),
      if (pendingListings > 0)
        (
          text:
              '$pendingListings marketplace ${pendingListings == 1 ? 'listing waits' : 'listings wait'} for review',
          target: 'Agents',
          tone: AppColors.warningOf(state.context),
          icon: Icons.rate_review_rounded,
        ),
      if (failedRuns > 0)
        (
          text:
              '$failedRuns agent ${failedRuns == 1 ? 'run' : 'runs'} failed recently',
          target: 'Projects',
          tone: AppColors.dangerOf(state.context),
          icon: Icons.running_with_errors_rounded,
        ),
      if (warn > 0)
        (
          text:
              '$warn deployment ${warn == 1 ? 'check is' : 'checks are'} worth a look',
          target: 'Health',
          tone: AppColors.warningOf(state.context),
          icon: Icons.tips_and_updates_rounded,
        ),
    ];
    final checks = ok + warn + fail;
    final score = checks == 0 ? 1.0 : ok / checks;
    final cores = _number(resources['cpu_cores'], fallback: 1);
    final load = _doubleList(resources['load_avg']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminHeroCard(
          icon: needs.isEmpty
              ? Icons.verified_rounded
              : Icons.notifications_active_rounded,
          title: needs.isEmpty
              ? 'All clear'
              : '${needs.length} ${needs.length == 1 ? 'thing needs' : 'things need'} you',
          message: needs.isEmpty
              ? 'No reviews, payouts or failing checks are waiting.'
              : 'Start with the most urgent below; everything else is running.',
          visual: AdminGauge(
            value: score,
            label: 'health',
            size: 128,
            color: fail > 0
                ? AppColors.dangerOf(state.context)
                : warn > 0
                ? AppColors.warningOf(state.context)
                : AppColors.successOf(state.context),
            display: checks == 0 ? '—' : '$ok/$checks',
          ),
        ),
        if (needs.isNotEmpty) ...[
          const SizedBox(height: 14),
          AdminSectionCard(
            title: 'Needs you',
            icon: Icons.inbox_rounded,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: Column(
              children: [
                for (final item in needs)
                  ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                    ),
                    leading: Container(
                      width: 40,
                      height: 40,
                      decoration: ShapeDecoration(
                        color: item.tone.withValues(alpha: .16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Icon(item.icon, color: item.tone, size: 21),
                    ),
                    title: Text(
                      item.text,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(item.target),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => state.widget.onNavigate(item.target),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 22),
        state._heading('Platform'),
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Users',
              value: _compact(counters['users'] ?? counters['accounts']),
              hint: 'Accounts and wallets',
              icon: Icons.people_rounded,
              onTap: () => state.widget.onNavigate('Users'),
            ),
            AdminStatCard(
              label: 'Projects',
              value: _compact(counters['projects'] ?? counters['spaces']),
              hint: 'Workspaces and machines',
              icon: Icons.folder_rounded,
              tone: AppColors.cyanOf(state.context),
              onTap: () => state.widget.onNavigate('Projects'),
            ),
            AdminStatCard(
              label: 'Bots',
              value: _compact(counters['bots']),
              hint: 'Agents and apps',
              icon: Icons.smart_toy_rounded,
              tone: AppColors.successOf(state.context),
              onTap: () => state.widget.onNavigate('Agents'),
            ),
            AdminStatCard(
              label: 'Agent runs',
              value: _compact(counters['room_turns']),
              hint: 'Turns across all projects',
              icon: Icons.play_circle_rounded,
              tone: AppColors.warningOf(state.context),
              onTap: () => state.widget.onNavigate('Projects'),
            ),
          ],
        ),
        const SizedBox(height: 22),
        AdminGrid(
          maxColumns: 3,
          minTileWidth: 300,
          children: [
            AdminSectionCard(
              title: 'Deployment checks',
              icon: Icons.monitor_heart_rounded,
              trailing: TextButton(
                onPressed: () => state.widget.onNavigate('Health'),
                child: const Text('Open'),
              ),
              child: AdminDonutPanel(
                size: 132,
                center: '$checks',
                caption: 'checks',
                slices: [
                  AdminChartSlice('Healthy', ok.toDouble(), AppColors.successOf(state.context)),
                  AdminChartSlice(
                    'Worth a look',
                    warn.toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                  AdminChartSlice(
                    'Need fixing',
                    fail.toDouble(),
                    AppColors.dangerOf(state.context),
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Recent agent runs',
              icon: Icons.play_circle_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: '${runs.length}',
                caption: 'runs',
                emptyLabel: 'No runs yet',
                slices: [
                  AdminChartSlice(
                    'Finished',
                    (runTones[AdminTone.ok] ?? 0).toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'In progress',
                    (runTones[AdminTone.warn] ?? 0).toDouble(),
                    AppColors.cyanOf(state.context),
                  ),
                  AdminChartSlice(
                    'Failed',
                    failedRuns.toDouble(),
                    AppColors.dangerOf(state.context),
                  ),
                  AdminChartSlice(
                    'Other',
                    (runTones[AdminTone.neutral] ?? 0).toDouble(),
                    scheme.outline,
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'This node',
              icon: Icons.dns_rounded,
              trailing: TextButton(
                onPressed: () => state.widget.onNavigate('Node · Host'),
                child: const Text('Live'),
              ),
              child: resources.isEmpty
                  ? Text('No host reading yet.', style: state._muted())
                  : Wrap(
                      alignment: WrapAlignment.spaceAround,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'CPU',
                          value:
                              (load.isEmpty ? 0 : load.first) /
                              (cores == 0 ? 1 : cores),
                        ),
                        AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'Memory',
                          value: _number(resources['mem_used_percent']) / 100,
                        ),
                        AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'Disk',
                          value: _number(resources['disk_used_percent']) / 100,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ],
    );
  }

Widget _buildUsersPage(_AppPageContentState state) {
    final accounts = _listOfMaps(
      _map(state.widget.results['users.accounts_list'])['accounts'],
    );
    final admins = _listOfMaps(
      _map(state.widget.results['admin.admins_list'])['admins'],
    );
    final adminIds = admins.map((a) => '${a['id']}').toSet();
    bool isAdmin(Map<String, dynamic> a) =>
        a['is_admin'] == true ||
        '${a['role']}' == 'admin' ||
        adminIds.contains('${a['id']}');
    String status(Map<String, dynamic> a) =>
        '${a['status'] ?? 'active'}'.toLowerCase();
    final q = state.search.text.trim().toLowerCase();
    final rows = accounts.where((a) {
      if (state.filter == 'admin' && !isAdmin(a)) return false;
      if (state.filter != 'all' && state.filter != 'admin' && state.filter != status(a)) {
        return false;
      }
      return q.isEmpty ||
          '${a['handle']} ${a['email']} ${a['id']} ${jsonEncode(a['profile'] ?? {})}'
              .toLowerCase()
              .contains(q);
    }).toList();
    final active = accounts.where((a) => status(a) == 'active').length;
    final disabled = accounts.where((a) => status(a) == 'disabled').length;
    final pending = accounts.where((a) => status(a) == 'pending').length;
    final adminCount = accounts.where(isAdmin).length;
    final palette = adminPalette(state.context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Accounts',
              icon: Icons.people_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: '${accounts.length}',
                caption: 'accounts',
                slices: [
                  AdminChartSlice(
                    'Active',
                    active.toDouble(),
                    AppColors.successOf(state.context),
                  ),
                  AdminChartSlice(
                    'Pending',
                    pending.toDouble(),
                    AppColors.warningOf(state.context),
                  ),
                  AdminChartSlice(
                    'Disabled',
                    disabled.toDouble(),
                    AppColors.dangerOf(state.context),
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Largest wallets',
              icon: Icons.account_balance_wallet_rounded,
              child: AdminBarList(
                maxItems: 4,
                empty: 'No wallet holds credits yet.',
                items: [
                  for (var i = 0; i < accounts.length; i++)
                    AdminChartSlice(
                      _displayName(accounts[i]),
                      _number(accounts[i]['balance']),
                      palette[1],
                      display: _credits(accounts[i]['balance']),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search name, handle, email, or user id',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'Everyone', count: accounts.length),
            AdminFilterOption(
              'active',
              'Active',
              count: active,
              icon: Icons.check_circle_outline_rounded,
            ),
            if (pending > 0)
              AdminFilterOption(
                'pending',
                'Pending',
                count: pending,
                icon: Icons.hourglass_empty_rounded,
              ),
            AdminFilterOption(
              'disabled',
              'Blocked',
              count: disabled,
              icon: Icons.block_rounded,
            ),
            AdminFilterOption(
              'admin',
              'Admins',
              count: adminCount,
              icon: Icons.shield_outlined,
            ),
          ],
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: q.isEmpty ? 'No accounts registered yet.' : 'No users match.',
          onRowTap: (index) => state._showUser(rows[index]),
          columns: const [
            AdminTableColumn('User', width: 220),
            AdminTableColumn('Email', width: 210),
            AdminTableColumn('Role', width: 100),
            AdminTableColumn('Status', width: 110),
            AdminTableColumn('Balance', width: 110, align: TextAlign.right),
            AdminTableColumn('Last seen', width: 130),
            // Three 48 px icon buttons plus cell padding, on one line.
            AdminTableColumn('Actions', width: 172, align: TextAlign.right),
          ],
          rows: [
            for (final a in rows)
              [
                state._personCell(
                  _displayName(a),
                  '@${a['handle'] ?? 'unknown'}',
                  avatar: _avatarOf(a),
                ),
                Text('${a['email'] ?? '—'}'),
                isAdmin(a)
                    ? const _RoleBadge(admin: true)
                    : const _RoleBadge(admin: false),
                AdminStatusPill(status(a)),
                Text(_credits(a['balance']), textAlign: TextAlign.right),
                Text(_date(a['last_seen'] ?? a['created_at'])),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 3,
                  children: [
                    IconButton(
                      tooltip: 'Edit profile and access',
                      onPressed: () => state._editUser(a),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
                    IconButton(
                      tooltip: 'Grant credits',
                      onPressed: () => state.widget.onAction(
                        'finance',
                        'wallet_mint',
                        {'target': a['id'], '_name': _displayName(a)},
                      ),
                      icon: const Icon(Icons.add_card_rounded, size: 18),
                    ),
                    AppPopupMenuButton<String>(
                      tooltip: 'More actions',
                      onSelected: (value) {
                        if (value == 'password') {
                          state.widget.onAction('users', 'account_password', {
                            'account': a['id'],
                            '_name': _displayName(a),
                          });
                        } else if (value == 'ledger') {
                          state._showUser(a, tab: 2);
                        } else {
                          state.widget.onAction('users', 'account_delete', {
                            'account': a['id'],
                            '_name': _displayName(a),
                          });
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'password',
                          child: ListTile(
                            leading: Icon(Icons.password_rounded),
                            title: Text('Set password'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'ledger',
                          child: ListTile(
                            leading: Icon(Icons.receipt_long_rounded),
                            title: Text('Wallet activity'),
                          ),
                        ),
                        PopupMenuDivider(),
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline_rounded),
                            title: Text('Delete account'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
          ],
        ),
        const SizedBox(height: 10),
        Text('${rows.length} of ${accounts.length} users', style: state._muted()),
      ],
    );
  }

void _buildEditUser(_AppPageContentState state, Map<String, dynamic> a) =>
      state.widget.onAction('users', 'account_update', {
        'account': a['id'],
        'handle': a['handle'],
        'email': a['email'],
        'role': a['role'],
        'is_admin': a['is_admin'],
        'status': a['status'],
        'profile': a['profile'] ?? <String, dynamic>{},
      });

Widget _buildProjectsPage(_AppPageContentState state) {
    final spaces = _listOfMaps(
      _map(state.widget.results['spaces.space_list_all'])['spaces'],
    );
    final q = state.search.text.trim().toLowerCase();
    final rows = spaces.where((s) {
      if (state.filter == 'awake' && _machineState(s) != 'awake') return false;
      if (state.filter == 'asleep' && _machineState(s) == 'awake') return false;
      return q.isEmpty ||
          '${s['name']} ${s['id']} ${s['owner_id']} ${_map(s['owner'])['handle']}'
              .toLowerCase()
              .contains(q);
    }).toList();
    rows.sort((a, b) {
      dynamic av;
      dynamic bv;
      if (state.sort == 'title') {
        av = '${a['name'] ?? a['id']}'.toLowerCase();
        bv = '${b['name'] ?? b['id']}'.toLowerCase();
      } else if (state.sort == 'owner') {
        av = '${_map(a['owner'])['handle'] ?? a['owner_id']}'.toLowerCase();
        bv = '${_map(b['owner'])['handle'] ?? b['owner_id']}'.toLowerCase();
      } else if (state.sort == 'spend') {
        av = _number(a['spent'] ?? _map(a['usage'])['spent']);
        bv = _number(b['spent'] ?? _map(b['usage'])['spent']);
      } else {
        av = '${a['created_at'] ?? ''}';
        bv = '${b['created_at'] ?? ''}';
      }
      final order = Comparable.compare(av as Comparable, bv as Comparable);
      return state.ascending ? order : -order;
    });
    final awake = spaces.where((s) => _machineState(s) == 'awake').length;
    final totalSpend = spaces.fold<double>(
      0,
      (sum, s) => sum + _number(s['spent'] ?? _map(s['usage'])['spent']),
    );
    final palette = adminPalette(state.context);
    final adminsSpace = _map(state.widget.results['spaces.admins_space_get']);
    final adminsSpaceId = '${_map(adminsSpace['space'])['id'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        state._adminsSpaceCard(spaces, adminsSpace),
        const SizedBox(height: 18),
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'Computers',
              icon: Icons.computer_rounded,
              subtitle: 'Awake computers are billed by the minute.',
              child: AdminDonutPanel(
                size: 132,
                center: '${spaces.length}',
                caption: 'projects',
                slices: [
                  AdminChartSlice('Awake', awake.toDouble(), AppColors.successOf(state.context)),
                  AdminChartSlice(
                    'Asleep or none',
                    (spaces.length - awake).toDouble(),
                    palette.first,
                  ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Top spenders',
              icon: Icons.trending_up_rounded,
              subtitle: 'Total ${_credits(totalSpend)} across projects',
              child: AdminBarList(
                maxItems: 4,
                empty: 'No project has spent anything yet.',
                items: [
                  for (final s in spaces)
                    AdminChartSlice(
                      '${s['name'] ?? s['id']}',
                      _number(s['spent'] ?? _map(s['usage'])['spent']),
                      palette[1],
                      display: _credits(
                        s['spent'] ?? _map(s['usage'])['spent'],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search title, id, or owner handle',
          onChanged: (_) => state.setState(() {}),
          trailing: AppPopupMenuButton<String>(
            tooltip: 'Sort projects',
            icon: const Icon(Icons.sort_rounded),
            onSelected: (value) => state.setState(() {
              if (state.sort == value) {
                state.ascending = !state.ascending;
              } else {
                state.sort = value;
                state.ascending = value == 'title' || value == 'owner';
              }
            }),
            itemBuilder: (_) => [
              for (final (value, label, icon) in const [
                ('created', 'Newest first', Icons.schedule_rounded),
                ('spend', 'Most spent', Icons.payments_outlined),
                ('title', 'Title', Icons.sort_by_alpha_rounded),
                ('owner', 'Owner', Icons.person_outline_rounded),
              ])
                CheckedPopupMenuItem(
                  value: value,
                  checked: state.sort == value,
                  child: Row(
                    children: [
                      Icon(icon, size: 18),
                      const SizedBox(width: 10),
                      Text(label),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'All projects', count: spaces.length),
            AdminFilterOption(
              'awake',
              'Awake',
              count: awake,
              icon: Icons.bolt_rounded,
            ),
            AdminFilterOption(
              'asleep',
              'Asleep',
              count: spaces.length - awake,
              icon: Icons.bedtime_outlined,
            ),
          ],
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: spaces.isEmpty
              ? 'No projects created yet.'
              : 'No projects match.',
          onRowTap: (index) => state._showProject(rows[index]),
          columns: const [
            AdminTableColumn('Project', width: 260),
            AdminTableColumn('Owner', width: 160),
            AdminTableColumn('Agents', width: 90, align: TextAlign.right),
            AdminTableColumn('Machine', width: 120),
            AdminTableColumn('Spend', width: 120, align: TextAlign.right),
            AdminTableColumn('Created', width: 150),
          ],
          rows: [
            for (final s in rows)
              [
                Row(
                  children: [
                    AdminAvatar(
                      '${s['name'] ?? s['id']}',
                      size: 34,
                      avatar: _avatarOf(s),
                      icon: '${s['id']}' == adminsSpaceId
                          ? Icons.admin_panel_settings_rounded
                          : s['home'] == true
                          ? Icons.home_rounded
                          : Icons.folder_rounded,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _primaryCell(
                        '${s['name'] ?? s['id']}',
                        '${'${s['id']}' == adminsSpaceId ? 'Admins space · ' : ''}${s['home'] == true ? 'Home · ' : ''}${_shortId(s['id'])}',
                      ),
                    ),
                  ],
                ),
                Text(_owner(s)),
                Text(
                  '${s['agents'] ?? _list(s['workers']).length}',
                  textAlign: TextAlign.right,
                ),
                AdminStatusPill(_machineState(s)),
                Text(
                  _credits(s['spent'] ?? _map(s['usage'])['spent']),
                  textAlign: TextAlign.right,
                ),
                Text(_date(s['created_at'])),
              ],
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${rows.length} projects · tap a row for overview, machine, cost, storage, logs, and people',
          style: state._muted(),
        ),
      ],
    );
  }

Widget _buildAdminsSpaceCard(
  _AppPageContentState state,
    List<Map<String, dynamic>> spaces,
    Map<String, dynamic> current,
  ) {
    final scheme = Theme.of(state.context).colorScheme;
    final chosen = _map(current['space']);
    final missing = '${current['missing'] ?? ''}';
    final admins = _listOfMaps(
      _map(state.widget.results['admin.admins_list'])['admins'],
    );
    final name = '${chosen['name'] ?? chosen['id'] ?? ''}';
    final choose = FilledButton.tonalIcon(
      onPressed: () => state._pickAdminsSpace(spaces, '${chosen['id'] ?? ''}'),
      icon: Icon(
        chosen.isEmpty ? Icons.add_rounded : Icons.swap_horiz_rounded,
        size: 18,
      ),
      label: Text(chosen.isEmpty ? 'Choose project' : 'Change'),
    );
    return AdminSectionCard(
      title: 'Platform admins space',
      icon: Icons.admin_panel_settings_rounded,
      subtitle:
          'Every platform admin is added to this project automatically, now and whenever someone is made an admin. Its agents and apps can read the platform database when they work for an admin.',
      child: state._toolbar(
        Row(
          children: [
            AdminAvatar(
              chosen.isEmpty ? '?' : name,
              size: 40,
              icon: chosen.isEmpty
                  ? Icons.folder_off_outlined
                  : Icons.admin_panel_settings_rounded,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: chosen.isEmpty
                  ? Text(
                      missing.isNotEmpty
                          ? 'The chosen project was deleted. Choose another one.'
                          : 'No project chosen. Admins are not added anywhere.',
                      style: missing.isNotEmpty
                          ? TextStyle(color: scheme.error)
                          : state._muted(),
                    )
                  : _primaryCell(
                      name,
                      '${admins.isEmpty ? 'Admins' : '${admins.length} ${admins.length == 1 ? 'admin' : 'admins'}'} are members · ${_shortId(chosen['id'])}',
                    ),
            ),
          ],
        ),
        [
          if (chosen.isNotEmpty)
            OutlinedButton(
              onPressed: () => state._showProject({...chosen}),
              child: const Text('Open'),
            ),
          if (chosen.isNotEmpty || missing.isNotEmpty)
            TextButton(
              onPressed: () async {
                if (await state._confirm(
                  'Stop using an admins space?',
                  'Admins already in ${chosen.isEmpty ? 'the project' : name} stay members; new admins are no longer added.',
                  'Stop',
                )) {
                  await state.widget.onDirectAction('spaces', 'admins_space_set', {
                    'space': '',
                  });
                }
              },
              child: const Text('Clear'),
            ),
          choose,
        ],
      ),
    );
  }

Future<void> _buildPickAdminsSpace(
  _AppPageContentState state,
    List<Map<String, dynamic>> spaces,
    String currentId,
  ) async {
    // Direct conversations are between two accounts and cannot take members.
    final candidates =
        spaces.where((s) => '${s['direct_key'] ?? ''}'.isEmpty).toList()..sort(
          (a, b) => '${a['name'] ?? a['id']}'.toLowerCase().compareTo(
            '${b['name'] ?? b['id']}'.toLowerCase(),
          ),
        );
    final picked = await showAppDialog<Map<String, dynamic>>(
      context: state.context,
      builder: (context) =>
          _AdminsSpacePicker(projects: candidates, currentId: currentId),
    );
    if (picked == null || '${picked['id']}' == currentId) return;
    await state.widget.onDirectAction('spaces', 'admins_space_set', {
      'space': '${picked['id']}',
    });
  }

Widget _buildChatReportsPage(_AppPageContentState state) {
    final scheme = Theme.of(state.context).colorScheme;
    final response = _map(state.widget.results['spaces.admin_chat_reports']);
    final reports = _listOfMaps(response['reports']);
    final open = _integer(response['open']);
    const statuses = ['open', 'resolved', 'dismissed', 'all'];
    final status = state.reportStatus;
    String person(dynamic ref) {
      final m = _map(ref);
      final name = '${m['display_name'] ?? ''}'.trim();
      final handle = '${m['handle'] ?? ''}'.trim();
      if (name.isNotEmpty && handle.isNotEmpty) return '$name (@$handle)';
      return name.isNotEmpty
          ? name
          : handle.isNotEmpty
          ? '@$handle'
          : 'Unknown';
    }

    Future<void> resolve(Map<String, dynamic> r, String to) async {
      try {
        await state.widget.onDirectAction('spaces', 'admin_chat_report_resolve', {
          'id': r['id'],
          'status': to,
        });
      } catch (_) {
        // The console reports the error.
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          children: [
            AdminStatCard(
              label: 'Open reports',
              value: '$open',
              hint: open == 0
                  ? 'Nothing waits for a decision.'
                  : 'Read the copied messages, then resolve or dismiss.',
              icon: Icons.flag_rounded,
              tone: open == 0 ? AppColors.successOf(state.context) : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Shown',
              value: '${reports.length}',
              hint: status == 'all' ? 'Every report' : 'Reports $status',
              icon: Icons.inbox_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in statuses)
              ChoiceChip(
                label: Text(s[0].toUpperCase() + s.substring(1)),
                selected: s == status,
                onSelected: (_) {
                  state.setState(() => state.reportStatus = s);
                  state.widget.onQuery?.call('spaces.admin_chat_reports', {
                    'status': s,
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        AdminSectionCard(
          title: 'Reports',
          icon: Icons.flag_rounded,
          subtitle:
              'Each report carries a copy of the messages as they were when it was filed.',
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: reports.isEmpty
              ? const AdminEmptyState(
                  'No reports',
                  'What people report in their chats shows up here.',
                  icon: Icons.flag_outlined,
                )
              : Column(
                  children: [
                    for (final r in reports)
                      ExpansionTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        collapsedShape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        leading: AdminAvatar(
                          person(r['accused']),
                          icon: Icons.flag_rounded,
                          size: 40,
                          avatar: _avatarOf(r['accused']),
                        ),
                        title: Text(
                          '${_humanKey('${r['reason'] ?? 'other'}')} · ${r['kind'] == 'message' ? 'a message' : 'a chat'}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          'About ${person(r['accused'])} · by ${person(r['reporter'])} · ${_date(r['created_at'])}',
                        ),
                        trailing: AdminStatusPill('${r['status'] ?? 'open'}'),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          14,
                        ),
                        children: [
                          AdminKeyValue(
                            'Where',
                            r['direct'] == true
                                ? 'Direct chat'
                                : '${r['space_name'] ?? 'Room'}',
                          ),
                          if ('${r['note'] ?? ''}'.isNotEmpty)
                            AdminKeyValue('Note', '${r['note']}'),
                          if (r['resolved_by'] != null)
                            AdminKeyValue(
                              'Decided by',
                              '${person(r['resolved_by'])} · ${_date(r['resolved_at'])}',
                            ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'MESSAGES',
                              style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final m in _listOfMaps(r['evidence']))
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: '${m['id']}' == '${r['message_id']}'
                                    ? scheme.errorContainer
                                    : scheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(AppShape.innerOf(state.context),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${person(m['sender'])} · ${_date(m['created_at'])}${m['edited_at'] != null ? ' · edited' : ''}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  KeyedSubtree(
                                    key: PageStorageKey<String>(
                                      'evidence:${r['id']}:${m['id']}',
                                    ),
                                    child: SelectableText(
                                      '${m['body'] ?? ''}'.isEmpty
                                          ? '(${m['attachments'] ?? 0} attachment(s))'
                                          : '${m['body']}',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if ('${r['status']}' == 'open') ...[
                                OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'dismissed'),
                                  icon: const Icon(
                                    Icons.do_not_disturb_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Dismiss'),
                                ),
                                FilledButton.icon(
                                  onPressed: () => resolve(r, 'resolved'),
                                  icon: const Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Mark resolved'),
                                ),
                              ] else
                                OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'open'),
                                  icon: const Icon(
                                    Icons.undo_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Reopen'),
                                ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }

Widget _buildPostReportsPage(_AppPageContentState state) {
    final scheme = Theme.of(state.context).colorScheme;
    final response = _map(state.widget.results['posts.admin_post_reports']);
    final reports = _listOfMaps(response['reports']);
    final open = _integer(response['open']);
    const statuses = ['open', 'resolved', 'dismissed', 'all'];
    final status = state.postReportStatus;
    String person(dynamic ref) {
      final m = _map(ref);
      final name = '${m['display_name'] ?? ''}'.trim();
      final handle = '${m['handle'] ?? ''}'.trim();
      if (name.isNotEmpty && handle.isNotEmpty && name != handle) {
        return '$name (@$handle)';
      }
      return handle.isNotEmpty
          ? '@$handle'
          : name.isNotEmpty
          ? name
          : 'Unknown';
    }

    Future<void> resolve(
      Map<String, dynamic> r,
      String to, {
      bool remove = false,
    }) async {
      try {
        await state.widget.onDirectAction('posts', 'admin_post_report_resolve', {
          'id': r['id'],
          'status': to,
          if (remove) 'remove_post': true,
        });
      } catch (_) {
        // The console reports the error.
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 2,
          children: [
            AdminStatCard(
              label: 'Open reports',
              value: '$open',
              hint: open == 0
                  ? 'Nothing waits for a decision.'
                  : 'Read the reported post, then remove it, resolve or dismiss.',
              icon: Icons.report_rounded,
              tone: open == 0 ? AppColors.successOf(state.context) : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Shown',
              value: '${reports.length}',
              hint: status == 'all' ? 'Every report' : 'Reports $status',
              icon: Icons.inbox_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in statuses)
              ChoiceChip(
                label: Text(s[0].toUpperCase() + s.substring(1)),
                selected: s == status,
                onSelected: (_) {
                  state.setState(() => state.postReportStatus = s);
                  state.widget.onQuery?.call('posts.admin_post_reports', {
                    'status': s,
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        AdminSectionCard(
          title: 'Reports',
          icon: Icons.report_rounded,
          subtitle:
              'Each report carries a copy of the post as it was when it was filed.',
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: reports.isEmpty
              ? const AdminEmptyState(
                  'No reports',
                  'Posts people report in the feed show up here.',
                  icon: Icons.report_outlined,
                )
              : Column(
                  children: [
                    for (final r in reports)
                      ExpansionTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        collapsedShape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        leading: AdminAvatar(
                          person(r['accused']),
                          icon: Icons.report_rounded,
                          size: 40,
                          avatar: _avatarOf(r['accused']),
                        ),
                        title: Text(
                          '${_humanKey('${r['reason'] ?? 'other'}')} · a post${r['deleted'] == true ? ' (removed)' : ''}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          'By ${person(r['accused'])} · reported by ${person(r['reporter'])} · ${_date(r['created_at'])}',
                        ),
                        trailing: AdminStatusPill('${r['status'] ?? 'open'}'),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          14,
                        ),
                        children: [
                          if ('${r['note'] ?? ''}'.isNotEmpty)
                            AdminKeyValue('Note', '${r['note']}'),
                          if (r['resolved_by'] != null)
                            AdminKeyValue(
                              'Decided by',
                              '${person(r['resolved_by'])} · ${_date(r['resolved_at'])}',
                            ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'REPORTED POST',
                              style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: scheme.errorContainer,
                              borderRadius: BorderRadius.circular(AppShape.innerOf(state.context),
                              ),
                            ),
                            child: KeyedSubtree(
                              key: PageStorageKey<String>(
                                'post-report:${r['id']}',
                              ),
                              child: SelectableText(
                                '${r['body'] ?? ''}',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                          if (r['current_body'] != null &&
                              '${r['current_body']}' != '${r['body']}') ...[
                            const SizedBox(height: 6),
                            AdminKeyValue(
                              'Edited since',
                              '${r['current_body']}',
                            ),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if ('${r['status']}' == 'open') ...[
                                OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'dismissed'),
                                  icon: const Icon(
                                    Icons.do_not_disturb_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Dismiss'),
                                ),
                                if (r['deleted'] != true)
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        resolve(r, 'resolved', remove: true),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                      size: 18,
                                    ),
                                    label: const Text('Remove post'),
                                  ),
                                FilledButton.icon(
                                  onPressed: () => resolve(r, 'resolved'),
                                  icon: const Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Mark resolved'),
                                ),
                              ] else
                                OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'open'),
                                  icon: const Icon(
                                    Icons.undo_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Reopen'),
                                ),
                            ],
                          ),
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }

void _buildShowProject(_AppPageContentState state, Map<String, dynamic> project) {
    final id = '${project['id'] ?? project['space_id'] ?? ''}';
    showAppDialog<void>(
      context: state.context,
      builder: (context) => _ProjectDialog(
        project: project,
        onAction: state.widget.onAction,
        loadDetail: () => state.widget.onDirectAction('spaces', 'space_detail', {
          'space': id,
          'admin': true,
        }),
        loadWork: () => state.widget.onDirectAction('spaces', 'admin_work_log', {
          'space': id,
          'limit': 200,
        }),
        loadFiles: () =>
            state.widget.onDirectAction('spaces', 'admin_files', {'space': id}),
      ),
    );
  }

void _buildShowUser(_AppPageContentState state, Map<String, dynamic> account, {int tab = 0}) {
    showAppDialog<void>(
      context: state.context,
      builder: (context) => _UserDialog(
        account: account,
        initialTab: tab,
        onAction: state.widget.onAction,
        onEdit: () => state._editUser(account),
        loadFinance: () => state.widget.onDirectAction('finance', 'admin_account', {
          'account': account['id'],
          'limit': 200,
        }),
      ),
    );
  }
