import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import 'admin_widgets.dart';
import '../../../shared/widgets/overlay_panels.dart';

typedef AdminAction = Future<void> Function(
    String namespace, String action, Map<String, dynamic> initialBody);
typedef AdminDirectAction = Future<dynamic> Function(
    String namespace, String action, Map<String, dynamic> body);

/// Purpose-built content for every route in the admin console. The page name
/// maps one-to-one to the original Expo route; only the surrounding shell is
/// shared.
class AdminPageContent extends StatefulWidget {
  const AdminPageContent({
    super.key,
    required this.page,
    required this.results,
    required this.loading,
    required this.onRefresh,
    this.onLiveRefresh,
    required this.onAction,
    required this.onDirectAction,
    required this.onNavigate,
    this.onQuery,
    this.oauthRedirectUri = '',
  });

  final String page;
  final Map<String, dynamic> results;
  final bool loading;
  final Future<void> Function() onRefresh;

  /// Periodic refresh used by live pages. It must update the data in place;
  /// falls back to [onRefresh] when not given.
  final Future<void> Function()? onLiveRefresh;
  final AdminAction onAction;
  final AdminDirectAction onDirectAction;
  final ValueChanged<String> onNavigate;

  /// Re-requests one call of the page with extra request fields, e.g. the
  /// period of the finance overview.
  final Future<void> Function(String call, Map<String, dynamic> body)? onQuery;

  /// Where providers send people back after signing in to an MCP server: the
  /// redirect an OAuth client for one has to be created with.
  final String oauthRedirectUri;

  @override
  State<AdminPageContent> createState() => _AppPageContentState();
}

class _AppPageContentState extends State<AdminPageContent> {
  final search = TextEditingController();

  /// A provider picked on a model picker that offers no model for it yet:
  /// shown, but not saved (the node takes a provider only with a model).
  final Map<String, String> _pickedProvider = {};
  String filter = 'all';

  /// Which chat reports are listed (the page starts with the open ones).
  String reportStatus = 'open';
  String postReportStatus = 'open';
  String sort = 'created';
  bool ascending = false;
  bool live = true;
  bool advanced = false;
  final selected = <String>{};
  final cpu = <double>[];
  final memory = <double>[];
  Timer? timer;
  bool ticking = false;

  @override
  void initState() {
    super.initState();
    _configureTimer();
    _sampleNode();
  }

  @override
  void didUpdateWidget(covariant AdminPageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page) {
      search.clear();
      filter = 'all';
      sort = 'created';
      ascending = false;
      selected.clear();
      live = true;
      _configureTimer();
    }
    // Seed the charts with the first reading; afterwards they advance once
    // per live tick so partial updates of other panels do not add samples.
    if (cpu.isEmpty &&
        !identical(oldWidget.results['admin.node_stats'],
            widget.results['admin.node_stats'])) {
      _sampleNode();
    }
  }

  void _configureTimer() {
    timer?.cancel();
    if (widget.page == 'Node · Host' || widget.page == 'Node · Logs') {
      timer = Timer.periodic(
          Duration(seconds: widget.page == 'Node · Logs' ? 3 : 5), (_) async {
        if (!mounted || !live || widget.loading || ticking) return;
        ticking = true;
        final page = widget.page;
        try {
          await (widget.onLiveRefresh ?? widget.onRefresh)();
        } finally {
          ticking = false;
        }
        if (mounted && page == widget.page) setState(_sampleNode);
      });
    }
  }

  void _sampleNode() {
    if (widget.page != 'Node · Host') return;
    final resources =
        _map(_map(widget.results['admin.node_stats'])['resources']);
    if (resources.isEmpty) return;
    final cores = _number(resources['cpu_cores'], fallback: 1);
    final load = _doubleList(resources['load_avg']);
    cpu.add(((load.isEmpty ? 0 : load.first) / (cores == 0 ? 1 : cores) * 100)
        .clamp(0, 100));
    memory.add(_number(resources['mem_used_percent']).clamp(0, 100));
    if (cpu.length > 60) cpu.removeAt(0);
    if (memory.length > 60) memory.removeAt(0);
  }

  @override
  void dispose() {
    timer?.cancel();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.results.isEmpty) {
      return const SkeletonPage();
    }
    final errors = widget.results.entries
        .where((entry) => _map(entry.value).containsKey('error'))
        .toList();
    final gutter = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 28.0;
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        key: PageStorageKey(widget.page),
        padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 48),
        children: [
          if (errors.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(AppShape.inner),
              ),
              child:
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.cloud_off_rounded,
                    color: Theme.of(context).colorScheme.onErrorContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    errors
                        .map((e) => '${e.key}: ${_map(e.value)['error']}')
                        .join('\n'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        fontSize: 13),
                  ),
                ),
              ]),
            ),
          _page(),
        ],
      ),
    );
  }

  Widget _page() => switch (widget.page) {
        'Overview' => _overview(),
        'Users' => _users(),
        'Projects' => _projects(),
        'Chat reports' => _chatReports(),
        'Post reports' => _postReports(),
        'Agents' => _agents(),
        'Apps' => _apps(),
        'Talent' => _talent(),
        'Talent requests' => _talentRequests(),
        'Finance · Overview' => _finance(),
        'Finance · Purchases' => _purchases(),
        'Finance · Payouts' => _payouts(),
        'Developer API' => _developer(),
        'Models' => _models(),
        'Decision model' => _decision(),
        'Image model' => _imageModel(),
        'Memory models' => _memoryModels(),
        'OpenCode' => _openCode(),
        'Health' => _health(),
        'Node · Host' => _node(),
        'Node · Modules' => _nodePlugins(),
        'Node · Logs' => _logs(),
        'Sandboxes' => _sandboxes(),
        'Storage' => _storage(),
        'Settings · Pricing' => _pricing(),
        'Settings · Machine' => _machine(),
        'Settings · Agent instructions' => _agentInstructions(),
        'Settings · Categories' => _categories(),
        _ => const AdminEmptyState(
            'Page unavailable', 'This admin route has no visual definition.'),
      };

  Widget _overview() {
    final scheme = Theme.of(context).colorScheme;
    final stats = _map(widget.results['admin.stats']);
    final counters =
        _map(stats['counters']).isNotEmpty ? _map(stats['counters']) : stats;
    final health = _map(widget.results['admin.health']);
    final counts = _map(health['counts']);
    final runs = _listOfMaps(_map(widget.results['admin.runs_list'])['runs']);
    final payouts = _listOfMaps(
        _map(widget.results['finance.payouts_list'])['payouts'] ??
            _map(widget.results['finance.payouts_list'])['requests']);
    final listings =
        _listOfMaps(_map(widget.results['market.catalog'])['listings']);
    final resources =
        _map(_map(widget.results['admin.node_stats'])['resources']);
    final pendingPayouts =
        payouts.where((p) => '${p['status']}' == 'pending').toList();
    final pendingListings =
        listings.where((l) => '${l['status']}' == 'pending').length;
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
          tone: AppColors.danger,
          icon: Icons.gpp_maybe_rounded,
        ),
      if (pendingPayouts.isNotEmpty)
        (
          text:
              '${pendingPayouts.length} payout ${pendingPayouts.length == 1 ? 'request' : 'requests'} · ${_money(_sum(pendingPayouts, 'amount'))}',
          target: 'Finance · Payouts',
          tone: AppColors.warning,
          icon: Icons.payments_rounded,
        ),
      if (pendingListings > 0)
        (
          text:
              '$pendingListings marketplace ${pendingListings == 1 ? 'listing waits' : 'listings wait'} for review',
          target: 'Agents',
          tone: AppColors.warning,
          icon: Icons.rate_review_rounded,
        ),
      if (failedRuns > 0)
        (
          text:
              '$failedRuns agent ${failedRuns == 1 ? 'run' : 'runs'} failed recently',
          target: 'Projects',
          tone: AppColors.danger,
          icon: Icons.running_with_errors_rounded,
        ),
      if (warn > 0)
        (
          text:
              '$warn deployment ${warn == 1 ? 'check is' : 'checks are'} worth a look',
          target: 'Health',
          tone: AppColors.warning,
          icon: Icons.tips_and_updates_rounded,
        ),
    ];
    final checks = ok + warn + fail;
    final score = checks == 0 ? 1.0 : ok / checks;
    final cores = _number(resources['cpu_cores'], fallback: 1);
    final load = _doubleList(resources['load_avg']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
              ? AppColors.danger
              : warn > 0
                  ? AppColors.warning
                  : AppColors.success,
          display: checks == 0 ? '—' : '$ok/$checks',
        ),
      ),
      if (needs.isNotEmpty) ...[
        const SizedBox(height: 14),
        AdminSectionCard(
          title: 'Needs you',
          icon: Icons.inbox_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
          child: Column(children: [
            for (final item in needs)
              ListTile(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppShape.control)),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: ShapeDecoration(
                      color: item.tone.withValues(alpha: .16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14))),
                  child: Icon(item.icon, color: item.tone, size: 21),
                ),
                title: Text(item.text,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(item.target),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => widget.onNavigate(item.target),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 22),
      _heading('Platform'),
      AdminGrid(children: [
        AdminStatCard(
            label: 'Users',
            value: _compact(counters['users'] ?? counters['accounts']),
            hint: 'Accounts and wallets',
            icon: Icons.people_rounded,
            onTap: () => widget.onNavigate('Users')),
        AdminStatCard(
            label: 'Projects',
            value: _compact(counters['projects'] ?? counters['spaces']),
            hint: 'Workspaces and machines',
            icon: Icons.folder_rounded,
            tone: AppColors.cyan,
            onTap: () => widget.onNavigate('Projects')),
        AdminStatCard(
            label: 'Bots',
            value: _compact(counters['bots']),
            hint: 'Agents and apps',
            icon: Icons.smart_toy_rounded,
            tone: AppColors.success,
            onTap: () => widget.onNavigate('Agents')),
        AdminStatCard(
            label: 'Agent runs',
            value: _compact(counters['room_turns']),
            hint: 'Turns across all projects',
            icon: Icons.play_circle_rounded,
            tone: AppColors.warning,
            onTap: () => widget.onNavigate('Projects')),
      ]),
      const SizedBox(height: 22),
      AdminGrid(maxColumns: 3, minTileWidth: 300, children: [
        AdminSectionCard(
          title: 'Deployment checks',
          icon: Icons.monitor_heart_rounded,
          trailing: TextButton(
              onPressed: () => widget.onNavigate('Health'),
              child: const Text('Open')),
          child: AdminDonutPanel(
            size: 132,
            center: '$checks',
            caption: 'checks',
            slices: [
              AdminChartSlice('Healthy', ok.toDouble(), AppColors.success),
              AdminChartSlice(
                  'Worth a look', warn.toDouble(), AppColors.warning),
              AdminChartSlice('Need fixing', fail.toDouble(), AppColors.danger),
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
              AdminChartSlice('Finished',
                  (runTones[AdminTone.ok] ?? 0).toDouble(), AppColors.success),
              AdminChartSlice('In progress',
                  (runTones[AdminTone.warn] ?? 0).toDouble(), AppColors.cyan),
              AdminChartSlice(
                  'Failed', failedRuns.toDouble(), AppColors.danger),
              AdminChartSlice(
                  'Other',
                  (runTones[AdminTone.neutral] ?? 0).toDouble(),
                  scheme.outline),
            ],
          ),
        ),
        AdminSectionCard(
          title: 'This node',
          icon: Icons.dns_rounded,
          trailing: TextButton(
              onPressed: () => widget.onNavigate('Node · Host'),
              child: const Text('Live')),
          child: resources.isEmpty
              ? Text('No host reading yet.', style: _muted())
              : Wrap(
                  alignment: WrapAlignment.spaceAround,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                      AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'CPU',
                          value: (load.isEmpty ? 0 : load.first) /
                              (cores == 0 ? 1 : cores)),
                      AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'Memory',
                          value: _number(resources['mem_used_percent']) / 100),
                      AdminGauge(
                          size: 96,
                          thickness: 10,
                          label: 'Disk',
                          value: _number(resources['disk_used_percent']) / 100),
                    ]),
        ),
      ]),
    ]);
  }

  Widget _users() {
    final accounts =
        _listOfMaps(_map(widget.results['users.accounts_list'])['accounts']);
    final admins =
        _listOfMaps(_map(widget.results['admin.admins_list'])['admins']);
    final adminIds = admins.map((a) => '${a['id']}').toSet();
    bool isAdmin(Map<String, dynamic> a) =>
        a['is_admin'] == true ||
        '${a['role']}' == 'admin' ||
        adminIds.contains('${a['id']}');
    String status(Map<String, dynamic> a) =>
        '${a['status'] ?? 'active'}'.toLowerCase();
    final q = search.text.trim().toLowerCase();
    final rows = accounts.where((a) {
      if (filter == 'admin' && !isAdmin(a)) return false;
      if (filter != 'all' && filter != 'admin' && filter != status(a)) {
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
    final palette = adminPalette(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Accounts',
          icon: Icons.people_rounded,
          child: AdminDonutPanel(
            size: 132,
            center: '${accounts.length}',
            caption: 'accounts',
            slices: [
              AdminChartSlice('Active', active.toDouble(), AppColors.success),
              AdminChartSlice('Pending', pending.toDouble(), AppColors.warning),
              AdminChartSlice(
                  'Disabled', disabled.toDouble(), AppColors.danger),
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
                AdminChartSlice(_displayName(accounts[i]),
                    _number(accounts[i]['balance']), palette[1],
                    display: _credits(accounts[i]['balance'])),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search name, handle, email, or user id',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'Everyone', count: accounts.length),
          AdminFilterOption('active', 'Active',
              count: active, icon: Icons.check_circle_outline_rounded),
          if (pending > 0)
            AdminFilterOption('pending', 'Pending',
                count: pending, icon: Icons.hourglass_empty_rounded),
          AdminFilterOption('disabled', 'Blocked',
              count: disabled, icon: Icons.block_rounded),
          AdminFilterOption('admin', 'Admins',
              count: adminCount, icon: Icons.shield_outlined),
        ],
      ),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: q.isEmpty ? 'No accounts registered yet.' : 'No users match.',
        onRowTap: (index) => _showUser(rows[index]),
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
              _personCell(_displayName(a), '@${a['handle'] ?? 'unknown'}',
                  avatar: _avatarOf(a)),
              Text('${a['email'] ?? '—'}'),
              isAdmin(a)
                  ? const _RoleBadge(admin: true)
                  : const _RoleBadge(admin: false),
              AdminStatusPill(status(a)),
              Text(_credits(a['balance']), textAlign: TextAlign.right),
              Text(_date(a['last_seen'] ?? a['created_at'])),
              Wrap(alignment: WrapAlignment.end, spacing: 3, children: [
                IconButton(
                    tooltip: 'Edit profile and access',
                    onPressed: () => _editUser(a),
                    icon: const Icon(Icons.edit_outlined, size: 18)),
                IconButton(
                    tooltip: 'Grant credits',
                    onPressed: () => widget.onAction('finance', 'wallet_mint', {
                          'target': a['id'],
                          '_name': _displayName(a),
                        }),
                    icon: const Icon(Icons.add_card_rounded, size: 18)),
                PopupMenuButton<String>(
                    tooltip: 'More actions',
                    onSelected: (value) {
                      if (value == 'password') {
                        widget.onAction('users', 'account_password',
                            {'account': a['id'], '_name': _displayName(a)});
                      } else if (value == 'ledger') {
                        _showUser(a, tab: 2);
                      } else {
                        widget.onAction('users', 'account_delete',
                            {'account': a['id'], '_name': _displayName(a)});
                      }
                    },
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'password',
                              child: ListTile(
                                  leading: Icon(Icons.password_rounded),
                                  title: Text('Set password'))),
                          PopupMenuItem(
                              value: 'ledger',
                              child: ListTile(
                                  leading: Icon(Icons.receipt_long_rounded),
                                  title: Text('Wallet activity'))),
                          PopupMenuDivider(),
                          PopupMenuItem(
                              value: 'delete',
                              child: ListTile(
                                  leading: Icon(Icons.delete_outline_rounded),
                                  title: Text('Delete account'))),
                        ]),
              ]),
            ],
        ],
      ),
      const SizedBox(height: 10),
      Text('${rows.length} of ${accounts.length} users', style: _muted()),
    ]);
  }

  void _editUser(Map<String, dynamic> a) =>
      widget.onAction('users', 'account_update', {
        'account': a['id'],
        'handle': a['handle'],
        'email': a['email'],
        'role': a['role'],
        'is_admin': a['is_admin'],
        'status': a['status'],
        'profile': a['profile'] ?? <String, dynamic>{},
      });

  Widget _projects() {
    final spaces =
        _listOfMaps(_map(widget.results['spaces.space_list_all'])['spaces']);
    final q = search.text.trim().toLowerCase();
    final rows = spaces.where((s) {
      if (filter == 'awake' && _machineState(s) != 'awake') return false;
      if (filter == 'asleep' && _machineState(s) == 'awake') return false;
      return q.isEmpty ||
          '${s['name']} ${s['id']} ${s['owner_id']} ${_map(s['owner'])['handle']}'
              .toLowerCase()
              .contains(q);
    }).toList();
    rows.sort((a, b) {
      dynamic av;
      dynamic bv;
      if (sort == 'title') {
        av = '${a['name'] ?? a['id']}'.toLowerCase();
        bv = '${b['name'] ?? b['id']}'.toLowerCase();
      } else if (sort == 'owner') {
        av = '${_map(a['owner'])['handle'] ?? a['owner_id']}'.toLowerCase();
        bv = '${_map(b['owner'])['handle'] ?? b['owner_id']}'.toLowerCase();
      } else if (sort == 'spend') {
        av = _number(a['spent'] ?? _map(a['usage'])['spent']);
        bv = _number(b['spent'] ?? _map(b['usage'])['spent']);
      } else {
        av = '${a['created_at'] ?? ''}';
        bv = '${b['created_at'] ?? ''}';
      }
      final order = Comparable.compare(av as Comparable, bv as Comparable);
      return ascending ? order : -order;
    });
    final awake = spaces.where((s) => _machineState(s) == 'awake').length;
    final totalSpend = spaces.fold<double>(
        0, (sum, s) => sum + _number(s['spent'] ?? _map(s['usage'])['spent']));
    final palette = adminPalette(context);
    final adminsSpace = _map(widget.results['spaces.admins_space_get']);
    final adminsSpaceId = '${_map(adminsSpace['space'])['id'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _adminsSpaceCard(spaces, adminsSpace),
      const SizedBox(height: 18),
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Computers',
          icon: Icons.computer_rounded,
          subtitle: 'Awake computers are billed by the minute.',
          child: AdminDonutPanel(
            size: 132,
            center: '${spaces.length}',
            caption: 'projects',
            slices: [
              AdminChartSlice('Awake', awake.toDouble(), AppColors.success),
              AdminChartSlice('Asleep or none',
                  (spaces.length - awake).toDouble(), palette.first),
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
                    display: _credits(s['spent'] ?? _map(s['usage'])['spent'])),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
        controller: search,
        hint: 'Search title, id, or owner handle',
        onChanged: (_) => setState(() {}),
        trailing: PopupMenuButton<String>(
          tooltip: 'Sort projects',
          icon: const Icon(Icons.sort_rounded),
          onSelected: (value) => setState(() {
            if (sort == value) {
              ascending = !ascending;
            } else {
              sort = value;
              ascending = value == 'title' || value == 'owner';
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
                  checked: sort == value,
                  child: Row(children: [
                    Icon(icon, size: 18),
                    const SizedBox(width: 10),
                    Text(label),
                  ])),
          ],
        ),
      ),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'All projects', count: spaces.length),
          AdminFilterOption('awake', 'Awake',
              count: awake, icon: Icons.bolt_rounded),
          AdminFilterOption('asleep', 'Asleep',
              count: spaces.length - awake, icon: Icons.bedtime_outlined),
        ],
      ),
      const SizedBox(height: 14),
      AdminDataTable(
        empty:
            spaces.isEmpty ? 'No projects created yet.' : 'No projects match.',
        onRowTap: (index) => _showProject(rows[index]),
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
              Row(children: [
                AdminAvatar('${s['name'] ?? s['id']}',
                    size: 34,
                    avatar: _avatarOf(s),
                    icon: '${s['id']}' == adminsSpaceId
                        ? Icons.admin_panel_settings_rounded
                        : s['home'] == true
                            ? Icons.home_rounded
                            : Icons.folder_rounded),
                const SizedBox(width: 10),
                Expanded(
                    child: _primaryCell('${s['name'] ?? s['id']}',
                        '${'${s['id']}' == adminsSpaceId ? 'Admins space · ' : ''}${s['home'] == true ? 'Home · ' : ''}${_shortId(s['id'])}')),
              ]),
              Text(_owner(s)),
              Text('${s['agents'] ?? _list(s['workers']).length}',
                  textAlign: TextAlign.right),
              AdminStatusPill(_machineState(s)),
              Text(_credits(s['spent'] ?? _map(s['usage'])['spent']),
                  textAlign: TextAlign.right),
              Text(_date(s['created_at'])),
            ],
        ],
      ),
      const SizedBox(height: 10),
      Text(
          '${rows.length} projects · tap a row for overview, machine, cost, storage, logs, and people',
          style: _muted()),
    ]);
  }

  /// The project every platform administrator is kept a member of: the node
  /// adds each admin to it when it is chosen and whenever someone becomes one.
  Widget _adminsSpaceCard(
      List<Map<String, dynamic>> spaces, Map<String, dynamic> current) {
    final scheme = Theme.of(context).colorScheme;
    final chosen = _map(current['space']);
    final missing = '${current['missing'] ?? ''}';
    final admins =
        _listOfMaps(_map(widget.results['admin.admins_list'])['admins']);
    final name = '${chosen['name'] ?? chosen['id'] ?? ''}';
    final choose = FilledButton.tonalIcon(
      onPressed: () => _pickAdminsSpace(spaces, '${chosen['id'] ?? ''}'),
      icon: Icon(chosen.isEmpty ? Icons.add_rounded : Icons.swap_horiz_rounded,
          size: 18),
      label: Text(chosen.isEmpty ? 'Choose project' : 'Change'),
    );
    return AdminSectionCard(
      title: 'Platform admins space',
      icon: Icons.admin_panel_settings_rounded,
      subtitle:
          'Every platform admin is added to this project automatically, now and whenever someone is made an admin. Its agents and apps can read the platform database when they work for an admin.',
      child: _toolbar(
        Row(children: [
          AdminAvatar(chosen.isEmpty ? '?' : name,
              size: 40,
              icon: chosen.isEmpty
                  ? Icons.folder_off_outlined
                  : Icons.admin_panel_settings_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: chosen.isEmpty
                ? Text(
                    missing.isNotEmpty
                        ? 'The chosen project was deleted. Choose another one.'
                        : 'No project chosen. Admins are not added anywhere.',
                    style: missing.isNotEmpty
                        ? TextStyle(color: scheme.error)
                        : _muted())
                : _primaryCell(name,
                    '${admins.isEmpty ? 'Admins' : '${admins.length} ${admins.length == 1 ? 'admin' : 'admins'}'} are members · ${_shortId(chosen['id'])}'),
          ),
        ]),
        [
          if (chosen.isNotEmpty)
            OutlinedButton(
                onPressed: () => _showProject({...chosen}),
                child: const Text('Open')),
          if (chosen.isNotEmpty || missing.isNotEmpty)
            TextButton(
                onPressed: () async {
                  if (await _confirm(
                      'Stop using an admins space?',
                      'Admins already in ${chosen.isEmpty ? 'the project' : name} stay members; new admins are no longer added.',
                      'Stop')) {
                    await widget.onDirectAction(
                        'spaces', 'admins_space_set', {'space': ''});
                  }
                },
                child: const Text('Clear')),
          choose,
        ],
      ),
    );
  }

  Future<void> _pickAdminsSpace(
      List<Map<String, dynamic>> spaces, String currentId) async {
    // Direct conversations are between two accounts and cannot take members.
    final candidates = spaces
        .where((s) => '${s['direct_key'] ?? ''}'.isEmpty)
        .toList()
      ..sort((a, b) => '${a['name'] ?? a['id']}'
          .toLowerCase()
          .compareTo('${b['name'] ?? b['id']}'.toLowerCase()));
    final picked = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) =>
          _AdminsSpacePicker(projects: candidates, currentId: currentId),
    );
    if (picked == null || '${picked['id']}' == currentId) return;
    await widget.onDirectAction(
        'spaces', 'admins_space_set', {'space': '${picked['id']}'});
  }

  Widget _agents() {
    final bots = _listOfMaps(_map(widget.results['admin.bots_list'])['bots'])
        .where((b) => '${b['kind'] ?? 'agent'}' == 'agent')
        .toList();
    final listings =
        _listOfMaps(_map(widget.results['market.catalog'])['listings']);
    final byBot = <String, Map<String, dynamic>>{
      for (final l in listings) '${l['bot_id'] ?? l['bot']}': l
    };
    String status(Map<String, dynamic> b) =>
        '${byBot['${b['id']}']?['status'] ?? 'unlisted'}';
    final q = search.text.trim().toLowerCase();
    final rows = bots.where((b) {
      return (filter == 'all' || filter == status(b)) &&
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
    final palette = adminPalette(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          Text('${bots.length} agents on this node',
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          [
            OutlinedButton.icon(
              onPressed: () => widget.onAction(
                  'bots', 'agent_import_samples', const <String, dynamic>{}),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Import samples'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  widget.onAction('bots', 'bot_create', {'kind': 'agent'}),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add agent'),
            ),
          ]),
      const SizedBox(height: 16),
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Marketplace',
          icon: Icons.storefront_rounded,
          child: AdminDonutPanel(
            size: 132,
            center: '${bots.length}',
            caption: 'agents',
            slices: [
              AdminChartSlice(
                  'Listed', count('approved').toDouble(), AppColors.success),
              AdminChartSlice(
                  'In review', count('pending').toDouble(), AppColors.warning),
              AdminChartSlice(
                  'Denied', count('denied').toDouble(), AppColors.danger),
              AdminChartSlice(
                  'Unlisted', count('unlisted').toDouble(), palette.first),
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
                    e.key, e.value, palette[(i + 1) % palette.length],
                    display:
                        '${e.value.round()} ${e.value == 1 ? 'agent' : 'agents'}'),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search agent name, @handle, owner, model, or fallbacks…',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'All', count: bots.length),
          AdminFilterOption('pending', 'Review',
              count: count('pending'), icon: Icons.rate_review_outlined),
          AdminFilterOption('approved', 'Listed',
              count: count('approved'), icon: Icons.storefront_outlined),
          AdminFilterOption('denied', 'Denied',
              count: count('denied'), icon: Icons.block_rounded),
          AdminFilterOption('unlisted', 'Unlisted',
              count: count('unlisted'), icon: Icons.visibility_off_outlined),
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
        rows: [
          for (final b in rows) _agentRow(b, byBot['${b['id']}']),
        ],
      ),
    ]);
  }

  List<Widget> _agentRow(
      Map<String, dynamic> b, Map<String, dynamic>? listing) {
    final status = '${listing?['status'] ?? 'unlisted'}';
    final name = '${b['name'] ?? b['handle'] ?? 'Agent'}';
    return [
      _personCell(name, '@${b['handle'] ?? _shortId(b['id'])}',
          icon: Icons.smart_toy_rounded, avatar: _avatarOf(b)),
      Text('@${b['owner_handle'] ?? _shortId(b['owner_id'])}'),
      _primaryCell(
          '${b['model'] ?? 'Default'}', '${b['provider'] ?? 'platform'}'),
      Text(_perMinute(b['per_minute'] ?? _map(b['cost'])['per_minute']),
          textAlign: TextAlign.right),
      AdminStatusPill(status == 'approved' ? 'listed' : status),
      Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
        IconButton(
            tooltip: 'Edit agent',
            onPressed: () => widget.onAction('bots', 'bot_edit', {
                  'bot': b['id'],
                  'name': b['name'],
                  'instructions': b['instructions'],
                  'provider': b['provider'],
                  'model': b['model'],
                  'cost': b['cost'] ??
                      {
                        if (b['per_minute'] != null)
                          'per_minute': b['per_minute']
                      },
                  '_kind': 'agent',
                }),
            icon: const Icon(Icons.edit_outlined, size: 18)),
        if (status == 'pending') ...[
          IconButton.filledTonal(
              tooltip: 'Approve listing',
              onPressed: () => widget.onDirectAction('market', 'approve', {
                    'listing': listing?['id'],
                    'bot': b['id'],
                  }),
              icon: const Icon(Icons.check_rounded,
                  size: 18, color: AppColors.success)),
          IconButton(
              tooltip: 'Deny listing',
              onPressed: () => widget.onAction('market', 'deny', {
                    'listing': listing?['id'],
                    'bot': b['id'],
                    '_name': name,
                  }),
              icon: const Icon(Icons.block_rounded,
                  size: 18, color: AppColors.danger)),
        ] else
          IconButton(
              tooltip: status == 'unlisted' ? 'List in market' : 'Unlist',
              onPressed: () => status == 'unlisted'
                  ? widget.onAction('market', 'publish', {
                      'bot': b['id'],
                      'type': 'agent',
                      'name': b['name'],
                      'description': b['description'],
                    })
                  : widget.onDirectAction('market', 'unpublish', {
                      'listing': listing?['id'],
                    }),
              icon: Icon(
                  status == 'unlisted'
                      ? Icons.storefront_outlined
                      : Icons.visibility_off_outlined,
                  size: 18)),
        PopupMenuButton<String>(
          tooltip: 'More',
          onSelected: (_) => widget
              .onAction('bots', 'bot_delete', {'bot': b['id'], '_name': name}),
          itemBuilder: (_) => const [
            PopupMenuItem(
                value: 'delete',
                child: ListTile(
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('Delete agent'))),
          ],
        ),
      ]),
    ];
  }

  Widget _apps() {
    final bots =
        _listOfMaps(_map(widget.results['admin.bots_list'])['bots']).where((b) {
      final kind = '${b['kind'] ?? ''}';
      return kind == 'tool' || kind == 'mcp';
    }).toList();
    final samples =
        _listOfMaps(_map(widget.results['tools.mcp_samples'])['samples']);
    final listings =
        _listOfMaps(_map(widget.results['market.catalog'])['listings']);
    bool isServer(Map<String, dynamic> b) =>
        '${b['kind']}' == 'mcp' || _map(b['descriptor']).containsKey('url');
    final q = search.text.trim().toLowerCase();
    final rows = bots
        .where((b) =>
            q.isEmpty ||
            '${b['name']} ${b['handle']} ${b['kind']} ${b['url']} ${b['description']}'
                .toLowerCase()
                .contains(q))
        .toList();
    final listedIds = listings
        .where((l) => '${l['status']}' == 'approved')
        .map((l) => '${l['bot_id'] ?? l['bot']}')
        .toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(children: [
        AdminStatCard(
            label: 'Apps', value: '${bots.length}', icon: Icons.apps_rounded),
        AdminStatCard(
            label: 'From MCP servers',
            value: '${bots.where(isServer).length}',
            icon: Icons.hub_rounded,
            tone: AppColors.cyan),
        AdminStatCard(
            label: 'In the catalog',
            value:
                '${bots.where((b) => listedIds.contains('${b['id']}')).length}',
            icon: Icons.storefront_rounded,
            tone: AppColors.success,
            progress: bots.isEmpty
                ? 0
                : bots.where((b) => listedIds.contains('${b['id']}')).length /
                    bots.length),
      ]),
      const SizedBox(height: 18),
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search apps',
              onChanged: (_) => setState(() {})),
          [
            OutlinedButton.icon(
              onPressed: () => widget.onAction(
                  'tools', 'mcp_import_samples', const <String, dynamic>{}),
              icon: const Icon(Icons.download_rounded, size: 18),
              label:
                  Text(samples.isEmpty ? 'Import samples' : 'Import catalog'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  widget.onAction('tools', 'mcp_register', const {}),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add an app'),
            ),
          ]),
      const SizedBox(height: 16),
      _appSection('Apps (${rows.length})', rows, listings, isServer),
    ]);
  }

  Widget _appSection(
      String title,
      List<Map<String, dynamic>> rows,
      List<Map<String, dynamic>> listings,
      bool Function(Map<String, dynamic>) isServer) {
    return AdminSectionCard(
      title: title,
      icon: Icons.apps_rounded,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: rows.isEmpty
          ? AdminEmptyState(
              'No apps',
              search.text.isEmpty
                  ? 'Add an app or import the catalog.'
                  : 'No apps match your search.',
              icon: Icons.apps_outlined)
          : Column(children: [
              for (final b in rows)
                Builder(builder: (context) {
                  final server = isServer(b);
                  final listing = listings
                      .cast<Map<String, dynamic>?>()
                      .firstWhere(
                          (l) => '${l?['bot_id'] ?? l?['bot']}' == '${b['id']}',
                          orElse: () => null);
                  final listed =
                      listing != null && '${listing['status']}' != 'unlisted';
                  final name = '${b['name'] ?? b['handle'] ?? b['id']}';
                  return _adaptiveTile(
                    leading: AdminAvatar(name,
                        size: 40,
                        avatar: _avatarOf(b),
                        icon: server ? Icons.hub_rounded : Icons.apps_rounded),
                    title: Text(name,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        [
                          server ? 'MCP server' : 'app',
                          '${b['url'] ?? _map(b['descriptor'])['url'] ?? ''}',
                          _perMinute(
                              b['per_minute'] ?? _map(b['cost'])['per_minute']),
                        ].where((v) => v.isNotEmpty && v != '—').join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    actions: [
                      AdminStatusPill(
                          listed ? 'listed' : '${b['status'] ?? 'unlisted'}'),
                      IconButton(
                          tooltip: 'Edit',
                          onPressed: () => server
                              ? widget.onAction('tools', 'mcp_update', {
                                  'bot': b['id'],
                                  'name': b['name'],
                                  'url':
                                      b['url'] ?? _map(b['descriptor'])['url'],
                                  'auth': b['auth'] ??
                                      _map(b['descriptor'])['auth'],
                                })
                              : widget.onAction('bots', 'bot_edit', {
                                  'bot': b['id'],
                                  'name': b['name'],
                                  'cost': b['cost'] ??
                                      {
                                        if (b['per_minute'] != null)
                                          'per_minute': b['per_minute']
                                      },
                                  '_kind': '${b['kind'] ?? 'tool'}',
                                }),
                          icon: const Icon(Icons.edit_outlined, size: 18)),
                      if (server)
                        IconButton(
                            tooltip: 'Sign-in client',
                            onPressed: () => _mcpClient(b, name),
                            icon: const Icon(Icons.key_outlined, size: 18)),
                      IconButton(
                          tooltip: listed ? 'Unlist' : 'List',
                          onPressed: () => listed
                              ? widget.onDirectAction('market', 'unpublish',
                                  {'listing': listing['id']})
                              : widget.onAction('market', 'publish', {
                                  'bot': b['id'],
                                  'type': '${b['kind'] ?? 'tool'}',
                                  'name': b['name'],
                                  'description': b['description'],
                                }),
                          icon: Icon(
                              listed
                                  ? Icons.visibility_off_outlined
                                  : Icons.storefront_outlined,
                              size: 18)),
                      IconButton(
                          tooltip: 'Delete',
                          onPressed: () => widget.onAction(
                              server ? 'tools' : 'bots',
                              server ? 'mcp_delete' : 'bot_delete',
                              {'bot': b['id'], '_name': name}),
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18)),
                    ],
                  );
                }),
            ]),
    );
  }

  /// The OAuth client people sign in to an MCP server with, for providers
  /// that will not register Aseman by themselves. Its secret is never shown;
  /// leaving it empty keeps the saved one.
  Future<void> _mcpClient(Map<String, dynamic> server, String name) async {
    dynamic saved;
    try {
      saved = await widget
          .onDirectAction('tools', 'mcp_oauth_get', {'bot': server['id']});
    } catch (_) {
      return; // The console reports the error.
    }
    if (!mounted) return;
    final s = _map(saved);
    final fields = {
      for (final k in const [
        'client_id',
        'client_secret',
        'authorization_endpoint',
        'token_endpoint',
        'scopes',
        'params'
      ])
        k: TextEditingController(
            text: k == 'client_secret' ? '' : '${s[k] ?? ''}'),
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
      context: context,
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
                      'For a provider that will not register Aseman by itself: create an OAuth client there, then save it here. People sign in with it; its secret stays on the node.'),
                  if (widget.oauthRedirectUri.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    AdminKeyValue('Redirect address', widget.oauthRedirectUri,
                        mono: true),
                  ],
                  const SizedBox(height: 8),
                  for (final e in fields.entries) ...[
                    TextField(
                        controller: e.value,
                        obscureText: e.key == 'client_secret',
                        decoration: InputDecoration(
                            labelText: labels[e.key],
                            hintText: e.key == 'client_secret' &&
                                    s['has_secret'] == true
                                ? 'Saved. Type a new one to replace it'
                                : null,
                            border: const OutlineInputBorder())),
                    const SizedBox(height: 10),
                  ],
                ]),
          ),
        ),
        actions: [
          if ('${s['client_id'] ?? ''}'.isNotEmpty)
            TextButton(
                onPressed: () => Navigator.pop(
                    context, {'bot': server['id'], 'client_id': ''}),
                child: const Text('Remove client')),
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'bot': server['id'],
                    for (final e in fields.entries)
                      if (e.key != 'client_secret' ||
                          e.value.text.trim().isNotEmpty)
                        e.key: e.value.text.trim(),
                  }),
              child: const Text('Save')),
        ],
      ),
    );
    for (final c in fields.values) {
      c.dispose();
    }
    if (body == null) return;
    try {
      await widget.onDirectAction('tools', 'mcp_oauth_set', body);
    } catch (_) {
      // The console reports the error.
    }
  }

  Widget _talent() {
    final response = _map(widget.results['users.accounts_list']);
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
    }).toList();
    final q = search.text.toLowerCase().trim();
    final rows = all.where((t) {
      final status = '${t['status'] ?? 'pending'}';
      return (filter == 'all' || filter == status) &&
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
    final palette = adminPalette(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Review status',
          icon: Icons.badge_rounded,
          child: AdminDonutPanel(
            size: 132,
            center: '${all.length}',
            caption: 'people',
            slices: [
              AdminChartSlice(
                  'Pending', count('pending').toDouble(), AppColors.warning),
              AdminChartSlice(
                  'Approved', count('approved').toDouble(), AppColors.success),
              AdminChartSlice(
                  'Denied', count('rejected').toDouble(), AppColors.danger),
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
                AdminChartSlice(e.key, e.value, palette[2],
                    display: '${e.value.round()}'),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search name, username, or skills',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('pending', 'Pending',
              count: count('pending'), icon: Icons.hourglass_empty_rounded),
          AdminFilterOption('approved', 'Approved',
              count: count('approved'), icon: Icons.verified_outlined),
          AdminFilterOption('rejected', 'Denied',
              count: count('rejected'), icon: Icons.block_rounded),
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
              _personCell('${t['name'] ?? t['display_name'] ?? 'Person'}',
                  '@${t['handle'] ?? t['username'] ?? 'unknown'}',
                  avatar: _avatarOf(t)),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (final skill in _stringList(t['skills']).take(3))
                  _Tag(skill),
                if (_stringList(t['skills']).length > 3)
                  _Tag('+${_stringList(t['skills']).length - 3}'),
              ]),
              Text(_credits(t['rate'] ?? t['hourly_rate']),
                  textAlign: TextAlign.right),
              AdminStatusPill('${t['status'] ?? 'pending'}'),
              Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
                if ('${t['status']}' != 'approved')
                  FilledButton.tonalIcon(
                      onPressed: () =>
                          widget.onDirectAction('users', 'account_update', {
                            'account': t['id'],
                            'profile': {'marketStatus': 'approved'},
                          }),
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: const Text('Approve')),
                if ('${t['status']}' != 'rejected')
                  IconButton(
                      tooltip: 'Deny',
                      onPressed: () =>
                          widget.onDirectAction('users', 'account_update', {
                            'account': t['id'],
                            'profile': {'marketStatus': 'rejected'},
                          }),
                      icon: const Icon(Icons.block_rounded,
                          size: 18, color: AppColors.danger)),
              ]),
            ],
        ],
      ),
    ]);
  }

  void _setPeriod(String value) {
    setState(() => filter = value);
    final days = const {'7d': 7, '30d': 30, '90d': 90}[value];
    widget.onQuery?.call('finance.overview', {
      if (days != null)
        'since': DateTime.now()
            .toUtc()
            .subtract(Duration(days: days))
            .toIso8601String(),
    });
  }

  /// Requests for talent people posted, which partners read through their
  /// API key, and the partner keys themselves.
  Widget _talentRequests() {
    final scheme = Theme.of(context).colorScheme;
    final all =
        _listOfMaps(_map(widget.results['talent.admin_requests'])['requests']);
    final keys =
        _listOfMaps(_map(widget.results['talent.partner_keys'])['keys']);
    int count(String s) => all.where((r) => '${r['status']}' == s).length;
    final status =
        const ['open', 'closed', 'hidden', 'deleted', 'all'].contains(filter)
            ? filter
            : 'all';
    final q = search.text.toLowerCase().trim();
    final rows = all.where((r) {
      final s = '${r['status']}';
      return (status == 'all' ? s != 'deleted' : s == status) &&
          (q.isEmpty ||
              '${r['title']} ${r['category']} ${r['company']} ${r['owner_handle']} ${_stringList(r['skills']).join(' ')}'
                  .toLowerCase()
                  .contains(q));
    }).toList()
      ..sort((a, b) =>
          '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}'));
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
        await widget.onDirectAction(
            'talent', 'admin_request_status', {'id': r['id'], 'status': to});
      } catch (_) {
        // The console reports the error.
      }
    }

    final activeKeys = keys.where((k) => '${k['status']}' == 'active').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 3, children: [
        AdminStatCard(
            label: 'Open requests',
            value: '${count('open')}',
            hint: 'What partners read now',
            icon: Icons.work_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Taken down',
            value: '${count('hidden')}',
            hint: 'Removed by an admin',
            icon: Icons.visibility_off_rounded,
            tone: count('hidden') == 0 ? null : AppColors.warning),
        AdminStatCard(
            label: 'Partner keys',
            value: '$activeKeys',
            hint: '${keys.length - activeKeys} revoked',
            icon: Icons.key_rounded),
      ]),
      const SizedBox(height: 18),
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search title, category, company or poster',
              onChanged: (_) => setState(() {})),
          const []),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: status,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'All',
              count: all.where((r) => '${r['status']}' != 'deleted').length),
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
                'No requests', 'Jobs people post for talent show up here.',
                icon: Icons.work_outline_rounded)
            : Column(children: [
                for (final r in rows)
                  ExpansionTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    collapsedShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    leading: AdminAvatar('${r['title']}',
                        icon: Icons.work_rounded, size: 40),
                    title: Text('${r['title']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${r['category']} · ${budget(r)} · @${r['owner_handle'] ?? '—'} · ${_date(r['created_at'])}'),
                    trailing: AdminStatusPill('${r['status']}' == 'hidden'
                        ? 'removed'
                        : '${r['status']}'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    expandedCrossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AdminKeyValue('Company', '${r['company'] ?? '—'}'),
                      if ('${r['timeline'] ?? ''}'.isNotEmpty)
                        AdminKeyValue(
                            'Timeline',
                            _humanKey('${r['timeline']}'
                                    .replaceAll('lt_', 'under '))
                                .toLowerCase()),
                      if (_stringList(r['skills']).isNotEmpty)
                        AdminKeyValue(
                            'Skills', _stringList(r['skills']).join(', ')),
                      const SizedBox(height: 6),
                      KeyedSubtree(
                        key: PageStorageKey<String>('request:${r['id']}'),
                        child: SelectableText('${r['description'] ?? ''}',
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurface)),
                      ),
                      if ('${r['status']}' != 'deleted') ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: '${r['status']}' == 'hidden'
                              ? OutlinedButton.icon(
                                  onPressed: () => setStatus(r, 'open'),
                                  icon:
                                      const Icon(Icons.undo_rounded, size: 18),
                                  label: const Text('Restore'))
                              : OutlinedButton.icon(
                                  onPressed: () => setStatus(r, 'hidden'),
                                  icon: const Icon(
                                      Icons.visibility_off_outlined,
                                      size: 18),
                                  label: const Text('Take down')),
                        ),
                      ],
                    ],
                  ),
              ]),
      ),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Partner keys',
        icon: Icons.key_rounded,
        subtitle:
            'Partners read the open requests on the developer host: GET /v1/partner/talent-requests with Authorization: Bearer pk_live_….',
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: FilledButton.icon(
                onPressed: _createPartnerKey,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('New partner key')),
          ),
          if (keys.isEmpty)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Text('No partner keys yet.', style: _muted()))
          else
            for (final k in keys)
              _adaptiveTile(
                leading: AdminAvatar('${k['name']}', icon: Icons.key_rounded),
                title: Text('${k['name']}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: SelectableText(
                    '${k['prefix']}…${k['last4']} · ${_integer(k['requests'])} calls · last used ${_date(k['last_used_at'])}'),
                actions: [
                  AdminStatusPill('${k['status']}'),
                  if ('${k['status']}' == 'active')
                    TextButton(
                        onPressed: () => _revokePartnerKey(k),
                        child: const Text('Revoke')),
                ],
              ),
        ]),
      ),
    ]);
  }

  Future<void> _createPartnerKey() async {
    final controller = TextEditingController();
    final name = await showAppDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: const Text('New partner key'),
        content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Partner name',
                hintText: 'Acme Recruiting',
                border: OutlineInputBorder()),
            onSubmitted: (v) => Navigator.pop(context, v)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Create')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    dynamic result;
    try {
      result = await widget.onDirectAction(
          'talent', 'partner_key_create', {'name': name.trim()});
    } catch (_) {
      return; // The console reports the error.
    }
    final secret = '${_map(result)['secret'] ?? ''}';
    if (secret.isEmpty || !mounted) return;
    await showAppDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: const Text('Copy the key now'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text(
              'It is shown only this once. Give it to the partner; only its last four characters are kept.'),
          const SizedBox(height: 12),
          SelectableText(secret,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        ]),
        actions: [
          TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy')),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _revokePartnerKey(Map<String, dynamic> key) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_off_rounded),
        title: Text('Revoke ${key['name']}?'),
        content: const Text(
            'The partner can no longer read requests with it. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget
          .onDirectAction('talent', 'partner_key_revoke', {'id': key['id']});
    } catch (_) {
      // The console reports the error.
    }
  }

  /// The developer API across every organization: what each spent and called
  /// in the last days, and the latest requests (read-only).
  Widget _developer() {
    final overview = _map(widget.results['developer.admin_orgs']);
    final totals = _map(overview['totals']);
    final orgs = _listOfMaps(overview['orgs']);
    final logs =
        _listOfMaps(_map(widget.results['developer.admin_logs'])['logs']);
    final window = _integer(totals['windowDays']);
    final q = search.text.toLowerCase().trim();
    final shown = orgs
        .where((o) =>
            q.isEmpty ||
            '${o['name']} ${o['owner']} ${o['id']}'.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => _number(b['spend']).compareTo(_number(a['spend'])));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 4, children: [
        AdminStatCard(
            label: 'Organizations',
            value: '${_integer(totals['orgs'])}',
            hint:
                '${_integer(totals['active'])} active in ${window == 0 ? 30 : window} days',
            icon: Icons.apartment_rounded),
        AdminStatCard(
            label: 'Spend',
            value: _money(totals['spend']),
            hint: '${_compact(totals['requests'])} requests',
            icon: Icons.payments_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Errors',
            value: _compact(totals['errors']),
            hint: 'Failed requests',
            icon: Icons.error_outline_rounded,
            tone: _integer(totals['errors']) == 0 ? null : AppColors.warning),
        AdminStatCard(
            label: 'Held in balances',
            value: _money(totals['balances']),
            hint:
                '${_integer(totals['keys'])} keys · ${_integer(totals['running'])} computers running · ${_bytes(totals['bytes'])} stored',
            icon: Icons.account_balance_wallet_rounded),
      ]),
      const SizedBox(height: 18),
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search organization or owner',
              onChanged: (_) => setState(() {})),
          const []),
      const SizedBox(height: 12),
      AdminDataTable(
        empty: 'No organization uses the developer API yet.',
        columns: const [
          AdminTableColumn('Organization', width: 240),
          AdminTableColumn('Balance', width: 110, align: TextAlign.right),
          AdminTableColumn('Spend', width: 110, align: TextAlign.right),
          AdminTableColumn('Requests', width: 110, align: TextAlign.right),
          AdminTableColumn('Keys · people', width: 130, align: TextAlign.right),
          AdminTableColumn('Last request', width: 150),
          AdminTableColumn('', width: 90, align: TextAlign.right),
        ],
        rows: [
          for (final o in shown)
            [
              _primaryCell('${o['name']}',
                  '${o['kind'] == 'personal' ? 'personal' : 'team'} · @${o['owner'] ?? '—'}'),
              Text(_money(o['balance']), textAlign: TextAlign.right),
              Text(_money(o['spend']), textAlign: TextAlign.right),
              Text(
                  '${_compact(o['requests'])}${_integer(o['errors']) > 0 ? ' (${_integer(o['errors'])} failed)' : ''}',
                  textAlign: TextAlign.right),
              Text('${_integer(o['keys'])} · ${_integer(o['members'])}',
                  textAlign: TextAlign.right),
              Text(_date(o['lastAt'])),
              TextButton(
                  onPressed: () => _showDeveloperOrg(o),
                  child: const Text('Open')),
            ]
        ],
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Latest requests',
        icon: Icons.receipt_long_rounded,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: _developerLogs(logs, withOrg: true),
      ),
    ]);
  }

  Widget _developerLogs(List<Map<String, dynamic>> logs,
          {bool withOrg = false}) =>
      AdminDataTable(
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
              _primaryCell('${l['method'] ?? ''} ${l['path'] ?? ''}',
                  '${l['keyName'] ?? ''} · ${_integer(l['latencyMs'])} ms'),
              _primaryCell('${l['model'] ?? '—'}',
                  '${l['provider'] ?? ''}${'${l['error'] ?? ''}'.isEmpty ? '' : ' · ${l['error']}'}'),
              AdminStatusPill(_integer(l['status']) >= 400
                  ? 'failed ${_integer(l['status'])}'
                  : 'ok ${_integer(l['status'])}'),
              Text('${_compact(l['tokensIn'])} / ${_compact(l['tokensOut'])}',
                  textAlign: TextAlign.right),
              Text(_money(l['cost']), textAlign: TextAlign.right),
            ]
        ],
      );

  Future<void> _showDeveloperOrg(Map<String, dynamic> org) async {
    dynamic value;
    try {
      value = await widget
          .onDirectAction('developer', 'admin_org', {'org': org['id']});
    } catch (_) {
      return; // The console reports the error.
    }
    if (!mounted) return;
    final d = _map(value);
    final total = _map(_map(d['usage'])['total']);
    final storage = _map(d['storage']);
    final settings = _map(d['settings']);
    await showAppDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 980, maxHeight: 760),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            Row(children: [
              AdminAvatar('${org['name']}',
                  size: 44, icon: Icons.apartment_rounded),
              const SizedBox(width: 12),
              Expanded(
                  child: _primaryCell(
                      '${org['name']}', '${org['id']} · @${org['owner']}')),
              IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 16),
            AdminGrid(maxColumns: 4, children: [
              AdminStatCard(
                  label: 'Balance',
                  value: _money(_map(d['org'])['balance']),
                  hint: '${_money(d['held'])} held for running work',
                  icon: Icons.account_balance_wallet_rounded),
              AdminStatCard(
                  label: 'Spend',
                  value: _money(total['spend']),
                  hint:
                      '${_compact(total['requests'])} requests · ${_compact(total['errors'])} failed',
                  icon: Icons.payments_rounded),
              AdminStatCard(
                  label: 'Monthly cap',
                  value: _number(settings['accountMonthlyCap']) > 0
                      ? _money(settings['accountMonthlyCap'])
                      : 'None',
                  hint: '${_money(settings['spentMonth'])} this month',
                  icon: Icons.savings_rounded),
              AdminStatCard(
                  label: 'Storage',
                  value: _bytes(storage['usedBytes']),
                  hint:
                      '${_integer(storage['files'])} files · ${_money(storage['perMonth'])} a month',
                  icon: Icons.cloud_rounded),
            ]),
            _heading('Keys'),
            AdminDataTable(
              empty: 'No keys.',
              columns: const [
                AdminTableColumn('Key', width: 240),
                AdminTableColumn('Status', width: 100),
                AdminTableColumn('This month',
                    width: 120, align: TextAlign.right),
                AdminTableColumn('Requests',
                    width: 100, align: TextAlign.right),
                AdminTableColumn('Last used', width: 150),
              ],
              rows: [
                for (final k in _listOfMaps(d['keyList']))
                  [
                    _primaryCell(
                        '${k['name']}', '${k['prefix']}…${k['last4']}'),
                    AdminStatusPill('${k['status']}'),
                    Text(_money(k['spentMonth']), textAlign: TextAlign.right),
                    Text(_compact(k['requests']), textAlign: TextAlign.right),
                    Text(_date(k['lastUsedAt'])),
                  ]
              ],
            ),
            _heading('People'),
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
                        '${m['name'] ?? m['handle']}', '@${m['handle']}'),
                    Text('${m['role']}'),
                    AdminStatusPill('${m['status']}'),
                  ]
              ],
            ),
            if (_listOfMaps(d['computerList']).isNotEmpty) ...[
              _heading('Computers'),
              AdminDataTable(
                empty: 'No computers.',
                columns: const [
                  AdminTableColumn('Computer', width: 240),
                  AdminTableColumn('Status', width: 120),
                  AdminTableColumn('Size', width: 160),
                  AdminTableColumn('Minutes',
                      width: 100, align: TextAlign.right),
                ],
                rows: [
                  for (final c in _listOfMaps(d['computerList']))
                    [
                      _primaryCell('${c['name']}', '${c['image']}'),
                      AdminStatusPill('${c['status']}'),
                      Text(
                          '${compactDecimal(_number(_map(c['spec'])['cpu']))} vCPU · ${_bytes(_number(_map(c['spec'])['memoryMb']) * 1024 * 1024)}'),
                      Text(compactDecimal(_number(c['minutes']), decimals: 1),
                          textAlign: TextAlign.right),
                    ]
                ],
              ),
            ],
            _heading('Requests'),
            _developerLogs(_listOfMaps(d['logs'])),
          ]),
        ),
      ),
    );
  }

  Widget _finance() {
    final o = _map(widget.results['finance.overview']);
    final income = _map(o['income']);
    final charged = _map(o['charged']);
    final paid = _map(o['paid_out']);
    final reconcile = _map(widget.results['finance.reconcile']);
    final costs = _map(widget.results['finance.costs']);
    final providers = _map(widget.results['finance.provider_costs']);
    final palette = adminPalette(context);
    final components = [
      AdminChartSlice('LLM tokens', _number(charged['llm']), palette[0],
          display: _money(charged['llm'])),
      AdminChartSlice('Computers', _number(charged['compute']), palette[1],
          display: _money(charged['compute'])),
      AdminChartSlice('Agent time', _number(charged['agent_time']), palette[2],
          display: _money(charged['agent_time'])),
      AdminChartSlice('Apps', _number(charged['tools']), palette[3],
          display: _money(charged['tools'])),
    ];
    final destinations = [
      AdminChartSlice('Creators', _number(paid['creators']), palette[4],
          display: _money(paid['creators'])),
      AdminChartSlice('Platform', _number(o['kept']), AppColors.success,
          display: _money(o['kept'])),
    ];
    final bill =
        _number(providers['bill'] ?? providers['total'] ?? costs['compute']);
    final billed = _number(providers['charged'] ?? charged['compute']);
    final issues = _listOfMaps(reconcile['issues']);
    final balanced = reconcile['ok'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminFilterChips<String>(
        selected: filter == 'all' || const {'7d', '30d', '90d'}.contains(filter)
            ? filter
            : 'all',
        onSelected: _setPeriod,
        options: const [
          AdminFilterOption('7d', 'Last 7 days',
              icon: Icons.date_range_rounded),
          AdminFilterOption('30d', 'Last 30 days'),
          AdminFilterOption('90d', 'Last 90 days'),
          AdminFilterOption('all', 'All time',
              icon: Icons.all_inclusive_rounded),
        ],
      ),
      const SizedBox(height: 16),
      AdminGrid(children: [
        AdminStatCard(
            label: 'Income',
            value: _money(income['credits_sold']),
            hint:
                'Credit packs sold · ${_integer(income['purchases'])} purchases',
            icon: Icons.south_west_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Customer spend',
            value: _money(charged['total']),
            hint: '${_credits(charged['total'])} used on work',
            icon: Icons.query_stats_rounded),
        AdminStatCard(
            label: 'Paid to creators',
            value: _money(paid['creators']),
            hint: "Earned by people's agents and tools",
            icon: Icons.people_alt_rounded,
            tone: palette[4]),
        AdminStatCard(
            label: 'Net revenue',
            value: _money(o['kept']),
            hint: 'Kept by the platform, before provider bills',
            icon: Icons.account_balance_rounded,
            progress: _number(charged['total']) <= 0
                ? null
                : _number(o['kept']) / _number(charged['total']),
            tone:
                _number(o['kept']) < 0 ? AppColors.danger : AppColors.success),
      ]),
      const SizedBox(height: 16),
      AdminGrid(maxColumns: 2, minTileWidth: 360, children: [
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
          child: Column(children: [
            AdminStackedBar(slices: destinations, height: 22),
            const SizedBox(height: 14),
            AdminKeyValue('Platform LLM', _money(paid['platform_llm'])),
            AdminKeyValue('Platform compute', _money(paid['platform_compute'])),
            AdminKeyValue('Platform bots', _money(paid['platform_bots'])),
            const Divider(height: 22),
            AdminKeyValue(
                'Unspent credits users hold', _money(o['held_by_users'])),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Computers: provider bill vs what you charged',
        icon: Icons.compare_arrows_rounded,
        child: LayoutBuilder(builder: (context, constraints) {
          final margin = billed <= 0 ? 0.0 : (billed - bill) / billed;
          final bars = Column(children: [
            AdminBarList(items: [
              AdminChartSlice('Customers charged', billed, AppColors.success,
                  display: _money(billed)),
              AdminChartSlice('Provider billed', bill, AppColors.warning,
                  display: _money(bill)),
            ]),
            for (final row in _listOfMaps(providers['by_resource']))
              AdminKeyValue('${row['label'] ?? row['resource']}',
                  _money(row['units'] ?? row['cost'])),
          ]);
          final gauge = AdminGauge(
            value: margin.clamp(0, 1).toDouble(),
            label: 'margin',
            display: billed <= 0 ? '—' : '${(margin * 100).round()}%',
            color: margin < 0 ? AppColors.danger : AppColors.success,
            size: 124,
          );
          if (constraints.maxWidth < 520) {
            return Column(children: [gauge, const SizedBox(height: 12), bars]);
          }
          return Row(children: [
            gauge,
            const SizedBox(width: 24),
            Expanded(child: bars),
          ]);
        }),
      ),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Ledger check',
        icon: balanced ? Icons.verified_rounded : Icons.report_rounded,
        trailing: IconButton.filledTonal(
            tooltip: 'Reconcile wallets',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.sync_rounded, size: 19)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AdminStatusPill(balanced ? 'healthy' : 'error'),
            const SizedBox(width: 10),
            Expanded(
              child: Text(balanced
                  ? 'Balanced — ${_integer(reconcile['checked'])} wallets checked'
                  : '${issues.length} reconciliation ${issues.length == 1 ? 'issue' : 'issues'} in ${_integer(reconcile['checked'])} wallets'),
            ),
          ]),
          for (final issue in issues)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(AppShape.control),
              ),
              child: Row(children: [
                const Icon(Icons.warning_amber_rounded,
                    color: AppColors.danger, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${issue['kind']}'.replaceAll('_', ' '),
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                        SelectableText(
                            '${issue['detail'] ?? ''} · ${issue['account_id'] ?? ''}',
                            style: _muted()),
                      ]),
                ),
              ]),
            ),
        ]),
      ),
    ]);
  }

  Widget _purchases() {
    final response = _map(widget.results['finance.purchases_list']);
    final all = _listOfMaps(response['purchases'] ?? response['transactions']);
    final q = search.text.trim().toLowerCase();
    final charged = all
        .where((p) => '${p['status']}' == 'credited' && p['sandbox'] != true)
        .toList();
    final sandbox = all.where((p) => p['sandbox'] == true).toList();
    final pending = all.where((p) => '${p['status']}' == 'pending').toList();
    final reversed = all.where((p) => '${p['status']}' == 'reversed').toList();
    final rows = all.where((p) {
      final match = switch (filter) {
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
    final selectedRows =
        all.where((p) => selected.contains(_rowId(p))).toList();
    final selectedSandbox =
        selectedRows.where((p) => p['sandbox'] == true).length;
    final selectedLive = selectedRows.length - selectedSandbox;
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(children: [
        AdminStatCard(
            label: 'Charged',
            value: _money(_sum(charged, 'amount')),
            hint: '${charged.length} live purchases',
            icon: Icons.paid_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Sandbox',
            value: _money(_sum(sandbox, 'amount')),
            hint: '${sandbox.length} test transactions',
            icon: Icons.science_rounded,
            tone: AppColors.cyan),
        AdminStatCard(
            label: 'Pending',
            value: _money(_sum(pending, 'amount')),
            hint: '${pending.length} waiting',
            icon: Icons.hourglass_top_rounded,
            tone: pending.isEmpty ? null : AppColors.warning),
        AdminStatCard(
            label: 'Reversed',
            value: _money(_sum(reversed, 'amount')),
            hint: '${reversed.length} refunds',
            icon: Icons.undo_rounded,
            tone: reversed.isEmpty ? null : AppColors.danger),
      ]),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Purchases by outcome',
        icon: Icons.stacked_bar_chart_rounded,
        child: AdminStackedBar(height: 20, slices: [
          AdminChartSlice('Live', charged.length.toDouble(), AppColors.success),
          AdminChartSlice('Sandbox', sandbox.length.toDouble(), AppColors.cyan),
          AdminChartSlice(
              'Pending', pending.length.toDouble(), AppColors.warning),
          AdminChartSlice(
              'Reversed', reversed.length.toDouble(), AppColors.danger),
        ]),
      ),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search email, product, or status',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
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
        child: selected.isEmpty
            ? const SizedBox(width: double.infinity)
            : Container(
                margin: const EdgeInsets.only(top: 12),
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(999)),
                child: Row(children: [
                  Icon(Icons.checklist_rounded,
                      color: scheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text('${selected.length} selected',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSecondaryContainer))),
                  TextButton(
                      onPressed: () => setState(selected.clear),
                      child: const Text('Clear')),
                  if (selectedLive > 0)
                    OutlinedButton(
                        onPressed: () => _labelPurchases(selectedRows, true),
                        child: Text('Mark sandbox ($selectedLive)')),
                  if (selectedLive > 0 && selectedSandbox > 0)
                    const SizedBox(width: 8),
                  if (selectedSandbox > 0)
                    FilledButton(
                        onPressed: () => _labelPurchases(selectedRows, false),
                        child: Text('Mark live ($selectedSandbox)')),
                ]),
              ),
      ),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: all.isEmpty
            ? 'Credit pack sales will appear here after the first top-up.'
            : 'No purchases match.',
        selected: (index) => selected.contains(_rowId(rows[index])),
        onRowTap: (index) => setState(() {
          final id = _rowId(rows[index]);
          selected.contains(id) ? selected.remove(id) : selected.add(id);
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
                  value: selected.contains(_rowId(p)),
                  onChanged: (_) => setState(() {
                        final id = _rowId(p);
                        selected.contains(id)
                            ? selected.remove(id)
                            : selected.add(id);
                      })),
              _personCell('${p['email'] ?? p['account_handle'] ?? 'Unknown'}',
                  _shortId(p['account_id'])),
              Text('${p['product_id'] ?? p['product'] ?? '—'}'),
              Text(_money(p['amount'] ?? p['listed_amount']),
                  textAlign: TextAlign.right),
              Wrap(spacing: 5, runSpacing: 4, children: [
                AdminStatusPill('${p['status'] ?? 'pending'}'),
                if (p['sandbox'] == true) const AdminStatusPill('sandbox'),
              ]),
              Text(_date(p['created_at'] ?? p['purchased_at'])),
              Text(_shortId(p['transaction_id'] ?? p['id'])),
            ],
        ],
      ),
    ]);
  }

  Future<void> _labelPurchases(
      List<Map<String, dynamic>> purchases, bool sandbox) async {
    await widget.onDirectAction('finance', 'purchases_label', {
      'transaction_ids':
          purchases.map((p) => '${p['transaction_id'] ?? p['id']}').toList(),
      'sandbox': sandbox,
    });
    if (mounted) setState(selected.clear);
  }

  Widget _payouts() {
    final response = _map(widget.results['finance.payouts_list']);
    final all = _listOfMaps(response['payouts'] ?? response['requests']);
    final pending = all.where((p) => '${p['status']}' == 'pending').toList();
    final paid = all.where((p) => '${p['status']}' == 'paid').toList();
    final rejected = all.where((p) => '${p['status']}' == 'rejected').toList();
    final ordered = [...all]..sort((a, b) {
        // Waiting requests first, then newest.
        final wait = ('${a['status']}' == 'pending' ? 0 : 1)
            .compareTo('${b['status']}' == 'pending' ? 0 : 1);
        return wait != 0
            ? wait
            : '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}');
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 3, children: [
        AdminStatCard(
            label: 'Waiting to pay',
            value: _money(_sum(pending, 'amount')),
            hint:
                '${pending.length} ${pending.length == 1 ? 'request' : 'requests'}',
            icon: Icons.hourglass_top_rounded,
            tone: pending.isEmpty ? null : AppColors.warning),
        AdminStatCard(
            label: 'Marked paid',
            value: _money(_sum(paid, 'amount')),
            hint: 'This queue only — already resolved',
            icon: Icons.price_check_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Returned',
            value: _money(_sum(rejected, 'amount')),
            hint: '${rejected.length} rejected',
            icon: Icons.undo_rounded,
            tone: rejected.isEmpty ? null : AppColors.danger),
      ]),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Queue',
        icon: Icons.payments_rounded,
        subtitle:
            'Pay creators externally, then record the provider confirmation here.',
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: ordered.isEmpty
            ? const AdminEmptyState(
                'No payouts', 'Creator withdrawal requests will appear here.',
                icon: Icons.payments_outlined)
            : Column(children: [
                for (final p in ordered)
                  ExpansionTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    collapsedShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    initiallyExpanded: '${p['status']}' == 'pending' &&
                        identical(p, ordered.first),
                    leading: AdminAvatar(
                        '${p['handle'] ?? p['account_id'] ?? '?'}',
                        size: 40),
                    title: Text(
                        '${(p['handle'] ?? '').toString().isEmpty ? p['account_id'] ?? 'Creator' : '@${p['handle']}'}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${_money(p['amount'])} · ${_date(p['created_at'])} · ${p['method'] ?? 'external'}'),
                    trailing: AdminStatusPill('${p['status'] ?? 'pending'}'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    children: [
                      for (final e in _map(p['destination']).entries)
                        AdminKeyValue(_humanKey(e.key), '${e.value}',
                            mono: true),
                      if (p['destination'] is String)
                        AdminKeyValue('Destination', '${p['destination']}',
                            mono: true),
                      AdminKeyValue(
                          'Request id', '${p['id'] ?? p['request_id']}',
                          mono: true),
                      if ('${p['status']}' == 'pending') ...[
                        const SizedBox(height: 8),
                        Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                  onPressed: () =>
                                      _resolvePayout(p, 'rejected'),
                                  icon:
                                      const Icon(Icons.undo_rounded, size: 18),
                                  label: const Text('Reject and return funds')),
                              FilledButton.icon(
                                  onPressed: () => _resolvePayout(p, 'paid'),
                                  icon: const Icon(Icons.price_check_rounded,
                                      size: 18),
                                  label: const Text('Mark paid')),
                            ]),
                      ],
                    ],
                  ),
              ]),
      ),
    ]);
  }

  void _resolvePayout(Map<String, dynamic> p, String status) =>
      widget.onAction('finance', 'payout_resolve', {
        'payout_id': p['id'],
        'status': status,
        '_amount': p['amount'],
        '_name': p['handle'],
      });

  Widget _models() {
    final response = _map(widget.results['llm.llm_providers_list']).isNotEmpty
        ? _map(widget.results['llm.llm_providers_list'])
        : _map(widget.results['llm.llm_models']);
    final providers = _listOfMaps(response['providers']);
    final models = <Map<String, dynamic>>[];
    for (final provider in providers) {
      for (final raw in _listOfMaps(provider['models'])) {
        models.add({...raw, '_provider': provider});
      }
    }
    final q = search.text.trim().toLowerCase();
    final shown = models.where((m) {
      final provider = _map(m['_provider']);
      final matches = switch (filter) {
        'all' => true,
        'unpriced' => m['unpriced'] == true,
        'disabled' => m['disabled'] == true,
        _ => '${provider['id']}' == filter ||
            _modelPurpose(m).toLowerCase() == filter,
      };
      return matches &&
          (q.isEmpty ||
              '${provider['name']} ${m['id']} ${m['name']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final palette = adminPalette(context);
    final purposeColor = {
      for (var i = 0; i < _modelKinds.length; i++)
        _modelKinds[i].$2: palette[i % palette.length],
    };
    final present = [
      for (final k in _modelKinds)
        if (models.any((m) => _modelPurpose(m) == k.$2)) k.$2
    ];
    final unpriced = models.where((m) => m['unpriced'] == true).length;
    final disabled = models.where((m) => m['disabled'] == true).length;
    final vercel = providers.where((p) => '${p['kind']}' == 'vercel').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Models by purpose',
          icon: Icons.category_rounded,
          child: AdminDonutPanel(
            size: 132,
            center: '${models.length}',
            caption: 'models',
            slices: [
              for (final purpose in present)
                AdminChartSlice(
                    purpose,
                    models
                        .where((m) => _modelPurpose(m) == purpose)
                        .length
                        .toDouble(),
                    purposeColor[purpose]!),
            ],
          ),
        ),
        AdminSectionCard(
          title: 'Output price per 1M tokens',
          icon: Icons.bar_chart_rounded,
          child: AdminBarList(
            maxItems: 5,
            empty: 'No priced models yet.',
            items: [
              for (final m in models)
                AdminChartSlice('${m['name'] ?? m['id']}',
                    _number(m['output_price']), purposeColor[_modelPurpose(m)]!,
                    display: _modelPrice(m['output_price'])),
            ],
          ),
        ),
      ]),
      const SizedBox(height: 18),
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search provider or model',
              onChanged: (_) => setState(() {})),
          [
            if (vercel.isNotEmpty)
              OutlinedButton.icon(
                  onPressed: () => _importVercel(vercel),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Import from Vercel')),
            FilledButton.icon(
                onPressed:
                    providers.isEmpty ? null : () => _showModel(providers),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add model')),
          ]),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'All', count: models.length),
          for (final purpose in present)
            AdminFilterOption(purpose.toLowerCase(), purpose,
                count: models.where((m) => _modelPurpose(m) == purpose).length),
          if (unpriced > 0)
            AdminFilterOption('unpriced', 'Needs a price', count: unpriced),
          if (disabled > 0)
            AdminFilterOption('disabled', 'Disabled', count: disabled),
          for (final p in providers)
            AdminFilterOption('${p['id']}', '${p['name']}',
                icon: Icons.hub_outlined),
        ],
      ),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: providers.isEmpty
            ? 'Add a provider first, then add its models here.'
            : 'No models match.',
        columns: const [
          AdminTableColumn('Provider', width: 180),
          AdminTableColumn('Model', width: 260),
          AdminTableColumn('Purpose', width: 130),
          AdminTableColumn('Price', width: 260, align: TextAlign.right),
          AdminTableColumn('Actions', width: 170, align: TextAlign.right),
        ],
        rows: [
          for (final m in shown)
            [
              Row(children: [
                Icon(
                    _map(m['_provider'])['enabled'] == false
                        ? Icons.cloud_off_rounded
                        : Icons.cloud_done_rounded,
                    size: 18,
                    color: _map(m['_provider'])['enabled'] == false
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : AppColors.success),
                const SizedBox(width: 8),
                Expanded(
                  child: _primaryCell(
                      '${_map(m['_provider'])['name']}',
                      _map(m['_provider'])['enabled'] == false
                          ? 'disabled'
                          : 'enabled'),
                ),
              ]),
              _primaryCell(
                  '${m['name'] ?? m['id']}',
                  [
                    if (m['name'] != null) '${m['id']}',
                    if (m['disabled'] == true) 'disabled',
                    if ('${m['source'] ?? ''}'.isNotEmpty)
                      m['markup'] is num
                          ? 'from ${m['source']} +${compactDecimal(_number(m['markup']))}%'
                          : m['unpriced'] == true
                              ? 'from ${m['source']}'
                              : 'from ${m['source']}, priced by hand',
                  ].join(' · ')),
              _Tag(_modelPurpose(m), color: purposeColor[_modelPurpose(m)]),
              Text(_modelPriceText(m),
                  textAlign: TextAlign.right,
                  style: m['unpriced'] == true
                      ? const TextStyle(
                          color: AppColors.warning, fontWeight: FontWeight.w700)
                      : null),
              Wrap(alignment: WrapAlignment.end, children: [
                IconButton(
                    tooltip: m['disabled'] == true
                        ? 'Enable model'
                        : 'Disable model',
                    onPressed: () =>
                        _setModelDisabled(m, m['disabled'] != true),
                    icon: Icon(
                        m['disabled'] == true
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 18)),
                IconButton(
                    tooltip: 'Edit model',
                    onPressed: () => _showModel(providers,
                        provider: _map(m['_provider']), model: m),
                    icon: const Icon(Icons.edit_outlined, size: 18)),
                IconButton(
                    tooltip: 'Remove model',
                    onPressed: () => _removeModel(m),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18)),
              ]),
            ],
        ],
      ),
    ]);
  }

  /// Disabling hides a model from new agents, the pickers and the developer
  /// API; agents already on it keep running. The provider is saved whole.
  Future<void> _setModelDisabled(Map<String, dynamic> model, bool disabled) {
    final provider = _map(model['_provider']);
    return widget.onDirectAction('llm', 'llm_provider_set', {
      ...provider,
      'models': [
        for (final m in _listOfMaps(provider['models']))
          if ('${m['id']}' == '${model['id']}')
            ({...m}..remove('disabled'))
              ..addAll({if (disabled) 'disabled': true})
          else
            m
      ],
    });
  }

  /// Brings Vercel AI Gateway's catalog into a Vercel provider at Vercel's
  /// price plus a markup; importing again updates the models in place.
  Future<void> _importVercel(List<Map<String, dynamic>> vercel) async {
    final last = [
      for (final p in vercel)
        for (final m in _listOfMaps(p['models']))
          if (m['markup'] is num) _number(m['markup'])
    ];
    final picked = await showAppDialog<(String, double)>(
      context: context,
      builder: (_) => _ImportVercelDialog(
          providers: vercel,
          markup: last.isEmpty ? null : last.first.toDouble()),
    );
    if (picked == null || !mounted) return;
    dynamic result;
    try {
      result = await widget.onDirectAction('llm', 'llm_import_vercel',
          {'provider_id': picked.$1, 'markup': picked.$2});
    } catch (_) {
      return; // The console reports the error.
    }
    await widget.onRefresh();
    if (!mounted) return;
    final r = _map(result);
    final skipped = _map(r['skipped']);
    final needPrice = _stringList(r['need_price']);
    final gone = _stringList(r['gone']);
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.download_done_rounded),
        title: const Text('Vercel models imported'),
        content: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${_integer(r['added'])} added · ${_integer(r['updated'])} updated · ${_integer(r['unchanged'])} unchanged, at Vercel\'s price +${compactDecimal(_number(r['markup']))}%.'),
                if (skipped.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      'Skipped: ${skipped.entries.map((e) => '${e.value} ${e.key}').join(', ')}.',
                      style: _muted()),
                ],
                if (needPrice.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      '${needPrice.length} need a price before they are served: ${needPrice.take(8).join(', ')}${needPrice.length > 8 ? '…' : ''}',
                      style: const TextStyle(color: AppColors.warning)),
                ],
                if (gone.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                      '${gone.length} imported before are no longer listed by Vercel (kept, remove them if unused): ${gone.take(8).join(', ')}${gone.length > 8 ? '…' : ''}',
                      style: _muted()),
                ],
              ]),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _showModel(List<Map<String, dynamic>> providers,
      {Map<String, dynamic>? provider, Map<String, dynamic>? model}) async {
    final selected = provider ??
        providers.firstWhere((p) => '${p['id']}' == filter,
            orElse: () => providers.first);
    await showAppDialog<void>(
      context: context,
      builder: (_) => _ModelEditorDialog(
        providers: providers,
        provider: selected,
        model: model,
        onSave: (nextProvider) =>
            widget.onDirectAction('llm', 'llm_provider_set', nextProvider),
      ),
    );
  }

  Future<void> _removeModel(Map<String, dynamic> model) async {
    final provider = _map(model['_provider']);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text('Remove ${model['name'] ?? model['id']}?'),
        content: Text(
            'Agents using it will fall back to the default model from ${provider['name']}.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.onDirectAction('llm', 'llm_provider_set', {
      ...provider,
      'models': _listOfMaps(provider['models'])
          .where((item) => '${item['id']}' != '${model['id']}')
          .toList(),
    });
  }

  Widget _decision() {
    final setting = _map(widget.results['llm.llm_decision_get']);
    final providers = _listOfMaps(setting['providers']);
    final enabled = setting['enabled'] == true;
    final providerId = '${setting['provider_id'] ?? ''}';
    final modelId = '${setting['model_id'] ?? ''}';
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _settingStatus(setting),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Fast decision model',
          icon: Icons.bolt_rounded,
          subtitle: 'App selection, routing, progress and completion checks.',
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppSwitchCard(
              icon: Icons.alt_route_rounded,
              title: enabled ? 'On' : 'Off',
              subtitle: enabled
                  ? 'Decisions use the fast model below together with each agent’s own model.'
                  : modelId.isEmpty
                      ? 'Pick a provider and model below to turn it on. Until then every agent decides with its own model.'
                      : 'Every agent decides with its own model.',
              value: enabled,
              onChanged: modelId.isEmpty && !enabled
                  ? null
                  : (value) => widget.onDirectAction('llm', 'llm_decision_set',
                      _decisionBody(setting, enabled: value)),
            ),
            const SizedBox(height: 20),
            _modelPicker(
              slot: 'decision',
              providers: providers,
              providerId: providerId,
              modelId: modelId,
              modelsOf: (id) => _decisionModels(providers, id),
              onSelect: (provider, model) => widget.onDirectAction(
                  'llm',
                  'llm_decision_set',
                  _decisionBody(setting, provider: provider, model: model)),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        AppSwitchCard(
          icon: Icons.verified_user_outlined,
          title: 'Auto-approve low-risk calls',
          subtitle:
              'Every other action still waits for a person; approvals are written to the work log.',
          value: setting['auto_approve'] == true,
          onChanged: (value) => widget.onDirectAction('llm', 'llm_decision_set',
              _decisionBody(setting, autoApprove: value)),
        ),
      ]),
    );
  }

  /// The node's OpenCode switch: on, OpenCode builds, tests and repairs the
  /// on-demand apps and does the spaces' coding, briefed by the agents; off
  /// (the default), the agents do all of it themselves. Either way apps get
  /// the same toolchain and the platform verifies each one before it opens.
  Widget _openCode() {
    final setting = _map(widget.results['spaces.opencode_get']);
    final enabled = setting['enabled'] == true;
    const shared = [
      'Fullstack Elpian apps (native frontend, phone widget) and web apps',
      'OpenUI agent islands wired to the project\'s apps and agents',
      'Elpian UI validation and headless end-to-end testing',
      'Platform checks before an app opens: it starts, runs on QuickJS, its scenarios pass',
      'Changes to existing apps in place, with their history',
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Both builders are complete: whichever is chosen is in effect.
        _settingStatus({...setting, 'active': setting.isNotEmpty}),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'App builder',
          icon: Icons.construction_rounded,
          subtitle:
              'Who builds, tests and repairs on-demand apps and writes code in projects.',
          child: AppSwitchCard(
            icon: Icons.terminal_rounded,
            title: enabled ? 'OpenCode on' : 'OpenCode off',
            subtitle: enabled
                ? 'Agents brief OpenCode, which plans, builds, tests and repairs apps and does every coding task in the project\'s computer, on the agents\' metered model gateway.'
                : 'The project\'s own agents build, test and repair apps and write code themselves. OpenCode is not used.',
            value: enabled,
            onChanged: setting.isEmpty
                ? null
                : (value) => widget.onDirectAction(
                    'spaces', 'opencode_set', {'enabled': value}),
          ),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'The same in both modes',
          icon: Icons.verified_outlined,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in shared)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.check_rounded, size: 18),
                          const SizedBox(width: 10),
                          Expanded(child: Text(line)),
                        ]),
                  ),
              ]),
        ),
      ]),
    );
  }

  /// The node's image model: agents make images with their image tool using
  /// this one model, whatever model they run on, charged at its prices.
  Widget _imageModel() {
    final setting = _map(widget.results['llm.llm_image_get']);
    final providers = _listOfMaps(setting['providers']);
    final enabled = setting['enabled'] == true;
    final providerId = '${setting['provider_id'] ?? ''}';
    final modelId = '${setting['model_id'] ?? ''}';
    Map<String, dynamic> body({bool? on, String? provider, String? model}) => {
          'enabled': on ?? enabled,
          'provider_id': provider ?? providerId,
          'model_id': model ?? modelId,
        };
    List<Map<String, dynamic>> imageModels(String id) => _listOfMaps(providers
        .cast<Map<String, dynamic>?>()
        .firstWhere((p) => '${p?['id']}' == id,
            orElse: () => null)?['image_models']);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _settingStatus(setting),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Image model',
          icon: Icons.image_rounded,
          subtitle:
              'Agents make images through the platform\'s image function, never with their own chat model, so any agent can make images. Mark a model "Image" on the Models page to offer it here.',
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            AppSwitchCard(
              icon: Icons.image_outlined,
              title: enabled ? 'On' : 'Off',
              subtitle: enabled
                  ? 'Images are made with the model below and charged at its prices on the Models page.'
                  : modelId.isEmpty
                      ? 'Pick a provider and model below to turn it on. Until then agents cannot make images.'
                      : 'Agents cannot make images.',
              value: enabled,
              onChanged: modelId.isEmpty && !enabled
                  ? null
                  : (value) => widget.onDirectAction(
                      'llm', 'llm_image_set', body(on: value)),
            ),
            const SizedBox(height: 20),
            _modelPicker(
              slot: 'image',
              providers: providers,
              providerId: providerId,
              modelId: modelId,
              modelsOf: imageModels,
              onSelect: (provider, model) => widget.onDirectAction('llm',
                  'llm_image_set', body(provider: provider, model: model)),
            ),
          ]),
        ),
      ]),
    );
  }

  /// Provider then model, each picked with chips. The node takes a provider
  /// only with one of its models, so picking a provider picks its first
  /// model too and saves both; a provider with no model for this purpose is
  /// shown with a hint and not saved. Options the node no longer offers stay
  /// visible (marked unavailable) so the current choice shows.
  Widget _modelPicker({
    required String slot,
    required List<Map<String, dynamic>> providers,
    required String providerId,
    required String modelId,
    required List<Map<String, dynamic>> Function(String providerId) modelsOf,
    required void Function(String providerId, String modelId) onSelect,
    bool allowNone = false,
  }) {
    final picked = _pickedProvider[slot];
    final shownProvider = picked ?? providerId;
    final models = modelsOf(shownProvider);
    final shownModel = picked != null ? '' : modelId;
    List<AppChoice<String>> choices(
            List<Map<String, dynamic>> options, String value, IconData icon) =>
        [
          for (final o in options)
            AppChoice('${o['id']}', '${o['name'] ?? o['id']}', icon: icon),
          if (value.isNotEmpty && !options.any((o) => '${o['id']}' == value))
            AppChoice(value, '$value (unavailable)',
                icon: Icons.warning_amber_rounded),
        ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AppChoiceField<String>(
        label: 'Provider',
        value: shownProvider,
        onChanged: (v) {
          if (v == shownProvider) return;
          final offered = modelsOf(v);
          if (v.isEmpty || offered.isNotEmpty) {
            setState(() => _pickedProvider.remove(slot));
            onSelect(v, v.isEmpty ? '' : '${offered.first['id']}');
          } else {
            setState(() => _pickedProvider[slot] = v);
          }
        },
        choices: [
          if (allowNone)
            const AppChoice('', 'None — not used',
                icon: Icons.do_not_disturb_on_outlined),
          ...choices(providers, shownProvider, Icons.hub_outlined),
        ],
      ),
      if (shownProvider.isNotEmpty) ...[
        const SizedBox(height: 18),
        AppChoiceField<String>(
          label: 'Model',
          hint: models.isEmpty
              ? 'This provider offers no model for this purpose yet. Mark one for it on the Models page.'
              : null,
          value: shownModel,
          onChanged: (v) {
            if (v == shownModel) return;
            setState(() => _pickedProvider.remove(slot));
            onSelect(shownProvider, v);
          },
          choices: choices(models, shownModel, Icons.memory_rounded),
        ),
      ],
    ]);
  }

  Widget _memoryModels() {
    final setting = _map(widget.results['llm.llm_memory_get']);
    final providers = _listOfMaps(setting['providers']);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _settingStatus(setting),
        const SizedBox(height: 16),
        _memorySlot(
          title: 'Memory chat model',
          icon: Icons.edit_note_rounded,
          hint:
              'Reads each finished conversation and writes down preferences, decisions, people, and ways of working.',
          providers: providers,
          setting: setting,
          providerKey: 'chat_provider_id',
          modelKey: 'chat_model_id',
          listKey: 'chat_models',
          active: setting['chat_active'],
        ),
        const SizedBox(height: 16),
        _memorySlot(
          title: 'Embedding model',
          icon: Icons.scatter_plot_rounded,
          hint:
              'Turns memories into vectors so agents find relevant context by meaning. Changing it re-indexes every project.',
          providers: providers,
          setting: setting,
          providerKey: 'embedding_provider_id',
          modelKey: 'embedding_model_id',
          listKey: 'embedding_models',
          active: setting['embedding_active'],
          confirm: true,
        ),
        const SizedBox(height: 14),
        Text(
            'Projects pay for memory token use at the model prices configured on Models, counted against the project budget.',
            style: _muted()),
      ]),
    );
  }

  Widget _memorySlot({
    required String title,
    required IconData icon,
    required String hint,
    required List<Map<String, dynamic>> providers,
    required Map<String, dynamic> setting,
    required String providerKey,
    required String modelKey,
    required String listKey,
    dynamic active,
    bool confirm = false,
  }) {
    final providerId = '${setting[providerKey] ?? ''}';
    List<Map<String, dynamic>> modelsOf(String id) {
      final provider = providers
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => '${p?['id']}' == id, orElse: () => null);
      return _listOfMaps(provider?[listKey] ?? provider?['models']);
    }

    Future<void> save(Map<String, dynamic> body) async {
      if (confirm &&
          !await _confirm(
              'Re-index every project?',
              'Changing the embedding model rebuilds every project’s memory index. Recall is slower until it finishes.',
              'Change model')) {
        return;
      }
      await widget.onDirectAction('llm', 'llm_memory_set', body);
    }

    return AdminSectionCard(
      title: title,
      icon: icon,
      subtitle: hint,
      trailing: active == null
          ? null
          : AdminStatusPill(active == true ? 'active' : 'off'),
      child: _modelPicker(
        slot: providerKey,
        allowNone: true,
        providers: providers,
        providerId: providerId,
        modelId: '${setting[modelKey] ?? ''}',
        modelsOf: modelsOf,
        onSelect: (provider, model) => save({
          ..._memoryBody(setting),
          providerKey: provider,
          modelKey: model,
        }),
      ),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.help_outline_rounded),
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action)),
          ],
        ),
      ) ==
      true;

  Widget _health() {
    final scheme = Theme.of(context).colorScheme;
    final report = _map(widget.results['admin.health']);
    final checks = _listOfMaps(report['checks']);
    final pluginHealth =
        _listOfMaps(_map(widget.results['admin.plugins_health'])['health']);
    final counts = _map(report['counts']);
    String statusOf(Map<String, dynamic> c) =>
        '${c['status'] ?? (c['ok'] == true ? 'ok' : 'fail')}';
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final check in checks) {
      (groups['${check['group'] ?? 'Platform'}'] ??= []).add(check);
    }
    if (pluginHealth.isNotEmpty) groups['Module health'] = pluginHealth;
    for (final rows in groups.values) {
      rows.sort((a, b) =>
          _healthRank(statusOf(a)).compareTo(_healthRank(statusOf(b))));
    }
    final fail = counts.isNotEmpty
        ? _integer(counts['fail'])
        : checks.where((c) => '${c['status']}' == 'fail').length;
    final warn = counts.isNotEmpty
        ? _integer(counts['warn'])
        : checks.where((c) => '${c['status']}' == 'warn').length;
    final ok = counts.isNotEmpty
        ? _integer(counts['ok'])
        : checks.where((c) => '${c['status']}' == 'ok').length;
    final total = ok + warn + fail;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminHeroCard(
        tone: fail > 0
            ? AppColors.danger
            : warn > 0
                ? AppColors.warning
                : AppColors.success,
        icon: fail > 0
            ? Icons.gpp_maybe_rounded
            : warn > 0
                ? Icons.tips_and_updates_rounded
                : Icons.verified_rounded,
        title: fail > 0
            ? '$fail ${fail == 1 ? 'check needs' : 'checks need'} fixing'
            : warn > 0
                ? 'Working, with $warn to review'
                : 'Healthy deployment',
        message: total == 0
            ? 'Re-check the deployment to load live configuration checks.'
            : 'Checked ${_date(report['generated_at'])}. Secrets are never shown, only whether they are set.',
        actions: [
          FilledButton.tonalIcon(
              onPressed: widget.onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Re-check')),
        ],
        visual: AdminDonutChart(
          size: 140,
          center: total == 0 ? '—' : '${(ok / total * 100).round()}%',
          caption: 'healthy',
          slices: [
            AdminChartSlice('Healthy', ok.toDouble(), AppColors.success),
            AdminChartSlice('Worth a look', warn.toDouble(), AppColors.warning),
            AdminChartSlice('Need fixing', fail.toDouble(), AppColors.danger),
          ],
        ),
      ),
      const SizedBox(height: 16),
      AdminGrid(maxColumns: 3, minTileWidth: 180, children: [
        AdminStatCard(
            label: 'Need fixing',
            value: '$fail',
            hint: fail > 0 ? 'Broken or unsafe' : 'Nothing broken',
            icon: Icons.cancel_rounded,
            tone: fail > 0 ? AppColors.danger : AppColors.success),
        AdminStatCard(
            label: 'Worth a look',
            value: '$warn',
            hint: 'Works, but something is unset',
            icon: Icons.error_rounded,
            tone: warn > 0 ? AppColors.warning : null),
        AdminStatCard(
            label: 'Healthy',
            value: '$ok',
            icon: Icons.check_circle_rounded,
            tone: AppColors.success),
      ]),
      const SizedBox(height: 16),
      for (final group in groups.entries) ...[
        AdminSectionCard(
          title: group.key,
          trailing: Text(
              '${group.value.where((c) => adminTone(statusOf(c)) == AdminTone.ok).length}/${group.value.length} ok',
              style: _muted()),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Column(children: [
            for (final c in group.value)
              Builder(builder: (context) {
                final tone = adminTone(statusOf(c));
                final color = adminToneColor(context, tone);
                final detail = '${c['detail'] ?? c['message'] ?? ''}';
                final fix = '${c['fix'] ?? ''}';
                return Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tone == AdminTone.ok
                        ? Colors.transparent
                        : color.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(AppShape.control),
                  ),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(adminToneIcon(tone), color: color, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${c['label'] ?? c['name'] ?? c['id']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                if (detail.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(detail, style: _muted()),
                                ],
                                if (fix.isNotEmpty && tone != AdminTone.ok) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                        color: scheme.primaryContainer,
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                    child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.build_circle_outlined,
                                              size: 16,
                                              color: scheme.onPrimaryContainer),
                                          const SizedBox(width: 6),
                                          Flexible(
                                            child: Text('Fix: $fix',
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: scheme
                                                        .onPrimaryContainer,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          ),
                                        ]),
                                  ),
                                ],
                              ]),
                        ),
                      ]),
                );
              }),
          ]),
        ),
        const SizedBox(height: 14),
      ],
      if (checks.isEmpty && pluginHealth.isEmpty)
        const AdminEmptyState('No health report',
            'Re-check the deployment to load live configuration checks.',
            icon: Icons.monitor_heart_outlined),
    ]);
  }

  Widget _liveChip(String period) => FilterChip(
        selected: live,
        showCheckmark: false,
        avatar:
            Icon(live ? Icons.sensors_rounded : Icons.pause_rounded, size: 18),
        label: Text(live ? 'Live · $period' : 'Paused'),
        onSelected: (value) => setState(() => live = value),
      );

  Widget _node() {
    final stats = _map(widget.results['admin.node_stats']);
    final r = _map(stats['resources']);
    final node = _map(stats['node']);
    final telemetry = _map(widget.results['admin.telemetry']);
    final plugins = _listOfMaps(telemetry['plugins']);
    final mesh = _map(widget.results['federation.nodes_list']);
    final nodes = _listOfMaps(mesh['nodes']);
    final load = _doubleList(r['load_avg']);
    final cores = _number(r['cpu_cores'], fallback: 1);
    final memoryPercent = _number(r['mem_used_percent']);
    final palette = adminPalette(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text('${node['id'] ?? 'This node'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ),
        _liveChip('5s'),
      ]),
      const SizedBox(height: 12),
      AdminSectionCard(
        title: 'Resources',
        icon: Icons.speed_rounded,
        child: Wrap(
          alignment: WrapAlignment.spaceAround,
          spacing: 12,
          runSpacing: 12,
          children: [
            AdminGauge(
                label: 'CPU load',
                value:
                    (load.isEmpty ? 0 : load.first) / (cores == 0 ? 1 : cores)),
            AdminGauge(label: 'Memory', value: memoryPercent / 100),
            AdminGauge(
                label: 'Disk', value: _number(r['disk_used_percent']) / 100),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AdminGrid(children: [
        AdminStatCard(
            label: 'Modules',
            value: '${node['plugins'] ?? 0}',
            hint: '${node['goroutines'] ?? 0} goroutines',
            icon: Icons.extension_rounded),
        AdminStatCard(
            label: 'Uptime',
            value: _uptime(r['host_uptime_sec']),
            hint: '${r['cpu_cores'] ?? '—'} cores',
            icon: Icons.timer_rounded,
            tone: AppColors.cyan),
        AdminStatCard(
            label: 'Disk',
            value: '${_number(r['disk_used_percent']).round()}%',
            hint:
                '${_bytes(r['disk_used_bytes'])} of ${_bytes(r['disk_total_bytes'])}',
            icon: Icons.storage_rounded,
            progress: _number(r['disk_used_percent']) / 100,
            tone: AppColors.warning),
        AdminStatCard(
            label: 'Runtime',
            value: '${node['go_version'] ?? '—'}',
            hint: 'Process ${_bytes(r['process_rss_bytes'])}',
            icon: Icons.code_rounded,
            tone: AppColors.success),
      ]),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, constraints) {
        final narrow = constraints.maxWidth < 700;
        final charts = <Widget>[
          AdminLiveChart(
            label: 'CPU load',
            samples: cpu,
            value: '${(cpu.isEmpty ? 0 : cpu.last).round()}%',
            subtitle:
                'load ${load.map((v) => v.toStringAsFixed(2)).join(' / ')}',
            color: AppColors.cyan,
          ),
          AdminLiveChart(
            label: 'Memory',
            samples: memory,
            value: '${memoryPercent.round()}%',
            subtitle:
                '${_bytes(r['mem_used_bytes'])} of ${_bytes(r['mem_total_bytes'])} · process ${_bytes(r['process_rss_bytes'])}',
            color: palette.first,
          ),
        ];
        if (narrow) {
          return Column(
              children: [charts[0], const SizedBox(height: 12), charts[1]]);
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: charts[0]),
          const SizedBox(width: 12),
          Expanded(child: charts[1]),
        ]);
      }),
      const SizedBox(height: 14),
      AdminSectionCard(
        title: 'Module health',
        icon: Icons.health_and_safety_rounded,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: plugins.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text('No telemetry yet.', style: _muted()))
            : Column(children: [
                for (final p in plugins)
                  ListTile(
                    leading: Icon(
                        adminToneIcon(
                            p['ok'] == true ? AdminTone.ok : AdminTone.bad),
                        color: p['ok'] == true
                            ? AppColors.success
                            : AppColors.danger),
                    title: Text('${p['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${p['message'] ?? ''}'),
                    trailing:
                        AdminStatusPill(p['ok'] == true ? 'healthy' : 'error'),
                  ),
              ]),
      ),
      const SizedBox(height: 14),
      AdminSectionCard(
        title: 'Mesh',
        icon: Icons.hub_rounded,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: nodes.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text('This node is not federated with any other.',
                    style: _muted()))
            : Column(children: [
                for (final n in nodes)
                  ListTile(
                    leading: AdminAvatar('${n['id']}',
                        icon: n['is_central'] == true
                            ? Icons.hub_rounded
                            : Icons.dns_rounded),
                    title: Text(
                        '${n['id']}${n['id'] == mesh['local_node'] ? ' (this node)' : ''}${n['is_central'] == true ? ' · central' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        '${n['url'] ?? ''} · last seen ${_date(n['last_seen'])}'),
                    trailing: AdminStatusPill('${n['status'] ?? 'unknown'}'),
                  ),
              ]),
      ),
    ]);
  }

  Widget _nodePlugins() {
    final plugins =
        _listOfMaps(_map(widget.results['admin.plugins_list'])['plugins']);
    final active = _map(_map(widget.results['admin.wiring'])['active']);
    bool loaded(Map<String, dynamic> p) =>
        const {'loaded', 'initialized', 'started'}.contains('${p['state']}');
    final q = search.text.trim().toLowerCase();
    final shown = plugins.where((p) {
      final kind = '${p['type']}' == 'adapter' ? 'adapter' : 'namespace';
      return (filter == 'all' ||
              filter == kind ||
              (filter == 'error' && p['last_error'] != null)) &&
          (q.isEmpty ||
              '${p['name']} ${p['type']} ${p['category']} ${p['provides']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final p in shown) {
      final key = '${p['type']}' == 'adapter'
          ? 'Adapters · ${p['category'] ?? 'other'}'
          : 'Action namespaces';
      (groups[key] ??= []).add(p);
    }
    final errors = plugins.where((p) => p['last_error'] != null).length;
    final loadedCount = plugins.where(loaded).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 3, minTileWidth: 180, children: [
        AdminStatCard(
            label: 'Loaded',
            value: '$loadedCount / ${plugins.length}',
            icon: Icons.extension_rounded,
            progress: plugins.isEmpty ? 0 : loadedCount / plugins.length),
        AdminStatCard(
            label: 'Active adapters',
            value: '${active.length}',
            hint: active.entries.map((e) => '${e.key}: ${e.value}').join(' · '),
            icon: Icons.cable_rounded,
            tone: AppColors.cyan),
        AdminStatCard(
            label: 'Errors',
            value: '$errors',
            icon: Icons.error_rounded,
            tone: errors > 0 ? AppColors.danger : AppColors.success),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search namespaces and adapters',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      AdminFilterChips<String>(
        selected: filter,
        onSelected: (v) => setState(() => filter = v),
        options: [
          AdminFilterOption('all', 'All', count: plugins.length),
          AdminFilterOption('namespace', 'Namespaces',
              icon: Icons.api_rounded,
              count: plugins.where((p) => '${p['type']}' != 'adapter').length),
          AdminFilterOption('adapter', 'Adapters',
              icon: Icons.cable_rounded,
              count: plugins.where((p) => '${p['type']}' == 'adapter').length),
          if (errors > 0)
            AdminFilterOption('error', 'With errors',
                icon: Icons.error_outline_rounded, count: errors),
        ],
      ),
      const SizedBox(height: 16),
      for (final group in groups.entries) ...[
        AdminSectionCard(
          title: group.key,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(children: [
            for (final p in group.value)
              _adaptiveTile(
                leading: AdminAvatar('${p['name']}',
                    icon: '${p['type']}' == 'adapter'
                        ? Icons.cable_rounded
                        : Icons.api_rounded),
                title: Text(
                    '${p['name']}${p['version'] == null ? '' : '  v${p['version']}'}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(
                    [
                      _stringList(p['provides']).join(', '),
                      p['state_changed'] == null
                          ? ''
                          : 'since ${_date(p['state_changed'])}',
                      '${p['last_error'] ?? ''}',
                    ].where((x) => x.isNotEmpty).join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                actions: [
                  if (p['category'] != null &&
                      active['${p['category']}'] == p['name'])
                    const _Tag('Active', icon: Icons.radio_button_checked)
                  else if (p['category'] != null)
                    TextButton(
                        onPressed: () => widget.onDirectAction(
                            'admin',
                            'plugins_set_active',
                            {'category': p['category'], 'plugin': p['name']}),
                        child: const Text('Make active')),
                  AdminStatusPill(
                      '${p['last_error'] == null ? p['state'] : 'error'}'),
                  Switch(
                    value: loaded(p),
                    thumbIcon: WidgetStateProperty.resolveWith((states) => Icon(
                        states.contains(WidgetState.selected)
                            ? Icons.power_rounded
                            : Icons.power_off_rounded)),
                    onChanged: (on) async {
                      if (!on &&
                          !await _confirm(
                              'Unload ${p['name']}?',
                              'Its actions stop answering until it is loaded again.',
                              'Unload')) {
                        return;
                      }
                      await widget.onDirectAction(
                          'admin',
                          on ? 'plugins_load' : 'plugins_unload',
                          {'name': p['name']});
                    },
                  ),
                ],
              ),
          ]),
        ),
        const SizedBox(height: 14),
      ],
      if (groups.isEmpty)
        const AdminEmptyState(
            'No modules match', 'Try a different namespace or adapter name.',
            icon: Icons.extension_off_rounded),
    ]);
  }

  Widget _logs() {
    final all = _listOfMaps(_map(widget.results['admin.logs'])['logs']);
    final q = search.text.trim().toLowerCase();
    final rows = all.where((line) {
      final level = _logLevel('${line['level'] ?? 'log'}');
      return (filter == 'all' || filter == level) &&
          (q.isEmpty ||
              '${line['logger']} ${line['context']} ${line['message']}'
                  .toLowerCase()
                  .contains(q));
    }).toList()
      ..sort((a, b) => '${a['time'] ?? ''}'.compareTo('${b['time'] ?? ''}'));
    final dump = rows.map((line) {
      final level =
          _logLevel('${line['level'] ?? 'log'}').toUpperCase().padRight(5);
      return '${_date(line['time'])} $level ${line['logger'] == null ? '' : '[${line['logger']}] '}${line['message'] ?? ''}';
    }).join('\n');
    int count(String level) =>
        all.where((l) => _logLevel('${l['level'] ?? 'log'}') == level).length;
    final scheme = Theme.of(context).colorScheme;
    // Events per minute over the window on screen, split by level.
    final buckets = <String, Map<String, int>>{};
    for (final line in all) {
      final t = _time(line['time']);
      if (t.length < 5) continue;
      final minute = t.substring(0, 5);
      final level = _logLevel('${line['level'] ?? 'log'}');
      final bucket = buckets[minute] ??= {};
      bucket[level] = (bucket[level] ?? 0) + 1;
    }
    final minutes = buckets.keys.toList()..sort();
    final recent =
        minutes.length > 30 ? minutes.sublist(minutes.length - 30) : minutes;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          AdminFilterChips<String>(
            selected: filter,
            onSelected: (v) => setState(() => filter = v),
            options: [
              AdminFilterOption('all', 'All', count: all.length),
              AdminFilterOption('log', 'Info',
                  count: count('log'), icon: Icons.info_outline_rounded),
              AdminFilterOption('warn', 'Warnings',
                  count: count('warn'), icon: Icons.warning_amber_rounded),
              AdminFilterOption('error', 'Errors',
                  count: count('error'), icon: Icons.error_outline_rounded),
            ],
          ),
          [
            _liveChip('3s'),
            IconButton.filledTonal(
              tooltip: 'Copy filtered log',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: dump));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Filtered log copied')));
                }
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
          ]),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 14),
        AdminSectionCard(
          title: 'Events per minute',
          icon: Icons.insights_rounded,
          child: AdminColumnChart(height: 84, columns: [
            for (final m in recent)
              AdminColumn(m, [
                AdminChartSlice(
                    'info',
                    ((buckets[m]!['log'] ?? 0) + (buckets[m]!['debug'] ?? 0))
                        .toDouble(),
                    scheme.primary.withValues(alpha: .55)),
                AdminChartSlice('warn', (buckets[m]!['warn'] ?? 0).toDouble(),
                    AppColors.warning),
                AdminChartSlice('error', (buckets[m]!['error'] ?? 0).toDouble(),
                    AppColors.danger),
              ]),
          ]),
        ),
      ],
      const SizedBox(height: 14),
      AdminSearchField(
          controller: search,
          hint: 'Filter by text…',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      ClipRRect(
        borderRadius: BorderRadius.circular(AppShape.card - 4),
        child: Container(
          height: 520,
          color: const Color(0xFF07101C),
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              color: const Color(0xFF0D1A2B),
              child: Row(children: [
                for (final c in const [
                  Color(0xFFFF6B79),
                  Color(0xFFFFB648),
                  Color(0xFF43D39E)
                ]) ...[
                  Container(
                      width: 10,
                      height: 10,
                      decoration:
                          BoxDecoration(color: c, shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                ],
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      '${rows.length} lines${all.length >= 500 ? ' · showing latest' : ''}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontFamily: 'monospace')),
                ),
              ]),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                          'No lines yet for this filter. Reproduce the problem, then refresh.',
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: rows.length,
                      itemBuilder: (_, index) {
                        final line = rows[index];
                        final level = _logLevel('${line['level'] ?? 'log'}');
                        final color = level == 'error'
                            ? AppColors.danger
                            : level == 'warn'
                                ? AppColors.warning
                                : level == 'debug'
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant
                                    : const Color(0xFFD3DEEA);
                        return SelectableText(
                          '${_time(line['time'])} ${level.toUpperCase().padRight(5)} ${line['logger'] == null ? '' : '[${line['logger']}] '}${line['message'] ?? ''}',
                          style: TextStyle(
                              color: color,
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.55),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Text(
          'Updated ${TimeOfDay.now().format(context)}${live ? ' · live every 3s' : ' · paused'}',
          style: _muted()),
    ]);
  }

  Widget _sandboxes() {
    final response = _map(widget.results['spaces.admin_sandboxes']);
    final rows = _listOfMaps(response['sandboxes']);
    final mine = rows
        .where((r) => _map(r['project']).isNotEmpty || r['space_id'] != null)
        .toList();
    final stray = rows.where((r) => !mine.contains(r)).toList();
    Widget list(List<Map<String, dynamic>> values, String empty) =>
        values.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(empty, style: _muted()))
            : Column(children: [
                for (final row in values)
                  _adaptiveTile(
                    leading: AdminAvatar(
                        '${_map(row['project'])['name'] ?? row['id']}',
                        icon: Icons.computer_rounded),
                    title: Text(
                        '${_map(row['project'])['name'] ?? row['machine'] ?? row['name'] ?? 'Unknown machine'}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: SelectableText(
                        '${row['id']} · started ${_date(row['started_at'] ?? row['created_at'])}'),
                    actions: [
                      const AdminStatusPill('running'),
                      if (_map(row['project']).isNotEmpty)
                        TextButton(
                            onPressed: () => _showProject(_map(row['project'])),
                            child: const Text('Open project'))
                      else
                        TextButton.icon(
                            onPressed: () => _terminateSandbox(row),
                            icon: const Icon(Icons.power_settings_new_rounded,
                                size: 18),
                            label: const Text('Terminate')),
                    ],
                  ),
              ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Running now',
          icon: Icons.computer_rounded,
          subtitle:
              'Every one is billed by ${response['provider'] ?? 'the provider'}.',
          child: AdminDonutPanel(
            size: 132,
            center: '${rows.length}',
            caption: 'machines',
            emptyLabel: 'None running',
            slices: [
              AdminChartSlice("Projects' computers", mine.length.toDouble(),
                  AppColors.success),
              AdminChartSlice('Not used by a project', stray.length.toDouble(),
                  AppColors.warning),
            ],
          ),
        ),
        AdminStatCard(
            label: 'Not used by a project',
            value: '${stray.length}',
            hint: stray.isEmpty
                ? 'Every running machine belongs to a project.'
                : 'Running without a project: check these',
            icon: Icons.report_problem_rounded,
            tone: stray.isEmpty ? AppColors.success : AppColors.warning),
      ]),
      if (stray.isNotEmpty) ...[
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Not used by a project',
            icon: Icons.report_problem_rounded,
            subtitle:
                'These run at the provider but no project on this node uses them.',
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: list(stray, 'None')),
      ],
      const SizedBox(height: 16),
      AdminSectionCard(
          title: "Projects' computers",
          icon: Icons.folder_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: list(mine, 'No project computer is running right now.')),
    ]);
  }

  Future<void> _terminateSandbox(Map<String, dynamic> row) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.power_settings_new_rounded),
        title: const Text('Terminate this machine?'),
        content: Text(
            '${row['machine'] ?? row['name'] ?? row['id']} runs at the provider '
            'without a project on this node. Terminating it stops its billing '
            'and deletes it; this cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Terminate')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.onDirectAction(
          'spaces', 'admin_terminate_sandbox', {'id': row['id']});
    } catch (_) {
      // The console reports the error.
    }
  }

  Widget _chatReports() {
    final scheme = Theme.of(context).colorScheme;
    final response = _map(widget.results['spaces.admin_chat_reports']);
    final reports = _listOfMaps(response['reports']);
    final open = _integer(response['open']);
    const statuses = ['open', 'resolved', 'dismissed', 'all'];
    final status = reportStatus;
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
        await widget.onDirectAction('spaces', 'admin_chat_report_resolve',
            {'id': r['id'], 'status': to});
      } catch (_) {
        // The console reports the error.
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, children: [
        AdminStatCard(
            label: 'Open reports',
            value: '$open',
            hint: open == 0
                ? 'Nothing waits for a decision.'
                : 'Read the copied messages, then resolve or dismiss.',
            icon: Icons.flag_rounded,
            tone: open == 0 ? AppColors.success : AppColors.warning),
        AdminStatCard(
            label: 'Shown',
            value: '${reports.length}',
            hint: status == 'all' ? 'Every report' : 'Reports $status',
            icon: Icons.inbox_rounded),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in statuses)
          ChoiceChip(
            label: Text(s[0].toUpperCase() + s.substring(1)),
            selected: s == status,
            onSelected: (_) {
              setState(() => reportStatus = s);
              widget.onQuery?.call('spaces.admin_chat_reports', {'status': s});
            },
          ),
      ]),
      const SizedBox(height: 12),
      AdminSectionCard(
        title: 'Reports',
        icon: Icons.flag_rounded,
        subtitle:
            'Each report carries a copy of the messages as they were when it was filed.',
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: reports.isEmpty
            ? const AdminEmptyState('No reports',
                'What people report in their chats shows up here.',
                icon: Icons.flag_outlined)
            : Column(children: [
                for (final r in reports)
                  ExpansionTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    collapsedShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    leading: AdminAvatar(person(r['accused']),
                        icon: Icons.flag_rounded,
                        size: 40,
                        avatar: _avatarOf(r['accused'])),
                    title: Text(
                        '${_humanKey('${r['reason'] ?? 'other'}')} · ${r['kind'] == 'message' ? 'a message' : 'a chat'}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        'About ${person(r['accused'])} · by ${person(r['reporter'])} · ${_date(r['created_at'])}'),
                    trailing: AdminStatusPill('${r['status'] ?? 'open'}'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    children: [
                      AdminKeyValue(
                          'Where',
                          r['direct'] == true
                              ? 'Direct chat'
                              : '${r['space_name'] ?? 'Room'}'),
                      if ('${r['note'] ?? ''}'.isNotEmpty)
                        AdminKeyValue('Note', '${r['note']}'),
                      if (r['resolved_by'] != null)
                        AdminKeyValue('Decided by',
                            '${person(r['resolved_by'])} · ${_date(r['resolved_at'])}'),
                      const SizedBox(height: 8),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: Text('MESSAGES',
                              style: TextStyle(
                                  fontSize: 11,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onSurfaceVariant))),
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
                              borderRadius:
                                  BorderRadius.circular(AppShape.inner)),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    '${person(m['sender'])} · ${_date(m['created_at'])}${m['edited_at'] != null ? ' · edited' : ''}',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: scheme.onSurfaceVariant)),
                                const SizedBox(height: 2),
                                KeyedSubtree(
                                  key: PageStorageKey<String>(
                                      'evidence:${r['id']}:${m['id']}'),
                                  child: SelectableText(
                                      '${m['body'] ?? ''}'.isEmpty
                                          ? '(${m['attachments'] ?? 0} attachment(s))'
                                          : '${m['body']}',
                                      style: const TextStyle(fontSize: 13)),
                                ),
                              ]),
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
                                  icon: const Icon(Icons.do_not_disturb_rounded,
                                      size: 18),
                                  label: const Text('Dismiss')),
                              FilledButton.icon(
                                  onPressed: () => resolve(r, 'resolved'),
                                  icon:
                                      const Icon(Icons.check_rounded, size: 18),
                                  label: const Text('Mark resolved')),
                            ] else
                              OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'open'),
                                  icon:
                                      const Icon(Icons.undo_rounded, size: 18),
                                  label: const Text('Reopen')),
                          ]),
                    ],
                  ),
              ]),
      ),
    ]);
  }

  Widget _postReports() {
    final scheme = Theme.of(context).colorScheme;
    final response = _map(widget.results['posts.admin_post_reports']);
    final reports = _listOfMaps(response['reports']);
    final open = _integer(response['open']);
    const statuses = ['open', 'resolved', 'dismissed', 'all'];
    final status = postReportStatus;
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

    Future<void> resolve(Map<String, dynamic> r, String to,
        {bool remove = false}) async {
      try {
        await widget.onDirectAction('posts', 'admin_post_report_resolve', {
          'id': r['id'],
          'status': to,
          if (remove) 'remove_post': true,
        });
      } catch (_) {
        // The console reports the error.
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, children: [
        AdminStatCard(
            label: 'Open reports',
            value: '$open',
            hint: open == 0
                ? 'Nothing waits for a decision.'
                : 'Read the reported post, then remove it, resolve or dismiss.',
            icon: Icons.report_rounded,
            tone: open == 0 ? AppColors.success : AppColors.warning),
        AdminStatCard(
            label: 'Shown',
            value: '${reports.length}',
            hint: status == 'all' ? 'Every report' : 'Reports $status',
            icon: Icons.inbox_rounded),
      ]),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in statuses)
          ChoiceChip(
            label: Text(s[0].toUpperCase() + s.substring(1)),
            selected: s == status,
            onSelected: (_) {
              setState(() => postReportStatus = s);
              widget.onQuery?.call('posts.admin_post_reports', {'status': s});
            },
          ),
      ]),
      const SizedBox(height: 12),
      AdminSectionCard(
        title: 'Reports',
        icon: Icons.report_rounded,
        subtitle:
            'Each report carries a copy of the post as it was when it was filed.',
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: reports.isEmpty
            ? const AdminEmptyState(
                'No reports', 'Posts people report in the feed show up here.',
                icon: Icons.report_outlined)
            : Column(children: [
                for (final r in reports)
                  ExpansionTile(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    collapsedShape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.control)),
                    leading: AdminAvatar(person(r['accused']),
                        icon: Icons.report_rounded,
                        size: 40,
                        avatar: _avatarOf(r['accused'])),
                    title: Text(
                        '${_humanKey('${r['reason'] ?? 'other'}')} · a post${r['deleted'] == true ? ' (removed)' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(
                        'By ${person(r['accused'])} · reported by ${person(r['reporter'])} · ${_date(r['created_at'])}'),
                    trailing: AdminStatusPill('${r['status'] ?? 'open'}'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    children: [
                      if ('${r['note'] ?? ''}'.isNotEmpty)
                        AdminKeyValue('Note', '${r['note']}'),
                      if (r['resolved_by'] != null)
                        AdminKeyValue('Decided by',
                            '${person(r['resolved_by'])} · ${_date(r['resolved_at'])}'),
                      const SizedBox(height: 8),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: Text('REPORTED POST',
                              style: TextStyle(
                                  fontSize: 11,
                                  letterSpacing: 1,
                                  fontWeight: FontWeight.w800,
                                  color: scheme.onSurfaceVariant))),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                            color: scheme.errorContainer,
                            borderRadius: BorderRadius.circular(AppShape.inner)),
                        child: KeyedSubtree(
                          key: PageStorageKey<String>('post-report:${r['id']}'),
                          child: SelectableText('${r['body'] ?? ''}',
                              style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                      if (r['current_body'] != null &&
                          '${r['current_body']}' != '${r['body']}') ...[
                        const SizedBox(height: 6),
                        AdminKeyValue('Edited since', '${r['current_body']}'),
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
                                  icon: const Icon(Icons.do_not_disturb_rounded,
                                      size: 18),
                                  label: const Text('Dismiss')),
                              if (r['deleted'] != true)
                                OutlinedButton.icon(
                                    onPressed: () =>
                                        resolve(r, 'resolved', remove: true),
                                    icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 18),
                                    label: const Text('Remove post')),
                              FilledButton.icon(
                                  onPressed: () => resolve(r, 'resolved'),
                                  icon:
                                      const Icon(Icons.check_rounded, size: 18),
                                  label: const Text('Mark resolved')),
                            ] else
                              OutlinedButton.icon(
                                  onPressed: () => resolve(r, 'open'),
                                  icon:
                                      const Icon(Icons.undo_rounded, size: 18),
                                  label: const Text('Reopen')),
                          ]),
                    ],
                  ),
              ]),
      ),
    ]);
  }

  Widget _storage() {
    final response = _map(widget.results['spaces.admin_storage']);
    final all = _listOfMaps(response['volumes']);
    final q = search.text.trim().toLowerCase();
    final rows = all
        .where((v) =>
            q.isEmpty ||
            '${v['name']} ${v['id']} ${_map(v['project'])['name']}'
                .toLowerCase()
                .contains(q))
        .toList();
    final used = rows.where((v) => _map(v['project']).isNotEmpty).toList();
    final unused = rows.where((v) => _map(v['project']).isEmpty).toList();
    final usedAll = all.where((v) => _map(v['project']).isNotEmpty).length;
    Widget list(List<Map<String, dynamic>> values, String empty) =>
        values.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Text(empty, style: _muted()))
            : Column(children: [
                for (final v in values)
                  _adaptiveTile(
                    leading: AdminAvatar(
                        '${_map(v['project'])['name'] ?? v['name'] ?? v['id']}',
                        icon: Icons.storage_rounded),
                    title: Text(
                        '${_map(v['project'])['name'] ?? v['name'] ?? v['id']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: SelectableText([
                      v['name'],
                      v['id'],
                      'created ${_date(v['created_at'])}'
                    ].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
                    actions: [
                      if (_map(v['project']).isNotEmpty)
                        TextButton(
                            onPressed: () => _showProject(_map(v['project'])),
                            child: const Text('Open project')),
                    ],
                  ),
              ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
          title: 'Volumes',
          icon: Icons.storage_rounded,
          subtitle: '${response['provider'] ?? 'Provider'} storage',
          child: AdminDonutPanel(
            size: 132,
            center: '${all.length}',
            caption: 'volumes',
            slices: [
              AdminChartSlice("Holding a project's files", usedAll.toDouble(),
                  AppColors.success),
              AdminChartSlice('With no project',
                  (all.length - usedAll).toDouble(), AppColors.warning),
            ],
          ),
        ),
        AdminStatCard(
            label: 'With no project',
            value: '${all.length - usedAll}',
            hint: "Left from deleted projects, or not this node's",
            icon: Icons.cleaning_services_rounded,
            tone:
                all.length == usedAll ? AppColors.success : AppColors.warning),
      ]),
      const SizedBox(height: 18),
      AdminSearchField(
          controller: search,
          hint: 'Search by project, volume name or id',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 16),
      AdminSectionCard(
          title: 'Projects (${used.length})',
          icon: Icons.folder_rounded,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: list(used, "No volume holds a project's files.")),
      if (unused.isNotEmpty) ...[
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'No project (${unused.length})',
            icon: Icons.cleaning_services_rounded,
            subtitle:
                'Nothing on this node uses these. Remove them at the provider only after checking they are not needed.',
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: list(unused, 'None')),
      ],
    ]);
  }

  Widget _pricing() => _PricingEditor(
        key: ValueKey(
            jsonEncode(_map(widget.results['settings.get'])['pricing'])),
        settings: _map(widget.results['settings.get']),
        onSave: (pricing) =>
            widget.onDirectAction('settings', 'update', {'pricing': pricing}),
        onModels: () => widget.onNavigate('Models'),
      );

  Widget _machine() => _MachineEditor(
        key: ValueKey(
            jsonEncode(_map(widget.results['settings.get'])['machine'])),
        settings: _map(widget.results['settings.get']),
        onSave: (machine) =>
            widget.onDirectAction('settings', 'update', {'machine': machine}),
      );

  Widget _agentInstructions() => _PromptEditor(
        key: ValueKey(
            _map(widget.results['settings.get'])['universal_system_prompt']),
        value:
            '${_map(widget.results['settings.get'])['universal_system_prompt'] ?? ''}',
        onSave: (value) => widget.onDirectAction(
            'settings', 'update', {'universal_system_prompt': value}),
      );

  Widget _categories() {
    final scheme = Theme.of(context).colorScheme;
    final settings = _map(widget.results['settings.get']);
    final enabled = _stringList(settings['categories']);
    const builtIn = {
      'productivity': Icons.task_alt_rounded,
      'research': Icons.travel_explore_rounded,
      'coding': Icons.code_rounded,
      'writing': Icons.edit_note_rounded,
      'design': Icons.palette_outlined,
      'data': Icons.dataset_outlined,
      'business': Icons.business_center_outlined,
      'education': Icons.school_outlined,
      'finance': Icons.show_chart_rounded,
      'legal': Icons.gavel_rounded,
      'marketing': Icons.campaign_outlined,
      'support': Icons.support_agent_rounded,
    };
    final custom = enabled.where((c) => !builtIn.containsKey(c)).toList()
      ..sort();
    final q = search.text.trim().toLowerCase();
    bool match(String id) => q.isEmpty || id.contains(q);
    void toggle(String id) {
      final next = [...enabled];
      enabled.contains(id) ? next.remove(id) : next.add(id);
      widget.onDirectAction('settings', 'update', {'categories': next});
    }

    String label(String id) => id.isEmpty
        ? id
        : '${id[0].toUpperCase()}${id.substring(1).replaceAll('-', ' ')}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(maxColumns: 2, minTileWidth: 260, children: [
        AdminStatCard(
            label: 'Shown in the market',
            value: '${enabled.length}',
            hint: 'Tap a category below to turn it on or off.',
            icon: Icons.category_rounded,
            progress: (builtIn.length + custom.length) == 0
                ? 0
                : enabled.length / (builtIn.length + custom.length)),
        AdminStatCard(
            label: 'Custom',
            value: '${custom.length}',
            hint: 'Added for this node',
            icon: Icons.new_label_rounded,
            tone: AppColors.cyan),
      ]),
      const SizedBox(height: 18),
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Filter categories',
              onChanged: (_) => setState(() {})),
          [
            FilledButton.icon(
              onPressed: () => _addCategory(enabled),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add category'),
            ),
          ]),
      const SizedBox(height: 16),
      AdminSectionCard(
        title: 'Built-in',
        icon: Icons.inventory_2_rounded,
        subtitle: 'Selected categories are offered when listing an agent.',
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in builtIn.entries)
            if (match(e.key))
              FilterChip(
                selected: enabled.contains(e.key),
                avatar: Icon(e.value, size: 18),
                label: Text(label(e.key)),
                onSelected: (_) => toggle(e.key),
              ),
        ]),
      ),
      const SizedBox(height: 14),
      AdminSectionCard(
        title: 'Custom',
        icon: Icons.new_label_rounded,
        child: custom.where(match).isEmpty
            ? Text(
                custom.isEmpty
                    ? 'No custom categories yet. Add one for a niche your node serves.'
                    : 'No custom category matches.',
                style: _muted())
            : Wrap(spacing: 8, runSpacing: 8, children: [
                for (final id in custom)
                  if (match(id))
                    InputChip(
                      label: Text(label(id)),
                      avatar: Icon(Icons.label_rounded,
                          size: 18, color: scheme.primary),
                      deleteIcon: const Icon(Icons.close_rounded, size: 18),
                      deleteButtonTooltipMessage: 'Remove',
                      onDeleted: () => toggle(id),
                    ),
              ]),
      ),
    ]);
  }

  Future<void> _addCategory(List<String> enabled) async {
    final controller = TextEditingController();
    String slug(String value) => value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final value = await showAppDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          icon: const Icon(Icons.new_label_rounded),
          title: const Text('Add category'),
          content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: controller,
                    autofocus: true,
                    onChanged: (_) => setDialog(() {}),
                    onSubmitted: (_) => Navigator.pop(context, controller.text),
                    decoration: const InputDecoration(
                        labelText: 'Name', hintText: 'e.g. Real estate')),
                const SizedBox(height: 12),
                if (slug(controller.text).isNotEmpty)
                  Chip(
                      avatar: const Icon(Icons.label_rounded, size: 18),
                      label: Text(slug(controller.text))),
              ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: slug(controller.text).isEmpty
                    ? null
                    : () => Navigator.pop(context, controller.text),
                child: const Text('Add')),
          ],
        ),
      ),
    );
    controller.dispose();
    if (value == null) return;
    final id = slug(value);
    if (id.isEmpty) return;
    await widget.onDirectAction('settings', 'update', {
      'categories': <String>{...enabled, id}.toList(),
    });
  }

  void _showProject(Map<String, dynamic> project) {
    final id = '${project['id'] ?? project['space_id'] ?? ''}';
    showAppDialog<void>(
      context: context,
      builder: (context) => _ProjectDialog(
        project: project,
        onAction: widget.onAction,
        loadDetail: () => widget.onDirectAction(
            'spaces', 'space_detail', {'space': id, 'admin': true}),
        loadWork: () => widget.onDirectAction(
            'spaces', 'admin_work_log', {'space': id, 'limit': 200}),
        loadFiles: () =>
            widget.onDirectAction('spaces', 'admin_files', {'space': id}),
      ),
    );
  }

  void _showUser(Map<String, dynamic> account, {int tab = 0}) {
    showAppDialog<void>(
      context: context,
      builder: (context) => _UserDialog(
        account: account,
        initialTab: tab,
        onAction: widget.onAction,
        onEdit: () => _editUser(account),
        loadFinance: () => widget.onDirectAction('finance', 'admin_account', {
          'account': account['id'],
          'limit': 200,
        }),
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
        child: Text(text,
            style: const TextStyle(
                fontSize: 18, letterSpacing: -.2, fontWeight: FontWeight.w800)),
      );

  Widget _personCell(String name, String secondary,
          {IconData? icon, String avatar = ''}) =>
      Row(children: [
        AdminAvatar(name, size: 34, icon: icon, avatar: avatar),
        const SizedBox(width: 10),
        Expanded(child: _primaryCell(name, secondary)),
      ]);

  /// A toolbar whose [actions] sit beside [main] on wide screens and wrap
  /// below it on narrow ones, so neither side gets squeezed.
  Widget _toolbar(Widget main, List<Widget> actions) =>
      LayoutBuilder(builder: (context, constraints) {
        if (constraints.maxWidth >= 640) {
          return Row(children: [
            Expanded(child: main),
            for (final action in actions) ...[const SizedBox(width: 8), action],
          ]);
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              main,
              const SizedBox(height: 10),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions),
            ]);
      });

  /// A list row whose actions trail on wide screens and move under the text
  /// on narrow ones, so the title keeps its width.
  Widget _adaptiveTile({
    Widget? leading,
    required Widget title,
    Widget? subtitle,
    required List<Widget> actions,
    EdgeInsetsGeometry? contentPadding,
  }) =>
      LayoutBuilder(builder: (context, constraints) {
        final buttons = Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: actions);
        final wide = constraints.maxWidth >= 560;
        return ListTile(
          contentPadding: contentPadding,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppShape.control)),
          leading: leading,
          title: title,
          subtitle: wide || actions.isEmpty
              ? subtitle
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (subtitle != null) subtitle,
                  const SizedBox(height: 6),
                  buttons,
                ]),
          trailing: wide && actions.isNotEmpty ? buttons : null,
        );
      });

  Widget _settingStatus(Map<String, dynamic> setting) {
    final scheme = Theme.of(context).colorScheme;
    final active = setting['active'] == true;
    final partly = !active &&
        (setting['chat_active'] == true || setting['embedding_active'] == true);
    final color = active
        ? AppColors.success
        : partly
            ? AppColors.warning
            : scheme.onSurfaceVariant;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      child: Row(children: [
        Icon(
            active
                ? Icons.check_circle_rounded
                : partly
                    ? Icons.timelapse_rounded
                    : Icons.pause_circle_outline_rounded,
            color: color,
            size: 28),
        const SizedBox(width: 14),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              active
                  ? 'In effect'
                  : partly
                      ? 'Partly in effect'
                      : 'Not in effect',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text('${setting['status'] ?? 'No status from the node.'}',
              style: _muted()),
        ])),
      ]),
    );
  }

  Map<String, dynamic> _decisionBody(Map<String, dynamic> setting,
          {bool? enabled,
          String? provider,
          String? model,
          bool? autoApprove}) =>
      {
        'enabled': enabled ?? setting['enabled'] == true,
        'provider_id': provider ?? setting['provider_id'] ?? '',
        'model_id': model ?? setting['model_id'] ?? '',
        'auto_approve': autoApprove ?? setting['auto_approve'] == true,
      };

  Map<String, dynamic> _memoryBody(Map<String, dynamic> setting) => {
        'chat_provider_id': setting['chat_provider_id'] ?? '',
        'chat_model_id': setting['chat_model_id'] ?? '',
        'embedding_provider_id': setting['embedding_provider_id'] ?? '',
        'embedding_model_id': setting['embedding_model_id'] ?? '',
      };

  List<Map<String, dynamic>> _decisionModels(
      List<Map<String, dynamic>> providers, String providerId) {
    final provider = providers
        .cast<Map<String, dynamic>?>()
        .firstWhere((p) => '${p?['id']}' == providerId, orElse: () => null);
    return _listOfMaps(provider?['decision_models'] ?? provider?['models']);
  }

  TextStyle _muted() => TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
      height: 1.35);
}

class _ModelEditorDialog extends StatefulWidget {
  const _ModelEditorDialog({
    required this.providers,
    required this.provider,
    required this.onSave,
    this.model,
  });

  final List<Map<String, dynamic>> providers;
  final Map<String, dynamic> provider;
  final Map<String, dynamic>? model;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  late String providerId;
  late String purpose;
  late bool disabled;
  late final String previousId;
  late final TextEditingController id;
  late final TextEditingController name;
  late final TextEditingController input;
  late final TextEditingController output;
  final units = <String, TextEditingController>{};
  bool saving = false;

  bool get editing => widget.model != null;
  Map<String, dynamic> get previous => widget.model ?? const {};

  @override
  void initState() {
    super.initState();
    final model = previous;
    providerId = '${widget.provider['id']}';
    previousId = '${model['id'] ?? ''}';
    id = TextEditingController(text: previousId);
    name = TextEditingController(text: '${model['name'] ?? ''}');
    input = TextEditingController(
        text: ledgerUsdField(_number(model['input_price'])));
    output = TextEditingController(
        text: ledgerUsdField(_number(model['output_price'])));
    final label = _modelPurpose(model);
    purpose = _modelKinds.firstWhere((k) => k.$2 == label).$1;
    disabled = model['disabled'] == true;
    final stored = _map(model['units']);
    for (final fields in _unitFields.values) {
      for (final (key, quoted, scale) in fields) {
        final v = _number(stored[key]) * scale;
        units[quoted] = TextEditingController(
            text: v > 0
                ? compactDecimal(v / ledgerUnitsPerUsd, decimals: 10)
                : '');
      }
    }
  }

  @override
  void dispose() {
    id.dispose();
    name.dispose();
    input.dispose();
    output.dispose();
    for (final c in units.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> save() async {
    final modelId = id.text.trim();
    final tokens = _tokenPriced.contains(purpose);
    final inputUnits =
        tokens ? parseUsdToLedger(input.text.isEmpty ? '0' : input.text) : 0;
    final outputUnits =
        tokens ? parseUsdToLedger(output.text.isEmpty ? '0' : output.text) : 0;
    if (modelId.isEmpty || inputUnits == null || outputUnits == null) {
      _say(
          'Enter the provider model id and valid dollar prices (up to six decimals).');
      return;
    }
    // Prices other than tokens: dollars per quoted unit in, ledger units per
    // stored unit out.
    Map<String, dynamic>? nextUnits;
    for (final (key, quoted, scale)
        in _unitFields[purpose] ?? const <(String, String, double)>[]) {
      final raw = units[quoted]!.text.trim().replaceFirst(RegExp(r'^\$'), '');
      if (raw.isEmpty) continue;
      final usd = double.tryParse(raw.replaceAll(',', ''));
      if (usd == null || usd < 0) {
        _say('$quoted: a dollar amount, e.g. 0.04.');
        return;
      }
      if (usd > 0) {
        final v = (usd * ledgerUnitsPerUsd / scale * 100).round() / 100;
        nextUnits = {...?nextUnits, key: v};
      }
    }
    final before = _map(previous['units']);
    // A video priced by resolution keeps those prices while its rate is left
    // as it was.
    if (purpose == 'video' &&
        before['second_by'] != null &&
        _number(nextUnits?['second']) == _number(before['second'])) {
      nextUnits = {...?nextUnits, 'second_by': before['second_by']};
    }
    final provider = widget.providers.firstWhere(
        (p) => '${p['id']}' == providerId,
        orElse: () => widget.provider);
    final models = _listOfMaps(provider['models']);
    if (models
        .any((m) => '${m['id']}' == modelId && '${m['id']}' != previousId)) {
      _say('$modelId is already listed.');
      return;
    }
    // What an import recorded (source, tags, inputs) stays; a price typed by
    // hand is no longer the source's price plus a markup.
    final kept = {...previous}
      ..remove('_provider')
      ..remove('name')
      ..remove('capabilities')
      ..remove('units')
      ..remove('unpriced')
      ..remove('disabled');
    bool sameUnits(Map<String, dynamic> a, Map<String, dynamic> b) =>
        {...a.keys, ...b.keys}.every((k) => k == 'second_by'
            ? jsonEncode(a[k]) == jsonEncode(b[k])
            : _number(a[k]) == _number(b[k]));
    final repriced = editing &&
        (_number(previous['input_price']) != inputUnits ||
            _number(previous['output_price']) != outputUnits ||
            !sameUnits(before, nextUnits ?? const {}));
    if (repriced) {
      kept
        ..remove('markup')
        ..remove('base_input_price')
        ..remove('base_output_price')
        ..remove('base_units');
    }
    final priced = inputUnits > 0 || outputUnits > 0 || nextUnits != null;
    final next = <String, dynamic>{
      ...kept,
      'id': modelId,
      if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
      'input_price': inputUnits,
      'output_price': outputUnits,
      if (nextUnits != null) 'units': nextUnits,
      'capabilities': [purpose],
      // Imported without a price, it is served once one is set.
      if (previous['unpriced'] == true && !priced) 'unpriced': true,
      if (disabled) 'disabled': true,
    };
    final nextModels = <Map<String, dynamic>>[
      for (final current in models)
        if ('${current['id']}' == previousId) next else current,
      if (!editing) next,
    ];
    setState(() => saving = true);
    try {
      await widget.onSave({...provider, 'models': nextModels});
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      _say('Could not save model: $error');
      setState(() => saving = false);
    }
  }

  static const _purposeHints = {
    'chat': 'Agents can use this as their main reasoning model.',
    'decision':
        'Used for app selection, routing, progress, and completion checks. Agents cannot use it as their main model.',
    'embedding':
        'Turns memories into vectors for semantic recall. Agents cannot use it as their main model.',
    'image':
        'Makes images: the node\'s image model and the developer API. Priced per image, by its tokens, or both.',
    'video': 'Makes videos for the developer API, priced per second.',
    'speech':
        'Turns text into speech for the developer API, priced per character.',
    'transcription':
        'Turns audio into text for the developer API, priced per minute.',
    'rerank':
        'Reranks search results for the developer API, priced per search.',
  };

  Widget _priceField(TextEditingController c, String label, String hint) =>
      TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder()));

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650, maxHeight: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(editing ? 'Edit model' : 'Add model',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w900))),
                IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded)),
              ]),
              if ('${previous['source'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                    previous['markup'] is num
                        ? 'Imported from ${previous['source']} at its price +${compactDecimal(_number(previous['markup']))}%. Typing a price here sets it by hand.'
                        : 'Imported from ${previous['source']}.',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
              const SizedBox(height: 18),
              DropdownButtonFormField<String>(
                initialValue: providerId,
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Provider', border: OutlineInputBorder()),
                items: [
                  for (final p in widget.providers)
                    DropdownMenuItem(
                        value: '${p['id']}',
                        child: Text('${p['name']} · ${p['kind']}',
                            overflow: TextOverflow.ellipsis))
                ],
                onChanged: editing
                    ? null
                    : (value) => setState(() => providerId = value!),
              ),
              const SizedBox(height: 14),
              TextField(
                  controller: id,
                  decoration: const InputDecoration(
                      labelText: 'Model id',
                      hintText: 'gpt-4.1',
                      helperText: 'Exactly as the provider names it.',
                      border: OutlineInputBorder())),
              const SizedBox(height: 14),
              TextField(
                  controller: name,
                  decoration: const InputDecoration(
                      labelText: 'Display name (optional)',
                      hintText: 'GPT-4.1',
                      border: OutlineInputBorder())),
              const SizedBox(height: 18),
              AppChoiceField<String>(
                label: 'What this model is for',
                value: purpose,
                onChanged: (value) => setState(() => purpose = value),
                choices: [
                  for (final (value, label) in _modelKinds)
                    AppChoice(value, value == 'chat' ? 'Agent model' : label,
                        hint: _purposeHints[value]),
                ],
              ),
              const SizedBox(height: 18),
              if (_tokenPriced.contains(purpose))
                Row(children: [
                  Expanded(
                      child: _priceField(input, 'Input \$/1M tokens', '2.50')),
                  const SizedBox(width: 12),
                  Expanded(
                      child:
                          _priceField(output, 'Output \$/1M tokens', '10.00')),
                ]),
              for (final (_, quoted, _) in _unitFields[purpose] ??
                  const <(String, String, double)>[]) ...[
                const SizedBox(height: 12),
                _priceField(units[quoted]!, quoted, '0.04'),
              ],
              const SizedBox(height: 14),
              AppSwitchCard(
                icon: Icons.visibility_off_outlined,
                title: disabled ? 'Disabled' : 'Offered',
                subtitle: disabled
                    ? 'Hidden from new agents, the pickers and the developer API. Agents already on it keep running.'
                    : 'Offered for new agents, the pickers and the developer API.',
                value: disabled,
                onChanged: (v) => setState(() => disabled = v),
              ),
              const SizedBox(height: 22),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                    onPressed: saving ? null : () => Navigator.pop(context),
                    child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton.icon(
                    onPressed: saving ? null : save,
                    icon: saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined, size: 18),
                    label: Text(saving ? 'Saving…' : 'Save')),
              ]),
            ]),
          ),
        ),
      );
}

/// Picks the Vercel provider and the markup for an import.
class _ImportVercelDialog extends StatefulWidget {
  const _ImportVercelDialog({required this.providers, this.markup});
  final List<Map<String, dynamic>> providers;

  /// The markup of the last import, offered again.
  final double? markup;

  @override
  State<_ImportVercelDialog> createState() => _ImportVercelDialogState();
}

class _ImportVercelDialogState extends State<_ImportVercelDialog> {
  late String providerId = '${widget.providers.first['id']}';
  late final markup = TextEditingController(
      text: widget.markup == null ? '' : compactDecimal(widget.markup!));
  String? error;

  @override
  void dispose() {
    markup.dispose();
    super.dispose();
  }

  void submit() {
    final v = double.tryParse(markup.text.trim().replaceFirst('%', ''));
    if (v == null || v < 0 || v > 1000) {
      setState(
          () => error = 'Enter a markup between 0 and 1000 percent, e.g. 20.');
      return;
    }
    Navigator.pop(context, (providerId, v));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.download_rounded),
        title: const Text('Import from Vercel'),
        content: SizedBox(
          width: 440,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                    'Brings Vercel AI Gateway\'s models in at Vercel\'s price plus your markup. Importing again updates them in place; prices you typed by hand stay.'),
                const SizedBox(height: 16),
                if (widget.providers.length > 1) ...[
                  AppChoiceField<String>(
                    label: 'Into',
                    value: providerId,
                    onChanged: (v) => setState(() => providerId = v),
                    choices: [
                      for (final p in widget.providers)
                        AppChoice('${p['id']}', '${p['name']}',
                            icon: Icons.hub_outlined),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: markup,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  onSubmitted: (_) => submit(),
                  decoration: InputDecoration(
                      labelText: 'Markup',
                      suffixText: '%',
                      hintText: '20',
                      errorText: error,
                      border: const OutlineInputBorder()),
                ),
              ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Import')),
        ],
      );
}

/// A Save bar that appears once something changed.
class _SaveBar extends StatelessWidget {
  const _SaveBar(
      {required this.dirty,
      required this.busy,
      required this.onSave,
      required this.onReset,
      this.message = 'You have unsaved changes'});
  final bool dirty;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onReset;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: !dirty
          ? const SizedBox(width: double.infinity, key: ValueKey('clean'))
          : Container(
              key: const ValueKey('dirty'),
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
              decoration: BoxDecoration(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(999)),
              child: Row(children: [
                Icon(Icons.edit_note_rounded, color: scheme.onInverseSurface),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(message,
                        style: TextStyle(
                            color: scheme.onInverseSurface,
                            fontWeight: FontWeight.w600))),
                TextButton(
                    onPressed: busy ? null : onReset,
                    style: TextButton.styleFrom(
                        foregroundColor: scheme.inversePrimary),
                    child: const Text('Reset')),
                const SizedBox(width: 4),
                FilledButton.icon(
                    onPressed: busy ? null : onSave,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(busy ? 'Saving…' : 'Save')),
              ]),
            ),
    );
  }
}

class _PricingEditor extends StatefulWidget {
  const _PricingEditor(
      {super.key,
      required this.settings,
      required this.onSave,
      required this.onModels});
  final Map<String, dynamic> settings;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;
  final VoidCallback onModels;

  @override
  State<_PricingEditor> createState() => _PricingEditorState();
}

class _PricingEditorState extends State<_PricingEditor> {
  /// Base rates in dollars per minute, resource rates in credits per minute.
  late Map<String, double> values = _initial();
  bool advanced = false;
  bool busy = false;

  Map<String, double> _initial() {
    final p = _map(widget.settings['pricing']);
    final sandbox = _map(p['sandbox']);
    final tool = _map(p['tool']);
    double usd(dynamic v) => ledgerToUsd(_number(v)).toDouble();
    double credits(dynamic v) => ledgerToCredits(_number(v)).toDouble();
    return {
      'agent_per_minute': usd(p['agent_per_minute']),
      'sandbox.per_minute': usd(sandbox['per_minute']),
      'tool.per_minute': usd(tool['per_minute']),
      'sandbox.cpu_per_min': credits(sandbox['cpu_per_min']),
      'sandbox.memory_per_gb_min': credits(sandbox['memory_per_gb_min']),
      'sandbox.disk_per_gb_min': credits(sandbox['disk_per_gb_min']),
      'tool.cpu_per_min': credits(tool['cpu_per_min']),
      'tool.memory_per_gb_min': credits(tool['memory_per_gb_min']),
      'tool.disk_per_gb_min': credits(tool['disk_per_gb_min']),
      // Dollars per GB-month; a node that never set it charges the default.
      'storage_gb_month':
          p.containsKey('storage_gb_month') ? usd(p['storage_gb_month']) : .05,
    };
  }

  @override
  void initState() {
    super.initState();
    advanced = values.entries
        .where((e) => e.key.contains('.') && !e.key.endsWith('per_minute'))
        .any((e) => e.value > 0);
  }

  bool get dirty {
    final initial = _initial();
    return values.entries.any((e) => (initial[e.key]! - e.value).abs() > 1e-9);
  }

  Future<void> save() async {
    int usd(String key) => usdToLedger(values[key]!);
    int credits(String key) => creditsToLedger(values[key]!);
    setState(() => busy = true);
    try {
      await widget.onSave({
        'agent_per_minute': usd('agent_per_minute'),
        'sandbox': {
          'per_minute': usd('sandbox.per_minute'),
          'cpu_per_min': credits('sandbox.cpu_per_min'),
          'memory_per_gb_min': credits('sandbox.memory_per_gb_min'),
          'disk_per_gb_min': credits('sandbox.disk_per_gb_min'),
        },
        'tool': {
          'per_minute': usd('tool.per_minute'),
          'cpu_per_min': credits('tool.cpu_per_min'),
          'memory_per_gb_min': credits('tool.memory_per_gb_min'),
          'disk_per_gb_min': credits('tool.disk_per_gb_min'),
        },
        'storage_gb_month': usd('storage_gb_month'),
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget rate(String key, String label, String hint, IconData icon) =>
      AppAmountField(
        label: label,
        hint: '$hint · \$${(values[key]! * 60).toStringAsFixed(2)} an hour',
        value: values[key]!,
        max: 1,
        step: .01,
        decimals: 4,
        unit: '\$ / min',
        presets: const [.01, .02, .05, .1, .25],
        presetLabel: _usd,
        format: (v) => '${_usd(v)} / min',
        onChanged: (v) => setState(() => values[key] = v),
      );

  Widget resource(String key, String label, String unit) => AppAmountField(
        label: label,
        value: values[key]!,
        max: 5,
        step: .1,
        decimals: 2,
        unit: 'credits',
        presets: const [0, .5, 1, 2],
        presetLabel: (v) => v == 0 ? 'None' : compactDecimal(v),
        format: (v) =>
            v == 0 ? 'None' : '${compactDecimal(v)} cr / $unit / min',
        onChanged: (v) => setState(() => values[key] = v),
      );

  @override
  Widget build(BuildContext context) {
    final palette = adminPalette(context);
    final hourly = [
      AdminChartSlice(
          'Agent time', values['agent_per_minute']! * 60, palette[0],
          display:
              '\$${(values['agent_per_minute']! * 60).toStringAsFixed(2)}'),
      AdminChartSlice(
          'Project computer', values['sandbox.per_minute']! * 60, palette[1],
          display:
              '\$${(values['sandbox.per_minute']! * 60).toStringAsFixed(2)}'),
      AdminChartSlice('Apps', values['tool.per_minute']! * 60, palette[3],
          display: '\$${(values['tool.per_minute']! * 60).toStringAsFixed(2)}'),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SaveBar(
            dirty: dirty,
            busy: busy,
            onSave: save,
            onReset: () => setState(() => values = _initial())),
        AdminSectionCard(
          title: 'An hour of busy work costs a user',
          icon: Icons.schedule_rounded,
          subtitle:
              'Agent time, its project computer and apps, before model tokens. Credits are shown at 100 per \$1.',
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                '\$${hourly.fold<double>(0, (sum, s) => sum + s.value).toStringAsFixed(2)}',
                style: const TextStyle(
                    fontSize: 34,
                    letterSpacing: -.8,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            AdminStackedBar(slices: hourly, height: 18),
          ]),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Base rates',
            icon: Icons.sell_rounded,
            subtitle: 'What users pay per minute.',
            child: Column(children: [
              rate('agent_per_minute', 'Agent time', 'While an agent works',
                  Icons.smart_toy_outlined),
              const SizedBox(height: 22),
              rate('sandbox.per_minute', 'Project computer',
                  'While the computer is awake', Icons.computer_outlined),
              const SizedBox(height: 22),
              rate('tool.per_minute', 'Apps', 'While one runs',
                  Icons.build_outlined),
            ])),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Developer storage',
            icon: Icons.cloud_outlined,
            subtitle:
                'What a developer API organization pays for each GB it keeps in Storage, per month.',
            child: AppAmountField(
              label: 'Storage',
              value: values['storage_gb_month']!,
              max: 1,
              step: .01,
              decimals: 3,
              unit: '\$ / GB-month',
              presets: const [0, .02, .05, .1],
              presetLabel: (v) => v == 0 ? 'Free' : _usd(v),
              format: (v) => v == 0 ? 'Free' : '${_usd(v)} / GB-month',
              onChanged: (v) => setState(() => values['storage_gb_month'] = v),
            )),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Model tokens',
            icon: Icons.memory_rounded,
            subtitle: 'Input and output prices are set per model.',
            child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                    onPressed: widget.onModels,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Edit model prices')))),
        const SizedBox(height: 16),
        AppSwitchCard(
          icon: Icons.tune_rounded,
          title: 'Per-resource rates',
          subtitle:
              'Charge extra for each vCPU, GB of RAM and GB of disk. Off means flat pricing.',
          value: advanced,
          onChanged: (v) => setState(() => advanced = v),
        ),
        if (advanced) ...[
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Project computer',
            icon: Icons.computer_rounded,
            subtitle: 'Extra credits per minute, per unit.',
            child: Column(children: [
              resource('sandbox.cpu_per_min', 'vCPU', 'vCPU'),
              const SizedBox(height: 20),
              resource('sandbox.memory_per_gb_min', 'RAM', 'GB'),
              const SizedBox(height: 20),
              resource('sandbox.disk_per_gb_min', 'Disk', 'GB'),
            ]),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Apps',
            icon: Icons.build_rounded,
            subtitle: 'Extra credits per minute, per unit.',
            child: Column(children: [
              resource('tool.cpu_per_min', 'vCPU', 'vCPU'),
              const SizedBox(height: 20),
              resource('tool.memory_per_gb_min', 'RAM', 'GB'),
              const SizedBox(height: 20),
              resource('tool.disk_per_gb_min', 'Disk', 'GB'),
            ]),
          ),
        ],
      ]),
    );
  }
}

class _MachineEditor extends StatefulWidget {
  const _MachineEditor(
      {super.key, required this.settings, required this.onSave});
  final Map<String, dynamic> settings;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;
  @override
  State<_MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<_MachineEditor> {
  /// CPU in vCPUs, memory and disk in GB; null means automatic.
  late Map<String, double?> values = _initial();
  bool busy = false;

  Map<String, double?> _initial() {
    final m = _map(widget.settings['machine']);
    double? gb(dynamic v) => v == null ? null : _number(v) / 1024;
    double? n(dynamic v) => v == null || '$v'.isEmpty ? null : _number(v);
    return {
      'cpu': n(m['cpu']) ?? 2,
      'memory': gb(m['memory_mb']) ?? 2,
      'disk': gb(m['disk_mb']) ?? 4,
      'reserve_cpu': n(m['reserve_cpu']),
      'reserve_memory': gb(m['reserve_memory_mb']),
      'max_cpu': n(m['max_cpu']),
      'max_memory': gb(m['max_memory_mb']),
      'provider_idle_min': n(m['provider_idle_min']) ?? 30,
      'max_lifetime_min': n(m['max_lifetime_min']) ?? 480,
      'command_timeout_sec': n(m['command_timeout_sec']) ?? 300,
    };
  }

  bool get dirty {
    final initial = _initial();
    return values.entries.any((e) => initial[e.key] != e.value);
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      int? mb(double? gb) => gb == null ? null : (gb * 1024).round();
      await widget.onSave({
        'cpu': values['cpu'],
        'memory_mb': mb(values['memory']),
        'disk_mb': mb(values['disk']),
        'reserve_cpu': values['reserve_cpu'],
        'reserve_memory_mb': mb(values['reserve_memory']),
        'max_cpu': values['max_cpu'],
        'max_memory_mb': mb(values['max_memory']),
        'provider_idle_min': values['provider_idle_min']?.round(),
        'max_lifetime_min': values['max_lifetime_min']?.round(),
        'command_timeout_sec': values['command_timeout_sec']?.round(),
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _size(double v, String unit) => '${compactDecimal(v)} $unit';

  Widget sizeChips(String key, String label, List<double> options, String unit,
      {bool auto = false, String? hint}) {
    final value = values[key];
    final all = <double>{...options, if (value != null) value}.toList()..sort();
    return AppChoiceField<double?>(
      label: label,
      hint: hint,
      value: value,
      onChanged: (v) => setState(() => values[key] = v),
      choices: [
        if (auto)
          const AppChoice<double?>(null, 'Automatic',
              icon: Icons.auto_mode_rounded),
        for (final o in all) AppChoice<double?>(o, _size(o, unit)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cpu = values['cpu'] ?? 2;
    final memory = values['memory'] ?? 2;
    Widget range(String label, double? reserve, double billed, double? max,
        String unit) {
      final top = [billed, reserve ?? 0, max ?? billed * 2]
          .reduce((a, b) => a > b ? a : b);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
        Text(
            'reserve ${reserve == null ? 'auto' : _size(reserve, unit)} · billed ${_size(billed, unit)} · ceiling ${max == null ? 'auto' : _size(max, unit)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        AdminStackedBar(legend: false, height: 14, slices: [
          AdminChartSlice(
              'Reserve', reserve ?? billed * .25, AppColors.success),
          AdminChartSlice(
              'Billed', billed - (reserve ?? billed * .25), scheme.primary),
          AdminChartSlice(
              'Burst', (max ?? billed * 2) - billed, AppColors.cyan),
          AdminChartSlice('', top - (max ?? billed * 2) + .0001,
              scheme.surfaceContainerHighest),
        ]),
      ]);
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SaveBar(
            dirty: dirty,
            busy: busy,
            onSave: save,
            onReset: () => setState(() => values = _initial())),
        AdminSectionCard(
          title: 'At a glance',
          icon: Icons.insights_rounded,
          subtitle:
              'From the idle reserve, through the billed size, up to the burst ceiling.',
          child: Column(children: [
            range('CPU', values['reserve_cpu'], cpu, values['max_cpu'], 'vCPU'),
            const SizedBox(height: 16),
            range('RAM', values['reserve_memory'], memory, values['max_memory'],
                'GB'),
            const SizedBox(height: 14),
            Wrap(spacing: 16, runSpacing: 6, children: [
              for (final (label, color) in [
                ('Idle reserve', AppColors.success),
                ('Billed size', scheme.primary),
                ('Burst', AppColors.cyan),
              ])
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 6),
                  Text(label, style: const TextStyle(fontSize: 12)),
                ]),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Billed size',
            icon: Icons.developer_board_rounded,
            subtitle: "What a project's computer is sold at and created with.",
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              sizeChips('cpu', 'vCPU', const [.5, 1, 2, 4, 8, 16], 'vCPU'),
              const SizedBox(height: 20),
              sizeChips('memory', 'RAM', const [.5, 1, 2, 4, 8, 16, 32], 'GB'),
              const SizedBox(height: 20),
              AppAmountField(
                label: 'Disk',
                value: values['disk'] ?? 4,
                min: 1,
                max: 200,
                step: 1,
                decimals: 0,
                unit: 'GB',
                presets: const [4, 10, 20, 50, 100],
                presetLabel: (v) => '${compactDecimal(v)} GB',
                format: (v) => '${compactDecimal(v)} GB',
                onChanged: (v) => setState(() => values['disk'] = v),
              ),
            ])),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Idle reserve',
            icon: Icons.bedtime_rounded,
            subtitle:
                'The share guaranteed and billed while a computer is awake and quiet.',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              sizeChips('reserve_cpu', 'vCPU', const [.25, .5, 1, 2], 'vCPU',
                  auto: true),
              const SizedBox(height: 20),
              sizeChips('reserve_memory', 'RAM', const [.25, .5, 1, 2], 'GB',
                  auto: true),
            ])),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Ceiling',
            icon: Icons.vertical_align_top_rounded,
            subtitle: 'The most a busy computer can use.',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              sizeChips('max_cpu', 'vCPU', const [2, 4, 8, 16], 'vCPU',
                  auto: true),
              const SizedBox(height: 20),
              sizeChips('max_memory', 'RAM', const [4, 8, 16, 32], 'GB',
                  auto: true),
            ])),
        const SizedBox(height: 16),
        AdminSectionCard(
            title: 'Time limits',
            icon: Icons.timer_outlined,
            subtitle:
                'When an idle computer is stopped at the provider, the longest any computer may run, and how long one command may take.',
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppAmountField(
                label: 'Stop when idle for',
                value: values['provider_idle_min'] ?? 30,
                min: 5,
                max: 1440,
                step: 5,
                decimals: 0,
                unit: 'min',
                presets: const [10, 30, 60, 120],
                presetLabel: _minutes,
                format: _minutes,
                onChanged: (v) => setState(() {
                  values['provider_idle_min'] = v;
                  final life = values['max_lifetime_min'] ?? 480;
                  if (life < v) values['max_lifetime_min'] = v;
                }),
              ),
              const SizedBox(height: 20),
              AppAmountField(
                label: 'Longest run',
                value: values['max_lifetime_min'] ?? 480,
                min: 30,
                max: 1440,
                step: 30,
                decimals: 0,
                unit: 'min',
                presets: const [120, 480, 720, 1440],
                presetLabel: _minutes,
                format: _minutes,
                onChanged: (v) => setState(() {
                  values['max_lifetime_min'] = v;
                  final idle = values['provider_idle_min'] ?? 30;
                  if (idle > v) values['provider_idle_min'] = v;
                }),
              ),
              const SizedBox(height: 20),
              AppAmountField(
                label: 'One command may take',
                value: values['command_timeout_sec'] ?? 300,
                min: 10,
                max: 3600,
                step: 10,
                decimals: 0,
                unit: 's',
                presets: const [60, 300, 900, 3600],
                presetLabel: _seconds,
                format: _seconds,
                onChanged: (v) =>
                    setState(() => values['command_timeout_sec'] = v),
              ),
            ])),
      ]),
    );
  }

  static String _minutes(double v) => v >= 60 && v % 60 == 0
      ? '${(v / 60).round()} h'
      : v >= 60
          ? '${(v / 60).floor()} h ${(v % 60).round()} min'
          : '${v.round()} min';

  static String _seconds(double v) =>
      v >= 60 && v % 60 == 0 ? '${(v / 60).round()} min' : '${v.round()} s';
}

class _PromptEditor extends StatefulWidget {
  const _PromptEditor({super.key, required this.value, required this.onSave});
  final String value;
  final Future<dynamic> Function(String) onSave;
  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final TextEditingController controller;
  bool busy = false;
  static const limit = 20000;
  static const snippets = {
    'Reply in the user’s language': 'Always answer in the user’s language.',
    'No invented facts':
        'Never invent facts, figures or dates; say when you are not sure.',
    'Cite sources': 'Cite the source of every figure you use.',
    'Ask before spending':
        'Ask before any action that spends more than 100 credits.',
    'Be concise': 'Keep answers short and lead with the conclusion.',
  };

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
    controller.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  void _insert(String line) {
    final text = controller.text.trimRight();
    controller.text = text.isEmpty ? line : '$text\n$line';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final length = controller.text.trim().length;
    // Roughly four characters a token for English text.
    final tokens = (length / 4).ceil();
    final over = length > limit;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SaveBar(
            dirty: controller.text != widget.value,
            busy: busy || over,
            message: over
                ? 'Too long: shorten to $limit characters to save'
                : 'You have unsaved changes',
            onReset: () => controller.text = widget.value,
            onSave: () async {
              setState(() => busy = true);
              try {
                await widget.onSave(controller.text);
              } finally {
                if (mounted) setState(() => busy = false);
              }
            }),
        AdminGrid(maxColumns: 3, minTileWidth: 200, children: [
          AdminStatCard(
              label: 'Length',
              value: '$length',
              hint: 'of $limit characters',
              icon: Icons.short_text_rounded,
              progress: length / limit,
              tone: over ? AppColors.danger : null),
          AdminStatCard(
              label: 'Tokens per turn',
              value: '≈$tokens',
              hint: 'Paid on every agent turn',
              icon: Icons.token_outlined,
              tone: tokens > 1500 ? AppColors.warning : AppColors.success),
          AdminStatCard(
              label: 'Rules',
              value:
                  '${controller.text.split('\n').where((l) => l.trim().isNotEmpty).length}',
              hint: 'Non-empty lines',
              icon: Icons.rule_rounded,
              tone: AppColors.cyan),
        ]),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Platform rules',
          icon: Icons.description_rounded,
          subtitle:
              'Added to every agent’s instructions. Keep it short — every turn pays for these tokens. Blank means none.',
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Quick add', style: _labelStyle(scheme)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final e in snippets.entries)
                ActionChip(
                  avatar: Icon(
                      controller.text.contains(e.value)
                          ? Icons.check_rounded
                          : Icons.add_rounded,
                      size: 18),
                  label: Text(e.key),
                  onPressed: controller.text.contains(e.value)
                      ? null
                      : () => _insert(e.value),
                ),
            ]),
            const SizedBox(height: 16),
            TextField(
                controller: controller,
                minLines: 10,
                maxLines: 24,
                style: const TextStyle(height: 1.5),
                decoration: InputDecoration(
                    hintText:
                        "Always answer in the user's language. Never invent delivery dates.",
                    errorText: over ? 'Over the $limit character limit' : null,
                    alignLabelWithHint: true)),
          ]),
        ),
      ]),
    );
  }
}

TextStyle _labelStyle(ColorScheme scheme) => TextStyle(
    fontSize: 13, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant);

/// The full-screen frame of a detail view: an avatar header, tabs, and
/// the selected tab's content.
class _DetailFrame extends StatelessWidget {
  const _DetailFrame({
    required this.title,
    required this.subtitle,
    required this.avatar,
    required this.tabs,
    required this.tab,
    required this.onTab,
    required this.onRefresh,
    required this.menu,
    required this.loading,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget avatar;
  final List<(String, IconData)> tabs;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onRefresh;
  final Widget menu;
  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 700;
    return Builder(
      builder: (context) => Dialog.fullscreen(
        backgroundColor: scheme.surface,
        child: DefaultTabController(
          length: tabs.length,
          initialIndex: tab,
          child: Scaffold(
            backgroundColor: scheme.surface,
            appBar: AppBar(
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              toolbarHeight: 72,
              leading: IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
              titleSpacing: 0,
              title: Row(children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                      ]),
                ),
              ]),
              actions: [
                IconButton(
                    tooltip: 'Refresh',
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded)),
                menu,
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(64),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: SegmentedTabBar(
                    width: 600,
                    compact: narrow,
                    onTap: onTab,
                    labels: [for (final (label, _) in tabs) label],
                    icons: [for (final (_, icon) in tabs) icon],
                  ),
                ),
              ),
            ),
            body: loading
                ? const SkeletonPage()
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: ListView(
                        key: ValueKey(tab),
                        padding: EdgeInsets.symmetric(
                            horizontal: narrow ? 16 : 28, vertical: 20),
                        children: [
                          Center(
                            child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 1100),
                                child: child),
                          ),
                        ]),
                  ),
          ),
        ),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  const _UserDialog({
    required this.account,
    required this.onAction,
    required this.onEdit,
    required this.loadFinance,
    this.initialTab = 0,
  });
  final Map<String, dynamic> account;
  final AdminAction onAction;
  final VoidCallback onEdit;
  final Future<dynamic> Function() loadFinance;
  final int initialTab;
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late int tab = widget.initialTab;
  bool loading = true;
  Map<String, dynamic> finance = const {};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    // Refreshing keeps the current figures visible until new ones arrive.
    try {
      final value = _map(await widget.loadFinance());
      if (mounted) setState(() => finance = value);
    } catch (_) {
      // The caller already reported the failure.
    } finally {
      if (mounted && loading) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final name = _displayName(a);
    return _DetailFrame(
      title: name,
      subtitle: '@${a['handle']} · ${a['email'] ?? ''}',
      avatar: AdminAvatar(name, size: 44, avatar: _avatarOf(a)),
      tabs: const [
        ('Summary', Icons.space_dashboard_rounded),
        ('Purchases', Icons.shopping_bag_rounded),
        ('Wallet', Icons.account_balance_wallet_rounded),
        ('Profile & access', Icons.manage_accounts_rounded),
      ],
      tab: tab,
      onTab: (value) => setState(() => tab = value),
      onRefresh: load,
      loading: loading,
      menu: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'delete') {
              widget.onAction('users', 'account_delete',
                  {'account': a['id'], '_name': name});
            }
          },
          itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                        leading: Icon(Icons.delete_outline_rounded),
                        title: Text('Delete user')))
              ]),
      child: switch (tab) {
        0 => _summary(),
        1 => _purchases(),
        2 => _wallet(),
        _ => _profile()
      },
    );
  }

  Widget _summary() {
    final m = _map(finance['summary']).isNotEmpty
        ? _map(finance['summary'])
        : finance;
    final palette = adminPalette(context);
    final kinds = _listOfMaps(m['by_kind'] ?? finance['by_kind']);
    final projects = _listOfMaps(m['projects'] ?? finance['projects']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(children: [
        AdminStatCard(
            label: 'Balance',
            value: _money(m['balance']),
            icon: Icons.account_balance_wallet_rounded,
            hint:
                '${_credits(m['balance'])}${_number(m['locked']) > 0 ? ' · ${_credits(m['locked'])} locked' : ''}'),
        AdminStatCard(
            label: 'Bought',
            value: _money(m['bought']),
            icon: Icons.shopping_bag_rounded,
            tone: AppColors.success,
            hint: '${m['bought_count'] ?? 0} packs · ${_credits(m['bought'])}'),
        AdminStatCard(
            label: 'Added by admin',
            value: _money(m['granted']),
            icon: Icons.card_giftcard_rounded,
            tone: AppColors.cyan,
            hint: _credits(m['granted'])),
        AdminStatCard(
            label: 'Spent',
            value: _money(m['spent']),
            icon: Icons.trending_down_rounded,
            tone: AppColors.warning,
            hint: _credits(m['spent'])),
      ]),
      const SizedBox(height: 16),
      AdminGrid(maxColumns: 2, minTileWidth: 340, children: [
        AdminSectionCard(
            title: 'What was spent on',
            icon: Icons.donut_large_rounded,
            child: AdminDonutPanel(
              size: 132,
              center: _money(m['spent']),
              caption: 'spent',
              emptyLabel: 'Nothing spent',
              slices: [
                for (final (i, row) in kinds.indexed)
                  AdminChartSlice(
                      '${row['kind'] ?? row['label']}',
                      _number(row['amount'] ?? row['spent']),
                      palette[i % palette.length],
                      display: _money(row['amount'] ?? row['spent'])),
              ],
            )),
        AdminSectionCard(
            title: 'Spent per project',
            icon: Icons.folder_rounded,
            child: AdminBarList(
              maxItems: 5,
              empty: 'No project spending yet.',
              items: [
                for (final row in projects)
                  AdminChartSlice(
                      '${row['name'] ?? row['space_name'] ?? row['space_id']}',
                      _number(row['spent']),
                      palette[1],
                      display: _money(row['spent'])),
              ],
            )),
      ]),
    ]);
  }

  Widget _purchases() {
    final rows = _listOfMaps(finance['purchases']);
    return AdminDataTable(empty: 'No purchases for this user.', columns: const [
      AdminTableColumn('Purchased', width: 160),
      AdminTableColumn('Product', width: 220),
      AdminTableColumn('Amount', width: 120, align: TextAlign.right),
      AdminTableColumn('Status', width: 130),
      AdminTableColumn('Transaction', width: 240)
    ], rows: [
      for (final p in rows)
        [
          Text(_date(p['created_at'])),
          Text('${p['product_id'] ?? 'Credit pack'}'),
          Text(_money(p['amount'] ?? p['listed_amount']),
              textAlign: TextAlign.right),
          AdminStatusPill('${p['status'] ?? 'credited'}'),
          SelectableText('${p['transaction_id'] ?? p['id']}')
        ]
    ]);
  }

  Widget _wallet() {
    final rows = _listOfMaps(finance['ledger'] ?? finance['entries']);
    return AdminDataTable(empty: 'No wallet activity.', columns: const [
      AdminTableColumn('When', width: 160),
      AdminTableColumn('Description', width: 320),
      AdminTableColumn('Kind', width: 130),
      AdminTableColumn('Amount', width: 130, align: TextAlign.right),
      AdminTableColumn('Balance', width: 130, align: TextAlign.right)
    ], rows: [
      for (final e in rows)
        [
          Text(_date(e['created_at'])),
          Text('${e['description'] ?? e['reason'] ?? e['kind']}'),
          _Tag('${e['kind'] ?? e['type']}'),
          Text(_credits(e['amount']),
              textAlign: TextAlign.right,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _number(e['amount']) < 0
                      ? AppColors.danger
                      : AppColors.success)),
          Text(_credits(e['balance']), textAlign: TextAlign.right)
        ]
    ]);
  }

  Widget _profile() {
    final a = widget.account;
    final name = _displayName(a);
    final disabled = '${a['status']}' == 'disabled';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Profile',
          icon: Icons.badge_rounded,
          trailing: FilledButton.tonalIcon(
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit')),
          child: Column(children: [
            AdminKeyValue('Name', name),
            AdminKeyValue('Username', '@${a['handle']}'),
            AdminKeyValue('Email', '${a['email'] ?? '—'}'),
            AdminKeyValue(
                'Role',
                a['is_admin'] == true || '${a['role']}' == 'admin'
                    ? 'Administrator'
                    : 'Member'),
            AdminKeyValue('Joined', _date(a['created_at'])),
            AdminKeyValue('User id', '${a['id']}', mono: true),
          ])),
      const SizedBox(height: 16),
      AdminGrid(maxColumns: 3, minTileWidth: 220, children: [
        _ActionTile(
          icon: disabled ? Icons.lock_open_rounded : Icons.block_rounded,
          title: disabled ? 'Allow sign-in' : 'Block sign-in',
          subtitle: disabled ? 'Currently blocked' : 'Data and wallet are kept',
          tone: disabled ? AppColors.success : AppColors.danger,
          onTap: widget.onEdit,
        ),
        _ActionTile(
          icon: Icons.password_rounded,
          title: 'Set new password',
          subtitle: 'Replace their sign-in password',
          onTap: () => widget.onAction(
              'users', 'account_password', {'account': a['id'], '_name': name}),
        ),
        _ActionTile(
          icon: Icons.add_card_rounded,
          title: 'Grant credits',
          subtitle: 'Add credits to their wallet',
          tone: AppColors.success,
          onTap: () => widget.onAction(
              'finance', 'wallet_mint', {'target': a['id'], '_name': name}),
        ),
      ]),
    ]);
  }
}

/// A large tappable action with an icon badge.
class _ActionTile extends StatelessWidget {
  const _ActionTile(
      {required this.icon,
      required this.title,
      required this.subtitle,
      required this.onTap,
      this.tone});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.primary;
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner + 4)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                  color: color.withValues(alpha: .16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15))),
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({
    required this.project,
    required this.onAction,
    required this.loadDetail,
    required this.loadWork,
    required this.loadFiles,
  });
  final Map<String, dynamic> project;
  final AdminAction onAction;
  final Future<dynamic> Function() loadDetail;
  final Future<dynamic> Function() loadWork;
  final Future<dynamic> Function() loadFiles;
  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  int tab = 0;
  bool loading = true;
  Map<String, dynamic> detail = const {};

  /// spaces.admin_work_log: the project's runs (with their events and where
  /// their time went), metered usage and memory charges. Null until loaded.
  Map<String, dynamic>? workLog;
  List<Map<String, dynamic>> files = const [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    // Refreshing keeps the current detail visible until new data arrives.
    try {
      final value = await widget.loadDetail();
      if (mounted) setState(() => detail = {...widget.project, ..._map(value)});
    } catch (_) {
      if (mounted) setState(() => detail = {...widget.project, ...detail});
    } finally {
      if (mounted && loading) setState(() => loading = false);
    }
  }

  Future<void> loadTab(int value) async {
    setState(() => tab = value);
    try {
      if (value == 4 && workLog == null) {
        final value = await widget.loadWork();
        if (mounted) setState(() => workLog = _map(value));
      }
      if (value == 3 && files.isEmpty) {
        final value = await widget.loadFiles();
        if (mounted) setState(() => files = _listOfMaps(_map(value)['files']));
      }
    } catch (_) {
      // The caller already reported the failure.
    }
  }

  Map<String, dynamic> get budget => _map(detail['budget']);
  dynamic get cap =>
      budget['cap'] ?? (detail['budget'] is num ? detail['budget'] : null);
  dynamic get spent =>
      detail['spent'] ?? _map(detail['usage'])['spent'] ?? budget['spent'];

  void _setBudget(String id) => widget.onAction('finance', 'budget_set', {
        'space': id,
        '_cap': cap,
        '_spent': spent,
      });

  @override
  Widget build(BuildContext context) {
    final id = '${detail['id'] ?? widget.project['id']}';
    final name = '${detail['name'] ?? widget.project['name'] ?? 'Project'}';
    return _DetailFrame(
      title: name,
      subtitle: id,
      avatar: AdminAvatar(name,
          size: 44,
          icon: Icons.folder_rounded,
          avatar: _avatarOf(detail).isNotEmpty
              ? _avatarOf(detail)
              : _avatarOf(widget.project)),
      tabs: const [
        ('Overview', Icons.space_dashboard_rounded),
        ('Machine', Icons.computer_rounded),
        ('Cost', Icons.savings_rounded),
        ('Storage', Icons.folder_open_rounded),
        ('Logs', Icons.receipt_long_rounded),
        ('People', Icons.group_rounded),
      ],
      tab: tab,
      onTab: loadTab,
      onRefresh: load,
      loading: loading,
      menu: PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'budget') _setBudget(id);
          if (value == 'delete') {
            widget.onAction(
                'spaces', 'space_delete', {'space': id, '_name': name});
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
              value: 'budget',
              child: ListTile(
                  leading: Icon(Icons.savings_outlined),
                  title: Text('Set budget'))),
          PopupMenuDivider(),
          PopupMenuItem(
              value: 'delete',
              child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('Delete project'))),
        ],
      ),
      child: switch (tab) {
        0 => _overview(),
        1 => _machine(id),
        2 => _cost(id),
        3 => _files(),
        4 => _work(),
        _ => _people(),
      },
    );
  }

  Widget _overview() {
    final machine = _map(detail['machine']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(children: [
        AdminStatCard(
            label: 'Machine',
            value: '${machine['state'] ?? 'none'}',
            hint: '${machine['provider'] ?? ''}',
            icon: Icons.computer_rounded,
            tone: adminToneColor(
                context, adminTone('${machine['state'] ?? 'none'}'))),
        AdminStatCard(
            label: 'Agents',
            value: '${detail['agents'] ?? _list(detail['workers']).length}',
            icon: Icons.smart_toy_rounded,
            tone: AppColors.cyan),
        AdminStatCard(
            label: 'Rooms',
            value: '${_list(detail['rooms']).length}',
            icon: Icons.forum_rounded,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Budget',
            value: _number(cap) == 0 ? 'No limit' : _credits(cap),
            hint: 'Spent ${_credits(spent)}',
            progress: _number(cap) == 0 ? null : _number(spent) / _number(cap),
            icon: Icons.savings_rounded,
            tone: AppColors.warning),
      ]),
      const SizedBox(height: 16),
      AdminSectionCard(
          title: 'Project',
          icon: Icons.info_outline_rounded,
          child: Column(children: [
            AdminKeyValue('Owner', _owner(detail)),
            AdminKeyValue('Created', _date(detail['created_at'])),
            AdminKeyValue('Updated', _date(detail['updated_at'])),
            AdminKeyValue('Project id', '${detail['id']}', mono: true),
          ])),
    ]);
  }

  Widget _machine(String id) {
    final machine = _map(detail['machine']);
    const ops = [
      ('status', 'Check state', 'Ask the provider', Icons.info_outline_rounded),
      (
        'provision',
        'Start',
        'Create or wake it',
        Icons.power_settings_new_rounded
      ),
      ('keepalive', 'Keep awake', 'Reset the idle timer', Icons.coffee_rounded),
      ('sleep', 'Sleep', 'Stop billing; keep files', Icons.bedtime_rounded),
      (
        'replace',
        'Replace',
        'Fresh machine from the image',
        Icons.autorenew_rounded
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Computer',
          icon: Icons.computer_rounded,
          trailing: AdminStatusPill('${machine['state'] ?? 'none'}'),
          child: Column(children: [
            AdminKeyValue('Provider id',
                '${machine['id'] ?? machine['sandbox_id'] ?? ''}',
                mono: true),
            AdminKeyValue('Started', _date(machine['started_at'])),
            AdminKeyValue('Last active', _date(machine['last_active_at'])),
          ])),
      const SizedBox(height: 16),
      AdminGrid(minTileWidth: 200, maxColumns: 5, children: [
        for (final (op, label, hint, icon) in ops)
          _ActionTile(
            icon: icon,
            title: label,
            subtitle: hint,
            tone: op == 'replace' || op == 'sleep' ? AppColors.warning : null,
            onTap: () => widget
                .onAction('spaces', 'computer', {'space': id, 'operation': op}),
          ),
      ]),
    ]);
  }

  Widget _cost(String id) {
    final limit = _number(cap);
    final used = _number(spent);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Budget and spend',
          icon: Icons.savings_rounded,
          trailing: FilledButton.tonalIcon(
              onPressed: () => _setBudget(id),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Set budget')),
          child: LayoutBuilder(builder: (context, constraints) {
            final gauge = AdminGauge(
              value: limit == 0 ? 0 : used / limit,
              label: limit == 0 ? 'no limit' : 'of budget',
              display: limit == 0 ? '∞' : null,
            );
            final facts = Column(children: [
              AdminKeyValue(
                  'Budget cap', limit == 0 ? 'No limit' : _credits(cap)),
              AdminKeyValue('Spent', _credits(spent)),
              AdminKeyValue(
                  'Remaining',
                  limit == 0
                      ? '—'
                      : _credits(budget['remaining'] ?? (limit - used))),
            ]);
            if (constraints.maxWidth < 480) {
              return Column(
                  children: [gauge, const SizedBox(height: 12), facts]);
            }
            return Row(children: [
              gauge,
              const SizedBox(width: 24),
              Expanded(child: facts),
            ]);
          })),
    ]);
  }

  Widget _files() => AdminDataTable(
        empty: 'No project files.',
        columns: const [
          AdminTableColumn('Path', width: 420),
          AdminTableColumn('Size', width: 120, align: TextAlign.right),
          AdminTableColumn('Modified', width: 160)
        ],
        rows: [
          for (final f in files)
            [
              Row(children: [
                Icon(
                    '${f['type'] ?? ''}' == 'dir' || f['is_dir'] == true
                        ? Icons.folder_rounded
                        : Icons.insert_drive_file_outlined,
                    size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text('${f['path'] ?? f['name']}')),
              ]),
              Text(_bytes(f['size']), textAlign: TextAlign.right),
              Text(_date(f['modified_at'] ?? f['updated_at']))
            ]
        ],
      );
  Widget _work() {
    final log = workLog;
    if (log == null) {
      return const SkeletonList(itemCount: 4);
    }
    final scheme = Theme.of(context).colorScheme;
    final runs = _listOfMaps(log['runs']);
    final usage = _listOfMaps(log['usage_events']);
    final memory = _listOfMaps(log['memory_events']);
    String ms(dynamic v) {
      final n = _number(v);
      return n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)} s'
          : '${n.round()} ms';
    }

    String took(Map<String, dynamic> run) {
      final start = DateTime.tryParse('${run['started_at'] ?? ''}');
      final end = DateTime.tryParse('${run['ended_at'] ?? ''}');
      if (start == null ||
          end == null ||
          start.year < 2000 ||
          end.year < 2000) {
        return '';
      }
      return ' · took ${ms(end.difference(start).inMilliseconds)}';
    }

    Widget heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                letterSpacing: 1,
                fontWeight: FontWeight.w800,
                color: scheme.onSurfaceVariant)));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      heading('RUNS'),
      if (runs.isEmpty)
        const AdminEmptyState(
            'No runs', 'Agent work in this project shows up here.',
            icon: Icons.receipt_long_outlined)
      else
        for (final run in runs)
          ExpansionTile(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.control)),
            collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.control)),
            title: Text(
                [
                  _stringList(run['agents']).isNotEmpty
                      ? _stringList(run['agents']).join(', ')
                      : 'Run',
                  if ('${run['actor'] ?? ''}'.isNotEmpty) 'by @${run['actor']}',
                ].join(' · '),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
                '${_date(run['created_at'])}${took(run)} · ${'${run['prompt'] ?? ''}'.replaceAll('\n', ' ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            trailing: AdminStatusPill('${run['status'] ?? '—'}'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ('${run['error'] ?? ''}'.isNotEmpty)
                AdminKeyValue('Error', '${run['error']}'),
              if (_listOfMaps(run['spans']).isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('Where the time went',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
                for (final s in _listOfMaps(run['spans']))
                  AdminKeyValue('${s['name']}',
                      '${ms(s['ms'])}${'${s['detail'] ?? ''}'.isEmpty ? '' : ' · ${s['detail']}'}'),
              ],
              const SizedBox(height: 6),
              for (final e in _listOfMaps(run['events']))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${e['sender'] ?? '—'} · ${e['kind'] == '' || e['kind'] == null ? 'message' : e['kind']} · ${_date(e['created_at'])}',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.onSurfaceVariant)),
                        KeyedSubtree(
                          key: PageStorageKey<String>('event:${e['id']}'),
                          child: SelectableText('${e['body'] ?? ''}',
                              maxLines: 8,
                              style: const TextStyle(fontSize: 12.5)),
                        ),
                      ]),
                ),
            ],
          ),
      heading('METERED USAGE'),
      AdminDataTable(
        empty: 'No metered usage.',
        columns: const [
          AdminTableColumn('Time', width: 150),
          AdminTableColumn('Agent', width: 150),
          AdminTableColumn('Model', width: 200),
          AdminTableColumn('Usage', width: 320),
          AdminTableColumn('Cost', width: 100, align: TextAlign.right),
        ],
        rows: [
          for (final u in usage)
            [
              Text(_date(u['created_at'])),
              Text('${u['bot_name'] ?? '—'}'),
              _primaryCell('${u['model'] ?? '—'}', '${u['provider'] ?? ''}'),
              Text([
                if ('${u['summary'] ?? ''}'.isNotEmpty) '${u['summary']}',
                if (_integer(u['decision_in']) + _integer(u['decision_out']) >
                    0)
                  'decisions ${_compact(u['decision_in'])} in / ${_compact(u['decision_out'])} out',
                if (_integer(u['image_count']) > 0)
                  '${_integer(u['image_count'])} image(s)${'${u['image_model'] ?? ''}'.isEmpty ? '' : ' with ${u['image_model']}'}',
              ].join(' · ')),
              Text(_money(u['cost']), textAlign: TextAlign.right),
            ]
        ],
      ),
      heading('MEMORY'),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
            'The agents\' memory is charged to the project in batches, apart from any one run.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ),
      AdminDataTable(
        empty: 'No memory charges yet.',
        columns: const [
          AdminTableColumn('Time', width: 150),
          AdminTableColumn('Tokens', width: 140, align: TextAlign.right),
          AdminTableColumn('Of which input',
              width: 140, align: TextAlign.right),
          AdminTableColumn('Cost', width: 100, align: TextAlign.right),
        ],
        rows: [
          for (final m in memory)
            [
              Text(_date(m['created_at'])),
              Text(_compact(m['tokens']), textAlign: TextAlign.right),
              Text(_compact(m['tokens_in']), textAlign: TextAlign.right),
              Text(_money(m['cost']), textAlign: TextAlign.right),
            ]
        ],
      ),
    ]);
  }

  Widget _people() {
    final people = [..._listOfMaps(detail['members'])];
    if (_map(detail['owner']).isNotEmpty) {
      people.insert(0, {..._map(detail['owner']), 'role': 'owner'});
    }
    return AdminDataTable(
      empty: 'No people attached to this project.',
      columns: const [
        AdminTableColumn('Person', width: 260),
        AdminTableColumn('Role', width: 150),
        AdminTableColumn('Joined', width: 160)
      ],
      rows: [
        for (final p in people)
          [
            Row(children: [
              AdminAvatar(_displayName(p), size: 34, avatar: _avatarOf(p)),
              const SizedBox(width: 10),
              Expanded(
                  child: _primaryCell(
                      _displayName(p), '@${p['handle'] ?? _shortId(p['id'])}')),
            ]),
            _Tag('${p['role'] ?? 'member'}'),
            Text(_date(p['created_at'] ?? p['joined_at']))
          ]
      ],
    );
  }
}

/// A small tonal label.
class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color == null
            ? scheme.surfaceContainerHighest
            : tint.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 13, color: color ?? scheme.primary),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color ?? scheme.onSurface)),
        ),
      ]),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.admin});
  final bool admin;
  @override
  Widget build(BuildContext context) => admin
      ? _Tag('Admin',
          color: Theme.of(context).colorScheme.primary,
          icon: Icons.shield_rounded)
      : const _Tag('Member');
}

/// The picture of a person, project, agent or app row, as the node sends it
/// (its avatar, a project's avatar id, a profile's or a descriptor's).
String _avatarOf(dynamic row) {
  final m = _map(row);
  for (final v in [
    m['avatar'],
    m['avatar_id'],
    _map(m['profile'])['avatar'],
    _map(m['descriptor'])['avatar'],
  ]) {
    final s = v is String ? v.trim() : '';
    if (s.isNotEmpty && !RegExp(r'^0+$').hasMatch(s)) return s;
  }
  return '';
}

Map<String, dynamic> _map(dynamic value) => value is Map
    ? value.map((key, item) => MapEntry('$key', item))
    : <String, dynamic>{};
List<dynamic> _list(dynamic value) => value is List ? value : const [];
List<Map<String, dynamic>> _listOfMaps(dynamic value) =>
    _list(value).whereType<Map<dynamic, dynamic>>().map(_map).toList();
List<String> _stringList(dynamic value) =>
    _list(value).map((x) => '$x').toList();
List<double> _doubleList(dynamic value) =>
    _list(value).map((x) => _number(x)).toList();
double _number(dynamic value, {double fallback = 0}) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;
int _integer(dynamic value) => _number(value).round();
String _compact(dynamic value) {
  final n = _number(value);
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '${n.round()}';
}

String _credits(dynamic value) {
  if (value == null || '$value'.isEmpty) return '—';
  return formatLedgerCredits(_number(value), exact: true);
}

String _money(dynamic credits) {
  if (credits == null || '$credits'.isEmpty) return '\$0.00';
  return formatLedgerUsd(_number(credits));
}

/// Dollars with cents, or up to four decimals below a cent.
String _usd(double v) =>
    v >= .01 || v == 0 ? '\$${v.toStringAsFixed(2)}' : '\$${compactDecimal(v)}';

String _perMinute(dynamic units) {
  if (units == null || '$units'.isEmpty || _number(units) == 0)
    return 'Default';
  return '${formatLedgerUsd(_number(units))}/min';
}

String _humanKey(String key) {
  final words = key.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  if (words.isEmpty) return key;
  return words.length <= 4
      ? words.toUpperCase()
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

String _modelPrice(dynamic credits) =>
    '\$${compactDecimal(ledgerToUsd(_number(credits)), decimals: 6)}';
String _date(dynamic value) {
  if (value == null || '$value'.isEmpty || value == 0) return '—';
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse('$value');
  if (date == null) return '$value';
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _time(dynamic value) {
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse('$value');
  if (date == null) return '';
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
}

String _bytes(dynamic value) {
  var n = _number(value);
  if (n <= 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit++;
  }
  return '${n.toStringAsFixed(n >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _shortId(dynamic value) {
  final id = '${value ?? ''}';
  return id.length <= 12 ? id : '${id.substring(0, 8)}…';
}

String _displayName(Map<String, dynamic> user) {
  final profile = _map(user['profile']);
  final name = [
    profile['firstName'] ?? profile['first_name'],
    profile['lastName'] ?? profile['last_name']
  ].where((x) => x != null && '$x'.trim().isNotEmpty).join(' ');
  return name.isNotEmpty
      ? name
      : '${user['name'] ?? user['handle'] ?? user['id'] ?? 'Unknown'}';
}

String _owner(Map<String, dynamic> space) {
  final owner = _map(space['owner']);
  if (owner['deleted'] == true) return 'Deleted account';
  final handle = owner['handle'] ?? space['owner_handle'];
  return handle == null
      ? _shortId(space['owner_id'])
      : '@${'$handle'.replaceFirst(RegExp(r'^@+'), '')}';
}

String _machineState(Map<String, dynamic> space) =>
    '${_map(space['machine'])['state'] ?? space['machine_state'] ?? 'none'}';
String _rowId(Map<String, dynamic> row) =>
    '${row['transaction_id'] ?? row['id']}';
double _sum(List<Map<String, dynamic>> rows, String key) => rows.fold(
    0,
    (sum, row) =>
        sum + _number(row[key] ?? row['credits'] ?? row['listed_amount']));

/// What a model is for: its capability, and the label the console shows.
const _modelKinds = <(String, String)>[
  ('chat', 'Agent'),
  ('decision', 'Decision'),
  ('embedding', 'Embedding'),
  ('image', 'Image'),
  ('video', 'Video'),
  ('speech', 'Speech'),
  ('transcription', 'Transcription'),
  ('rerank', 'Rerank'),
];

String _modelPurpose(Map<String, dynamic> model) {
  final capabilities = _stringList(model['capabilities']);
  for (final (capability, label) in _modelKinds.skip(1)) {
    if (capabilities.any((c) => c.contains(capability))) return label;
  }
  return 'Agent';
}

/// A model's prices other than tokens, as the console edits them: the
/// stored unit, the quoted unit and how many stored units one quoted unit is.
const _unitFields = <String, List<(String, String, double)>>{
  'image': [('image', '\$ per image', 1)],
  'video': [('second', '\$ per second of video', 1)],
  'speech': [('character', '\$ per 1M characters', 1e6)],
  'transcription': [('second', '\$ per minute of audio', 60)],
  'rerank': [('search', '\$ per search', 1)],
};

/// Kinds also, or only, priced by their tokens.
const _tokenPriced = {'chat', 'decision', 'embedding', 'image', 'rerank'};

String _unitUsd(num units) {
  final usd = units / ledgerUnitsPerUsd;
  if (usd <= 0) return '\$0';
  return '\$${usd >= 1 ? usd.toStringAsFixed(2) : compactDecimal(usd, decimals: 8)}';
}

/// What a model costs, in one line: tokens, or its unit, as it is priced.
String _modelPriceText(Map<String, dynamic> m) {
  if (m['unpriced'] == true) return 'needs a price';
  final kind = _modelKinds
      .firstWhere((k) => k.$2 == _modelPurpose(m),
          orElse: () => _modelKinds.first)
      .$1;
  final u = _map(m['units']);
  final parts = <String>[
    if (_number(u['image']) > 0) '${_unitUsd(_number(u['image']))} / image',
    if (kind == 'video' && _map(u['second_by']).isNotEmpty)
      _map(u['second_by'])
          .entries
          .map((e) => '${e.key} ${_unitUsd(_number(e.value))}/s')
          .join(' · ')
    else if (kind == 'video' && _number(u['second']) > 0)
      '${_unitUsd(_number(u['second']))} / second',
    if (kind == 'transcription' && _number(u['second']) > 0)
      '${_unitUsd(_number(u['second']) * 60)} / minute',
    if (_number(u['character']) > 0)
      '${_unitUsd(_number(u['character']) * 1e6)} / 1M characters',
    if (_number(u['search']) > 0) '${_unitUsd(_number(u['search']))} / search',
  ];
  final input = _number(m['input_price']), output = _number(m['output_price']);
  if (input > 0 || output > 0 || parts.isEmpty) {
    parts.add(output > 0
        ? '${_modelPrice(input)} in · ${_modelPrice(output)} out / 1M'
        : '${_modelPrice(input)} / 1M tokens');
  }
  return parts.join(' · ');
}

String _logLevel(String value) {
  final v = value.toLowerCase();
  if (v.startsWith('err') || v == 'fatal' || v == 'panic') return 'error';
  if (v.startsWith('warn')) return 'warn';
  if (v == 'debug') return 'debug';
  return 'log';
}

int _healthRank(String status) => status == 'fail' || status == 'error'
    ? 0
    : status == 'warn'
        ? 1
        : 2;
String _uptime(dynamic value) {
  final seconds = _integer(value);
  if (seconds <= 0) return '—';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return days > 0
      ? '${days}d ${hours}h'
      : hours > 0
          ? '${hours}h ${minutes}m'
          : '${minutes}m';
}

Widget _primaryCell(String primary, String secondary) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(primary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          if (secondary.isNotEmpty)
            Builder(
                builder: (context) => Text(secondary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 10,
                        color: Theme.of(context).colorScheme.onSurfaceVariant)))
        ]);

/// Searchable list of the projects that can be the platform admins space; it
/// pops the chosen one.
class _AdminsSpacePicker extends StatefulWidget {
  const _AdminsSpacePicker({required this.projects, required this.currentId});
  final List<Map<String, dynamic>> projects;
  final String currentId;

  @override
  State<_AdminsSpacePicker> createState() => _AdminsSpacePickerState();
}

class _AdminsSpacePickerState extends State<_AdminsSpacePicker> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = query.text.trim().toLowerCase();
    final rows = widget.projects
        .where((s) =>
            q.isEmpty ||
            '${s['name']} ${s['id']} ${_map(s['owner'])['handle']}'
                .toLowerCase()
                .contains(q))
        .toList();
    return AlertDialog(
      icon: const Icon(Icons.admin_panel_settings_rounded),
      title: const Text('Choose the admins space'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(children: [
          TextField(
            controller: query,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search title, id, or owner handle'),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text(widget.projects.isEmpty
                        ? 'No projects created yet.'
                        : 'No projects match.'))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final s = rows[i];
                      final selected = '${s['id']}' == widget.currentId;
                      return ListTile(
                        leading: AdminAvatar('${s['name'] ?? s['id']}',
                            size: 34,
                            icon: Icons.folder_rounded,
                            avatar: _avatarOf(s)),
                        title: Text('${s['name'] ?? s['id']}'),
                        subtitle: Text('${_owner(s)} · ${_shortId(s['id'])}'),
                        trailing:
                            selected ? const Icon(Icons.check_rounded) : null,
                        selected: selected,
                        onTap: () => Navigator.pop(context, s),
                      );
                    }),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
      ],
    );
  }
}
