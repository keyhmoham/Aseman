import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import 'admin_widgets.dart';

part 'admin_editors.dart';
part 'admin_people_pages.dart';
part 'admin_catalog_pages.dart';
part 'admin_finance_pages.dart';
part 'admin_ai_pages.dart';
part 'admin_ops_pages.dart';

typedef AdminAction =
    Future<void> Function(
      String namespace,
      String action,
      Map<String, dynamic> initialBody,
    );
typedef AdminDirectAction =
    Future<dynamic> Function(
      String namespace,
      String action,
      Map<String, dynamic> body,
    );

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
        !identical(
          oldWidget.results['admin.node_stats'],
          widget.results['admin.node_stats'],
        )) {
      _sampleNode();
    }
  }

  void _configureTimer() {
    timer?.cancel();
    if (widget.page == 'Node · Host' || widget.page == 'Node · Logs') {
      timer = Timer.periodic(
        Duration(seconds: widget.page == 'Node · Logs' ? 3 : 5),
        (_) async {
          if (!mounted || !live || widget.loading || ticking) return;
          ticking = true;
          final page = widget.page;
          try {
            await (widget.onLiveRefresh ?? widget.onRefresh)();
          } finally {
            ticking = false;
          }
          if (mounted && page == widget.page) setState(_sampleNode);
        },
      );
    }
  }

  void _sampleNode() {
    if (widget.page != 'Node · Host') return;
    final resources = _map(
      _map(widget.results['admin.node_stats'])['resources'],
    );
    if (resources.isEmpty) return;
    final cores = _number(resources['cpu_cores'], fallback: 1);
    final load = _doubleList(resources['load_avg']);
    cpu.add(
      ((load.isEmpty ? 0 : load.first) / (cores == 0 ? 1 : cores) * 100).clamp(
        0,
        100,
      ),
    );
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
                borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.cloud_off_rounded,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      errors
                          .map((e) => '${e.key}: ${_map(e.value)['error']}')
                          .join('\n'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
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
    'Voice' => _voice(),
    'Memory models' => _memoryModels(),
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
      'Page unavailable',
      'This admin route has no visual definition.',
    ),
  };

  Widget _overview() => _buildOverviewPage(this);

  Widget _users() => _buildUsersPage(this);

  void _editUser(Map<String, dynamic> a) => _buildEditUser(this, a);

  Widget _projects() => _buildProjectsPage(this);

  /// The project every platform administrator is kept a member of: the node
  /// adds each admin to it when it is chosen and whenever someone becomes one.
  Widget _adminsSpaceCard(
    List<Map<String, dynamic>> spaces,
    Map<String, dynamic> current,
  ) =>
      _buildAdminsSpaceCard(this, spaces, current);

  Future<void> _pickAdminsSpace(
    List<Map<String, dynamic>> spaces,
    String currentId,
  ) async =>
      _buildPickAdminsSpace(this, spaces, currentId);

  Widget _agents() => _buildAgentsPage(this);

  List<Widget> _agentRow(
    Map<String, dynamic> b,
    Map<String, dynamic>? listing,
  ) =>
      _buildAgentRow(this, b, listing);

  Widget _apps() => _buildAppsPage(this);

  Widget _appSection(
    String title,
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> listings,
    bool Function(Map<String, dynamic>) isServer,
  ) =>
      _buildAppSection(this, title, rows, listings, isServer);

  /// The OAuth client people sign in to an MCP server with, for providers
  /// that will not register Aseman by themselves. Its secret is never shown;
  /// leaving it empty keeps the saved one.
  Future<void> _mcpClient(Map<String, dynamic> server, String name) async => _buildMcpClient(this, server, name);

  Widget _talent() => _buildTalentPage(this);

  void _setPeriod(String value) => _buildSetPeriod(this, value);

  /// Requests for talent people posted, which partners read through their
  /// API key, and the partner keys themselves.
  Widget _talentRequests() => _buildTalentRequestsPage(this);

  Future<void> _createPartnerKey() async => _buildCreatePartnerKey(this);

  Future<void> _revokePartnerKey(Map<String, dynamic> key) async => _buildRevokePartnerKey(this, key);

  /// The developer API across every organization: what each spent and called
  /// in the last days, and the latest requests (read-only).
  Widget _developer() => _buildDeveloperPage(this);

  /// Platforms and the boolean bridge onto main Aseman.
  Widget _developerPlatforms() => _buildDeveloperPlatformsPage(this);

  Widget _developerLogs(
    List<Map<String, dynamic>> logs, {
    bool withOrg = false,
  }) =>
      _buildDeveloperLogs(this, logs, withOrg: withOrg);

  Future<void> _showDeveloperOrg(Map<String, dynamic> org) async => _buildShowDeveloperOrg(this, org);

  Widget _finance() => _buildFinancePage(this);

  Widget _purchases() => _buildPurchasesPage(this);

  Future<void> _labelPurchases(
    List<Map<String, dynamic>> purchases,
    bool sandbox,
  ) async =>
      _buildLabelPurchases(this, purchases, sandbox);

  Widget _payouts() => _buildPayoutsPage(this);

  void _resolvePayout(Map<String, dynamic> p, String status) => _buildResolvePayout(this, p, status);

  Widget _models() => _buildModelsPage(this);

  /// Disabling hides a model from new agents, the pickers and the developer
  /// API; agents already on it keep running. The provider is saved whole.
  Future<void> _setModelDisabled(Map<String, dynamic> model, bool disabled) => _buildSetModelDisabled(this, model, disabled);

  /// Brings Vercel AI Gateway's catalog into a Vercel provider at Vercel's
  /// price plus a markup; importing again updates the models in place.
  Future<void> _importVercel(List<Map<String, dynamic>> vercel) async => _buildImportVercel(this, vercel);

  Future<void> _showModel(
    List<Map<String, dynamic>> providers, {
    Map<String, dynamic>? provider,
    Map<String, dynamic>? model,
  }) async =>
      _buildShowModel(this, providers, provider: provider, model: model);

  Future<void> _removeModel(Map<String, dynamic> model) async => _buildRemoveModel(this, model);

  Widget _decision() => _buildDecisionPage(this);

  /// The node's image model: agents make images with their image tool using
  /// this one model, whatever model they run on, charged at its prices.
  Widget _imageModel() => _buildImageModelPage(this);

  /// Live voice chat models (Admin → AI → Voice): transcription hears the
  /// person, speech speaks Aseman's reply. Mark models Speech / Transcription
  /// (or Live) on the Models page so they appear here.
  Widget _voice() => _buildVoicePage(this);

  Widget _voiceRoleCard({
    required String role,
    required String title,
    required IconData icon,
    required String subtitle,
    required Map<String, dynamic> roles,
    required List<Map<String, dynamic>> providers,
    required bool showVoiceName,
  }) =>
      _buildVoiceRoleCard(this, role: role, title: title, icon: icon, subtitle: subtitle, roles: roles, providers: providers, showVoiceName: showVoiceName);

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
  }) =>
      _buildModelPicker(this, slot: slot, providers: providers, providerId: providerId, modelId: modelId, modelsOf: modelsOf, onSelect: onSelect, allowNone: allowNone);

  Widget _memoryModels() => _buildMemoryModelsPage(this);

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
  }) =>
      _buildMemorySlot(this, title: title, icon: icon, hint: hint, providers: providers, setting: setting, providerKey: providerKey, modelKey: modelKey, listKey: listKey, active: active, confirm: confirm);

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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Widget _health() => _buildHealthPage(this);

  Widget _liveChip(String period) => _buildLiveChip(this, period);

  Widget _node() => _buildNodePage(this);

  Widget _nodePlugins() => _buildNodePluginsPage(this);

  Widget _logs() => _buildLogsPage(this);

  Widget _sandboxes() => _buildSandboxesPage(this);

  Future<void> _terminateSandbox(Map<String, dynamic> row) async => _buildTerminateSandbox(this, row);

  Widget _chatReports() => _buildChatReportsPage(this);

  Widget _postReports() => _buildPostReportsPage(this);

  Widget _storage() => _buildStoragePage(this);

  Widget _pricing() => _PricingEditor(
    key: ValueKey(jsonEncode(_map(widget.results['settings.get'])['pricing'])),
    settings: _map(widget.results['settings.get']),
    onSave: (pricing) =>
        widget.onDirectAction('settings', 'update', {'pricing': pricing}),
    onModels: () => widget.onNavigate('Models'),
  );

  Widget _machine() => _MachineEditor(
    key: ValueKey(jsonEncode(_map(widget.results['settings.get'])['machine'])),
    settings: _map(widget.results['settings.get']),
    onSave: (machine) =>
        widget.onDirectAction('settings', 'update', {'machine': machine}),
  );

  Widget _agentInstructions() => _PromptEditor(
    key: ValueKey(
      _map(widget.results['settings.get'])['universal_system_prompt'],
    ),
    value:
        '${_map(widget.results['settings.get'])['universal_system_prompt'] ?? ''}',
    onSave: (value) => widget.onDirectAction('settings', 'update', {
      'universal_system_prompt': value,
    }),
  );

  Widget _categories() => _buildCategoriesPage(this);

  Future<void> _addCategory(List<String> enabled) async => _buildAddCategory(this, enabled);

  void _showProject(Map<String, dynamic> project) => _buildShowProject(this, project);

  void _showUser(Map<String, dynamic> account, {int tab = 0}) => _buildShowUser(this, account, tab: tab);

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        letterSpacing: -.2,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _personCell(
    String name,
    String secondary, {
    IconData? icon,
    String avatar = '',
  }) => Row(
    children: [
      AdminAvatar(name, size: 34, icon: icon, avatar: avatar),
      const SizedBox(width: 10),
      Expanded(child: _primaryCell(name, secondary)),
    ],
  );

  /// A toolbar whose [actions] sit beside [main] on wide screens and wrap
  /// below it on narrow ones, so neither side gets squeezed.
  Widget _toolbar(Widget main, List<Widget> actions) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 640) {
        return Row(
          children: [
            Expanded(child: main),
            for (final action in actions) ...[const SizedBox(width: 8), action],
          ],
        );
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
            children: actions,
          ),
        ],
      );
    },
  );

  /// A list row whose actions trail on wide screens and move under the text
  /// on narrow ones, so the title keeps its width.
  Widget _adaptiveTile({
    Widget? leading,
    required Widget title,
    Widget? subtitle,
    required List<Widget> actions,
    EdgeInsetsGeometry? contentPadding,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final buttons = Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: actions,
      );
      final wide = constraints.maxWidth >= 560;
      return ListTile(
        contentPadding: contentPadding,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
        ),
        leading: leading,
        title: title,
        subtitle: wide || actions.isEmpty
            ? subtitle
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subtitle != null) subtitle,
                  const SizedBox(height: 6),
                  buttons,
                ],
              ),
        trailing: wide && actions.isNotEmpty ? buttons : null,
      );
    },
  );

  Widget _settingStatus(Map<String, dynamic> setting) => _buildSettingStatus(this, setting);

  Map<String, dynamic> _decisionBody(
    Map<String, dynamic> setting, {
    bool? enabled,
    String? provider,
    String? model,
    bool? autoApprove,
  }) =>
      _buildDecisionBody(this, setting, enabled: enabled, provider: provider, model: model, autoApprove: autoApprove);

  Map<String, dynamic> _memoryBody(Map<String, dynamic> setting) => _buildMemoryBody(this, setting);

  List<Map<String, dynamic>> _decisionModels(
    List<Map<String, dynamic>> providers,
    String providerId,
  ) =>
      _buildDecisionModels(this, providers, providerId);

  TextStyle _muted() => TextStyle(
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    fontSize: 12,
    height: 1.35,
  );
}

