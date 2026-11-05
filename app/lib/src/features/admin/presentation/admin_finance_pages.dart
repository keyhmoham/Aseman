part of 'admin_page_content.dart';

void _buildSetPeriod(_AppPageContentState state, String value) {
    state.setState(() => state.filter = value);
    final days = const {'7d': 7, '30d': 30, '90d': 90}[value];
    state.widget.onQuery?.call('finance.overview', {
      if (days != null)
        'since': DateTime.now()
            .toUtc()
            .subtract(Duration(days: days))
            .toIso8601String(),
    });
  }

Widget _buildDeveloperPage(_AppPageContentState state) {
    final overview = _map(state.widget.results['developer.admin_orgs']);
    final totals = _map(overview['totals']);
    final orgs = _listOfMaps(overview['orgs']);
    final logs = _listOfMaps(
      _map(state.widget.results['developer.admin_logs'])['logs'],
    );
    final window = _integer(totals['windowDays']);
    final q = state.search.text.toLowerCase().trim();
    final shown =
        orgs
            .where(
              (o) =>
                  q.isEmpty ||
                  '${o['name']} ${o['owner']} ${o['id']}'
                      .toLowerCase()
                      .contains(q),
            )
            .toList()
          ..sort((a, b) => _number(b['spend']).compareTo(_number(a['spend'])));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 4,
          children: [
            AdminStatCard(
              label: 'Organizations',
              value: '${_integer(totals['orgs'])}',
              hint:
                  '${_integer(totals['active'])} active in ${window == 0 ? 30 : window} days',
              icon: Icons.apartment_rounded,
            ),
            AdminStatCard(
              label: 'Spend',
              value: _money(totals['spend']),
              hint: '${_compact(totals['requests'])} requests',
              icon: Icons.payments_rounded,
              tone: AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Errors',
              value: _compact(totals['errors']),
              hint: 'Failed requests',
              icon: Icons.error_outline_rounded,
              tone: _integer(totals['errors']) == 0 ? null : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Held in balances',
              value: _money(totals['balances']),
              hint:
                  '${_integer(totals['keys'])} keys · ${_integer(totals['running'])} computers running · ${_bytes(totals['bytes'])} stored',
              icon: Icons.account_balance_wallet_rounded,
            ),
          ],
        ),
        const SizedBox(height: 18),
        state._toolbar(
          AdminSearchField(
            controller: state.search,
            hint: 'Search organization or owner',
            onChanged: (_) => state.setState(() {}),
          ),
          const [],
        ),
        const SizedBox(height: 12),
        AdminDataTable(
          empty: 'No organization uses the developer API yet.',
          columns: const [
            AdminTableColumn('Organization', width: 240),
            AdminTableColumn('Balance', width: 110, align: TextAlign.right),
            AdminTableColumn('Spend', width: 110, align: TextAlign.right),
            AdminTableColumn('Requests', width: 110, align: TextAlign.right),
            AdminTableColumn(
              'Keys · people',
              width: 130,
              align: TextAlign.right,
            ),
            AdminTableColumn('Last request', width: 150),
            AdminTableColumn('', width: 90, align: TextAlign.right),
          ],
          rows: [
            for (final o in shown)
              [
                _primaryCell(
                  '${o['name']}',
                  '${o['kind'] == 'personal' ? 'personal' : 'team'} · @${o['owner'] ?? '—'}',
                ),
                Text(_money(o['balance']), textAlign: TextAlign.right),
                Text(_money(o['spend']), textAlign: TextAlign.right),
                Text(
                  '${_compact(o['requests'])}${_integer(o['errors']) > 0 ? ' (${_integer(o['errors'])} failed)' : ''}',
                  textAlign: TextAlign.right,
                ),
                Text(
                  '${_integer(o['keys'])} · ${_integer(o['members'])}',
                  textAlign: TextAlign.right,
                ),
                Text(_date(o['lastAt'])),
                TextButton(
                  onPressed: () => state._showDeveloperOrg(o),
                  child: const Text('Open'),
                ),
              ],
          ],
        ),
        const SizedBox(height: 18),
        state._developerPlatforms(),
        const SizedBox(height: 18),
        AdminSectionCard(
          title: 'Latest requests',
          icon: Icons.receipt_long_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: state._developerLogs(logs, withOrg: true),
        ),
      ],
    );
  }

Widget _buildDeveloperPlatformsPage(_AppPageContentState state) {
    final platforms = _listOfMaps(
      _map(state.widget.results['developer.admin_platforms'])['platforms'],
    );
    return AdminSectionCard(
      title: 'Sub-platforms',
      icon: Icons.layers_rounded,
      subtitle:
          'Isolated by default. Bridging lets that platform and main Aseman see each other; platforms never see each other.',
      child: platforms.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No sub-platforms yet.'),
            )
          : AdminDataTable(
              empty: 'No sub-platforms yet.',
              columns: const [
                AdminTableColumn('Platform', width: 220),
                AdminTableColumn('Slug', width: 140),
                AdminTableColumn('Main Aseman', width: 160),
                AdminTableColumn('', width: 140, align: TextAlign.right),
              ],
              rows: [
                for (final p in platforms)
                  [
                    Text('${p['name']}'),
                    Text('${p['slug']}',
                        style: const TextStyle(fontFamily: 'monospace')),
                    Text(p['mainAccess'] == true ? 'Bridged' : 'Isolated'),
                    TextButton(
                      onPressed: () async {
                        await state.widget.onDirectAction(
                          'developer',
                          'admin_platform_access',
                          {
                            'platform': p['id'],
                            'access': p['mainAccess'] != true,
                          },
                        );
                        await state.widget.onRefresh();
                      },
                      child: Text(p['mainAccess'] == true
                          ? 'Isolate'
                          : 'Bridge to Aseman'),
                    ),
                  ],
              ],
            ),
    );
  }

Widget _buildDeveloperLogs(
  _AppPageContentState state,
    List<Map<String, dynamic>> logs, {
    bool withOrg = false,
  }) => AdminDataTable(
    empty: 'No requests yet.',
    columns: [
      const AdminTableColumn('Time', width: 150),
      if (withOrg) const AdminTableColumn('Organization', width: 160),
      const AdminTableColumn('Request', width: 260),
      const AdminTableColumn('Model', width: 200),
      const AdminTableColumn('Status', width: 90),
      const AdminTableColumn('Tokens', width: 120, align: TextAlign.right),
      const AdminTableColumn('Cost', width: 90, align: TextAlign.right),
    ],
    rows: [
      for (final l in logs)
        [
          Text(_date(l['at'])),
          if (withOrg) Text('${l['orgName'] ?? l['org'] ?? '—'}'),
          _primaryCell(
            '${l['method'] ?? ''} ${l['path'] ?? ''}',
            '${l['keyName'] ?? ''} · ${_integer(l['latencyMs'])} ms',
          ),
          _primaryCell(
            '${l['model'] ?? '—'}',
            '${l['provider'] ?? ''}${'${l['error'] ?? ''}'.isEmpty ? '' : ' · ${l['error']}'}',
          ),
          AdminStatusPill(
            _integer(l['status']) >= 400
                ? 'failed ${_integer(l['status'])}'
                : 'ok ${_integer(l['status'])}',
          ),
          Text(
            '${_compact(l['tokensIn'])} / ${_compact(l['tokensOut'])}',
            textAlign: TextAlign.right,
          ),
          Text(_money(l['cost']), textAlign: TextAlign.right),
        ],
    ],
  );

Future<void> _buildShowDeveloperOrg(_AppPageContentState state, Map<String, dynamic> org) async {
    dynamic value;
    try {
      value = await state.widget.onDirectAction('developer', 'admin_org', {
        'org': org['id'],
      });
    } catch (_) {
      return; // The console reports the error.
    }
    if (!state.mounted) return;
    final d = _map(value);
    final total = _map(_map(d['usage'])['total']);
    final storage = _map(d['storage']);
    final settings = _map(d['settings']);
    await showAppDialog<void>(
      context: state.context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Row(
                children: [
                  AdminAvatar(
                    '${org['name']}',
                    size: 44,
                    icon: Icons.apartment_rounded,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _primaryCell(
                      '${org['name']}',
                      '${org['id']} · @${org['owner']}',
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              AdminGrid(
                maxColumns: 4,
                children: [
                  AdminStatCard(
                    label: 'Balance',
                    value: _money(_map(d['org'])['balance']),
                    hint: '${_money(d['held'])} held for running work',
                    icon: Icons.account_balance_wallet_rounded,
                  ),
                  AdminStatCard(
                    label: 'Spend',
                    value: _money(total['spend']),
                    hint:
                        '${_compact(total['requests'])} requests · ${_compact(total['errors'])} failed',
                    icon: Icons.payments_rounded,
                  ),
                  AdminStatCard(
                    label: 'Monthly cap',
                    value: _number(settings['accountMonthlyCap']) > 0
                        ? _money(settings['accountMonthlyCap'])
                        : 'None',
                    hint: '${_money(settings['spentMonth'])} this month',
                    icon: Icons.savings_rounded,
                  ),
                  AdminStatCard(
                    label: 'Storage',
                    value: _bytes(storage['usedBytes']),
                    hint:
                        '${_integer(storage['files'])} files · ${_money(storage['perMonth'])} a month',
                    icon: Icons.cloud_rounded,
                  ),
                ],
              ),
              state._heading('Keys'),
              AdminDataTable(
                empty: 'No keys.',
                columns: const [
                  AdminTableColumn('Key', width: 240),
                  AdminTableColumn('Status', width: 100),
                  AdminTableColumn(
                    'This month',
                    width: 120,
                    align: TextAlign.right,
                  ),
                  AdminTableColumn(
                    'Requests',
                    width: 100,
                    align: TextAlign.right,
                  ),
                  AdminTableColumn('Last used', width: 150),
                ],
                rows: [
                  for (final k in _listOfMaps(d['keyList']))
                    [
                      _primaryCell(
                        '${k['name']}',
                        '${k['prefix']}…${k['last4']}',
                      ),
                      AdminStatusPill('${k['status']}'),
                      Text(_money(k['spentMonth']), textAlign: TextAlign.right),
                      Text(_compact(k['requests']), textAlign: TextAlign.right),
                      Text(_date(k['lastUsedAt'])),
                    ],
                ],
              ),
              state._heading('People'),
              AdminDataTable(
                empty: 'No members.',
                columns: const [
                  AdminTableColumn('Person', width: 240),
                  AdminTableColumn('Role', width: 120),
                  AdminTableColumn('Status', width: 120),
                ],
                rows: [
                  for (final m in _listOfMaps(d['members']))
                    [
                      _primaryCell(
                        '${m['name'] ?? m['handle']}',
                        '@${m['handle']}',
                      ),
                      Text('${m['role']}'),
                      AdminStatusPill('${m['status']}'),
                    ],
                ],
              ),
              if (_listOfMaps(d['computerList']).isNotEmpty) ...[
                state._heading('Computers'),
                AdminDataTable(
                  empty: 'No computers.',
                  columns: const [
                    AdminTableColumn('Computer', width: 240),
                    AdminTableColumn('Status', width: 120),
                    AdminTableColumn('Size', width: 160),
                    AdminTableColumn(
                      'Minutes',
                      width: 100,
                      align: TextAlign.right,
                    ),
                  ],
                  rows: [
                    for (final c in _listOfMaps(d['computerList']))
                      [
                        _primaryCell('${c['name']}', '${c['image']}'),
                        AdminStatusPill('${c['status']}'),
                        Text(
                          '${compactDecimal(_number(_map(c['spec'])['state.cpu']))} vCPU · ${_bytes(_number(_map(c['spec'])['memoryMb']) * 1024 * 1024)}',
                        ),
                        Text(
                          compactDecimal(_number(c['minutes']), decimals: 1),
                          textAlign: TextAlign.right,
                        ),
                      ],
                  ],
                ),
              ],
              state._heading('Requests'),
              state._developerLogs(_listOfMaps(d['logs'])),
            ],
          ),
        ),
      ),
    );
  }

Widget _buildFinancePage(_AppPageContentState state) {
    final o = _map(state.widget.results['finance.overview']);
    final income = _map(o['income']);
    final charged = _map(o['charged']);
    final paid = _map(o['paid_out']);
    final reconcile = _map(state.widget.results['finance.reconcile']);
    final costs = _map(state.widget.results['finance.costs']);
    final providers = _map(state.widget.results['finance.provider_costs']);
    final palette = adminPalette(state.context);
    final components = [
      AdminChartSlice(
        'LLM tokens',
        _number(charged['llm']),
        palette[0],
        display: _money(charged['llm']),
      ),
      AdminChartSlice(
        'Computers',
        _number(charged['compute']),
        palette[1],
        display: _money(charged['compute']),
      ),
      AdminChartSlice(
        'Agent time',
        _number(charged['agent_time']),
        palette[2],
        display: _money(charged['agent_time']),
      ),
      AdminChartSlice(
        'Apps',
        _number(charged['tools']),
        palette[3],
        display: _money(charged['tools']),
      ),
    ];
    final destinations = [
      AdminChartSlice(
        'Creators',
        _number(paid['creators']),
        palette[4],
        display: _money(paid['creators']),
      ),
      AdminChartSlice(
        'Platform',
        _number(o['kept']),
        AppColors.successOf(state.context),
        display: _money(o['kept']),
      ),
    ];
    final bill = _number(
      providers['bill'] ?? providers['total'] ?? costs['compute'],
    );
    final billed = _number(providers['charged'] ?? charged['compute']);
    final issues = _listOfMaps(reconcile['issues']);
    final balanced = reconcile['ok'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminFilterChips<String>(
          selected:
              state.filter == 'all' || const {'7d', '30d', '90d'}.contains(state.filter)
              ? state.filter
              : 'all',
          onSelected: state._setPeriod,
          options: const [
            AdminFilterOption(
              '7d',
              'Last 7 days',
              icon: Icons.date_range_rounded,
            ),
            AdminFilterOption('30d', 'Last 30 days'),
            AdminFilterOption('90d', 'Last 90 days'),
            AdminFilterOption(
              'all',
              'All time',
              icon: Icons.all_inclusive_rounded,
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Income',
              value: _money(income['credits_sold']),
              hint:
                  'Credit packs sold · ${_integer(income['purchases'])} purchases',
              icon: Icons.south_west_rounded,
              tone: AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Customer spend',
              value: _money(charged['total']),
              hint: '${_credits(charged['total'])} used on work',
              icon: Icons.query_stats_rounded,
            ),
            AdminStatCard(
              label: 'Paid to creators',
              value: _money(paid['creators']),
              hint: "Earned by people's agents and tools",
              icon: Icons.people_alt_rounded,
              tone: palette[4],
            ),
            AdminStatCard(
              label: 'Net revenue',
              value: _money(o['kept']),
              hint: 'Kept by the platform, before provider bills',
              icon: Icons.account_balance_rounded,
              progress: _number(charged['total']) <= 0
                  ? null
                  : _number(o['kept']) / _number(charged['total']),
              tone: _number(o['kept']) < 0
                  ? AppColors.dangerOf(state.context)
                  : AppColors.successOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 360,
          children: [
            AdminSectionCard(
              title: 'What customers spent it on',
              icon: Icons.donut_large_rounded,
              child: AdminDonutPanel(
                center: _money(charged['total']),
                caption: 'spent',
                slices: components,
              ),
            ),
            AdminSectionCard(
              title: 'Where it ended up',
              icon: Icons.call_split_rounded,
              child: Column(
                children: [
                  AdminStackedBar(slices: destinations, height: 22),
                  const SizedBox(height: 14),
                  AdminKeyValue('Platform LLM', _money(paid['platform_llm'])),
                  AdminKeyValue(
                    'Platform compute',
                    _money(paid['platform_compute']),
                  ),
                  AdminKeyValue('Platform bots', _money(paid['platform_bots'])),
                  const Divider(height: 22),
                  AdminKeyValue(
                    'Unspent credits users hold',
                    _money(o['held_by_users']),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Computers: provider bill vs what you charged',
          icon: Icons.compare_arrows_rounded,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final margin = billed <= 0 ? 0.0 : (billed - bill) / billed;
              final bars = Column(
                children: [
                  AdminBarList(
                    items: [
                      AdminChartSlice(
                        'Customers charged',
                        billed,
                        AppColors.successOf(context),
                        display: _money(billed),
                      ),
                      AdminChartSlice(
                        'Provider billed',
                        bill,
                        AppColors.warningOf(context),
                        display: _money(bill),
                      ),
                    ],
                  ),
                  for (final row in _listOfMaps(providers['by_resource']))
                    AdminKeyValue(
                      '${row['label'] ?? row['resource']}',
                      _money(row['units'] ?? row['cost']),
                    ),
                ],
              );
              final gauge = AdminGauge(
                value: margin.clamp(0, 1).toDouble(),
                label: 'margin',
                display: billed <= 0 ? '—' : '${(margin * 100).round()}%',
                color: margin < 0 ? AppColors.dangerOf(context) : AppColors.successOf(context),
                size: 124,
              );
              if (constraints.maxWidth < 520) {
                return Column(
                  children: [gauge, const SizedBox(height: 12), bars],
                );
              }
              return Row(
                children: [
                  gauge,
                  const SizedBox(width: 24),
                  Expanded(child: bars),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Ledger check',
          icon: balanced ? Icons.verified_rounded : Icons.report_rounded,
          trailing: IconButton.filledTonal(
            tooltip: 'Reconcile wallets',
            onPressed: state.widget.onRefresh,
            icon: const Icon(Icons.sync_rounded, size: 19),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AdminStatusPill(balanced ? 'healthy' : 'error'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      balanced
                          ? 'Balanced — ${_integer(reconcile['checked'])} wallets checked'
                          : '${issues.length} reconciliation ${issues.length == 1 ? 'issue' : 'issues'} in ${_integer(reconcile['checked'])} wallets',
                    ),
                  ),
                ],
              ),
              for (final issue in issues)
                Container(
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.dangerOf(state.context).withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: AppColors.dangerOf(state.context),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${issue['kind']}'.replaceAll('_', ' '),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SelectableText(
                              '${issue['detail'] ?? ''} · ${issue['account_id'] ?? ''}',
                              style: state._muted(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

Widget _buildPurchasesPage(_AppPageContentState state) {
    final response = _map(state.widget.results['finance.purchases_list']);
    final all = _listOfMaps(response['purchases'] ?? response['transactions']);
    final q = state.search.text.trim().toLowerCase();
    final charged = all
        .where((p) => '${p['status']}' == 'credited' && p['sandbox'] != true)
        .toList();
    final sandbox = all.where((p) => p['sandbox'] == true).toList();
    final pending = all.where((p) => '${p['status']}' == 'pending').toList();
    final reversed = all.where((p) => '${p['status']}' == 'reversed').toList();
    final rows = all.where((p) {
      final match = switch (state.filter) {
        'live' => '${p['status']}' == 'credited' && p['sandbox'] != true,
        'sandbox' => p['sandbox'] == true,
        'pending' => '${p['status']}' == 'pending',
        'reversed' => '${p['status']}' == 'reversed',
        _ => true,
      };
      return match &&
          (q.isEmpty ||
              '${p['email']} ${p['product_id']} ${p['status']} ${p['transaction_id']} ${p['id']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final selectedRows = all
        .where((p) => state.selected.contains(_rowId(p)))
        .toList();
    final selectedSandbox = selectedRows
        .where((p) => p['sandbox'] == true)
        .length;
    final selectedLive = selectedRows.length - selectedSandbox;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Charged',
              value: _money(_sum(charged, 'amount')),
              hint: '${charged.length} live purchases',
              icon: Icons.paid_rounded,
              tone: AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Sandbox',
              value: _money(_sum(sandbox, 'amount')),
              hint: '${sandbox.length} test transactions',
              icon: Icons.science_rounded,
              tone: AppColors.cyanOf(state.context),
            ),
            AdminStatCard(
              label: 'Pending',
              value: _money(_sum(pending, 'amount')),
              hint: '${pending.length} waiting',
              icon: Icons.hourglass_top_rounded,
              tone: pending.isEmpty ? null : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Reversed',
              value: _money(_sum(reversed, 'amount')),
              hint: '${reversed.length} refunds',
              icon: Icons.undo_rounded,
              tone: reversed.isEmpty ? null : AppColors.dangerOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Purchases by outcome',
          icon: Icons.stacked_bar_chart_rounded,
          child: AdminStackedBar(
            height: 20,
            slices: [
              AdminChartSlice(
                'Live',
                charged.length.toDouble(),
                AppColors.successOf(state.context),
              ),
              AdminChartSlice(
                'Sandbox',
                sandbox.length.toDouble(),
                AppColors.cyanOf(state.context),
              ),
              AdminChartSlice(
                'Pending',
                pending.length.toDouble(),
                AppColors.warningOf(state.context),
              ),
              AdminChartSlice(
                'Reversed',
                reversed.length.toDouble(),
                AppColors.dangerOf(state.context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AdminSearchField(
          controller: state.search,
          hint: 'Search email, product, or status',
          onChanged: (_) => state.setState(() {}),
        ),
        const SizedBox(height: 12),
        AdminFilterChips<String>(
          selected: state.filter,
          onSelected: (v) => state.setState(() => state.filter = v),
          options: [
            AdminFilterOption('all', 'All', count: all.length),
            AdminFilterOption('live', 'Live', count: charged.length),
            AdminFilterOption('sandbox', 'Sandbox', count: sandbox.length),
            AdminFilterOption('pending', 'Pending', count: pending.length),
            AdminFilterOption('reversed', 'Reversed', count: reversed.length),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: state.selected.isEmpty
              ? const SizedBox(width: double.infinity)
              : Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  decoration: BoxDecoration(
                    color: ThemeRoles.selectedFill(state.context),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.checklist_rounded,
                        color: ThemeRoles.selectedInk(state.context),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${state.selected.length} selected',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: ThemeRoles.selectedInk(state.context),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => state.setState(state.selected.clear),
                        child: const Text('Clear'),
                      ),
                      if (selectedLive > 0)
                        OutlinedButton(
                          onPressed: () => state._labelPurchases(selectedRows, true),
                          child: Text('Mark sandbox ($selectedLive)'),
                        ),
                      if (selectedLive > 0 && selectedSandbox > 0)
                        const SizedBox(width: 8),
                      if (selectedSandbox > 0)
                        FilledButton(
                          onPressed: () => state._labelPurchases(selectedRows, false),
                          child: Text('Mark live ($selectedSandbox)'),
                        ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 14),
        AdminDataTable(
          empty: all.isEmpty
              ? 'Credit pack sales will appear here after the first top-up.'
              : 'No purchases match.',
          selected: (index) => state.selected.contains(_rowId(rows[index])),
          onRowTap: (index) => state.setState(() {
            final id = _rowId(rows[index]);
            state.selected.contains(id) ? state.selected.remove(id) : state.selected.add(id);
          }),
          columns: const [
            AdminTableColumn('', width: 48),
            AdminTableColumn('Customer', width: 240),
            AdminTableColumn('Product', width: 180),
            AdminTableColumn('Amount', width: 110, align: TextAlign.right),
            AdminTableColumn('Status', width: 170),
            AdminTableColumn('Purchased', width: 150),
            AdminTableColumn('Transaction', width: 170),
          ],
          rows: [
            for (final p in rows)
              [
                Checkbox(
                  value: state.selected.contains(_rowId(p)),
                  onChanged: (_) => state.setState(() {
                    final id = _rowId(p);
                    state.selected.contains(id)
                        ? state.selected.remove(id)
                        : state.selected.add(id);
                  }),
                ),
                state._personCell(
                  '${p['email'] ?? p['account_handle'] ?? 'Unknown'}',
                  _shortId(p['account_id']),
                ),
                Text('${p['product_id'] ?? p['product'] ?? '—'}'),
                Text(
                  _money(p['amount'] ?? p['listed_amount']),
                  textAlign: TextAlign.right,
                ),
                Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: [
                    AdminStatusPill('${p['status'] ?? 'pending'}'),
                    if (p['sandbox'] == true) const AdminStatusPill('sandbox'),
                  ],
                ),
                Text(_date(p['created_at'] ?? p['purchased_at'])),
                Text(_shortId(p['transaction_id'] ?? p['id'])),
              ],
          ],
        ),
      ],
    );
  }

Future<void> _buildLabelPurchases(
  _AppPageContentState state,
    List<Map<String, dynamic>> purchases,
    bool sandbox,
  ) async {
    await state.widget.onDirectAction('finance', 'purchases_label', {
      'transaction_ids': purchases
          .map((p) => '${p['transaction_id'] ?? p['id']}')
          .toList(),
      'sandbox': sandbox,
    });
    if (state.mounted) state.setState(state.selected.clear);
  }

Widget _buildPayoutsPage(_AppPageContentState state) {
    final response = _map(state.widget.results['finance.payouts_list']);
    final all = _listOfMaps(response['payouts'] ?? response['requests']);
    final pending = all.where((p) => '${p['status']}' == 'pending').toList();
    final paid = all.where((p) => '${p['status']}' == 'paid').toList();
    final rejected = all.where((p) => '${p['status']}' == 'rejected').toList();
    final ordered = [...all]
      ..sort((a, b) {
        // Waiting requests first, then newest.
        final wait = ('${a['status']}' == 'pending' ? 0 : 1).compareTo(
          '${b['status']}' == 'pending' ? 0 : 1,
        );
        return wait != 0
            ? wait
            : '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}');
      });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          maxColumns: 3,
          children: [
            AdminStatCard(
              label: 'Waiting to pay',
              value: _money(_sum(pending, 'amount')),
              hint:
                  '${pending.length} ${pending.length == 1 ? 'request' : 'requests'}',
              icon: Icons.hourglass_top_rounded,
              tone: pending.isEmpty ? null : AppColors.warningOf(state.context),
            ),
            AdminStatCard(
              label: 'Marked paid',
              value: _money(_sum(paid, 'amount')),
              hint: 'This queue only — already resolved',
              icon: Icons.price_check_rounded,
              tone: AppColors.successOf(state.context),
            ),
            AdminStatCard(
              label: 'Returned',
              value: _money(_sum(rejected, 'amount')),
              hint: '${rejected.length} rejected',
              icon: Icons.undo_rounded,
              tone: rejected.isEmpty ? null : AppColors.dangerOf(state.context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Queue',
          icon: Icons.payments_rounded,
          subtitle:
              'Pay creators externally, then record the provider confirmation here.',
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: ordered.isEmpty
              ? const AdminEmptyState(
                  'No payouts',
                  'Creator withdrawal requests will appear here.',
                  icon: Icons.payments_outlined,
                )
              : Column(
                  children: [
                    for (final p in ordered)
                      ExpansionTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        collapsedShape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppShape.controlOf(state.context)),
                        ),
                        initiallyExpanded:
                            '${p['status']}' == 'pending' &&
                            identical(p, ordered.first),
                        leading: AdminAvatar(
                          '${p['handle'] ?? p['account_id'] ?? '?'}',
                          size: 40,
                        ),
                        title: Text(
                          '${(p['handle'] ?? '').toString().isEmpty ? p['account_id'] ?? 'Creator' : '@${p['handle']}'}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${_money(p['amount'])} · ${_date(p['created_at'])} · ${p['method'] ?? 'external'}',
                        ),
                        trailing: AdminStatusPill(
                          '${p['status'] ?? 'pending'}',
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          14,
                        ),
                        children: [
                          for (final e in _map(p['destination']).entries)
                            AdminKeyValue(
                              _humanKey(e.key),
                              '${e.value}',
                              mono: true,
                            ),
                          if (p['destination'] is String)
                            AdminKeyValue(
                              'Destination',
                              '${p['destination']}',
                              mono: true,
                            ),
                          AdminKeyValue(
                            'Request id',
                            '${p['id'] ?? p['request_id']}',
                            mono: true,
                          ),
                          if ('${p['status']}' == 'pending') ...[
                            const SizedBox(height: 8),
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () =>
                                      state._resolvePayout(p, 'rejected'),
                                  icon: const Icon(
                                    Icons.undo_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Reject and return funds'),
                                ),
                                FilledButton.icon(
                                  onPressed: () => state._resolvePayout(p, 'paid'),
                                  icon: const Icon(
                                    Icons.price_check_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Mark paid'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                  ],
                ),
        ),
      ],
    );
  }

void _buildResolvePayout(_AppPageContentState state, Map<String, dynamic> p, String status) =>
      state.widget.onAction('finance', 'payout_resolve', {
        'payout_id': p['id'],
        'status': status,
        '_amount': p['amount'],
        '_name': p['handle'],
      });
