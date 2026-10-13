import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import 'admin_widgets.dart';

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
    required this.onAction,
    required this.onDirectAction,
    required this.onNavigate,
  });

  final String page;
  final Map<String, dynamic> results;
  final bool loading;
  final Future<void> Function() onRefresh;
  final AdminAction onAction;
  final AdminDirectAction onDirectAction;
  final ValueChanged<String> onNavigate;

  @override
  State<AdminPageContent> createState() => _AdminPageContentState();
}

class _AdminPageContentState extends State<AdminPageContent> {
  final search = TextEditingController();
  String filter = 'all';
  String sort = 'created';
  bool ascending = false;
  bool live = true;
  bool advanced = false;
  final selected = <String>{};
  final cpu = <double>[];
  final memory = <double>[];
  Timer? timer;

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
    if (oldWidget.results != widget.results) _sampleNode();
  }

  void _configureTimer() {
    timer?.cancel();
    if (widget.page == 'Node · Host' || widget.page == 'Node · Logs') {
      timer = Timer.periodic(
          Duration(seconds: widget.page == 'Node · Logs' ? 3 : 5), (_) {
        if (mounted && live && !widget.loading) widget.onRefresh();
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
      return const Center(child: CircularProgressIndicator());
    }
    final errors = widget.results.entries
        .where((entry) => _map(entry.value).containsKey('error'))
        .toList();
    final gutter = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 24.0;
    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        key: PageStorageKey(widget.page),
        padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 40),
        children: [
          if (errors.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: AppColors.danger.withValues(alpha: .3)),
              ),
              child: Text(
                errors
                    .map((e) => '${e.key}: ${_map(e.value)['error']}')
                    .join('\n'),
                style: const TextStyle(color: AppColors.danger, fontSize: 12),
              ),
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
        'Agents' => _agents(),
        'Tools' => _tools(),
        'Talent' => _talent(),
        'Finance · Overview' => _finance(),
        'Finance · Purchases' => _purchases(),
        'Finance · Payouts' => _payouts(),
        'Models' => _models(),
        'Decision model' => _decision(),
        'Memory models' => _memoryModels(),
        'Health' => _health(),
        'Node · Host' => _node(),
        'Node · Plugins' => _nodePlugins(),
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
    final stats = _map(widget.results['admin.stats']);
    final counters =
        _map(stats['counters']).isNotEmpty ? _map(stats['counters']) : stats;
    final health = _map(widget.results['admin.health']);
    final counts = _map(health['counts']);
    final runs = _listOfMaps(_map(widget.results['admin.runs_list'])['runs']);
    final failedRuns = runs.where((r) {
      final s = '${r['status']}'.toLowerCase();
      return s == 'failed' || s == 'error';
    }).length;
    final needs = <({String text, String target, Color tone})>[
      if (_integer(counts['fail']) > 0)
        (
          text: '${_integer(counts['fail'])} deploy checks need attention',
          target: 'Health',
          tone: AppColors.danger
        ),
      if (_integer(counts['warn']) > 0)
        (
          text:
              '${_integer(counts['warn'])} deployment checks are worth a look',
          target: 'Health',
          tone: AppColors.warning
        ),
      if (failedRuns > 0)
        (
          text: '$failedRuns agent runs failed recently',
          target: 'Projects',
          tone: AppColors.danger
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
        title: 'Needs you',
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: needs.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                    'All clear: no reviews, payouts or failing checks are waiting.'))
            : Column(
                children: [
                  for (final item in needs)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                              color: item.tone, shape: BoxShape.circle)),
                      title: Text(item.text,
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      trailing: Text('${item.target} →',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700)),
                      onTap: () => widget.onNavigate(item.target),
                    ),
                ],
              ),
      ),
      const SizedBox(height: 18),
      Text('PLATFORM', style: _eyebrow()),
      const SizedBox(height: 9),
      _statGrid([
        AdminStatCard(
            label: 'Users',
            value: _compact(counters['users'] ?? counters['accounts']),
            hint: 'Accounts and wallets',
            icon: Icons.people_outline,
            onTap: () => widget.onNavigate('Users')),
        AdminStatCard(
            label: 'Projects',
            value: _compact(counters['projects'] ?? counters['spaces']),
            hint: 'Workspaces and machines',
            icon: Icons.folder_outlined,
            onTap: () => widget.onNavigate('Projects')),
        AdminStatCard(
            label: 'Bots',
            value: _compact(counters['bots']),
            hint: 'Agents, tools and miniapps',
            icon: Icons.smart_toy_outlined,
            onTap: () => widget.onNavigate('Agents')),
        AdminStatCard(
            label: 'Agent runs',
            value: _compact(counters['room_turns']),
            hint: 'Turns across all projects',
            icon: Icons.play_circle_outline,
            onTap: () => widget.onNavigate('Projects')),
      ]),
    ]);
  }

  Widget _users() {
    final accounts =
        _listOfMaps(_map(widget.results['users.accounts_list'])['accounts']);
    final admins =
        _listOfMaps(_map(widget.results['admin.admins_list'])['admins']);
    final q = search.text.trim().toLowerCase();
    final rows = accounts.where((a) {
      final status = '${a['status'] ?? 'active'}'.toLowerCase();
      if (filter != 'all' &&
          filter != status &&
          !(filter == 'admin' && a['is_admin'] == true)) return false;
      return q.isEmpty ||
          '${a['handle']} ${a['email']} ${a['id']} ${jsonEncode(a['profile'] ?? {})}'
              .toLowerCase()
              .contains(q);
    }).toList();
    final active = accounts
        .where((a) => '${a['status'] ?? 'active'}'.toLowerCase() == 'active')
        .length;
    final adminIds = admins.map((a) => '${a['id']}').toSet();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Accounts',
            value: '${accounts.length}',
            hint: 'Registered users'),
        AdminStatCard(
            label: 'Active',
            value: '$active',
            hint: 'Can sign in',
            tone: AppColors.success),
        AdminStatCard(
            label: 'Admins',
            value: '${admins.length}',
            hint: 'Platform operators'),
        AdminStatCard(
            label: 'Disabled',
            value: '${accounts.length - active}',
            hint: 'Access blocked',
            tone: accounts.length == active ? null : AppColors.warning),
      ]),
      const SizedBox(height: 14),
      AdminSearchField(
          controller: search,
          hint: 'Search name, handle, email, or user id',
          onChanged: (_) => setState(() {}),
          trailing: _filterMenu(const {
            'all': 'All users',
            'active': 'Active',
            'disabled': 'Disabled',
            'pending': 'Pending',
            'admin': 'Admins',
          })),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: q.isEmpty ? 'No accounts registered yet.' : 'No users match.',
        onRowTap: (index) => _showUser(rows[index]),
        columns: const [
          AdminTableColumn('User', width: 220),
          AdminTableColumn('Email', width: 240),
          AdminTableColumn('Role', width: 100),
          AdminTableColumn('Status', width: 110),
          AdminTableColumn('Balance', width: 120, align: TextAlign.right),
          AdminTableColumn('Last seen', width: 160),
          // Three 48 px icon buttons plus cell padding, on one line.
          AdminTableColumn('Actions', width: 172, align: TextAlign.right),
        ],
        rows: [
          for (final a in rows)
            [
              _primaryCell(_displayName(a),
                  '@${a['handle'] ?? 'unknown'}\n${_shortId(a['id'])}'),
              Text('${a['email'] ?? '—'}'),
              Text(a['is_admin'] == true || adminIds.contains('${a['id']}')
                  ? 'Admin'
                  : '${a['role'] ?? 'User'}'),
              AdminStatusPill('${a['status'] ?? 'active'}'),
              Text(_credits(a['balance']), textAlign: TextAlign.right),
              Text(_date(a['last_seen'] ?? a['created_at'])),
              Wrap(alignment: WrapAlignment.end, spacing: 3, children: [
                IconButton(
                    tooltip: 'Edit profile and access',
                    onPressed: () =>
                        widget.onAction('users', 'account_update', {
                          'account': a['id'],
                          'handle': a['handle'],
                          'email': a['email'],
                          'role': a['role'],
                          'status': a['status'],
                          'profile': a['profile'] ?? <String, dynamic>{},
                        }),
                    icon: const Icon(Icons.edit_outlined, size: 18)),
                IconButton(
                    tooltip: 'Grant credits',
                    onPressed: () => widget.onAction('finance', 'wallet_mint', {
                          'target': a['id'],
                        }),
                    icon: const Icon(Icons.add_card_rounded, size: 18)),
                PopupMenuButton<String>(
                    tooltip: 'More actions',
                    onSelected: (value) {
                      if (value == 'password') {
                        widget.onAction(
                            'users', 'account_password', {'account': a['id']});
                      } else if (value == 'ledger') {
                        widget.onAction('finance', 'admin_account',
                            {'account': a['id'], 'limit': 100});
                      } else {
                        widget.onAction(
                            'users', 'account_delete', {'account': a['id']});
                      }
                    },
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'password', child: Text('Set password')),
                          PopupMenuItem(
                              value: 'ledger', child: Text('Wallet activity')),
                          PopupMenuDivider(),
                          PopupMenuItem(
                              value: 'delete', child: Text('Delete account')),
                        ]),
              ]),
            ],
        ],
      ),
      const SizedBox(height: 10),
      Text('${rows.length} of ${accounts.length} users',
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 11)),
    ]);
  }

  Widget _projects() {
    final spaces =
        _listOfMaps(_map(widget.results['spaces.space_list_all'])['spaces']);
    final q = search.text.trim().toLowerCase();
    final rows = spaces.where((s) {
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
      } else {
        av = '${a['created_at'] ?? ''}';
        bv = '${b['created_at'] ?? ''}';
      }
      final order = Comparable.compare(av as Comparable, bv as Comparable);
      return ascending ? order : -order;
    });
    final awake = spaces.where((s) => _machineState(s) == 'awake').length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Projects',
            value: '${spaces.length}',
            hint: 'Workspaces on this node'),
        AdminStatCard(
            label: 'Computers awake',
            value: '$awake',
            hint: 'Currently incurring runtime cost',
            tone: awake > 0 ? AppColors.success : null),
        AdminStatCard(
            label: 'Sleeping',
            value: '${spaces.length - awake}',
            hint: 'No active compute'),
      ]),
      const SizedBox(height: 14),
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
              ascending = value != 'created';
            }
          }),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'created', child: Text('Sort by created')),
            PopupMenuItem(value: 'title', child: Text('Sort by title')),
            PopupMenuItem(value: 'owner', child: Text('Sort by owner')),
          ],
        ),
      ),
      const SizedBox(height: 14),
      AdminDataTable(
        empty:
            spaces.isEmpty ? 'No projects created yet.' : 'No projects match.',
        onRowTap: (index) => _showProject(rows[index]),
        columns: const [
          AdminTableColumn('Project', width: 240),
          AdminTableColumn('Owner', width: 170),
          AdminTableColumn('Agents', width: 90, align: TextAlign.right),
          AdminTableColumn('Machine', width: 120),
          AdminTableColumn('Spend', width: 120, align: TextAlign.right),
          AdminTableColumn('Created', width: 160),
        ],
        rows: [
          for (final s in rows)
            [
              _primaryCell('${s['name'] ?? s['id']}',
                  '${s['home'] == true ? 'home · ' : ''}${_shortId(s['id'])}'),
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
          style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
    ]);
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
    final q = search.text.trim().toLowerCase();
    final rows = bots.where((b) {
      final listing = byBot['${b['id']}'];
      final status = '${listing?['status'] ?? 'unlisted'}';
      return (filter == 'all' || filter == status) &&
          (q.isEmpty ||
              '${b['name']} ${b['handle']} ${b['owner_handle']} ${b['provider']} ${b['model']} ${b['fallback_models']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    final pending = listings
        .where((l) =>
            '${l['type'] ?? l['kind']}' == 'agent' &&
            '${l['status']}' == 'pending')
        .length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          Wrap(spacing: 8, runSpacing: 8, children: [
            _filterChip('All', 'all'),
            _filterChip('Listed', 'approved'),
            _filterChip('Review', 'pending', count: pending),
            _filterChip('Denied', 'denied'),
            _filterChip('Unlisted', 'unlisted'),
          ]),
          [
            OutlinedButton.icon(
              onPressed: () => widget.onAction(
                  'bots', 'agent_import_samples', const <String, dynamic>{}),
              icon: const Icon(Icons.download_rounded, size: 17),
              label: const Text('Import samples'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  widget.onAction('bots', 'bot_create', {'kind': 'agent'}),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add agent'),
            ),
          ]),
      const SizedBox(height: 12),
      AdminSearchField(
          controller: search,
          hint: 'Search agent name, @handle, owner, model, or fallbacks…',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: bots.isEmpty
            ? 'No agents have been created on this node yet.'
            : 'No agents match this search or filter.',
        columns: const [
          AdminTableColumn('Agent', width: 230),
          AdminTableColumn('Owner', width: 150),
          AdminTableColumn('Backbone', width: 210),
          AdminTableColumn('Rate', width: 110, align: TextAlign.right),
          AdminTableColumn('Listing', width: 110),
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
    return [
      _primaryCell('${b['name'] ?? b['handle'] ?? 'Agent'}',
          '@${b['handle'] ?? _shortId(b['id'])}'),
      Text('${b['owner_handle'] ?? _shortId(b['owner_id'])}'),
      _primaryCell(
          '${b['model'] ?? 'Default'}', '${b['provider'] ?? 'platform'}'),
      Text(_credits(b['per_minute'] ?? _map(b['cost'])['per_minute']),
          textAlign: TextAlign.right),
      AdminStatusPill(status),
      Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
        IconButton(
            tooltip: 'Edit agent',
            onPressed: () => widget.onAction('bots', 'bot_edit', {
                  'bot': b['id'],
                  'name': b['name'],
                  'instructions': b['instructions'],
                  'provider': b['provider'],
                  'model': b['model'],
                  'cost': b['cost'] ?? <String, dynamic>{},
                }),
            icon: const Icon(Icons.edit_outlined, size: 18)),
        if (status == 'pending') ...[
          IconButton(
              tooltip: 'Approve listing',
              onPressed: () => widget.onDirectAction('market', 'approve', {
                    'listing': listing?['id'],
                    'bot': b['id'],
                  }),
              icon: const Icon(Icons.check_circle_outline,
                  size: 18, color: AppColors.success)),
          IconButton(
              tooltip: 'Deny listing',
              onPressed: () => widget.onAction('market', 'deny', {
                    'listing': listing?['id'],
                    'bot': b['id'],
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
          onSelected: (_) =>
              widget.onAction('bots', 'bot_delete', {'bot': b['id']}),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'delete', child: Text('Delete agent')),
          ],
        ),
      ]),
    ];
  }

  Widget _tools() {
    final bots =
        _listOfMaps(_map(widget.results['admin.bots_list'])['bots']).where((b) {
      final kind = '${b['kind'] ?? ''}';
      return kind == 'tool' || kind == 'miniapp' || kind == 'mcp';
    }).toList();
    final samples =
        _listOfMaps(_map(widget.results['tools.mcp_samples'])['samples']);
    final listings =
        _listOfMaps(_map(widget.results['market.catalog'])['listings']);
    final q = search.text.trim().toLowerCase();
    final rows = bots
        .where((b) =>
            q.isEmpty ||
            '${b['name']} ${b['handle']} ${b['kind']} ${b['url']} ${b['description']}'
                .toLowerCase()
                .contains(q))
        .toList();
    final servers = rows
        .where((b) =>
            '${b['kind']}' == 'mcp' || _map(b['descriptor']).containsKey('url'))
        .toList();
    final tools = rows.where((b) => !servers.contains(b)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search MCP servers, tools and miniapps',
              onChanged: (_) => setState(() {})),
          [
            OutlinedButton.icon(
              onPressed: () => widget.onAction(
                  'tools', 'mcp_import_samples', const <String, dynamic>{}),
              icon: const Icon(Icons.download_rounded, size: 17),
              label:
                  Text(samples.isEmpty ? 'Import samples' : 'Import catalog'),
            ),
            FilledButton.icon(
              onPressed: () =>
                  widget.onAction('tools', 'mcp_register', const {}),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add server'),
            ),
          ]),
      const SizedBox(height: 16),
      _toolSection('MCP servers (${servers.length})', servers, listings,
          server: true),
      const SizedBox(height: 18),
      _toolSection('Tools and miniapps (${tools.length})', tools, listings),
    ]);
  }

  Widget _toolSection(String title, List<Map<String, dynamic>> rows,
      List<Map<String, dynamic>> listings,
      {bool server = false}) {
    return AdminSectionCard(
      title: title,
      padding: EdgeInsets.zero,
      child: rows.isEmpty
          ? AdminEmptyState(
              server ? 'No MCP servers' : 'No tools or miniapps',
              search.text.isEmpty
                  ? 'Nothing in this section yet.'
                  : 'No items match your search.')
          : Column(children: [
              for (final b in rows)
                Builder(builder: (context) {
                  final listing = listings
                      .cast<Map<String, dynamic>?>()
                      .firstWhere(
                          (l) => '${l?['bot_id'] ?? l?['bot']}' == '${b['id']}',
                          orElse: () => null);
                  final listed =
                      listing != null && '${listing['status']}' != 'unlisted';
                  return _adaptiveTile(
                    leading: CircleAvatar(
                        child: Icon(server
                            ? Icons.hub_outlined
                            : '${b['kind']}' == 'miniapp'
                                ? Icons.widgets_outlined
                                : Icons.build_outlined)),
                    title: Text('${b['name'] ?? b['handle'] ?? b['id']}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        [
                          '${b['kind'] ?? (server ? 'MCP server' : 'tool')}',
                          '${b['url'] ?? _map(b['descriptor'])['url'] ?? ''}',
                          _credits(
                              b['per_minute'] ?? _map(b['cost'])['per_minute']),
                        ].where((v) => v.isNotEmpty && v != '—').join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                    actions: [
                      AdminStatusPill(
                          listed ? 'listed' : '${b['status'] ?? 'unlisted'}'),
                      IconButton(
                          tooltip: 'Edit',
                          onPressed: () => widget.onAction('tools',
                                  server ? 'mcp_update' : 'mcp_register', {
                                'bot': b['id'],
                                'name': b['name'],
                                'url': b['url']
                              }),
                          icon: const Icon(Icons.edit_outlined, size: 18)),
                      IconButton(
                          tooltip: listed ? 'Unlist' : 'List',
                          onPressed: () => listed
                              ? widget.onDirectAction('market', 'unpublish',
                                  {'listing': listing['id']})
                              : widget.onAction('market', 'publish', {
                                  'bot': b['id'],
                                  'type': '${b['kind'] ?? 'tool'}',
                                  'name': b['name'],
                                }),
                          icon: Icon(
                              listed
                                  ? Icons.visibility_off_outlined
                                  : Icons.storefront_outlined,
                              size: 18)),
                      IconButton(
                          tooltip: 'Delete',
                          onPressed: () => widget.onAction(
                              'tools', 'mcp_delete', {'bot': b['id']}),
                          icon: const Icon(Icons.delete_outline_rounded,
                              size: 18)),
                    ],
                  );
                }),
            ]),
    );
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [
        _filterChip('Pending', 'pending'),
        _filterChip('Approved', 'approved'),
        _filterChip('Denied', 'rejected'),
        _filterChip('All', 'all'),
      ]),
      const SizedBox(height: 12),
      AdminSearchField(
          controller: search,
          hint: 'Search name, username, or skills',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: all.isEmpty
            ? 'No hireable talent matches this status.'
            : 'No people match your search.',
        columns: const [
          AdminTableColumn('Person', width: 220),
          AdminTableColumn('Skills', width: 280),
          AdminTableColumn('Rate', width: 110, align: TextAlign.right),
          AdminTableColumn('Status', width: 110),
          AdminTableColumn('Actions', width: 180, align: TextAlign.right),
        ],
        rows: [
          for (final t in rows)
            [
              _primaryCell('${t['name'] ?? t['display_name'] ?? 'Person'}',
                  '@${t['handle'] ?? t['username'] ?? 'unknown'}'),
              Text(_stringList(t['skills']).join(', ')),
              Text(_credits(t['rate'] ?? t['hourly_rate']),
                  textAlign: TextAlign.right),
              AdminStatusPill('${t['status'] ?? 'pending'}'),
              Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
                TextButton(
                    onPressed: () =>
                        widget.onAction('users', 'account_update', {
                          'account': t['id'],
                          'profile': {'marketStatus': 'approved'},
                        }),
                    child: const Text('Approve')),
                TextButton(
                    onPressed: () =>
                        widget.onAction('users', 'account_update', {
                          'account': t['id'],
                          'profile': {'marketStatus': 'rejected'},
                        }),
                    child: const Text('Deny')),
              ]),
            ],
        ],
      ),
    ]);
  }

  Widget _finance() {
    final o = _map(widget.results['finance.overview']);
    final income = _map(o['income']);
    final charged = _map(o['charged']);
    final paid = _map(o['paid_out']);
    final reconcile = _map(widget.results['finance.reconcile']);
    final costs = _map(widget.results['finance.costs']);
    final providers = _map(widget.results['finance.provider_costs']);
    final components = <({String label, double value, Color color})>[
      (
        label: 'Compute',
        value: _number(charged['compute']),
        color: AppColors.cyan
      ),
      (
        label: 'Tools',
        value: _number(charged['tools']),
        color: AppColors.primary
      ),
      (label: 'LLM', value: _number(charged['llm']), color: AppColors.warning),
      (
        label: 'Agent time',
        value: _number(charged['agent_time']),
        color: AppColors.success
      ),
    ];
    final total = components.fold<double>(0, (sum, item) => sum + item.value);
    final issues = _listOfMaps(reconcile['issues']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, children: [
        _filterChip('7 days', '7d'),
        _filterChip('30 days', '30d'),
        _filterChip('90 days', '90d'),
        _filterChip('All time', 'all'),
      ]),
      const SizedBox(height: 14),
      _statGrid([
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
            icon: Icons.people_alt_outlined),
        AdminStatCard(
            label: 'Net revenue',
            value: _money(o['kept']),
            hint: 'Kept by the platform, before provider bills',
            icon: Icons.account_balance_outlined,
            tone:
                _number(o['kept']) < 0 ? AppColors.danger : AppColors.success),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'What customers spent it on',
        child: LayoutBuilder(builder: (context, constraints) {
          final bars = _FinanceBars(items: components, total: total);
          final values = Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final item in components)
                AdminKeyValue(item.label, _money(item.value)),
            ],
          );
          if (constraints.maxWidth < 600) {
            return Column(children: [bars, const SizedBox(height: 12), values]);
          }
          return SizedBox(
            height: 190,
            child: Row(children: [
              Expanded(flex: 2, child: bars),
              const SizedBox(width: 24),
              Expanded(child: values),
            ]),
          );
        }),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Computers: provider bill vs what you charged',
        child: Column(children: [
          AdminKeyValue(
              'Provider billed',
              _money(
                  providers['bill'] ?? providers['total'] ?? costs['compute'])),
          AdminKeyValue('Customers charged',
              _money(providers['charged'] ?? charged['compute'])),
          AdminKeyValue('Margin', _money(providers['margin'])),
          for (final row in _listOfMaps(providers['by_resource']))
            AdminKeyValue('  ${row['label'] ?? row['resource']}',
                _money(row['units'] ?? row['cost'])),
        ]),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Where it ended up',
        child: Column(children: [
          AdminKeyValue(
              'Creators (their agents and tools)', _money(paid['creators'])),
          AdminKeyValue('Platform', _money(o['kept'])),
          AdminKeyValue('Platform LLM', _money(paid['platform_llm'])),
          AdminKeyValue('Platform compute', _money(paid['platform_compute'])),
          AdminKeyValue('Platform bots', _money(paid['platform_bots'])),
          const Divider(),
          AdminKeyValue(
              'Unspent credits users hold', _money(o['held_by_users'])),
        ]),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Ledger check',
        trailing: IconButton(
            tooltip: 'Reconcile wallets',
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.sync_rounded, size: 19)),
        child: Column(children: [
          Row(children: [
            AdminStatusPill(reconcile['ok'] == true ? 'healthy' : 'error'),
            const SizedBox(width: 10),
            Expanded(
              child: Text(reconcile['ok'] == true
                  ? 'Balanced — ${_integer(reconcile['checked'])} wallets checked'
                  : '${issues.length} reconciliation issue(s)'),
            ),
          ]),
          for (final issue in issues)
            AdminKeyValue('${issue['kind']}',
                '${issue['account_id'] ?? ''} ${issue['detail'] ?? ''}',
                mono: true),
        ]),
      ),
    ]);
  }

  Widget _purchases() {
    final response = _map(widget.results['finance.purchases_list']);
    final all = _listOfMaps(response['purchases'] ?? response['transactions']);
    final q = search.text.trim().toLowerCase();
    final rows = all
        .where((p) =>
            q.isEmpty ||
            '${p['email']} ${p['product_id']} ${p['status']} ${p['transaction_id']} ${p['id']}'
                .toLowerCase()
                .contains(q))
        .toList();
    final charged = all
        .where((p) => '${p['status']}' == 'credited' && p['sandbox'] != true)
        .toList();
    final sandbox = all.where((p) => p['sandbox'] == true).toList();
    final pending = all.where((p) => '${p['status']}' == 'pending').toList();
    final reversed = all.where((p) => '${p['status']}' == 'reversed').toList();
    final selectedRows =
        all.where((p) => selected.contains(_rowId(p))).toList();
    final selectedSandbox =
        selectedRows.where((p) => p['sandbox'] == true).length;
    final selectedLive = selectedRows.length - selectedSandbox;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Charged',
            value: _money(_sum(charged, 'amount')),
            hint: '${charged.length} live purchases',
            tone: AppColors.success),
        AdminStatCard(
            label: 'Sandbox',
            value: _money(_sum(sandbox, 'amount')),
            hint: '${sandbox.length} test transactions'),
        AdminStatCard(
            label: 'Pending',
            value: _money(_sum(pending, 'amount')),
            hint: '${pending.length} waiting',
            tone: pending.isEmpty ? null : AppColors.warning),
        AdminStatCard(
            label: 'Reversed',
            value: _money(_sum(reversed, 'amount')),
            hint: '${reversed.length} refunds',
            tone: reversed.isEmpty ? null : AppColors.danger),
      ]),
      const SizedBox(height: 14),
      AdminSearchField(
          controller: search,
          hint: 'Search email, product, or status',
          onChanged: (_) => setState(() {})),
      if (selected.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Expanded(child: Text('${selected.length} selected')),
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
              FilledButton.tonal(
                  onPressed: () => _labelPurchases(selectedRows, false),
                  child: Text('Mark live ($selectedSandbox)')),
          ]),
        ),
      ],
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
          AdminTableColumn('✓', width: 42),
          AdminTableColumn('Customer', width: 230),
          AdminTableColumn('Product', width: 180),
          AdminTableColumn('Amount', width: 110, align: TextAlign.right),
          AdminTableColumn('Status', width: 150),
          AdminTableColumn('Purchased', width: 170),
          AdminTableColumn('Transaction', width: 190),
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
              _primaryCell('${p['email'] ?? p['account_handle'] ?? 'Unknown'}',
                  _shortId(p['account_id'])),
              Text('${p['product_id'] ?? p['product'] ?? '—'}'),
              Text(_money(p['amount'] ?? p['listed_amount']),
                  textAlign: TextAlign.right),
              Wrap(spacing: 5, children: [
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
    final ordered = [...all]..sort((a, b) =>
        '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Waiting to pay',
            value: _money(_sum(pending, 'amount')),
            hint: '${pending.length} requests',
            tone: pending.isEmpty ? null : AppColors.warning),
        AdminStatCard(
            label: 'Marked paid',
            value: _money(_sum(paid, 'amount')),
            hint: 'This queue only — already resolved',
            tone: AppColors.success),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Queue',
        subtitle:
            'Pay creators externally, then record the provider confirmation here.',
        padding: EdgeInsets.zero,
        child: ordered.isEmpty
            ? const AdminEmptyState(
                'No payouts', 'Creator withdrawal requests will appear here.')
            : Column(children: [
                for (final p in ordered)
                  ExpansionTile(
                    leading: CircleAvatar(
                        child: Text(
                            ('${p['handle'] ?? ''}'.characters.firstOrNull ??
                                    '?')
                                .toUpperCase())),
                    title: Text(
                        '${p['handle'] ?? p['account_id'] ?? 'Creator'}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(
                        '${_money(p['amount'])} · ${_date(p['created_at'])} · ${p['method'] ?? 'external'}'),
                    trailing: AdminStatusPill('${p['status'] ?? 'pending'}'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    children: [
                      AdminKeyValue(
                          'Destination', _jsonSummary(p['destination']),
                          mono: true),
                      AdminKeyValue(
                          'Request id', '${p['id'] ?? p['request_id']}',
                          mono: true),
                      if ('${p['status']}' == 'pending')
                        Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              OutlinedButton(
                                  onPressed: () => widget.onAction(
                                          'finance', 'payout_resolve', {
                                        'payout_id': p['id'],
                                        'resolution_id': '${p['id']}-rejected',
                                        'status': 'rejected',
                                      }),
                                  child: const Text('Reject and return funds')),
                              const SizedBox(width: 8),
                              FilledButton(
                                  onPressed: () => widget.onAction(
                                          'finance', 'payout_resolve', {
                                        'payout_id': p['id'],
                                        'resolution_id': '${p['id']}-paid',
                                        'status': 'paid',
                                      }),
                                  child: const Text('Mark paid')),
                            ]),
                    ],
                  ),
              ]),
      ),
    ]);
  }

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
      return (filter == 'all' || '${provider['id']}' == filter) &&
          (q.isEmpty ||
              '${provider['name']} ${m['id']} ${m['name']}'
                  .toLowerCase()
                  .contains(q));
    }).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          AdminSearchField(
              controller: search,
              hint: 'Search provider or model',
              onChanged: (_) => setState(() {})),
          [
            DropdownButton<String>(
              value:
                  providers.any((p) => '${p['id']}' == filter) ? filter : 'all',
              items: [
                const DropdownMenuItem(
                    value: 'all', child: Text('All providers')),
                for (final p in providers)
                  DropdownMenuItem(
                      value: '${p['id']}',
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: Text('${p['name']}',
                              overflow: TextOverflow.ellipsis))),
              ],
              onChanged: (value) => setState(() => filter = value ?? 'all'),
            ),
            FilledButton.icon(
                onPressed:
                    providers.isEmpty ? null : () => _showModel(providers),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add model')),
          ]),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: providers.isEmpty
            ? 'Add a provider first, then add its models here.'
            : 'No models match.',
        columns: const [
          AdminTableColumn('Provider', width: 180),
          AdminTableColumn('Model', width: 260),
          AdminTableColumn('Purpose', width: 140),
          AdminTableColumn('Input \$/1M', width: 120, align: TextAlign.right),
          AdminTableColumn('Output \$/1M', width: 120, align: TextAlign.right),
          AdminTableColumn('Actions', width: 130, align: TextAlign.right),
        ],
        rows: [
          for (final m in shown)
            [
              _primaryCell(
                  '${_map(m['_provider'])['name']}',
                  _map(m['_provider'])['enabled'] == false
                      ? 'disabled'
                      : 'enabled'),
              _primaryCell('${m['name'] ?? m['id']}',
                  m['name'] != null ? '${m['id']}' : ''),
              Text(_modelPurpose(m)),
              Text(_modelPrice(m['input_price']), textAlign: TextAlign.right),
              Text(_modelPrice(m['output_price']), textAlign: TextAlign.right),
              Wrap(alignment: WrapAlignment.end, children: [
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

  Future<void> _showModel(List<Map<String, dynamic>> providers,
      {Map<String, dynamic>? provider, Map<String, dynamic>? model}) async {
    final selected = provider ??
        providers.firstWhere((p) => filter != 'all' && '${p['id']}' == filter,
            orElse: () => providers.first);
    await showDialog<void>(
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _settingStatus(setting),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Decision model',
        subtitle: 'Tool selection, routing, progress and completion checks.',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                  value: true,
                  label: Text('On'),
                  icon: Icon(Icons.bolt_rounded)),
              ButtonSegment(
                  value: false,
                  label: Text('Off'),
                  icon: Icon(Icons.power_settings_new_rounded)),
            ],
            selected: {enabled},
            onSelectionChanged: (value) => widget.onDirectAction(
                'llm',
                'llm_decision_set',
                _decisionBody(setting, enabled: value.first)),
          ),
          const SizedBox(height: 10),
          Text(
              'On: decisions use the fast model below together with each agent’s own model. Off: every agent decides with its own model.',
              style: _muted()),
        ]),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Provider and model',
        child: Column(children: [
          DropdownButtonFormField<String>(
            initialValue: providerId.isEmpty ? null : providerId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Provider'),
            items: _optionItems(providers, providerId),
            onChanged: (value) {
              if (value == null) return;
              widget.onAction('llm', 'llm_decision_set',
                  _decisionBody(setting, provider: value, model: ''));
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: '${setting['model_id'] ?? ''}'.isEmpty
                ? null
                : '${setting['model_id']}',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Model'),
            items: _optionItems(_decisionModels(providers, providerId),
                '${setting['model_id'] ?? ''}'),
            onChanged: (value) {
              if (value == null) return;
              widget.onAction('llm', 'llm_decision_set',
                  _decisionBody(setting, model: value));
            },
          ),
        ]),
      ),
      const SizedBox(height: 18),
      SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: const Text('Auto-approve low-risk calls',
            style: TextStyle(fontWeight: FontWeight.w700)),
        subtitle: const Text(
            'Every other tool call still waits for a person; approvals are written to the work log.'),
        value: setting['auto_approve'] == true,
        onChanged: (value) => widget.onDirectAction('llm', 'llm_decision_set',
            _decisionBody(setting, autoApprove: value)),
      ),
    ]);
  }

  Widget _memoryModels() {
    final setting = _map(widget.results['llm.llm_memory_get']);
    final providers = _listOfMaps(setting['providers']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _settingStatus(setting),
      const SizedBox(height: 18),
      _memorySlot(
        title: 'Memory chat model',
        hint:
            'Reads each finished conversation and writes down preferences, decisions, people, and ways of working.',
        providers: providers,
        setting: setting,
        providerKey: 'chat_provider_id',
        modelKey: 'chat_model_id',
        listKey: 'chat_models',
      ),
      const SizedBox(height: 18),
      _memorySlot(
        title: 'Embedding model',
        hint:
            'Turns memories into vectors so agents find relevant context by meaning. Changing it re-indexes every project.',
        providers: providers,
        setting: setting,
        providerKey: 'embedding_provider_id',
        modelKey: 'embedding_model_id',
        listKey: 'embedding_models',
      ),
      const SizedBox(height: 14),
      Text(
          'Projects pay for memory token use at the model prices configured on Models, counted against the project budget.',
          style: _muted()),
    ]);
  }

  Widget _memorySlot({
    required String title,
    required String hint,
    required List<Map<String, dynamic>> providers,
    required Map<String, dynamic> setting,
    required String providerKey,
    required String modelKey,
    required String listKey,
  }) {
    final providerId = '${setting[providerKey] ?? ''}';
    final provider = providers
        .cast<Map<String, dynamic>?>()
        .firstWhere((p) => '${p?['id']}' == providerId, orElse: () => null);
    return AdminSectionCard(
      title: title,
      subtitle: hint,
      child: Column(children: [
        DropdownButtonFormField<String>(
          initialValue: providerId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Provider'),
          items: [
            const DropdownMenuItem(value: '', child: Text('None — not used')),
            ..._optionItems(providers, providerId),
          ],
          onChanged: (value) => widget.onAction('llm', 'llm_memory_set', {
            ..._memoryBody(setting),
            providerKey: value ?? '',
            modelKey: '',
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: '${setting[modelKey] ?? ''}'.isEmpty
              ? null
              : '${setting[modelKey]}',
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Model'),
          items: _optionItems(
              _listOfMaps(provider?[listKey] ?? provider?['models']),
              '${setting[modelKey] ?? ''}'),
          onChanged: providerId.isEmpty
              ? null
              : (value) => widget.onAction('llm', 'llm_memory_set', {
                    ..._memoryBody(setting),
                    modelKey: value ?? '',
                  }),
        ),
      ]),
    );
  }

  Widget _health() {
    final report = _map(widget.results['admin.health']);
    final checks = _listOfMaps(report['checks']);
    final pluginHealth =
        _listOfMaps(_map(widget.results['admin.plugins_health'])['health']);
    final counts = _map(report['counts']);
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final check in checks) {
      (groups['${check['group'] ?? 'Platform'}'] ??= []).add(check);
    }
    if (pluginHealth.isNotEmpty) groups['Plugin health'] = pluginHealth;
    for (final rows in groups.values) {
      rows.sort((a, b) =>
          _healthRank('${a['status'] ?? (a['ok'] == true ? 'ok' : 'fail')}')
              .compareTo(_healthRank(
                  '${b['status'] ?? (b['ok'] == true ? 'ok' : 'fail')}')));
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Need fixing',
            value: '$fail',
            hint: fail > 0 ? 'Broken or unsafe' : 'Nothing broken',
            tone: fail > 0 ? AppColors.danger : AppColors.success),
        AdminStatCard(
            label: 'Worth a look',
            value: '$warn',
            hint: 'Works, but something is unset',
            tone: warn > 0 ? AppColors.warning : null),
        AdminStatCard(label: 'Healthy', value: '$ok', tone: AppColors.success),
      ]),
      const SizedBox(height: 18),
      for (final group in groups.entries) ...[
        AdminSectionCard(
          title: group.key,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (final c in group.value)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .outlineVariant
                                .withValues(alpha: .4)))),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text('${c['label'] ?? c['name'] ?? c['id']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800))),
                        AdminStatusPill(
                            '${c['status'] ?? (c['ok'] == true ? 'ok' : 'error')}'),
                      ]),
                      if ('${c['detail'] ?? c['message'] ?? ''}'
                          .isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text('${c['detail'] ?? c['message']}', style: _muted()),
                      ],
                      if ('${c['fix'] ?? ''}'.isNotEmpty &&
                          '${c['status']}' != 'ok') ...[
                        const SizedBox(height: 5),
                        Text('Fix: ${c['fix']}',
                            style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w700)),
                      ],
                    ]),
              ),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      if (checks.isEmpty && pluginHealth.isEmpty)
        const AdminEmptyState('No health report',
            'Re-check the deployment to load live configuration checks.'),
      Text(
          'Checked ${_date(report['generated_at'])}. Secrets are never shown, only whether they are set.',
          style: _muted()),
    ]);
  }

  Widget _node() {
    final stats = _map(widget.results['admin.node_stats']);
    final r = _map(stats['resources']);
    final node = _map(stats['node']);
    final telemetry = _map(widget.results['admin.telemetry']);
    final plugins = _listOfMaps(telemetry['plugins']);
    final mesh = _map(widget.results['federation.nodes_list']);
    final nodes = _listOfMaps(mesh['nodes']);
    final load = _doubleList(r['load_avg']);
    final memoryPercent = _number(r['mem_used_percent']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        FilterChip(
            selected: live,
            avatar: Icon(live ? Icons.play_arrow_rounded : Icons.pause_rounded,
                size: 17),
            label: Text(live ? 'Live · 5s' : 'Paused'),
            onSelected: (value) => setState(() => live = value)),
      ]),
      const SizedBox(height: 8),
      _statGrid([
        AdminStatCard(
            label: 'Node',
            value: '${node['id'] ?? '—'}',
            hint: '${node['go_version'] ?? ''}',
            icon: Icons.dns_outlined),
        AdminStatCard(
            label: 'Plugins',
            value: '${node['plugins'] ?? 0}',
            hint: '${node['goroutines'] ?? 0} goroutines',
            icon: Icons.extension_outlined),
        AdminStatCard(
            label: 'Uptime',
            value: _uptime(r['host_uptime_sec']),
            hint: '${r['cpu_cores'] ?? '—'} cores',
            icon: Icons.timer_outlined),
        AdminStatCard(
            label: 'Disk',
            value: '${_number(r['disk_used_percent']).round()}%',
            hint:
                '${_bytes(r['disk_used_bytes'])} of ${_bytes(r['disk_total_bytes'])}',
            icon: Icons.storage_outlined),
      ]),
      const SizedBox(height: 16),
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
            color: AppColors.primary,
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
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Plugin health',
        child: plugins.isEmpty
            ? const Text('No telemetry yet.')
            : Column(children: [
                for (final p in plugins)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${p['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${p['message'] ?? ''}'),
                    trailing:
                        AdminStatusPill(p['ok'] == true ? 'healthy' : 'error'),
                  ),
              ]),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Mesh',
        child: nodes.isEmpty
            ? const Text('This node is not federated with any other.')
            : Column(children: [
                for (final n in nodes)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.hub_outlined),
                    title: Text(
                        '${n['id']}${n['id'] == mesh['local_node'] ? ' (this node)' : ''}${n['is_central'] == true ? ' · central' : ''}'),
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
    final q = search.text.trim().toLowerCase();
    final shown = plugins
        .where((p) =>
            q.isEmpty ||
            '${p['name']} ${p['type']} ${p['category']} ${p['provides']}'
                .toLowerCase()
                .contains(q))
        .toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final p in shown) {
      final key = '${p['type']}' == 'adapter'
          ? 'Adapters · ${p['category'] ?? 'other'}'
          : 'Action namespaces';
      (groups[key] ??= []).add(p);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSearchField(
          controller: search,
          hint: 'Search namespaces and adapters',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 16),
      for (final group in groups.entries) ...[
        AdminSectionCard(
          title: group.key,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (final p in group.value)
              _adaptiveTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon('${p['type']}' == 'adapter'
                    ? Icons.cable_rounded
                    : Icons.api_rounded),
                title: Text(
                    '${p['name']}${p['version'] == null ? '' : '  v${p['version']}'}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
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
                      active['${p['category']}'] != p['name'])
                    TextButton(
                        onPressed: () => widget.onDirectAction(
                            'admin',
                            'plugins_set_active',
                            {'category': p['category'], 'plugin': p['name']}),
                        child: const Text('Make active')),
                  AdminStatusPill(
                      '${p['last_error'] == null ? p['state'] : 'error'}'),
                  OutlinedButton(
                    onPressed: () {
                      final loaded = const {'loaded', 'initialized', 'started'}
                          .contains('${p['state']}');
                      widget.onDirectAction(
                          'admin',
                          loaded ? 'plugins_unload' : 'plugins_load',
                          {'name': p['name']});
                    },
                    child: Text(const {'loaded', 'initialized', 'started'}
                            .contains('${p['state']}')
                        ? 'Unload'
                        : 'Load'),
                  ),
                ],
              ),
          ]),
        ),
        const SizedBox(height: 16),
      ],
      if (groups.isEmpty)
        const AdminEmptyState(
            'No plugins match', 'Try a different namespace or adapter name.'),
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _toolbar(
          Wrap(spacing: 8, runSpacing: 8, children: [
            _filterChip('All', 'all'),
            _filterChip('Info', 'log'),
            _filterChip('Warnings', 'warn'),
            _filterChip('Errors', 'error'),
          ]),
          [
            FilterChip(
              selected: live,
              label: Text(live ? 'Live' : 'Paused'),
              avatar: Icon(
                  live ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 17),
              onSelected: (value) => setState(() => live = value),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: dump));
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Filtered log copied')));
              },
              icon: const Icon(Icons.copy_rounded, size: 17),
              label: const Text('Copy'),
            ),
          ]),
      const SizedBox(height: 12),
      AdminSearchField(
          controller: search,
          hint: 'Filter by text…',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      AdminSectionCard(
        title:
            '${rows.length} lines${all.length >= 500 ? ' · showing latest' : ''}',
        padding: EdgeInsets.zero,
        child: Container(
          height: 520,
          color: const Color(0xFF07101C),
          child: rows.isEmpty
              ? const Center(
                  child: Text(
                      'No lines yet for this filter. Reproduce the problem, then refresh.',
                      style: TextStyle(color: AppColors.muted)))
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
                                ? AppColors.muted
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
            ? Padding(padding: const EdgeInsets.all(8), child: Text(empty))
            : Column(children: [
                for (final row in values)
                  _adaptiveTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const CircleAvatar(child: Icon(Icons.computer_rounded)),
                    title: Text(
                        '${_map(row['project'])['name'] ?? row['machine'] ?? row['name'] ?? 'Unknown machine'}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: SelectableText(
                        '${row['id']} · started ${_date(row['started_at'] ?? row['created_at'])}'),
                    actions: [
                      const AdminStatusPill('running'),
                      if (_map(row['project']).isNotEmpty)
                        TextButton(
                            onPressed: () => _showProject(_map(row['project'])),
                            child: const Text('Open project')),
                    ],
                  ),
              ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Running now',
            value: '${rows.length}',
            hint:
                'Every one is being billed by ${response['provider'] ?? 'the provider'}'),
        AdminStatCard(label: "Projects' computers", value: '${mine.length}'),
        AdminStatCard(
            label: 'Not used by a project',
            value: '${stray.length}',
            hint: stray.isEmpty
                ? 'None'
                : 'Running without a project: check these',
            tone: stray.isEmpty ? null : AppColors.warning),
      ]),
      if (stray.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'Not used by a project',
            subtitle:
                'These run at the provider but no project on this node uses them.',
            child: list(stray, 'None')),
      ],
      const SizedBox(height: 18),
      AdminSectionCard(
          title: "Projects' computers",
          child: list(mine, 'No project computer is running right now.')),
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
    Widget list(List<Map<String, dynamic>> values, String empty) =>
        values.isEmpty
            ? Padding(padding: const EdgeInsets.all(8), child: Text(empty))
            : Column(children: [
                for (final v in values)
                  _adaptiveTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const CircleAvatar(child: Icon(Icons.storage_outlined)),
                    title: Text(
                        '${_map(v['project'])['name'] ?? v['name'] ?? v['id']}',
                        style: const TextStyle(fontWeight: FontWeight.w800)),
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
      _statGrid([
        AdminStatCard(
            label: 'Volumes',
            value: '${all.length}',
            hint: '${response['provider'] ?? 'Provider'} storage'),
        AdminStatCard(
            label: "Holding a project's files",
            value: '${all.where((v) => _map(v['project']).isNotEmpty).length}'),
        AdminStatCard(
            label: 'With no project',
            value: '${all.where((v) => _map(v['project']).isEmpty).length}',
            hint: "Left from deleted projects, or not this node's"),
      ]),
      const SizedBox(height: 14),
      AdminSearchField(
          controller: search,
          hint: 'Search by project, volume name or id',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Projects (${used.length})',
          child: list(used, "No volume holds a project's files.")),
      if (unused.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'No project (${unused.length})',
            subtitle:
                'Nothing on this node uses these. Remove them at the provider only after checking they are not needed.',
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
    final settings = _map(widget.results['settings.get']);
    final enabled = _stringList(settings['categories']);
    const builtIn = [
      'productivity',
      'research',
      'coding',
      'writing',
      'design',
      'data',
      'business',
      'education',
      'finance',
      'legal',
      'marketing',
      'support',
    ];
    final all = <String>{...builtIn, ...enabled}.toList()..sort();
    final q = search.text.trim().toLowerCase();
    final rows = all.where((x) => q.isEmpty || x.contains(q)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: Text('${enabled.length} categories on', style: _muted())),
        FilledButton.tonalIcon(
          onPressed: () => _addCategory(enabled),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Add'),
        ),
      ]),
      const SizedBox(height: 12),
      AdminSearchField(
          controller: search,
          hint: 'Filter categories',
          onChanged: (_) => setState(() {})),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: 'No categories match.',
        columns: const [
          AdminTableColumn('Category', width: 250),
          AdminTableColumn('Kind', width: 150),
          AdminTableColumn('Status', width: 120),
          AdminTableColumn('Actions', width: 150, align: TextAlign.right),
        ],
        rows: [
          for (final id in rows)
            [
              Text(id, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(builtIn.contains(id) ? 'Built-in' : 'Custom'),
              AdminStatusPill(enabled.contains(id) ? 'active' : 'disabled'),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () {
                    final next = [...enabled];
                    if (enabled.contains(id)) {
                      next.remove(id);
                    } else {
                      next.add(id);
                    }
                    widget.onDirectAction(
                        'settings', 'update', {'categories': next});
                  },
                  child: Text(builtIn.contains(id)
                      ? (enabled.contains(id) ? 'Disable' : 'Enable')
                      : 'Remove'),
                ),
              ),
            ],
        ],
      ),
    ]);
  }

  Future<void> _addCategory(List<String> enabled) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add category'),
        content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Lowercase id; spaces become hyphens. Saved immediately.'),
              const SizedBox(height: 14),
              TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                      labelText: 'Category id', hintText: 'e.g. legal')),
            ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final id = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (id.isEmpty) return;
    await widget.onDirectAction('settings', 'update', {
      'categories': <String>{...enabled, id}.toList(),
    });
  }

  void _showProject(Map<String, dynamic> project) {
    final id = '${project['id'] ?? project['space_id'] ?? ''}';
    showDialog<void>(
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

  void _showUser(Map<String, dynamic> account) {
    showDialog<void>(
      context: context,
      builder: (context) => _UserDialog(
        account: account,
        onAction: widget.onAction,
        loadFinance: () => widget.onDirectAction('finance', 'admin_account', {
          'account': account['id'],
          'limit': 200,
        }),
      ),
    );
  }

  Widget _filterMenu(Map<String, String> entries) => DropdownButton<String>(
        value: entries.containsKey(filter) ? filter : entries.keys.first,
        items: [
          for (final e in entries.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value))
        ],
        onChanged: (value) =>
            setState(() => filter = value ?? entries.keys.first),
      );

  Widget _filterChip(String label, String value, {int? count}) => FilterChip(
        selected: filter == value,
        label: Text(count != null && count > 0 ? '$label  $count' : label),
        onSelected: (_) => setState(() => filter = value),
      );

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
    final active = setting['active'] == true;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(children: [
        Icon(active ? Icons.check_circle_rounded : Icons.info_outline_rounded,
            color: active ? AppColors.success : AppColors.muted),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              active
                  ? 'In effect'
                  : (setting['chat_active'] == true ||
                          setting['embedding_active'] == true)
                      ? 'Partly in effect'
                      : 'Not in effect',
              style: const TextStyle(fontWeight: FontWeight.w900)),
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

  /// Dropdown items for [options], plus one for [value] when the node no
  /// longer offers it (a disabled provider, a removed model): a dropdown whose
  /// value has no matching item fails to build.
  List<DropdownMenuItem<String>> _optionItems(
          List<Map<String, dynamic>> options, String value) =>
      [
        for (final o in options)
          DropdownMenuItem(
              value: '${o['id']}',
              child: Text('${o['name'] ?? o['id']}',
                  overflow: TextOverflow.ellipsis)),
        if (value.isNotEmpty && !options.any((o) => '${o['id']}' == value))
          DropdownMenuItem(
              value: value,
              child: Text('$value (unavailable)',
                  overflow: TextOverflow.ellipsis)),
      ];

  List<Map<String, dynamic>> _decisionModels(
      List<Map<String, dynamic>> providers, String providerId) {
    final provider = providers
        .cast<Map<String, dynamic>?>()
        .firstWhere((p) => '${p?['id']}' == providerId, orElse: () => null);
    return _listOfMaps(provider?['decision_models'] ?? provider?['models']);
  }

  TextStyle _eyebrow() => TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 11,
      fontWeight: FontWeight.w900,
      letterSpacing: .8);
  TextStyle _muted() => TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
      height: 1.35);
}

class _FinanceBars extends StatelessWidget {
  const _FinanceBars({required this.items, required this.total});
  final List<({String label, double value, Color color})> items;
  final double total;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                SizedBox(
                    width: 82,
                    child:
                        Text(item.label, style: const TextStyle(fontSize: 11))),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: LinearProgressIndicator(
                      minHeight: 18,
                      value: total <= 0 ? 0 : item.value / total,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation(item.color),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                    width: 42,
                    child: Text(
                        total <= 0
                            ? '0%'
                            : '${(item.value / total * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w800))),
              ]),
            ),
        ],
      );
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
  late final String previousId;
  late final TextEditingController id;
  late final TextEditingController name;
  late final TextEditingController input;
  late final TextEditingController output;
  bool saving = false;

  bool get editing => widget.model != null;

  @override
  void initState() {
    super.initState();
    final model = widget.model ?? const <String, dynamic>{};
    providerId = '${widget.provider['id']}';
    previousId = '${model['id'] ?? ''}';
    id = TextEditingController(text: previousId);
    name = TextEditingController(text: '${model['name'] ?? ''}');
    input = TextEditingController(
        text: ledgerUsdField(_number(model['input_price'])));
    output = TextEditingController(
        text: ledgerUsdField(_number(model['output_price'])));
    purpose = _modelPurpose(model).toLowerCase();
  }

  @override
  void dispose() {
    id.dispose();
    name.dispose();
    input.dispose();
    output.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final modelId = id.text.trim();
    final inputUnits = parseUsdToLedger(input.text);
    final outputUnits = parseUsdToLedger(output.text);
    if (modelId.isEmpty || inputUnits == null || outputUnits == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Enter the provider model id and valid dollar prices (up to six decimals).')));
      return;
    }
    final provider = widget.providers.firstWhere(
        (p) => '${p['id']}' == providerId,
        orElse: () => widget.provider);
    final models = _listOfMaps(provider['models']);
    if (models
        .any((m) => '${m['id']}' == modelId && '${m['id']}' != previousId)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$modelId is already listed.')));
      return;
    }
    final next = <String, dynamic>{
      'id': modelId,
      if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
      'input_price': inputUnits,
      'output_price': outputUnits,
      'capabilities': [purpose],
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
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save model: $error')));
      setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650, maxHeight: 720),
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
              const Text('WHAT THIS MODEL IS FOR',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1)),
              const SizedBox(height: 8),
              // Three long labels do not fit side by side on a phone.
              SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'chat', label: Text('Agent model')),
                      ButtonSegment(
                          value: 'decision', label: Text('Decision model')),
                      ButtonSegment(
                          value: 'embedding', label: Text('Embedding model')),
                    ],
                    selected: {purpose},
                    onSelectionChanged: (value) =>
                        setState(() => purpose = value.first),
                  )),
              const SizedBox(height: 8),
              Text(
                  purpose == 'chat'
                      ? 'Agents can use this as their main reasoning model.'
                      : purpose == 'decision'
                          ? 'Used for tool selection, routing, progress, and completion checks. Agents cannot use it as their main model.'
                          : 'Turns memories into vectors for semantic recall. Agents cannot use it as their main model.',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: input,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: 'Input \$/1M tokens',
                            hintText: '2.50',
                            border: OutlineInputBorder()))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextField(
                        controller: output,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        decoration: const InputDecoration(
                            labelText: 'Output \$/1M tokens',
                            hintText: '10.00',
                            border: OutlineInputBorder()))),
              ]),
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
  late final Map<String, TextEditingController> fields;
  bool advanced = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    final p = _map(widget.settings['pricing']);
    final sandbox = _map(p['sandbox']);
    final tool = _map(p['tool']);
    fields = {
      'agent_per_minute':
          _controller(ledgerUsdField(_number(p['agent_per_minute']))),
      'sandbox.per_minute':
          _controller(ledgerUsdField(_number(sandbox['per_minute']))),
      'tool.per_minute':
          _controller(ledgerUsdField(_number(tool['per_minute']))),
      'sandbox.cpu_per_min':
          _controller(ledgerCreditsField(_number(sandbox['cpu_per_min']))),
      'sandbox.memory_per_gb_min': _controller(
          ledgerCreditsField(_number(sandbox['memory_per_gb_min']))),
      'sandbox.disk_per_gb_min':
          _controller(ledgerCreditsField(_number(sandbox['disk_per_gb_min']))),
      'tool.cpu_per_min':
          _controller(ledgerCreditsField(_number(tool['cpu_per_min']))),
      'tool.memory_per_gb_min':
          _controller(ledgerCreditsField(_number(tool['memory_per_gb_min']))),
      'tool.disk_per_gb_min':
          _controller(ledgerCreditsField(_number(tool['disk_per_gb_min']))),
    };
    advanced = fields.entries
        .where((e) => e.key.contains('.') && !e.key.endsWith('per_minute'))
        .any((e) => _parse(e.value.text) > 0);
  }

  @override
  void dispose() {
    for (final field in fields.values) field.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final agent = parseUsdToLedger(fields['agent_per_minute']!.text);
    final computer = parseUsdToLedger(fields['sandbox.per_minute']!.text);
    final tool = parseUsdToLedger(fields['tool.per_minute']!.text);
    final resources = <String, int?>{
      for (final key in fields.keys
          .where((key) => key.contains('.') && !key.endsWith('.per_minute')))
        key: parseCreditsToLedger(fields[key]!.text),
    };
    if (agent == null ||
        computer == null ||
        tool == null ||
        resources.values.any((value) => value == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter valid non-negative rates.')));
      return;
    }
    setState(() => busy = true);
    try {
      await widget.onSave({
        'agent_per_minute': agent,
        'sandbox': {
          'per_minute': computer,
          'cpu_per_min': resources['sandbox.cpu_per_min'],
          'memory_per_gb_min': resources['sandbox.memory_per_gb_min'],
          'disk_per_gb_min': resources['sandbox.disk_per_gb_min'],
        },
        'tool': {
          'per_minute': tool,
          'cpu_per_min': resources['tool.cpu_per_min'],
          'memory_per_gb_min': resources['tool.memory_per_gb_min'],
          'disk_per_gb_min': resources['tool.disk_per_gb_min'],
        },
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget input(String key, String label, String hint,
          {String suffix = '\$ / min'}) =>
      TextField(
        controller: fields[key],
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
            labelText: label, hintText: hint, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(
                    'What users pay per minute. Credits are shown to users at 100 per \$1.',
                    style: TextStyle(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant))),
            FilledButton.icon(
                onPressed: busy ? null : save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(busy ? 'Saving…' : 'Save')),
          ]),
          const SizedBox(height: 18),
          AdminSectionCard(
              title: 'Base rates',
              child: Column(children: [
                input('agent_per_minute', 'Agent time', '0.06'),
                const SizedBox(height: 14),
                input('sandbox.per_minute', 'Project computer', '0.12'),
                const SizedBox(height: 14),
                input('tool.per_minute', 'Tools & miniapps', '0.02'),
              ])),
          const SizedBox(height: 16),
          AdminSectionCard(
              title: 'Model tokens',
              subtitle: 'Input and output prices are set per model.',
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                      onPressed: widget.onModels,
                      child: const Text('Edit model prices')))),
          const SizedBox(height: 16),
          TextButton.icon(
              onPressed: () => setState(() => advanced = !advanced),
              icon: Icon(advanced ? Icons.expand_less : Icons.expand_more),
              label: Text(
                  '${advanced ? 'Hide' : 'Show'} per-resource rates (advanced)')),
          if (advanced) ...[
            const SizedBox(height: 10),
            AdminSectionCard(
              title: 'Per-resource rates',
              subtitle:
                  'Extra credits per minute for each vCPU, GB of RAM and GB of disk. Leave at 0 for flat pricing.',
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Project computer',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    input('sandbox.cpu_per_min', 'vCPU', '0',
                        suffix: 'credits / vCPU / min'),
                    const SizedBox(height: 10),
                    input('sandbox.memory_per_gb_min', 'RAM GB', '0',
                        suffix: 'credits / GB / min'),
                    const SizedBox(height: 10),
                    input('sandbox.disk_per_gb_min', 'Disk GB', '0',
                        suffix: 'credits / GB / min'),
                    const SizedBox(height: 18),
                    const Text('Tools & miniapps',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    input('tool.cpu_per_min', 'vCPU', '0',
                        suffix: 'credits / vCPU / min'),
                    const SizedBox(height: 10),
                    input('tool.memory_per_gb_min', 'RAM GB', '0',
                        suffix: 'credits / GB / min'),
                    const SizedBox(height: 10),
                    input('tool.disk_per_gb_min', 'Disk GB', '0',
                        suffix: 'credits / GB / min'),
                  ]),
            ),
          ],
        ]),
      );
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
  late final Map<String, TextEditingController> fields;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    final m = _map(widget.settings['machine']);
    fields = {
      'cpu': _controller(m['cpu']),
      'memory_mb': _controller(_number(m['memory_mb']) / 1024),
      'disk_mb': _controller(_number(m['disk_mb']) / 1024),
      'reserve_cpu': _controller(m['reserve_cpu']),
      'reserve_memory_mb': _controller(m['reserve_memory_mb'] == null
          ? ''
          : _number(m['reserve_memory_mb']) / 1024),
      'max_cpu': _controller(m['max_cpu']),
      'max_memory_mb': _controller(
          m['max_memory_mb'] == null ? '' : _number(m['max_memory_mb']) / 1024),
    };
  }

  @override
  void dispose() {
    for (final f in fields.values) f.dispose();
    super.dispose();
  }

  Widget field(String key, String label, String hint, {String? suffix}) =>
      TextField(
          controller: fields[key],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
              labelText: label, hintText: hint, suffixText: suffix));
  Future<void> save() async {
    setState(() => busy = true);
    try {
      double? optional(String key, {double factor = 1}) =>
          fields[key]!.text.trim().isEmpty
              ? null
              : _parse(fields[key]!.text) * factor;
      await widget.onSave({
        'cpu': _parse(fields['cpu']!.text),
        'memory_mb': (_parse(fields['memory_mb']!.text) * 1024).round(),
        'disk_mb': (_parse(fields['disk_mb']!.text) * 1024).round(),
        'reserve_cpu': optional('reserve_cpu'),
        'reserve_memory_mb':
            optional('reserve_memory_mb', factor: 1024)?.round(),
        'max_cpu': optional('max_cpu'),
        'max_memory_mb': optional('max_memory_mb', factor: 1024)?.round(),
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                  onPressed: busy ? null : save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(busy ? 'Saving…' : 'Save'))),
          const SizedBox(height: 14),
          AdminSectionCard(
              title: 'Billed size',
              subtitle:
                  "What a project's computer is sold at and created with.",
              child: Row(children: [
                Expanded(child: field('cpu', 'vCPU', '2')),
                const SizedBox(width: 12),
                Expanded(child: field('memory_mb', 'RAM', '2', suffix: 'GB')),
                const SizedBox(width: 12),
                Expanded(child: field('disk_mb', 'Disk', '4', suffix: 'GB'))
              ])),
          const SizedBox(height: 16),
          AdminSectionCard(
              title: 'Idle reserve',
              subtitle:
                  'The share guaranteed and billed while a computer is awake and quiet. Blank uses automatic defaults.',
              child: Row(children: [
                Expanded(child: field('reserve_cpu', 'vCPU', 'auto')),
                const SizedBox(width: 12),
                Expanded(
                    child:
                        field('reserve_memory_mb', 'RAM', 'auto', suffix: 'GB'))
              ])),
          const SizedBox(height: 16),
          AdminSectionCard(
              title: 'Ceiling',
              subtitle:
                  'The most a busy computer can use. Blank uses automatic defaults.',
              child: Row(children: [
                Expanded(child: field('max_cpu', 'vCPU', 'auto')),
                const SizedBox(width: 12),
                Expanded(
                    child: field('max_memory_mb', 'RAM', 'auto', suffix: 'GB'))
              ])),
        ]),
      );
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

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(
                  'Keep it short — every turn pays for these tokens. Blank means none.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          FilledButton.icon(
              onPressed: busy || controller.text.trim().length > 20000
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await widget.onSave(controller.text);
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(busy ? 'Saving…' : 'Save')),
        ]),
        const SizedBox(height: 16),
        TextField(
            controller: controller,
            minLines: 10,
            maxLines: 24,
            decoration: InputDecoration(
                labelText:
                    'Platform rules · ${controller.text.trim().length}/20000',
                hintText:
                    "Always answer in the user's language. Never invent delivery dates.",
                alignLabelWithHint: true,
                border: const OutlineInputBorder())),
      ]);
}

class _UserDialog extends StatefulWidget {
  const _UserDialog(
      {required this.account,
      required this.onAction,
      required this.loadFinance});
  final Map<String, dynamic> account;
  final AdminAction onAction;
  final Future<dynamic> Function() loadFinance;
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  int tab = 0;
  bool loading = true;
  Map<String, dynamic> finance = const {};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      finance = _map(await widget.loadFinance());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const tabs = ['Summary', 'Purchases', 'Wallet', 'Profile & access'];
    final a = widget.account;
    return Dialog.fullscreen(
        child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded)),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_displayName(a),
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
          Text('@${a['handle']} · ${a['email'] ?? ''}',
              style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.onSurfaceVariant))
        ]),
        actions: [
          IconButton(onPressed: load, icon: const Icon(Icons.refresh_rounded)),
          PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'delete')
                  widget.onAction(
                      'users', 'account_delete', {'account': a['id']});
              },
              itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete user'))
                  ])
        ],
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (var i = 0; i < tabs.length; i++)
                    ButtonSegment(value: i, label: Text(tabs[i]))
                ],
                selected: {tab},
                onSelectionChanged: (value) =>
                    setState(() => tab = value.first))),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(24), children: [_content()]),
    ));
  }

  Widget _content() => switch (tab) {
        0 => _summary(),
        1 => _purchases(),
        2 => _wallet(),
        _ => _profile()
      };
  Widget _summary() {
    final m = _map(finance['summary']).isNotEmpty
        ? _map(finance['summary'])
        : finance;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Balance',
            value: _money(m['balance']),
            hint:
                '${_credits(m['balance'])}${_number(m['locked']) > 0 ? ' · ${_credits(m['locked'])} locked' : ''}'),
        AdminStatCard(
            label: 'Bought',
            value: _money(m['bought']),
            hint: '${m['bought_count'] ?? 0} packs · ${_credits(m['bought'])}'),
        AdminStatCard(
            label: 'Added by admin',
            value: _money(m['granted']),
            hint: _credits(m['granted'])),
        AdminStatCard(
            label: 'Spent',
            value: _money(m['spent']),
            hint: _credits(m['spent'])),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'What was spent on',
          child: Column(children: [
            for (final row in _listOfMaps(m['by_kind'] ?? finance['by_kind']))
              AdminKeyValue('${row['kind'] ?? row['label']}',
                  _money(row['amount'] ?? row['spent']))
          ])),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Spent per project',
          child: Column(children: [
            for (final row in _listOfMaps(m['projects'] ?? finance['projects']))
              AdminKeyValue(
                  '${row['name'] ?? row['space_name'] ?? row['space_id']}',
                  _money(row['spent']))
          ])),
    ]);
  }

  Widget _purchases() {
    final rows = _listOfMaps(finance['purchases']);
    return AdminDataTable(empty: 'No purchases for this user.', columns: const [
      AdminTableColumn('Purchased', width: 180),
      AdminTableColumn('Product', width: 220),
      AdminTableColumn('Amount', width: 130, align: TextAlign.right),
      AdminTableColumn('Status', width: 130),
      AdminTableColumn('Transaction', width: 260)
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
      AdminTableColumn('When', width: 180),
      AdminTableColumn('Description', width: 320),
      AdminTableColumn('Kind', width: 140),
      AdminTableColumn('Amount', width: 130, align: TextAlign.right),
      AdminTableColumn('Balance', width: 130, align: TextAlign.right)
    ], rows: [
      for (final e in rows)
        [
          Text(_date(e['created_at'])),
          Text('${e['description'] ?? e['reason'] ?? e['kind']}'),
          Text('${e['kind'] ?? e['type']}'),
          Text(_credits(e['amount']), textAlign: TextAlign.right),
          Text(_credits(e['balance']), textAlign: TextAlign.right)
        ]
    ]);
  }

  Widget _profile() {
    final a = widget.account;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Profile',
          child: Column(children: [
            AdminKeyValue('Name', _displayName(a)),
            AdminKeyValue('Username', '@${a['handle']}'),
            AdminKeyValue('Email', '${a['email'] ?? '—'}'),
            AdminKeyValue('Role',
                '${a['role'] ?? (a['is_admin'] == true ? 'admin' : 'user')}'),
            AdminKeyValue('Status', '${a['status'] ?? 'active'}'),
            const SizedBox(height: 8),
            Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                    onPressed: () =>
                        widget.onAction('users', 'account_update', {
                          'account': a['id'],
                          'handle': a['handle'],
                          'email': a['email'],
                          'role': a['role'],
                          'status': a['status'],
                          'profile': a['profile'] ?? <String, dynamic>{}
                        }),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit profile')))
          ])),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Access',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(
                onPressed: () => widget.onAction('users', 'account_update', {
                      'account': a['id'],
                      'status':
                          '${a['status']}' == 'disabled' ? 'active' : 'disabled'
                    }),
                child: Text('${a['status']}' == 'disabled'
                    ? 'Enable user'
                    : 'Disable user')),
            OutlinedButton(
                onPressed: () => widget.onAction(
                    'users', 'account_password', {'account': a['id']}),
                child: const Text('Set new password'))
          ])),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Grant credits',
          child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  onPressed: () => widget
                      .onAction('finance', 'wallet_mint', {'target': a['id']}),
                  icon: const Icon(Icons.add_card_rounded),
                  label: const Text('Grant credits')))),
    ]);
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
  List<Map<String, dynamic>> work = const [];
  List<Map<String, dynamic>> files = const [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final value = await widget.loadDetail();
      detail = {...widget.project, ..._map(value)};
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadTab(int value) async {
    setState(() => tab = value);
    if (value == 4 && work.isEmpty) {
      final value = await widget.loadWork();
      if (mounted)
        setState(() => work = _listOfMaps(_map(value)['logs'] ??
            _map(value)['work'] ??
            _map(value)['events']));
    }
    if (value == 3 && files.isEmpty) {
      final value = await widget.loadFiles();
      if (mounted) setState(() => files = _listOfMaps(_map(value)['files']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = '${detail['id'] ?? widget.project['id']}';
    final tabs = const [
      'Overview',
      'Machine',
      'Cost',
      'Storage',
      'Logs',
      'People'
    ];
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded)),
          title:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${detail['name'] ?? widget.project['name'] ?? 'Project'}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            Text(id,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                onPressed: load,
                icon: const Icon(Icons.refresh_rounded)),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'budget')
                  widget.onAction('finance', 'budget_set', {'space': id});
                if (value == 'delete')
                  widget.onAction('spaces', 'space_delete', {'space': id});
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'budget', child: Text('Set budget')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'delete', child: Text('Delete project')),
              ],
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (var i = 0; i < tabs.length; i++)
                    ButtonSegment(value: i, label: Text(tabs[i]))
                ],
                selected: {tab},
                onSelectionChanged: (value) => loadTab(value.first),
              ),
            ),
          ),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(24), children: [_tab(id)]),
      ),
    );
  }

  Widget _tab(String id) => switch (tab) {
        0 => _overview(),
        1 => _machine(id),
        2 => _cost(id),
        3 => _files(),
        4 => _work(),
        _ => _people(),
      };
  Widget _overview() {
    final machine = _map(detail['machine']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _statGrid([
        AdminStatCard(
            label: 'Machine',
            value: '${machine['state'] ?? 'none'}',
            hint: '${machine['provider'] ?? ''}',
            icon: Icons.computer_outlined),
        AdminStatCard(
            label: 'Agents',
            value: '${detail['agents'] ?? _list(detail['workers']).length}',
            icon: Icons.smart_toy_outlined),
        AdminStatCard(
            label: 'Rooms',
            value: '${_list(detail['rooms']).length}',
            icon: Icons.forum_outlined),
        AdminStatCard(
            label: 'Budget',
            value: _credits(_map(detail['budget'])['cap'] ?? detail['budget']),
            icon: Icons.account_balance_wallet_outlined),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Project',
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
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Computer',
          child: Column(children: [
            AdminKeyValue('State', '${machine['state'] ?? 'none'}'),
            AdminKeyValue('Provider id',
                '${machine['id'] ?? machine['sandbox_id'] ?? ''}',
                mono: true),
            AdminKeyValue('Started', _date(machine['started_at'])),
            AdminKeyValue('Last active', _date(machine['last_active_at'])),
          ])),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final op in const [
          'status',
          'provision',
          'keepalive',
          'sleep',
          'replace'
        ])
          OutlinedButton(
              onPressed: () => widget.onAction(
                  'spaces', 'computer', {'space': id, 'operation': op}),
              child: Text(op[0].toUpperCase() + op.substring(1))),
      ]),
    ]);
  }

  Widget _cost(String id) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AdminSectionCard(
            title: 'Budget and spend',
            child: Column(children: [
              AdminKeyValue('Budget cap',
                  _credits(_map(detail['budget'])['cap'] ?? detail['budget'])),
              AdminKeyValue('Spent',
                  _credits(detail['spent'] ?? _map(detail['usage'])['spent'])),
              AdminKeyValue(
                  'Remaining', _credits(_map(detail['budget'])['remaining'])),
            ])),
        const SizedBox(height: 14),
        FilledButton.icon(
            onPressed: () =>
                widget.onAction('finance', 'budget_set', {'space': id}),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Set budget')),
      ]);
  Widget _files() => AdminDataTable(
        empty: 'No project files.',
        columns: const [
          AdminTableColumn('Path', width: 420),
          AdminTableColumn('Size', width: 120, align: TextAlign.right),
          AdminTableColumn('Modified', width: 180)
        ],
        rows: [
          for (final f in files)
            [
              Text('${f['path'] ?? f['name']}'),
              Text(_bytes(f['size']), textAlign: TextAlign.right),
              Text(_date(f['modified_at'] ?? f['updated_at']))
            ]
        ],
      );
  Widget _work() => AdminDataTable(
        empty: 'No work log entries.',
        columns: const [
          AdminTableColumn('Time', width: 170),
          AdminTableColumn('Agent', width: 170),
          AdminTableColumn('Event', width: 220),
          AdminTableColumn('Detail', width: 400)
        ],
        rows: [
          for (final e in work)
            [
              Text(_date(e['created_at'] ?? e['time'])),
              Text('${e['bot_name'] ?? e['agent'] ?? '—'}'),
              Text('${e['kind'] ?? e['event'] ?? e['status'] ?? '—'}'),
              Text('${e['message'] ?? e['detail'] ?? e['prompt'] ?? ''}')
            ]
        ],
      );
  Widget _people() {
    final people = [..._listOfMaps(detail['members'])];
    if (_map(detail['owner']).isNotEmpty)
      people.insert(0, {..._map(detail['owner']), 'role': 'owner'});
    return AdminDataTable(
      empty: 'No people attached to this project.',
      columns: const [
        AdminTableColumn('Person', width: 260),
        AdminTableColumn('Role', width: 150),
        AdminTableColumn('Joined', width: 180)
      ],
      rows: [
        for (final p in people)
          [
            _primaryCell(
                _displayName(p), '@${p['handle'] ?? _shortId(p['id'])}'),
            Text('${p['role'] ?? 'member'}'),
            Text(_date(p['created_at'] ?? p['joined_at']))
          ]
      ],
    );
  }
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
String _jsonSummary(dynamic value) {
  if (value == null) return '—';
  if (value is String) return value;
  return const JsonEncoder.withIndent('  ').convert(value);
}

String _modelPurpose(Map<String, dynamic> model) {
  final capabilities = _stringList(model['capabilities']);
  if (capabilities.any((c) => c.contains('embedding'))) return 'Embedding';
  if (capabilities.any((c) => c.contains('decision'))) return 'Decision';
  return 'Agent';
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

/// Stat cards laid out four, two or one per row depending on the width.
Widget _statGrid(List<Widget> cards) =>
    LayoutBuilder(builder: (context, constraints) {
      final count = math.min(
          cards.length,
          constraints.maxWidth >= 900
              ? 4
              : constraints.maxWidth >= 540
                  ? 2
                  : 1);
      final width = (constraints.maxWidth - 12 * (count - 1)) / count;
      return Wrap(spacing: 12, runSpacing: 12, children: [
        for (final card in cards) SizedBox(width: width, child: card)
      ]);
    });

Widget _primaryCell(String primary, String secondary) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(primary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800)),
          if (secondary.isNotEmpty)
            Text(secondary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: AppColors.muted))
        ]);
TextEditingController _controller(dynamic value) => TextEditingController(
    text: value == null || '$value'.isEmpty
        ? ''
        : value is num
            ? value.toString()
            : '$value');
double _parse(String value) => double.tryParse(value.trim()) ?? 0;
