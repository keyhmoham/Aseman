import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/backend_action_ui.dart';
import '../../../shared/widgets/panel_header.dart';
import 'admin_page_content.dart';
import 'llm_providers_tab.dart';

typedef JsonMap = Map<String, dynamic>;

class _Call {
  const _Call(this.namespace, this.action, [this.body = const {}]);
  final String namespace;
  final String action;
  final JsonMap body;
  String get label => '$namespace.$action';
}

class _Page {
  const _Page(this.label, this.hint, this.icon,
      {this.calls = const [], this.actions = const [], this.providers = false});
  final String label;
  final String hint;
  final IconData icon;
  final List<_Call> calls;
  final List<_Call> actions;
  final bool providers;
}

class _Section {
  const _Section(this.label, this.pages);
  final String label;
  final List<_Page> pages;
}

/// Complete platform administration console. Its hierarchy mirrors the web
/// console and every card talks to the backend action used by that page.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  static const sections = <_Section>[
    _Section('Operate', [
      _Page('Overview', 'What needs attention', Icons.dashboard_outlined,
          calls: [
            _Call('admin', 'stats'),
            _Call('admin', 'health'),
            _Call('admin', 'runs_list'),
            _Call('admin', 'node_stats'),
            _Call('finance', 'payouts_list'),
            _Call('market', 'catalog', {'status': 'all'}),
          ]),
      _Page('Users', 'Accounts, wallets and roles', Icons.people_outline,
          calls: [
            _Call('users', 'accounts_list'),
            _Call('admin', 'admins_list')
          ],
          actions: [
            _Call('users', 'account_update'),
            _Call('users', 'account_password'),
            _Call('users', 'account_delete'),
            _Call('finance', 'wallet_mint'),
            _Call('finance', 'admin_account'),
          ]),
      _Page('Projects', 'Workspaces, machines and spend', Icons.folder_outlined,
          calls: [
            _Call('spaces', 'space_list_all')
          ],
          actions: [
            _Call('spaces', 'space_detail', {'admin': true}),
            _Call('spaces', 'admin_work_log'),
            _Call('spaces', 'admin_files'),
            _Call('spaces', 'space_delete'),
            _Call('finance', 'budget_set'),
          ]),
    ]),
    _Section('Catalog', [
      _Page('Agents', 'Create, price and approve agents',
          Icons.smart_toy_outlined,
          calls: [
            _Call('admin', 'bots_list'),
            _Call('bots', 'agent_samples'),
            _Call('market', 'catalog', {'status': 'all'}),
            _Call('market', 'stats'),
          ],
          actions: [
            _Call('bots', 'agent_import_samples'),
            _Call('bots', 'bot_create'),
            _Call('bots', 'bot_edit'),
            _Call('bots', 'bot_delete'),
            _Call('market', 'publish'),
            _Call('market', 'approve'),
            _Call('market', 'deny'),
            _Call('market', 'unpublish'),
          ]),
      _Page('Tools', 'Tools, miniapps and what they cost', Icons.build_outlined,
          calls: [
            _Call('admin', 'bots_list'),
            _Call('tools', 'mcp_samples'),
            _Call('market', 'catalog', {'status': 'all'}),
          ],
          actions: [
            _Call('tools', 'mcp_import_samples'),
            _Call('tools', 'mcp_register'),
            _Call('tools', 'mcp_update'),
            _Call('tools', 'mcp_delete'),
            _Call('tools', 'mcp_oauth_set'),
            _Call('market', 'publish'),
            _Call('market', 'unpublish'),
          ]),
      _Page('Talent', 'People listed for hire', Icons.badge_outlined, calls: [
        _Call('users', 'accounts_list'),
        _Call('talent', 'list_mine')
      ], actions: [
        _Call('users', 'account_update'),
      ]),
    ]),
    _Section('Money', [
      _Page('Finance · Overview', 'Revenue, costs and reconciliation',
          Icons.account_balance_wallet_outlined,
          calls: [
            _Call('finance', 'overview'),
            _Call('finance', 'costs'),
            _Call('finance', 'provider_costs'),
            _Call('finance', 'reconcile'),
          ]),
      _Page('Finance · Purchases', 'Store transactions and environments',
          Icons.receipt_long_outlined,
          calls: [_Call('finance', 'purchases_list')],
          actions: [_Call('finance', 'purchases_label')]),
      _Page('Finance · Payouts', 'Review and resolve payout requests',
          Icons.payments_outlined,
          calls: [_Call('finance', 'payouts_list')],
          actions: [_Call('finance', 'payout_resolve')]),
    ]),
    _Section('AI', [
      _Page('Providers', 'Endpoints and API keys', Icons.key_outlined,
          providers: true),
      _Page('Models', 'Model list and token prices', Icons.memory_outlined,
          calls: [_Call('llm', 'llm_providers_list')],
          actions: [_Call('llm', 'llm_provider_set')]),
      _Page('Decision model', 'Tool selection and work decisions',
          Icons.alt_route_outlined,
          calls: [_Call('llm', 'llm_decision_get')],
          actions: [_Call('llm', 'llm_decision_set')]),
      _Page('Memory models', 'Learning and semantic recall',
          Icons.psychology_outlined,
          calls: [_Call('llm', 'llm_memory_get')],
          actions: [_Call('llm', 'llm_memory_set')]),
    ]),
    _Section('System', [
      _Page('Health', 'Deployment checklist', Icons.monitor_heart_outlined,
          calls: [_Call('admin', 'health'), _Call('admin', 'plugins_health')]),
      _Page('Node · Host', 'Host, mesh and live telemetry', Icons.dns_outlined,
          calls: [
            _Call('admin', 'node_stats'),
            _Call('admin', 'telemetry'),
            _Call('federation', 'node_info'),
            _Call('federation', 'nodes_list'),
          ]),
      _Page('Node · Plugins', 'Runtime plugins and active adapters',
          Icons.extension_outlined,
          calls: [
            _Call('admin', 'plugins_list'),
            _Call('admin', 'plugins_health'),
            _Call('admin', 'wiring'),
          ],
          actions: [
            _Call('admin', 'plugins_load'),
            _Call('admin', 'plugins_unload'),
            _Call('admin', 'plugins_stop'),
            _Call('admin', 'plugins_set_active'),
          ]),
      _Page('Node · Logs', 'Server event stream', Icons.article_outlined,
          calls: [
            _Call('admin', 'logs', {'limit': 500})
          ]),
      _Page('Sandboxes', 'Machines running at the provider',
          Icons.computer_outlined,
          calls: [_Call('spaces', 'admin_sandboxes')]),
      _Page('Storage', 'Volumes and project files', Icons.storage_outlined,
          calls: [_Call('spaces', 'admin_storage')]),
      _Page('Settings · Pricing', 'Runtime and resource rates',
          Icons.sell_outlined,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'pricing': <String, dynamic>{}})
          ]),
      _Page('Settings · Machine', 'Computer size, reserve and ceiling',
          Icons.developer_board_outlined,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'machine': <String, dynamic>{}})
          ]),
      _Page('Settings · Agent instructions', 'Universal system instructions',
          Icons.description_outlined,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'universal_system_prompt': ''})
          ]),
      _Page('Settings · Categories', 'Marketplace categories',
          Icons.category_outlined,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'categories': <String>[]})
          ]),
    ]),
  ];

  int section = 0;
  int page = 0;
  bool loading = false;
  Map<String, dynamic> results = const {};

  /// Bumped whenever the visible page changes so responses that arrive for a
  /// page the admin already left are dropped.
  int _generation = 0;
  Future<void>? _refreshing;

  _Page get current => sections[section].pages[page];

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Loads the current page from scratch. The spinner is only shown here,
  /// when there is nothing on screen yet.
  Future<void> load() async {
    final selected = current;
    final generation = ++_generation;
    _refreshing = null;
    if (selected.providers) return;
    setState(() {
      loading = true;
      results = const {};
    });
    await _fetch(selected, generation, keepOnError: false);
    if (!mounted || generation != _generation) return;
    setState(() => loading = false);
  }

  /// Refreshes the current page in place. Data already on screen stays
  /// visible and every call updates only its own panel when it returns, so
  /// live pages never fall back to the loading state. Overlapping requests
  /// (timer ticks, pull to refresh, the refresh button) share one round trip;
  /// [afterChange] waits for one already in flight and fetches again so the
  /// result of a mutation is never missed.
  Future<void> refresh({bool background = false, bool afterChange = false}) {
    if (current.providers) return Future.value();
    if (loading) return Future.value();
    final pending = _refreshing;
    if (pending != null) {
      return afterChange ? pending.then((_) => refresh()) : pending;
    }
    late final Future<void> next;
    next =
        _fetch(current, _generation, keepOnError: background).whenComplete(() {
      if (identical(_refreshing, next)) _refreshing = null;
    });
    return _refreshing = next;
  }

  Future<void> _fetch(_Page selected, int generation,
      {required bool keepOnError}) async {
    await Future.wait(selected.calls.map((call) async {
      dynamic value;
      try {
        value = await widget.dependencies.service.invokeAction(
          call.namespace,
          call.action,
          body: call.body,
          timeout: const Duration(minutes: 3),
        );
      } catch (error) {
        // A missed background tick keeps the last good data instead of
        // replacing a working panel with an error.
        final previous = results[call.label];
        if (keepOnError && previous != null && !_isError(previous)) return;
        value = {'error': '$error'};
      }
      if (!mounted || generation != _generation) return;
      // Unchanged responses leave the panel untouched.
      if (results.containsKey(call.label) &&
          _jsonEquals(results[call.label], value)) {
        return;
      }
      setState(() => results = {...results, call.label: value});
    }));
  }

  static bool _isError(dynamic value) =>
      value is Map && value.containsKey('error');

  static bool _jsonEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_jsonEquals(a[key], b[key])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_jsonEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  void select(int nextSection, int nextPage) {
    setState(() {
      section = nextSection;
      page = nextPage;
    });
    load();
  }

  Future<void> runAction(_Call call) async {
    final body = await showBackendActionForm(
      context,
      namespace: call.namespace,
      action: call.action,
      initialBody: call.body,
    );
    if (body == null || !mounted) return;
    try {
      final value = await widget.dependencies.service.invokeAction(
          call.namespace, call.action,
          body: body, timeout: const Duration(minutes: 10));
      if (!mounted) return;
      setState(() => results = {...results, call.label: value});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${call.label} completed')));
      await refresh(afterChange: true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${call.label}: $error')));
    }
  }

  Future<dynamic> runDirectAction(
      String namespace, String action, JsonMap body) async {
    try {
      final value = await widget.dependencies.service.invokeAction(
          namespace, action,
          body: body, timeout: const Duration(minutes: 10));
      if (!mounted) return value;
      const mutations = {
        'account_update',
        'account_password',
        'account_delete',
        'wallet_mint',
        'budget_set',
        'purchases_label',
        'payout_resolve',
        'approve',
        'deny',
        'publish',
        'unpublish',
        'respond',
        'llm_provider_set',
        'llm_decision_set',
        'llm_memory_set',
        'plugins_load',
        'plugins_unload',
        'plugins_stop',
        'plugins_set_active',
        'update',
      };
      if (mutations.contains(action)) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$namespace.$action completed')));
        await refresh(afterChange: true);
      }
      return value;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$namespace.$action: $error')));
      }
      rethrow;
    }
  }

  void navigateToLabel(String label) {
    for (var s = 0; s < sections.length; s++) {
      for (var p = 0; p < sections[s].pages.length; p++) {
        if (sections[s].pages[p].label == label) {
          select(s, p);
          return;
        }
      }
    }
  }

  Future<void> openSearch() async {
    final entries = <(int, int, _Page)>[
      for (var s = 0; s < sections.length; s++)
        for (var p = 0; p < sections[s].pages.length; p++)
          (s, p, sections[s].pages[p]),
    ];
    final picked = await showSearch<(int, int)?>(
        context: context, delegate: _AdminSearch(entries));
    if (picked != null) select(picked.$1, picked.$2);
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 820;
    final actions = [
      IconButton(
          tooltip: 'Search',
          onPressed: openSearch,
          icon: const Icon(Icons.search_rounded)),
      IconButton(
          tooltip: 'Refresh',
          onPressed: current.providers ? null : refresh,
          icon: const Icon(Icons.refresh_rounded)),
    ];
    final content = Column(children: [
      // On compact screens the app bar carries the title and actions.
      if (!compact)
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
          child: PanelHeader(
            icon: Icons.admin_panel_settings_outlined,
            title: current.label,
            subtitle: current.hint,
            onClose: () => Navigator.pop(context),
            actions: actions,
          ),
        )
      else
        const SizedBox(height: 12),
      Expanded(
        child: current.providers
            ? Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: width < 600 ? 16 : 24),
                child: LlmProvidersTab(service: widget.dependencies.service))
            : AdminPageContent(
                key: ValueKey(current.label),
                page: current.label,
                results: results,
                loading: loading,
                onRefresh: refresh,
                onLiveRefresh: () => refresh(background: true),
                onAction: (namespace, action, body) =>
                    runAction(_Call(namespace, action, body)),
                onDirectAction: runDirectAction,
                onNavigate: navigateToLabel,
              ),
      ),
    ]);

    if (compact) {
      return Scaffold(
        drawer: Drawer(
            child: SafeArea(
                child: _Navigation(
          selectedSection: section,
          selectedPage: page,
          onSelect: (s, p) {
            Navigator.pop(context);
            select(s, p);
          },
        ))),
        appBar: AppBar(
          title:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(current.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            Text(current.hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
          actions: [
            ...actions,
            IconButton(
                tooltip: 'Close admin console',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded)),
          ],
        ),
        body: content,
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Row(children: [
          SizedBox(
            width: 268,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: _Navigation(
                selectedSection: section,
                selectedPage: page,
                onSelect: select,
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ]),
      ),
    );
  }
}

class _Navigation extends StatelessWidget {
  const _Navigation(
      {required this.selectedSection,
      required this.selectedPage,
      required this.onSelect});
  final int selectedSection;
  final int selectedPage;
  final void Function(int, int) onSelect;

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 18),
            child: Text('TRADERA ADMIN',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2)),
          ),
          for (var s = 0; s < _AdminScreenState.sections.length; s++) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 13, 12, 5),
              child: Text(_AdminScreenState.sections[s].label.toUpperCase(),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: AppColors.muted,
                      letterSpacing: .8)),
            ),
            for (var p = 0; p < _AdminScreenState.sections[s].pages.length; p++)
              ListTile(
                dense: true,
                selected: s == selectedSection && p == selectedPage,
                selectedTileColor: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: .12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                leading:
                    Icon(_AdminScreenState.sections[s].pages[p].icon, size: 19),
                title: Text(_AdminScreenState.sections[s].pages[p].label,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                onTap: () => onSelect(s, p),
              ),
          ],
        ],
      );
}

class _AdminSearch extends SearchDelegate<(int, int)?> {
  _AdminSearch(this.entries);
  final List<(int, int, _Page)> entries;
  @override
  List<Widget> buildActions(BuildContext context) => [
        IconButton(
            onPressed: () => query = '', icon: const Icon(Icons.clear_rounded)),
      ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
      onPressed: () => close(context, null),
      icon: const Icon(Icons.arrow_back_rounded));
  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);
  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.toLowerCase().trim();
    final shown = entries.where((e) =>
        q.isEmpty || '${e.$3.label} ${e.$3.hint}'.toLowerCase().contains(q));
    return ListView(children: [
      for (final e in shown)
        ListTile(
          leading: Icon(e.$3.icon),
          title: Text(e.$3.label),
          subtitle: Text(e.$3.hint),
          onTap: () => close(context, (e.$1, e.$2)),
        ),
    ]);
  }
}
