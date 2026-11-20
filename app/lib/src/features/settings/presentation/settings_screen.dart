import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/default_theme_packs.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_pack_controller.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart' show AppChoice;
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar_editor.dart';
import '../../../shared/widgets/avatar_face.dart';
import '../../../shared/widgets/settings_kit.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/theme_slot_host.dart';
import '../../../shared/widgets/user_profile_sheet.dart';
import '../../account/presentation/account_panel.dart';
import '../../admin/presentation/admin_screen.dart';
import '../../assistant/assistant.dart';
import '../../market/presentation/bots_store_screen.dart';
import '../../marketing/marketing_links.dart';
import 'widgets/devices_panel.dart';
import 'widgets/notify_prefs_panel.dart';
import 'widgets/privacy_settings_panel.dart';

enum _SettingsPane {
  account,
  profile,
  appearance,
  wallet,
  assistant,
  approvals,
  connections,
  agents,
  notifications,
  privacy,
  devices,
  storage,
  about,
  admin,
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.dependencies});
  final AppDependencies? dependencies;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool tradeConfirmations = true;
  bool agentApprovals = true;
  bool priceAlerts = true;
  bool socialNotifications = false;
  bool biometrics = true;
  bool analytics = false;
  bool reducedMotion = false;
  bool compactNumbers = true;
  double textScale = 1;
  String currency = 'USD';
  String region = 'Global';
  String quietHours = '23:00–07:00';
  String mediaQuality = 'Automatic';
  String _cacheSize = '…';
  _SettingsPane _pane = _SettingsPane.appearance;

  /// The page open on a phone; null shows the hub of rows.
  _SettingsPane? _mobilePane;

  /// Panels register here so pull-to-refresh reloads what is on screen.
  final _refresh = SettingsRefreshRegistry();

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _measureCache();
  }

  Future<void> _measureCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = prefs.getKeys().length * 64;
      if (!mounted) return;
      setState(() {
        _cacheSize = size >= 1048576
            ? '${(size / 1048576).toStringAsFixed(1)} MB'
            : size >= 1024
            ? '${(size / 1024).toStringAsFixed(0)} KB'
            : '$size B';
      });
    } catch (_) {}
  }

  Future<void> _clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      const sessionKey = 'aseman.session';
      final session = prefs.getString(sessionKey);
      // Appearance is a device preference kept in the same store. Clearing
      // drafts and other cached data leaves the chosen theme in place.
      final theme = prefs.getString(AppSettingsController.storageKey);
      await prefs.clear();
      if (session != null) {
        await prefs.setString(sessionKey, session);
      }
      if (theme != null) {
        await prefs.setString(AppSettingsController.storageKey, theme);
      }
      await _measureCache();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Local cache cleared')));
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    final deps = widget.dependencies;
    if (deps == null) return;
    try {
      final tree = await deps.service.fetchMyMetadata();
      final prefs = _prefsOf(tree);
      if (!mounted) return;
      setState(() {
        tradeConfirmations = _readBool(
          prefs,
          'tradeConfirmations',
          tradeConfirmations,
        );
        agentApprovals = _readBool(prefs, 'agentApprovals', agentApprovals);
        priceAlerts = _readBool(prefs, 'priceAlerts', priceAlerts);
        socialNotifications = _readBool(
          prefs,
          'socialNotifications',
          socialNotifications,
        );
        biometrics = _readBool(prefs, 'biometrics', biometrics);
        analytics = _readBool(prefs, 'analytics', analytics);
        reducedMotion = _readBool(prefs, 'reducedMotion', reducedMotion);
        compactNumbers = _readBool(prefs, 'compactNumbers', compactNumbers);
        textScale = _readNum(prefs, 'textScale', textScale);
        currency = _readString(prefs, 'currency', currency);
        region = _readString(prefs, 'region', region);
        quietHours = _readString(prefs, 'quietHours', quietHours);
        mediaQuality = _readString(prefs, 'mediaQuality', mediaQuality);
      });
    } catch (_) {}
  }

  static String _readString(
    Map<String, dynamic> prefs,
    String key,
    String fallback,
  ) {
    final v = prefs[key];
    return v is String && v.isNotEmpty ? v : fallback;
  }

  static Map<String, dynamic> _prefsOf(Map<String, dynamic> tree) {
    final profile = tree['profile'];
    if (profile is Map) {
      final prefs = profile['preferences'];
      if (prefs is Map) return prefs.cast<String, dynamic>();
    }
    return const {};
  }

  static bool _readBool(Map<String, dynamic> prefs, String key, bool fallback) {
    final v = prefs[key];
    return v is bool ? v : fallback;
  }

  static double _readNum(
    Map<String, dynamic> prefs,
    String key,
    double fallback,
  ) {
    final v = prefs[key];
    return v is num ? v.toDouble() : fallback;
  }

  Future<void> _save(String key, Object? value) async {
    final deps = widget.dependencies;
    if (deps == null) return;
    try {
      await deps.service.updateMetadata([
        {'op': 'set', 'path': 'profile/preferences/$key', 'value': value},
      ]);
    } catch (_) {}
  }

  void _toggle(void Function(bool) setter, bool value, String key) {
    setState(() => setter(value));
    _save(key, value);
  }

  void _choose(void Function(String) setter, String value, String key) {
    setState(() => setter(value));
    unawaited(_save(key, value));
  }

  Future<void> _confirmClearCache() async {
    final ok = await confirmAppAction(
      context,
      icon: Icons.cleaning_services_rounded,
      title: 'Clear local cache?',
      message:
          'Saved drafts and cached data on this device are removed. You stay signed in.',
      action: 'Clear cache',
    );
    if (ok) await _clearCache();
  }

  static final _textSizes = <double, String>{
    .85: 'Small',
    1.0: 'Default',
    1.15: 'Large',
    1.3: 'Largest',
  };

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final windowClass = AppWindowClass.fromWidth(width);
    // Below the large class, keep one centered column. Large and wider use
    // a section list beside the active section.
    final split = AppWindowScope.supportingPane(context);
    final side = split
        ? AppLayout.gutterWidth
        : math.max(windowClass.margin, (width - 840) / 2);
    final scheme = Theme.of(context).colorScheme;
    final isAdmin = widget.dependencies?.sessionController.isAdmin ?? false;

    if (!split) return _buildMobile(context, side, isAdmin);

    final page = Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                side,
                AppSpacing.lg,
                side,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _SettingsNav.labelOf(_pane),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.4,
                          ),
                    ),
                  ),
                  if (_refreshable.contains(_pane))
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _refresh.refreshAll,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(side, 0, side, AppSpacing.xl),
            sliver: SliverList.list(children: [_paneBody(_pane, split: true)]),
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: AppLayout.listPaneWidth,
            child: Material(
              color: scheme.surfaceContainerLow,
              child: _SettingsNav(
                selected: _pane,
                showSignedIn: widget.dependencies != null,
                showAdmin: isAdmin,
                onSelect: (pane) => setState(() => _pane = pane),
              ),
            ),
          ),
          const PaneDivider(),
          Expanded(child: page),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- mobile

  /// Phone layout: a grouped hub of rows, each opening its own page. Back
  /// from a page returns to the hub before it leaves Settings.
  Widget _buildMobile(BuildContext context, double side, bool isAdmin) {
    final scheme = Theme.of(context).colorScheme;
    final pane = _mobilePane;
    return PopScope(
      canPop: pane == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && pane != null) setState(() => _mobilePane = null);
      },
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, .02),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
          child: pane == null
              ? _buildHub(context, side, isAdmin)
              : _buildDetail(context, side, pane),
        ),
      ),
    );
  }

  Widget _buildHub(BuildContext context, double side, bool isAdmin) {
    final signedIn = widget.dependencies != null;
    final packs = ThemePackScope.maybeOf(context);
    final settings = AppSettingsScope.of(context);
    final packName = (packs?.pack ?? DefaultThemePacks.kashi).meta.name;
    final mode = switch (settings.themeMode) {
      ThemeMode.system => 'System',
      ThemeMode.light => 'Light',
      ThemeMode.dark => 'Dark',
    };

    Widget row(
      _SettingsPane pane,
      String label,
      IconData icon, {
      String? subtitle,
    }) => QuietTile(
      icon: icon,
      label: label,
      subtitle: subtitle,
      onTap: () => setState(() => _mobilePane = pane),
    );

    return CustomScrollView(
      key: const ValueKey('settings-hub'),
      slivers: [
        SliverToBoxAdapter(
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                side,
                AppSpacing.xs,
                side,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  if (Navigator.of(context).canPop()) ...[
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: AppSpacing.xxs),
                  ] else
                    const SizedBox(width: AppSpacing.xs, height: 48),
                  Expanded(
                    child: Text(
                      'Settings',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.6,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(side, 0, side, AppSpacing.xxl),
          sliver: SliverList.list(
            children: [
              _AccountCard(dependencies: widget.dependencies),
              const SizedBox(height: AppSpacing.lg),
              SettingsGroup(
                children: [
                  row(
                    _SettingsPane.account,
                    'Account & sign-in',
                    Icons.account_circle_outlined,
                    subtitle: 'Email, password and identity',
                  ),
                  if (signedIn)
                    row(
                      _SettingsPane.profile,
                      'Profile',
                      Icons.person_outline,
                      subtitle: 'Name, bio and links',
                    ),
                  if (signedIn)
                    row(
                      _SettingsPane.wallet,
                      'Wallet',
                      Icons.account_balance_wallet_outlined,
                      subtitle: 'Balance and payments',
                    ),
                ],
              ),
              SettingsGroup(
                caption: 'Personalise',
                children: [
                  row(
                    _SettingsPane.appearance,
                    'Appearance',
                    Icons.palette_outlined,
                    subtitle: '$packName · $mode',
                  ),
                  row(
                    _SettingsPane.notifications,
                    'Notifications',
                    Icons.notifications_none_rounded,
                    subtitle: quietHours == 'Off'
                        ? 'Quiet hours off'
                        : 'Quiet $quietHours',
                  ),
                ],
              ),
              SettingsGroup(
                caption: 'Agents',
                children: [
                  row(
                    _SettingsPane.agents,
                    'Agents & actions',
                    Icons.smart_toy_outlined,
                    subtitle: 'Confirmations, currency, limits',
                  ),
                  if (signedIn)
                    row(
                      _SettingsPane.approvals,
                      'Approvals',
                      Icons.verified_user_outlined,
                      subtitle: 'Pending permission requests',
                    ),
                  if (signedIn)
                    row(
                      _SettingsPane.connections,
                      'Connections',
                      Icons.hub_outlined,
                      subtitle: 'Services, apps and wallets',
                    ),
                  if (signedIn)
                    row(
                      _SettingsPane.assistant,
                      'Setup',
                      Icons.checklist_rounded,
                      subtitle: 'Finish getting started',
                    ),
                ],
              ),
              SettingsGroup(
                caption: 'Privacy & data',
                children: [
                  row(
                    _SettingsPane.privacy,
                    'Privacy & security',
                    Icons.lock_outline_rounded,
                    subtitle: 'Visibility, biometrics, analytics',
                  ),
                  if (signedIn)
                    row(
                      _SettingsPane.devices,
                      'Devices',
                      Icons.devices_outlined,
                      subtitle: 'Where you are signed in',
                    ),
                  row(
                    _SettingsPane.storage,
                    'Storage & data',
                    Icons.storage_outlined,
                    subtitle: 'Cache $_cacheSize · $mediaQuality media',
                  ),
                ],
              ),
              SettingsGroup(
                children: [
                  row(
                    _SettingsPane.about,
                    'About Aseman',
                    Icons.info_outline_rounded,
                    subtitle: 'Pricing and how it works',
                  ),
                  if (isAdmin)
                    row(
                      _SettingsPane.admin,
                      'Admin console',
                      Icons.space_dashboard_outlined,
                      subtitle: 'People, rooms, money and the node',
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDetail(BuildContext context, double side, _SettingsPane pane) {
    final title = _SettingsNav.labelOf(pane);
    // The bar is outside the scroll view so Back stays reachable.
    return Column(
      key: ValueKey('settings-${pane.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              side,
              AppSpacing.xs,
              side,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => setState(() => _mobilePane = null),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const SizedBox(width: AppSpacing.xxs),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh.refreshAll,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                side,
                AppSpacing.xs,
                side,
                AppSpacing.xxl,
              ),
              children: [_paneBody(pane, split: false)],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- panes

  static const _refreshable = {
    _SettingsPane.account,
    _SettingsPane.wallet,
    _SettingsPane.assistant,
    _SettingsPane.approvals,
    _SettingsPane.connections,
    _SettingsPane.notifications,
    _SettingsPane.privacy,
    _SettingsPane.devices,
  };

  /// The content of one settings pane, wrapped in the theme slot it belongs
  /// to. [split] is the wide layout, where the account card heads the
  /// account pane (a phone shows it on the hub instead).
  Widget _paneBody(_SettingsPane pane, {required bool split}) {
    final body = SettingsRefreshScope(
      registry: _refresh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _paneSections(pane, split: split),
      ),
    );
    final slot = switch (pane) {
      _SettingsPane.appearance => FeatureSlots.settingsAppearance,
      _SettingsPane.profile => FeatureSlots.settingsAccount,
      _SettingsPane.notifications => FeatureSlots.settingsNotifications,
      _SettingsPane.privacy ||
      _SettingsPane.devices ||
      _SettingsPane.storage ||
      _SettingsPane.about => FeatureSlots.settingsAdvanced,
      _ => null,
    };
    return slot == null ? body : ThemeSlotHost(slot: slot, child: body);
  }

  List<Widget> _paneSections(_SettingsPane pane, {required bool split}) {
    final deps = widget.dependencies;
    final settings = AppSettingsScope.of(context);
    final scheme = Theme.of(context).colorScheme;

    switch (pane) {
      case _SettingsPane.account:
        return [
          if (split) ...[
            _AccountCard(dependencies: deps),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (deps != null)
            AccountPanel(
              dependencies: deps,
              area: AccountArea.account,
              embedded: true,
            )
          else
            const SettingsGroup(
              children: [
                SettingsEmpty(
                  icon: Icons.account_circle_outlined,
                  title: 'Signed out',
                  message: 'Sign in to manage your account.',
                ),
              ],
            ),
        ];

      case _SettingsPane.appearance:
        final textSize = _textSizes.keys.reduce(
          (a, b) => (a - textScale).abs() <= (b - textScale).abs() ? a : b,
        );
        final packs = ThemePackScope.maybeOf(context);
        final active = packs?.pack.id ?? DefaultThemePacks.kashiId;
        final pack = packs?.pack ?? DefaultThemePacks.kashi;
        final selected = pack.resolvePalette(
          paletteId: settings.paletteId,
          accent: settings.accent,
        );
        return [
          SettingsCard(
            caption: 'Mode',
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    icon: Icon(Icons.brightness_auto_outlined),
                    label: Text('System'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    icon: Icon(Icons.light_mode_outlined),
                    label: Text('Light'),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    icon: Icon(Icons.dark_mode_outlined),
                    label: Text('Dark'),
                  ),
                ],
                selected: {settings.themeMode},
                onSelectionChanged: (value) =>
                    settings.setThemeMode(value.first),
              ),
            ),
          ),
          SettingsCard(
            caption: 'Theme pack',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final p in DefaultThemePacks.all)
                      ChoiceChip(
                        label: Text(p.meta.name),
                        selected: active == p.id,
                        onSelected: packs == null
                            ? null
                            : (_) {
                                packs.applyBuiltin(p.id);
                                settings.syncPaletteToPack(p);
                              },
                      ),
                  ],
                ),
                if (deps != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => showBotsStore(context, deps),
                      icon: const Icon(Icons.storefront_outlined),
                      label: const Text('Browse themes in Store'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SettingsCard(
            caption: '${pack.meta.name} colour',
            child: Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final option in pack.selectablePalettes)
                  _AccentChoice(
                    color: option
                        .forBrightness(Theme.of(context).brightness)
                        .accent,
                    label: option.label,
                    selected: selected.id == option.id,
                    onTap: () => settings.setPalette(option),
                  ),
              ],
            ),
          ),
          SettingsCard(
            caption: 'Text size',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'The quick brown fox jumps over the lazy dog.',
                  textScaler: TextScaler.linear(textSize),
                  style: TextStyle(height: 1.3, color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                SegmentedButton<double>(
                  showSelectedIcon: false,
                  segments: [
                    for (final e in _textSizes.entries)
                      ButtonSegment(
                        value: e.key,
                        label: Text(
                          e.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  selected: {textSize},
                  onSelectionChanged: (v) {
                    setState(() => textScale = v.first);
                    _save('textScale', v.first);
                  },
                ),
              ],
            ),
          ),
          SettingsGroup(
            caption: 'Motion & numbers',
            children: [
              _SwitchTile(
                icon: Icons.animation_rounded,
                title: 'Reduce motion',
                subtitle: 'Use simpler interface transitions',
                value: reducedMotion,
                onChanged: (v) =>
                    _toggle((x) => reducedMotion = x, v, 'reducedMotion'),
              ),
              _SwitchTile(
                icon: Icons.onetwothree_rounded,
                title: 'Compact numbers',
                subtitle: 'Show 1.2K instead of 1,200',
                value: compactNumbers,
                onChanged: (v) =>
                    _toggle((x) => compactNumbers = x, v, 'compactNumbers'),
              ),
            ],
          ),
        ];

      case _SettingsPane.profile:
        if (deps == null) return const [];
        return [UserProfileSheet(dependencies: deps, embedded: true)];

      case _SettingsPane.wallet:
        if (deps == null) return const [];
        return [
          AccountPanel(
            dependencies: deps,
            area: AccountArea.wallet,
            embedded: true,
          ),
        ];

      case _SettingsPane.assistant:
        if (deps == null) return const [];
        return [SetupPanel(dependencies: deps, embedded: true)];

      case _SettingsPane.approvals:
        if (deps == null) return const [];
        return [ApprovalsPanel(dependencies: deps, embedded: true)];

      case _SettingsPane.connections:
        if (deps == null) return const [];
        return [
          ConnectionsPanel(dependencies: deps, embedded: true),
          const SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.apps_outlined,
                title: 'Connected apps',
                subtitle: 'Services, apps and wallets',
              ),
            ],
          ),
        ];

      case _SettingsPane.agents:
        return [
          SettingsGroup(
            caption: 'Safety',
            footer: 'Agents always ask first when a rule here says so.',
            children: [
              _SwitchTile(
                icon: Icons.fact_check_outlined,
                title: 'Confirm sensitive actions',
                subtitle: 'Ask before an agent takes a sensitive action',
                value: tradeConfirmations,
                onChanged: (v) => _toggle(
                  (x) => tradeConfirmations = x,
                  v,
                  'tradeConfirmations',
                ),
              ),
              _SwitchTile(
                icon: Icons.admin_panel_settings_outlined,
                title: 'Approve new permissions',
                subtitle: 'Ask before an agent gets a new capability',
                value: agentApprovals,
                onChanged: (v) =>
                    _toggle((x) => agentApprovals = x, v, 'agentApprovals'),
              ),
            ],
          ),
          SettingsGroup(
            caption: 'Defaults',
            children: [
              SettingsChoiceRow<String>(
                icon: Icons.payments_outlined,
                label: 'Currency',
                value: currency,
                choices: const [
                  AppChoice('USD', 'USD \$'),
                  AppChoice('EUR', 'EUR €'),
                  AppChoice('GBP', 'GBP £'),
                  AppChoice('JPY', 'JPY ¥'),
                ],
                onChanged: (v) => _choose((x) => currency = x, v, 'currency'),
              ),
              SettingsChoiceRow<String>(
                icon: Icons.public,
                label: 'Region',
                value: region,
                choices: const [
                  AppChoice('Global', 'Global', icon: Icons.public),
                  AppChoice('US', 'United States'),
                  AppChoice('EU', 'Europe'),
                  AppChoice('Asia', 'Asia'),
                  AppChoice('Other', 'Other'),
                ],
                onChanged: (v) => _choose((x) => region = x, v, 'region'),
              ),
            ],
          ),
          const SettingsGroup(
            caption: 'Limits',
            children: [
              _SettingsTile(
                icon: Icons.shield_outlined,
                title: 'Agent limits',
                subtitle: 'Spending caps and allowed action defaults',
              ),
            ],
          ),
        ];

      case _SettingsPane.notifications:
        return [
          if (deps != null)
            NotifyPrefsPanel(dependencies: deps, embedded: true),
          SettingsGroup(
            caption: 'Alerts',
            children: [
              _SwitchTile(
                icon: Icons.notifications_active_outlined,
                title: 'Agent and workspace alerts',
                subtitle: 'Updates from agents and shared workspaces',
                value: priceAlerts,
                onChanged: (v) =>
                    _toggle((x) => priceAlerts = x, v, 'priceAlerts'),
              ),
              _SwitchTile(
                icon: Icons.forum_outlined,
                title: 'Social and room activity',
                subtitle: 'Replies, mentions and room messages',
                value: socialNotifications,
                onChanged: (v) => _toggle(
                  (x) => socialNotifications = x,
                  v,
                  'socialNotifications',
                ),
              ),
            ],
          ),
          SettingsGroup(
            caption: 'Do not disturb',
            footer: 'No notifications during these hours.',
            children: [
              SettingsChoiceRow<String>(
                icon: Icons.bedtime_outlined,
                label: 'Quiet hours',
                value: quietHours,
                choices: const [
                  AppChoice('Off', 'Off'),
                  AppChoice('22:00–08:00', '22:00 – 08:00'),
                  AppChoice('23:00–07:00', '23:00 – 07:00'),
                  AppChoice('00:00–06:00', '00:00 – 06:00'),
                ],
                onChanged: (v) =>
                    _choose((x) => quietHours = x, v, 'quietHours'),
              ),
            ],
          ),
        ];

      case _SettingsPane.privacy:
        return [
          if (deps != null)
            PrivacySettingsPanel(dependencies: deps, embedded: true),
          SettingsGroup(
            caption: 'Security',
            children: [
              _SwitchTile(
                icon: Icons.fingerprint_rounded,
                title: 'Biometric unlock',
                subtitle: 'Use fingerprint or face to open Aseman',
                value: biometrics,
                onChanged: (v) =>
                    _toggle((x) => biometrics = x, v, 'biometrics'),
              ),
              const _SettingsTile(
                icon: Icons.key_outlined,
                title: 'Passkeys and two-factor',
              ),
            ],
          ),
          SettingsGroup(
            caption: 'Your data',
            children: [
              _SwitchTile(
                icon: Icons.insights_rounded,
                title: 'Share anonymous analytics',
                subtitle: 'Helps improve Aseman. Never includes your content',
                value: analytics,
                onChanged: (v) => _toggle((x) => analytics = x, v, 'analytics'),
              ),
              const _SettingsTile(
                icon: Icons.download_outlined,
                title: 'Export your data',
              ),
            ],
          ),
        ];

      case _SettingsPane.devices:
        if (deps == null) return const [];
        return [DevicesPanel(dependencies: deps, embedded: true)];

      case _SettingsPane.storage:
        return [
          SettingsGroup(
            caption: 'Media',
            footer: 'Applies to photos and videos you upload.',
            children: [
              SettingsChoiceRow<String>(
                icon: Icons.high_quality_outlined,
                label: 'Upload quality',
                value: mediaQuality,
                choices: const [
                  AppChoice(
                    'Automatic',
                    'Automatic',
                    icon: Icons.auto_mode_rounded,
                    hint: 'Balances quality and data use',
                  ),
                  AppChoice(
                    'Original',
                    'Original',
                    icon: Icons.photo_size_select_actual_outlined,
                    hint: 'Full size, uses the most data',
                  ),
                  AppChoice(
                    'Data saver',
                    'Data saver',
                    icon: Icons.data_saver_on_rounded,
                    hint: 'Smaller files, faster uploads',
                  ),
                ],
                onChanged: (v) =>
                    _choose((x) => mediaQuality = x, v, 'mediaQuality'),
              ),
            ],
          ),
          SettingsGroup(
            caption: 'On this device',
            footer: 'Clears saved drafts and cached data. You stay signed in.',
            children: [
              _SettingsTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear local cache',
                subtitle: 'Uses $_cacheSize',
                onTap: _confirmClearCache,
              ),
            ],
          ),
        ];

      case _SettingsPane.about:
        final body = TextStyle(height: 1.5, color: scheme.onSurfaceVariant);
        return [
          SettingsCard(
            caption: 'Pricing',
            child: Text(pricingBlurb, style: body),
          ),
          SettingsCard(
            caption: 'How it works',
            child: Text(howItWorksBlurb, style: body),
          ),
        ];

      case _SettingsPane.admin:
        if (deps == null || !deps.sessionController.isAdmin) return const [];
        return [
          SettingsGroup(
            footer: 'People, rooms, money and the node.',
            children: [
              QuietTile(
                icon: Icons.space_dashboard_outlined,
                label: 'Open admin console',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AdminScreen(dependencies: deps),
                  ),
                ),
              ),
            ],
          ),
        ];
    }
  }
}

class _SettingsNav extends StatelessWidget {
  const _SettingsNav({
    required this.selected,
    required this.showSignedIn,
    required this.showAdmin,
    required this.onSelect,
  });

  final _SettingsPane selected;
  final bool showSignedIn;
  final bool showAdmin;
  final ValueChanged<_SettingsPane> onSelect;

  static const _items =
      <({_SettingsPane pane, String label, IconData icon, bool signedIn})>[
        (
          pane: _SettingsPane.account,
          label: 'Account',
          icon: Icons.account_circle_outlined,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.profile,
          label: 'Profile',
          icon: Icons.person_outline,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.appearance,
          label: 'Appearance',
          icon: Icons.palette_outlined,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.wallet,
          label: 'Wallet',
          icon: Icons.account_balance_wallet_outlined,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.assistant,
          label: 'Setup',
          icon: Icons.checklist_rounded,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.approvals,
          label: 'Approvals',
          icon: Icons.verified_user_outlined,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.connections,
          label: 'Connections',
          icon: Icons.hub_outlined,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.agents,
          label: 'Agents',
          icon: Icons.smart_toy_outlined,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.notifications,
          label: 'Notifications',
          icon: Icons.notifications_none_rounded,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.privacy,
          label: 'Privacy',
          icon: Icons.lock_outline_rounded,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.devices,
          label: 'Devices',
          icon: Icons.devices_outlined,
          signedIn: true,
        ),
        (
          pane: _SettingsPane.storage,
          label: 'Storage',
          icon: Icons.storage_outlined,
          signedIn: false,
        ),
        (
          pane: _SettingsPane.about,
          label: 'About',
          icon: Icons.info_outline_rounded,
          signedIn: false,
        ),
      ];

  /// The title a pane carries on its phone page.
  static String labelOf(_SettingsPane pane) => switch (pane) {
    _SettingsPane.account => 'Account & sign-in',
    _SettingsPane.agents => 'Agents & actions',
    _SettingsPane.privacy => 'Privacy & security',
    _SettingsPane.storage => 'Storage & data',
    _SettingsPane.about => 'About Aseman',
    _SettingsPane.admin => 'Admin console',
    _ => _items.firstWhere((i) => i.pane == pane).label,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
          child: Text(
            'Settings',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        for (final item in _items)
          if (!item.signedIn || showSignedIn)
            ListTile(
              selected: selected == item.pane,
              selectedTileColor: scheme.secondaryContainer,
              shape: const StadiumBorder(),
              leading: Icon(item.icon),
              title: Text(item.label),
              onTap: () => onSelect(item.pane),
            ),
        if (showAdmin)
          ListTile(
            selected: selected == _SettingsPane.admin,
            selectedTileColor: scheme.secondaryContainer,
            shape: const StadiumBorder(),
            leading: const Icon(Icons.space_dashboard_outlined),
            title: const Text('Admin'),
            onTap: () => onSelect(_SettingsPane.admin),
          ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({this.dependencies});
  final AppDependencies? dependencies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = dependencies?.sessionController.session;
    final handle = session?.handle ?? 'me';
    final accountId = session?.accountId ?? '';
    final initials = handle.isEmpty
        ? 'ME'
        : handle.substring(0, 1).toUpperCase();
    final Widget avatar = dependencies == null
        ? Builder(
            builder: (context) {
              const size = 60.0;
              final corners = context.avatarBorderRadius(size);
              return HaloRing(
                accent: scheme.primary,
                borderRadius: corners,
                child: AvatarFace(
                  size: size,
                  borderRadius: corners,
                  backgroundColor: scheme.primary,
                  child: Text(
                    initials,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimary,
                    ),
                  ),
                ),
              );
            },
          )
        : AvatarEditor(
            service: dependencies!.service,
            avatar: dependencies!.sessionController.avatar,
            initials: initials,
            filled: true,
            subject: 'profile picture',
            enabled: accountId.isNotEmpty,
            identity: accountId,
            onChanged: dependencies!.sessionController.setAvatar,
          );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '@$handle',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 20,
            letterSpacing: -.3,
            fontWeight: FontWeight.w900,
            color: scheme.onSurface,
          ),
        ),
        Text(
          accountId.isEmpty ? 'Signed out' : shortAccountId(accountId),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
    return SoftCard(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: AppSpacing.md),
          Expanded(child: identity),
        ],
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => QuietSwitchTile(
    icon: icon,
    label: title,
    subtitle: subtitle,
    value: value,
    onChanged: onChanged,
  );
}

/// A row that opens a related screen. Without [onTap] it is not available
/// yet, and says so instead of doing nothing when tapped.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return QuietTile(
      icon: icon,
      label: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: onTap == null
          ? SoftMetaChip(label: 'Soon', accent: scheme.onSurfaceVariant)
          : null,
    );
  }
}

class _AccentChoice extends StatelessWidget {
  const _AccentChoice({
    required this.color,
    required this.selected,
    required this.onTap,
    this.label,
  });
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final onAccent = color.computeLuminance() > 0.45
        ? Colors.black87
        : Colors.white;
    return Tooltip(
      message: label ?? '',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.onSurface
                  : Colors.transparent,
              width: 3,
            ),
          ),
          child: selected ? Icon(Icons.check_rounded, color: onAccent) : null,
        ),
      ),
    );
  }
}
