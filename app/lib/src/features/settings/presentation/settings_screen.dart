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
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar_editor.dart';
import '../../../shared/widgets/avatar_face.dart';
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

  bool _show(_SettingsPane pane, bool split) => !split || _pane == pane;

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

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final windowClass = AppWindowClass.fromWidth(width);
    final textSize = _textSizes.keys.reduce(
      (a, b) => (a - textScale).abs() <= (b - textScale).abs() ? a : b,
    );
    // Below the large class, keep one centered column. Large and wider use
    // a section list beside the active section.
    final split = AppWindowScope.supportingPane(context);
    final side = split
        ? AppLayout.gutterWidth
        : math.max(windowClass.margin, (width - 840) / 2);
    final scheme = Theme.of(context).colorScheme;
    final isAdmin = widget.dependencies?.sessionController.isAdmin ?? false;
    final page = Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          if (!split)
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  side,
                  AppSpacing.md,
                  side,
                  AppSpacing.sm,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (Navigator.of(context).canPop()) ...[
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                    ],
                    const Expanded(
                      child: SkySectionHeader(
                        icon: Icons.settings_rounded,
                        title: 'Settings',
                        subtitle: 'Appearance, account and how Aseman behaves',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              side,
              AppSpacing.xxs,
              side,
              AppSpacing.xl,
            ),
            sliver: SliverList.list(
              children: [
                if (_show(_SettingsPane.account, split)) ...[
                  _AccountCard(dependencies: widget.dependencies),
                  if (widget.dependencies != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _Section(
                      title: 'Sign-in',
                      icon: Icons.security_outlined,
                      children: [
                        AccountPanel(
                          dependencies: widget.dependencies!,
                          area: AccountArea.account,
                          embedded: true,
                        ),
                      ],
                    ),
                  ],
                ],
                if (_show(_SettingsPane.appearance, split))
                ThemeSlotHost(
                  slot: FeatureSlots.settingsAppearance,
                  child: _Section(
                    title: 'Appearance',
                    icon: Icons.palette_outlined,
                    children: [
                      const _Label('Theme pack'),
                      Builder(
                        builder: (context) {
                          final packs = ThemePackScope.maybeOf(context);
                          final active =
                              packs?.pack.id ?? DefaultThemePacks.paperId;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: [
                                  for (final pack in DefaultThemePacks.all)
                                    ChoiceChip(
                                      label: Text(pack.meta.name),
                                      selected: active == pack.id,
                                      onSelected: packs == null
                                          ? null
                                          : (_) {
                                              packs.applyBuiltin(pack.id);
                                              settings.syncPaletteToPack(pack);
                                            },
                                    ),
                                ],
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              if (widget.dependencies != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    onPressed: () => showBotsStore(
                                      context,
                                      widget.dependencies!,
                                    ),
                                    icon: const Icon(Icons.storefront_outlined),
                                    label: const Text('Browse themes in Store'),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      const _Label('Light / dark'),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<ThemeMode>(
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
                      const SizedBox(height: AppSpacing.lg),
                      Builder(
                        builder: (context) {
                          final packs = ThemePackScope.maybeOf(context);
                          final pack = packs?.pack ?? DefaultThemePacks.paper;
                          final options = pack.selectablePalettes;
                          final selected = pack.resolvePalette(
                            paletteId: settings.paletteId,
                            accent: settings.accent,
                          );
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _Label('${pack.meta.name} palette'),
                              const SizedBox(height: AppSpacing.sm),
                              Wrap(
                                spacing: AppSpacing.sm,
                                runSpacing: AppSpacing.sm,
                                children: [
                                  for (final option in options)
                                    _AccentChoice(
                                      color: option.accent,
                                      label: option.label,
                                      selected: selected.id == option.id,
                                      onTap: () => settings.setPalette(option),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        children: [
                          const Expanded(child: _Label('Text size')),
                          Text(
                            'Aa',
                            textScaler: TextScaler.linear(textSize),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: SegmentedButton<double>(
                          showSelectedIcon: false,
                          segments: [
                            for (final e in _textSizes.entries)
                              ButtonSegment(value: e.key, label: Text(e.value)),
                          ],
                          selected: {textSize},
                          onSelectionChanged: (v) {
                            setState(() => textScale = v.first);
                            _save('textScale', v.first);
                          },
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm + 2),
                      _SwitchTile(
                        icon: Icons.animation_rounded,
                        title: 'Reduce motion',
                        subtitle: 'Use simpler interface transitions',
                        value: reducedMotion,
                        onChanged: (v) => _toggle(
                          (x) => reducedMotion = x,
                          v,
                          'reducedMotion',
                        ),
                      ),
                      _SwitchTile(
                        icon: Icons.onetwothree_rounded,
                        title: 'Compact numbers',
                        subtitle: 'Show 1.2K instead of 1,200',
                        value: compactNumbers,
                        onChanged: (v) => _toggle(
                          (x) => compactNumbers = x,
                          v,
                          'compactNumbers',
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.dependencies != null &&
                    _show(_SettingsPane.profile, split))
                  ThemeSlotHost(
                    slot: FeatureSlots.settingsAccount,
                    child: _Section(
                    title: 'Profile',
                    icon: Icons.person_outline,
                    children: [
                      UserProfileSheet(
                        dependencies: widget.dependencies!,
                        embedded: true,
                      ),
                    ],
                  ),
                  ),
                if (widget.dependencies != null &&
                    _show(_SettingsPane.wallet, split))
                  _Section(
                    title: 'Wallet',
                    icon: Icons.account_balance_wallet_outlined,
                    children: [
                      AccountPanel(
                        dependencies: widget.dependencies!,
                        area: AccountArea.wallet,
                        embedded: true,
                      ),
                    ],
                  ),
                if (widget.dependencies != null &&
                    _show(_SettingsPane.assistant, split))
                  _Section(
                    title: 'Setup',
                    icon: Icons.checklist_rounded,
                    children: [
                      SetupPanel(
                        dependencies: widget.dependencies!,
                        embedded: true,
                      ),
                    ],
                  ),
                if (widget.dependencies != null &&
                    _show(_SettingsPane.approvals, split))
                  _Section(
                    title: 'Approvals',
                    icon: Icons.verified_user_outlined,
                    children: [
                      ApprovalsPanel(
                        dependencies: widget.dependencies!,
                        embedded: true,
                      ),
                    ],
                  ),
                if (widget.dependencies != null &&
                    _show(_SettingsPane.connections, split))
                  _Section(
                    title: 'Connections',
                    icon: Icons.hub_outlined,
                    children: [
                      ConnectionsPanel(
                        dependencies: widget.dependencies!,
                        embedded: true,
                      ),
                      const _SettingsTile(
                        icon: Icons.apps_outlined,
                        title: 'Connected apps',
                        subtitle: 'Services, apps and wallets',
                      ),
                    ],
                  ),
                if (_show(_SettingsPane.agents, split))
                _Section(
                  title: 'Agents & actions',
                  icon: Icons.smart_toy_outlined,
                  children: [
                    _SwitchTile(
                      icon: Icons.fact_check_outlined,
                      title: 'Confirm sensitive actions',
                      subtitle:
                          'Require confirmation before an agent takes a sensitive action',
                      value: tradeConfirmations,
                      onChanged: (v) => _toggle(
                        (x) => tradeConfirmations = x,
                        v,
                        'tradeConfirmations',
                      ),
                    ),
                    _SwitchTile(
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Approve new agent permissions',
                      subtitle: 'Ask before an agent gets a new capability',
                      value: agentApprovals,
                      onChanged: (v) => _toggle(
                        (x) => agentApprovals = x,
                        v,
                        'agentApprovals',
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppChoiceField<String>(
                      label: 'Default currency',
                      value: currency,
                      choices: const [
                        AppChoice('USD', 'USD \$'),
                        AppChoice('EUR', 'EUR €'),
                        AppChoice('GBP', 'GBP £'),
                        AppChoice('JPY', 'JPY ¥'),
                      ],
                      onChanged: (v) =>
                          _choose((x) => currency = x, v, 'currency'),
                    ),
                    const SizedBox(height: 18),
                    AppChoiceField<String>(
                      label: 'Region',
                      value: region,
                      choices: const [
                        AppChoice('Global', 'Global', icon: Icons.public),
                        AppChoice('US', 'US'),
                        AppChoice('EU', 'EU'),
                        AppChoice('Asia', 'Asia'),
                        AppChoice('Other', 'Other'),
                      ],
                      onChanged: (v) => _choose((x) => region = x, v, 'region'),
                    ),
                    const SizedBox(height: 8),
                    const _SettingsTile(
                      icon: Icons.shield_outlined,
                      title: 'Agent limits',
                      subtitle: 'Spending caps and allowed action defaults',
                    ),
                  ],
                ),
                if (_show(_SettingsPane.notifications, split))
                ThemeSlotHost(
                  slot: FeatureSlots.settingsNotifications,
                  child: _Section(
                    title: 'Notifications',
                    icon: Icons.notifications_none_rounded,
                    children: [
                      if (widget.dependencies != null)
                        NotifyPrefsPanel(
                          dependencies: widget.dependencies!,
                          embedded: true,
                        ),
                      _SwitchTile(
                        icon: Icons.notifications_active_outlined,
                        title: 'Agent and workspace alerts',
                        value: priceAlerts,
                        onChanged: (v) =>
                            _toggle((x) => priceAlerts = x, v, 'priceAlerts'),
                      ),
                      _SwitchTile(
                        icon: Icons.forum_outlined,
                        title: 'Social and room activity',
                        value: socialNotifications,
                        onChanged: (v) => _toggle(
                          (x) => socialNotifications = x,
                          v,
                          'socialNotifications',
                        ),
                      ),
                      const SizedBox(height: 12),
                      AppChoiceField<String>(
                        label: 'Quiet hours',
                        hint: 'No notifications during these hours.',
                        value: quietHours,
                        choices: const [
                          AppChoice(
                            'Off',
                            'Off',
                            icon: Icons.notifications_active_outlined,
                          ),
                          AppChoice('22:00–08:00', '22:00 – 08:00'),
                          AppChoice('23:00–07:00', '23:00 – 07:00'),
                          AppChoice('00:00–06:00', '00:00 – 06:00'),
                        ],
                        onChanged: (v) =>
                            _choose((x) => quietHours = x, v, 'quietHours'),
                      ),
                    ],
                  ),
                ),
                if (_show(_SettingsPane.privacy, split) ||
                    _show(_SettingsPane.devices, split) ||
                    _show(_SettingsPane.storage, split) ||
                    _show(_SettingsPane.about, split))
                ThemeSlotHost(
                  slot: FeatureSlots.settingsAdvanced,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_show(_SettingsPane.privacy, split))
                      _Section(
                        title: 'Privacy',
                        icon: Icons.lock_outline_rounded,
                        children: [
                          if (widget.dependencies != null)
                            PrivacySettingsPanel(
                              dependencies: widget.dependencies!,
                              embedded: true,
                            ),
                          _SwitchTile(
                            icon: Icons.fingerprint_rounded,
                            title: 'Biometric unlock',
                            value: biometrics,
                            onChanged: (v) =>
                                _toggle((x) => biometrics = x, v, 'biometrics'),
                          ),
                          _SwitchTile(
                            icon: Icons.insights_rounded,
                            title: 'Share anonymous analytics',
                            value: analytics,
                            onChanged: (v) =>
                                _toggle((x) => analytics = x, v, 'analytics'),
                          ),
                          const _SettingsTile(
                            icon: Icons.key_outlined,
                            title: 'Passkeys and two-factor authentication',
                          ),
                          const _SettingsTile(
                            icon: Icons.download_outlined,
                            title: 'Export your data',
                          ),
                        ],
                      ),
                      if (widget.dependencies != null &&
                          _show(_SettingsPane.devices, split))
                      _Section(
                        title: 'Devices',
                        icon: Icons.devices_outlined,
                        children: [
                          DevicesPanel(
                            dependencies: widget.dependencies!,
                            embedded: true,
                          ),
                        ],
                      ),
                      if (_show(_SettingsPane.storage, split))
                      _Section(
                        title: 'Storage & data',
                        icon: Icons.storage_outlined,
                        children: [
                          AppChoiceField<String>(
                            label: 'Media upload quality',
                            value: mediaQuality,
                            choices: const [
                              AppChoice(
                                'Automatic',
                                'Automatic',
                                icon: Icons.auto_mode_rounded,
                              ),
                              AppChoice('Original', 'Original'),
                              AppChoice('Data saver', 'Data saver'),
                            ],
                            onChanged: (v) => _choose(
                              (x) => mediaQuality = x,
                              v,
                              'mediaQuality',
                            ),
                          ),
                          const SizedBox(height: 8),
                          _SettingsTile(
                            icon: Icons.cleaning_services_outlined,
                            title: 'Clear local cache',
                            subtitle: 'Uses $_cacheSize on this device',
                            onTap: _confirmClearCache,
                          ),
                        ],
                      ),
                      if (_show(_SettingsPane.about, split))
                      const _Section(
                        title: 'About',
                        icon: Icons.info_outline_rounded,
                        children: [
                          const _Label('Pricing'),
                          const Text(
                            pricingBlurb,
                            style: TextStyle(height: 1.45),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          const _Label('How it works'),
                          const Text(
                            howItWorksBlurb,
                            style: TextStyle(height: 1.45),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isAdmin && _show(_SettingsPane.admin, split))
                  _Section(
                    title: 'Admin',
                    icon: Icons.space_dashboard_outlined,
                    children: [
                      const Text(
                        'People, rooms, money and the node.',
                        style: TextStyle(height: 1.45),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      FilledButton.icon(
                        onPressed: widget.dependencies == null
                            ? null
                            : () {
                                final deps = widget.dependencies!;
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        AdminScreen(dependencies: deps),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.space_dashboard_outlined),
                        label: const Text('Open admin console'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (!split) return page;
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
          accountId.isEmpty ? 'Signed out' : accountId,
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

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SoftCard(
        radius: AppShape.card,
        showOrb: false,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg - 2,
          AppSpacing.md,
          AppSpacing.lg - 2,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SkyIconBadge(icon: icon, size: 40),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -.4,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm - 2),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
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
