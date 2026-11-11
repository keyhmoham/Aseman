import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app_dependencies.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/default_theme_packs.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_pack_controller.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar_editor.dart';
import '../../../shared/widgets/avatar_face.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/theme_slot_host.dart';
import '../../../shared/widgets/user_profile_sheet.dart';
import '../../account/presentation/account_panel.dart';
import '../../assistant/assistant.dart';
import '../../market/presentation/bots_store_screen.dart';
import '../../marketing/marketing_links.dart';
import 'widgets/notify_prefs_panel.dart';
import 'widgets/privacy_settings_panel.dart';

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

  /// Opens one of the account panels.
  void _openAccount(AccountArea area) {
    final deps = widget.dependencies;
    if (deps == null) return;
    showAccountPanel(context, deps, area);
  }

  void _openAssistant(Widget Function(AppDependencies deps) panel) {
    final deps = widget.dependencies;
    if (deps == null) return;
    openPanel(context, panel(deps));
  }

  void _openProfile() {
    final deps = widget.dependencies;
    if (deps == null) return;
    showFloatingPanel(
      context,
      UserProfileSheet(dependencies: deps),
      maxWidth: 760,
    );
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
    final wide = MediaQuery.sizeOf(context).width > 900;
    final textSize = _textSizes.keys.reduce(
      (a, b) => (a - textScale).abs() <= (b - textScale).abs() ? a : b,
    );
    final side = wide ? 80.0 : AppSpacing.md;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    side, AppSpacing.md, side, AppSpacing.sm),
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
                        subtitle:
                            'Appearance, account and how Aseman behaves',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
                side, AppSpacing.xxs, side, AppSpacing.xl),
            sliver: SliverList.list(
              children: [
                  _AccountCard(
                    dependencies: widget.dependencies,
                    onProfile: _openProfile,
                    onManage: () => _openAccount(AccountArea.account),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ThemeSlotHost(
                    slot: FeatureSlots.settingsAppearance,
                    child: _Section(
                    title: 'Appearance',
                    icon: Icons.palette_outlined,
                    children: [
                      const _Label('Theme pack'),
                      Builder(builder: (context) {
                        final packs = ThemePackScope.maybeOf(context);
                        final active = packs?.pack.id ?? DefaultThemePacks.skyId;
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
                      }),
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
                      Builder(builder: (context) {
                        final packs = ThemePackScope.maybeOf(context);
                        final pack =
                            packs?.pack ?? DefaultThemePacks.sky;
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
                      }),
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
                      onChanged: (v) =>
                          _toggle((x) => reducedMotion = x, v, 'reducedMotion'),
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
                ThemeSlotHost(
                  slot: FeatureSlots.settingsAccount,
                  child: _Section(
                  title: 'Account & identity',
                  icon: Icons.manage_accounts_outlined,
                  children: [
                    _SettingsTile(
                      icon: Icons.person_outline,
                      title: 'Profile information',
                      subtitle: 'Name, username, bio and profile media',
                      onTap: _openProfile,
                    ),
                    _SettingsTile(
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Wallet',
                      subtitle: 'Balance, top-ups, purchases and project usage',
                      onTap: () => _openAccount(AccountArea.wallet),
                    ),
                    const _SettingsTile(
                      icon: Icons.apps_outlined,
                      title: 'Connected apps',
                      subtitle: 'Services, apps and wallets',
                    ),
                  ],
                ),
                ),
                if (widget.dependencies != null)
                  _Section(
                    title: 'Your assistant',
                    icon: Icons.auto_awesome_outlined,
                    children: [
                      _SettingsTile(
                        icon: Icons.checklist_rounded,
                        title: 'Setup checklist',
                        subtitle:
                            'Accounts, notifications and what your assistant still needs',
                        onTap: () => _openAssistant(
                          (deps) => SetupPanel(dependencies: deps),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.verified_user_outlined,
                        title: 'What agents may always do',
                        subtitle: 'The actions you always allowed, to revoke',
                        onTap: () => _openAssistant(
                          (deps) => ApprovalsPanel(dependencies: deps),
                        ),
                      ),
                      _SettingsTile(
                        icon: Icons.hub_outlined,
                        title: 'Connections',
                        subtitle: 'Slack, Teams, SMS, and what runs on its own',
                        onTap: () => _openAssistant(
                          (deps) => ConnectionsPanel(dependencies: deps),
                        ),
                      ),
                    ],
                  ),
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
                ThemeSlotHost(
                  slot: FeatureSlots.settingsNotifications,
                  child: _Section(
                  title: 'Notifications',
                  icon: Icons.notifications_none_rounded,
                  children: [
                    if (widget.dependencies != null)
                      _SettingsTile(
                        icon: Icons.tune_rounded,
                        title: 'Notification preferences',
                        subtitle: 'Rooms, chats, calls and invites',
                        onTap: () =>
                            showNotifyPrefs(context, widget.dependencies!),
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
                    const SizedBox(height: 8),
                    _SettingsTile(
                      icon: Icons.notifications_active_outlined,
                      title: 'Push notifications on this device',
                      subtitle: 'Turn device notifications on or off',
                      onTap: () => _openAccount(AccountArea.account),
                    ),
                  ],
                ),
                ),
                ThemeSlotHost(
                  slot: FeatureSlots.settingsAdvanced,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                _Section(
                  title: 'Privacy & security',
                  icon: Icons.lock_outline_rounded,
                  children: [
                    if (widget.dependencies != null)
                      _SettingsTile(
                        icon: Icons.privacy_tip_outlined,
                        title: 'Who may contact you',
                        subtitle:
                            'Messages, voice calls, video calls and invites',
                        onTap: () => showPrivacySettings(
                            context, widget.dependencies!),
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
                    _SettingsTile(
                      icon: Icons.password_rounded,
                      title: 'Password and sign-in',
                      subtitle: 'Change your password, username and email',
                      onTap: () => _openAccount(AccountArea.account),
                    ),
                    const _SettingsTile(
                      icon: Icons.key_outlined,
                      title: 'Passkeys and two-factor authentication',
                    ),
                    const _SettingsTile(
                      icon: Icons.devices_outlined,
                      title: 'Active sessions',
                      subtitle: 'Review devices signed into your account',
                    ),
                    const _SettingsTile(
                      icon: Icons.download_outlined,
                      title: 'Export your data',
                    ),
                  ],
                ),
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
                      onChanged: (v) =>
                          _choose((x) => mediaQuality = x, v, 'mediaQuality'),
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
                  _Section(
                    title: 'About',
                    icon: Icons.info_outline_rounded,
                    children: [
                      _SettingsTile(
                        icon: Icons.payments_outlined,
                        title: 'Pricing',
                        subtitle: 'Credits and how billing works',
                        onTap: () => showMarketingPage(context,
                            title: 'Pricing', body: pricingBlurb),
                      ),
                      _SettingsTile(
                        icon: Icons.route_outlined,
                        title: 'How it works',
                        subtitle: 'Projects, agents and Aseman',
                        onTap: () => showMarketingPage(context,
                            title: 'How it works', body: howItWorksBlurb),
                      ),
                    ],
                  ),
                    ],
                  ),
                ),
                ],
              ),
            ),
          ],
        ),
    );
  }

}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    this.dependencies,
    required this.onProfile,
    required this.onManage,
  });
  final AppDependencies? dependencies;
  final VoidCallback onProfile;
  final VoidCallback onManage;

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
        ? Builder(builder: (context) {
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
          })
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
    final actions = Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      alignment: WrapAlignment.end,
      children: [
        OutlinedButton(
          onPressed: dependencies == null ? null : onProfile,
          child: const Text('Profile'),
        ),
        FilledButton(
          onPressed: dependencies == null ? null : onManage,
          child: const Text('Account'),
        ),
      ],
    );
    return SoftCard(
      padding: const EdgeInsets.all(20),
      // A narrow card (a phone) puts the buttons under the name: beside it
      // they cannot wrap and would push past the card's edge.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 420;
          final header = Row(
            children: [
              avatar,
              const SizedBox(width: AppSpacing.md),
              Expanded(child: identity),
              if (!narrow) ...[const SizedBox(width: AppSpacing.xs), actions],
            ],
          );
          if (!narrow) return header;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: AppSpacing.md),
              Align(alignment: AlignmentDirectional.centerEnd, child: actions),
            ],
          );
        },
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
            AppSpacing.lg - 2, AppSpacing.md, AppSpacing.lg - 2, AppSpacing.md),
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
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
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
          ? SoftMetaChip(
              label: 'Soon',
              accent: scheme.onSurfaceVariant,
            )
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
