import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_shape.dart';
import 'admin_forms.dart';
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
  const _Page(this.label, this.hint, this.icon, this.selectedIcon,
      {this.calls = const [], this.actions = const [], this.providers = false});
  final String label;
  final String hint;
  final IconData icon;
  final IconData selectedIcon;
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
  State<AdminScreen> createState() => _AppScreenState();
}

class _AppScreenState extends State<AdminScreen> {
  static const sections = <_Section>[
    _Section('Operate', [
      _Page('Overview', 'What needs attention', Icons.dashboard_outlined,
          Icons.dashboard_rounded,
          calls: [
            _Call('admin', 'stats'),
            _Call('admin', 'health'),
            _Call('admin', 'runs_list'),
            _Call('admin', 'node_stats'),
            _Call('finance', 'payouts_list'),
            _Call('market', 'catalog', {'status': 'all'}),
          ]),
      _Page('Users', 'Accounts, wallets and roles', Icons.people_outline,
          Icons.people_rounded,
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
          Icons.folder_rounded,
          calls: [
            _Call('spaces', 'space_list_all'),
            _Call('spaces', 'admins_space_get'),
            _Call('admin', 'admins_list'),
          ],
          actions: [
            _Call('spaces', 'space_detail', {'admin': true}),
            _Call('spaces', 'admin_work_log'),
            _Call('spaces', 'admin_files'),
            _Call('spaces', 'space_delete'),
            _Call('spaces', 'admins_space_set'),
            _Call('finance', 'budget_set'),
          ]),
    ]),
    _Section('Catalog', [
      _Page('Agents', 'Create, price and approve agents',
          Icons.smart_toy_outlined, Icons.smart_toy_rounded,
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
          Icons.build_rounded,
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
      _Page('Talent', 'People listed for hire', Icons.badge_outlined,
          Icons.badge_rounded,
          calls: [
            _Call('users', 'accounts_list'),
            _Call('talent', 'list_mine')
          ],
          actions: [
            _Call('users', 'account_update'),
          ]),
    ]),
    _Section('Money', [
      _Page(
          'Finance · Overview',
          'Revenue, costs and reconciliation',
          Icons.account_balance_wallet_outlined,
          Icons.account_balance_wallet_rounded,
          calls: [
            _Call('finance', 'overview'),
            _Call('finance', 'costs'),
            _Call('finance', 'provider_costs'),
            _Call('finance', 'reconcile'),
          ]),
      _Page('Finance · Purchases', 'Store transactions and environments',
          Icons.receipt_long_outlined, Icons.receipt_long_rounded,
          calls: [_Call('finance', 'purchases_list')],
          actions: [_Call('finance', 'purchases_label')]),
      _Page('Finance · Payouts', 'Review and resolve payout requests',
          Icons.payments_outlined, Icons.payments_rounded,
          calls: [_Call('finance', 'payouts_list')],
          actions: [_Call('finance', 'payout_resolve')]),
    ]),
    _Section('AI', [
      _Page('Providers', 'Endpoints and API keys', Icons.key_outlined,
          Icons.key_rounded,
          providers: true),
      _Page('Models', 'Model list and token prices', Icons.memory_outlined,
          Icons.memory_rounded,
          calls: [_Call('llm', 'llm_providers_list')],
          actions: [_Call('llm', 'llm_provider_set')]),
      _Page('Decision model', 'Tool selection and work decisions',
          Icons.alt_route_outlined, Icons.alt_route_rounded,
          calls: [_Call('llm', 'llm_decision_get')],
          actions: [_Call('llm', 'llm_decision_set')]),
      _Page('Memory models', 'Learning and semantic recall',
          Icons.psychology_outlined, Icons.psychology_rounded,
          calls: [_Call('llm', 'llm_memory_get')],
          actions: [_Call('llm', 'llm_memory_set')]),
    ]),
    _Section('System', [
      _Page('Health', 'Deployment checklist', Icons.monitor_heart_outlined,
          Icons.monitor_heart_rounded,
          calls: [_Call('admin', 'health'), _Call('admin', 'plugins_health')]),
      _Page('Node · Host', 'Host, mesh and live telemetry', Icons.dns_outlined,
          Icons.dns_rounded,
          calls: [
            _Call('admin', 'node_stats'),
            _Call('admin', 'telemetry'),
            _Call('federation', 'node_info'),
            _Call('federation', 'nodes_list'),
          ]),
      _Page('Node · Plugins', 'Runtime plugins and active adapters',
          Icons.extension_outlined, Icons.extension_rounded,
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
          Icons.article_rounded,
          calls: [
            _Call('admin', 'logs', {'limit': 500})
          ]),
      _Page('Sandboxes', 'Machines running at the provider',
          Icons.computer_outlined, Icons.computer_rounded,
          calls: [_Call('spaces', 'admin_sandboxes')]),
      _Page('Storage', 'Volumes and project files', Icons.storage_outlined,
          Icons.storage_rounded,
          calls: [_Call('spaces', 'admin_storage')]),
      _Page('Settings · Pricing', 'Runtime and resource rates',
          Icons.sell_outlined, Icons.sell_rounded,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'pricing': <String, dynamic>{}})
          ]),
      _Page('Settings · Machine', 'Computer size, reserve and ceiling',
          Icons.developer_board_outlined, Icons.developer_board_rounded,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'machine': <String, dynamic>{}})
          ]),
      _Page('Settings · Agent instructions', 'Universal system instructions',
          Icons.description_outlined, Icons.description_rounded,
          calls: [
            _Call('settings', 'get')
          ],
          actions: [
            _Call('settings', 'update', {'universal_system_prompt': ''})
          ]),
      _Page('Settings · Categories', 'Marketplace categories',
          Icons.category_outlined, Icons.category_rounded,
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

  /// Request bodies a page set for its calls (a finance period, say), by
  /// call label. They last until the admin leaves the page.
  final queries = <String, Map<String, dynamic>>{};

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
          body: {...call.body, ...?queries[call.label]},
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
      queries.clear();
    });
    load();
  }

  /// Re-requests [label] with [body] merged into its request.
  Future<void> setQuery(String label, Map<String, dynamic> body) {
    setState(() => queries[label] = body);
    return refresh(afterChange: true);
  }

  void _toast(String message, {bool error = false}) {
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(children: [
          Icon(error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
              color: error ? scheme.errorContainer : scheme.inversePrimary,
              size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ]),
      ));
  }

  static String _errorText(Object error) => '$error'.replaceFirst(
      RegExp(r'^(Exception|TraderaException|ApiException):\s*'), '');

  Future<void> runAction(_Call call) async {
    final body = await showAdminActionForm(
      context,
      namespace: call.namespace,
      action: call.action,
      initialBody: call.body,
      lookup: (namespace, action, body) => widget.dependencies.service
          .invokeAction(namespace, action,
              body: body, timeout: const Duration(minutes: 1)),
    );
    if (body == null || !mounted) return;
    try {
      final value = await widget.dependencies.service.invokeAction(
          call.namespace, call.action,
          body: body, timeout: const Duration(minutes: 10));
      if (!mounted) return;
      setState(() => results = {...results, call.label: value});
      _toast(adminActionDone(call.namespace, call.action));
      await refresh(afterChange: true);
    } catch (error) {
      if (!mounted) return;
      _toast(_errorText(error), error: true);
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
        'admins_space_set',
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
        _toast(adminActionDone(namespace, action));
        await refresh(afterChange: true);
      }
      return value;
    } catch (error) {
      if (mounted) _toast(_errorText(error), error: true);
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
  Widget build(BuildContext context) => _shell();

  Widget _shell() => Builder(builder: (context) {
        final scheme = Theme.of(context).colorScheme;
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
              padding: const EdgeInsets.fromLTRB(28, 22, 20, 14),
              child: Row(children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: ShapeDecoration(
                    color: scheme.primaryContainer,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                  ),
                  child: Icon(current.selectedIcon,
                      color: scheme.onPrimaryContainer, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sections[section].label.toUpperCase(),
                            style: TextStyle(
                                fontSize: 11,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w700,
                                color: scheme.primary)),
                        Text(current.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 30,
                                height: 1.15,
                                letterSpacing: -.6,
                                fontWeight: FontWeight.w800)),
                        Text(current.hint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13, color: scheme.onSurfaceVariant)),
                      ]),
                ),
                ...actions,
                const SizedBox(width: 4),
                IconButton.filledTonal(
                    tooltip: 'Close admin console',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded)),
              ]),
            )
          else
            const SizedBox(height: 8),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, .02), end: Offset.zero)
                      .animate(animation),
                  child: child,
                ),
              ),
              child: KeyedSubtree(
                key: ValueKey(current.label),
                child: current.providers
                    ? Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: width < 600 ? 16 : 28),
                        child: LlmProvidersTab(
                            service: widget.dependencies.service))
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
                        onQuery: setQuery,
                      ),
              ),
            ),
          ),
        ]);

        if (compact) {
          return Scaffold(
            backgroundColor: scheme.surface,
            drawer: _Navigation(
              selectedSection: section,
              selectedPage: page,
              onSelect: (s, p) {
                Navigator.pop(context);
                select(s, p);
              },
            ),
            appBar: AppBar(
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              titleSpacing: 0,
              title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(current.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800)),
                    Text(current.hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
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
          backgroundColor: scheme.surfaceContainerLowest,
          body: SafeArea(
            child: Row(children: [
              SizedBox(
                width: 288,
                child: _Navigation(
                  permanent: true,
                  selectedSection: section,
                  selectedPage: page,
                  onSelect: select,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                  child: Material(
                    color: scheme.surface,
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppShape.card + 4)),
                    child: content,
                  ),
                ),
              ),
            ]),
          ),
        );
      });
}

/// The console's sections as a Material 3 navigation drawer: section
/// headings with pill-shaped destinations that fill in when selected.
class _Navigation extends StatelessWidget {
  const _Navigation({
    required this.selectedSection,
    required this.selectedPage,
    required this.onSelect,
    this.permanent = false,
  });
  final int selectedSection;
  final int selectedPage;
  final void Function(int, int) onSelect;
  final bool permanent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const sections = _AppScreenState.sections;
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: ShapeDecoration(
                color: scheme.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: Icon(Icons.admin_panel_settings_rounded,
                  color: scheme.onPrimary, size: 22),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tradera',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 18,
                            height: 1.1,
                            fontWeight: FontWeight.w800)),
                    Text('Admin console',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12)),
                  ]),
            ),
          ]),
        ),
        for (var s = 0; s < sections.length; s++) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
            child: Text(sections[s].label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.primary)),
          ),
          for (var p = 0; p < sections[s].pages.length; p++)
            _NavTile(
              page: sections[s].pages[p],
              selected: s == selectedSection && p == selectedPage,
              onTap: () => onSelect(s, p),
            ),
        ],
      ],
    );
    if (permanent) {
      return Material(color: scheme.surfaceContainerLowest, child: list);
    }
    return Drawer(
        backgroundColor: scheme.surfaceContainerLow,
        child: SafeArea(child: list));
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile(
      {required this.page, required this.selected, required this.onTap});
  final _Page page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color =
        selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            selected: selected,
            button: true,
            child: SizedBox(
              height: 48,
              child: Row(children: [
                const SizedBox(width: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: Icon(selected ? page.selectedIcon : page.icon,
                      key: ValueKey(selected), size: 22, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(page.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: selected ? color : scheme.onSurface,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500)),
                ),
                const SizedBox(width: 12),
              ]),
            ),
          ),
        ),
      ),
    );
  }
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
