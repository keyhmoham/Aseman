import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app_dependencies.dart';
import '../../../core/settings/app_settings.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar_editor.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/user_profile_sheet.dart';
import '../../account/presentation/account_panel.dart';

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
      const sessionKey = 'tradera.session';
      final session = prefs.getString(sessionKey);
      await prefs.clear();
      if (session != null) {
        await prefs.setString(sessionKey, session);
      }
      await _measureCache();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Local cache cleared')));
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
        tradeConfirmations =
            _readBool(prefs, 'tradeConfirmations', tradeConfirmations);
        agentApprovals = _readBool(prefs, 'agentApprovals', agentApprovals);
        priceAlerts = _readBool(prefs, 'priceAlerts', priceAlerts);
        socialNotifications =
            _readBool(prefs, 'socialNotifications', socialNotifications);
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
      Map<String, dynamic> prefs, String key, String fallback) {
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
      Map<String, dynamic> prefs, String key, double fallback) {
    final v = prefs[key];
    return v is num ? v.toDouble() : fallback;
  }

  Future<void> _save(String key, Object? value) async {
    final deps = widget.dependencies;
    if (deps == null) return;
    try {
      await deps.service.updateMetadata([
        {
          'op': 'set',
          'path': 'profile/preferences/$key',
          'value': value,
        }
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
    final ok = await confirmAppAction(context,
        icon: Icons.cleaning_services_rounded,
        title: 'Clear local cache?',
        message:
            'Saved drafts and cached data on this device are removed. You stay signed in.',
        action: 'Clear cache');
    if (ok) await _clearCache();
  }

  /// Opens one of the account panels.
  void _openAccount(AccountArea area) {
    final deps = widget.dependencies;
    if (deps == null) return;
    showAccountPanel(context, deps, area);
  }

  void _openProfile() {
    final deps = widget.dependencies;
    if (deps == null) return;
    showFloatingPanel(context, UserProfileSheet(dependencies: deps),
        maxWidth: 760);
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
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width > 900;
    final textSize = _textSizes.keys.reduce(
        (a, b) => (a - textScale).abs() <= (b - textScale).abs() ? a : b);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: CustomScrollView(slivers: [
        SliverAppBar.large(
          title: const Text('Settings'),
          backgroundColor: scheme.surface,
          surfaceTintColor: Colors.transparent,
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(wide ? 80 : 16, 4, wide ? 80 : 16, 32),
          sliver: SliverList.list(children: [
            _AccountCard(
                dependencies: widget.dependencies,
                onManage: () => _openAccount(AccountArea.account)),
            const SizedBox(height: 16),
            _Section(
                title: 'Appearance',
                icon: Icons.palette_outlined,
                children: [
                  const _Label('Theme'),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment(
                              value: ThemeMode.system,
                              icon: Icon(Icons.brightness_auto_outlined),
                              label: Text('System')),
                          ButtonSegment(
                              value: ThemeMode.light,
                              icon: Icon(Icons.light_mode_outlined),
                              label: Text('Light')),
                          ButtonSegment(
                              value: ThemeMode.dark,
                              icon: Icon(Icons.dark_mode_outlined),
                              label: Text('Dark'))
                        ],
                        selected: {
                          settings.themeMode
                        },
                        onSelectionChanged: (value) =>
                            settings.setThemeMode(value.first)),
                  ),
                  const SizedBox(height: 22),
                  const _Label('Accent color'),
                  Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: _accents
                          .map((color) => _AccentChoice(
                              color: color,
                              selected: settings.accent == color,
                              onTap: () => settings.setAccent(color)))
                          .toList()),
                  const SizedBox(height: 22),
                  Row(children: [
                    const Expanded(child: _Label('Text size')),
                    Text('Aa',
                        textScaler: TextScaler.linear(textSize),
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                  ]),
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
                  const SizedBox(height: 14),
                  _SwitchTile(
                      icon: Icons.animation_rounded,
                      title: 'Reduce motion',
                      subtitle: 'Use simpler interface transitions',
                      value: reducedMotion,
                      onChanged: (v) => _toggle(
                          (x) => reducedMotion = x, v, 'reducedMotion')),
                  _SwitchTile(
                      icon: Icons.onetwothree_rounded,
                      title: 'Compact market numbers',
                      subtitle: 'Show 1.2K instead of 1,200',
                      value: compactNumbers,
                      onChanged: (v) => _toggle(
                          (x) => compactNumbers = x, v, 'compactNumbers')),
                ]),
            _Section(
                title: 'Account & identity',
                icon: Icons.manage_accounts_outlined,
                children: [
                  _SettingsTile(
                      icon: Icons.person_outline,
                      title: 'Profile information',
                      subtitle: 'Name, username, bio and profile media',
                      onTap: _openProfile),
                  _SettingsTile(
                      icon: Icons.workspace_premium_outlined,
                      title: 'Wallet',
                      subtitle: 'Balance, top-ups and purchases',
                      onTap: () => _openAccount(AccountArea.wallet)),
                  _SettingsTile(
                      icon: Icons.query_stats_rounded,
                      title: 'Usage',
                      subtitle: 'What each project spent and on which models',
                      onTap: () => _openAccount(AccountArea.usage)),
                  const _SettingsTile(
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Trading accounts',
                      subtitle: 'Exchanges, brokers and wallets'),
                ]),
            _Section(
                title: 'Trading & agents',
                icon: Icons.candlestick_chart,
                children: [
                  _SwitchTile(
                      icon: Icons.fact_check_outlined,
                      title: 'Confirm trade execution',
                      subtitle:
                          'Require confirmation before an agent submits an order',
                      value: tradeConfirmations,
                      onChanged: (v) => _toggle((x) => tradeConfirmations = x,
                          v, 'tradeConfirmations')),
                  _SwitchTile(
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Approve new agent permissions',
                      subtitle: 'Ask before an agent gets a new capability',
                      value: agentApprovals,
                      onChanged: (v) => _toggle(
                          (x) => agentApprovals = x, v, 'agentApprovals')),
                  const SizedBox(height: 12),
                  AppChoiceField<String>(
                      label: 'Default currency',
                      value: currency,
                      choices: const [
                        AppChoice('USD', 'USD \$'),
                        AppChoice('EUR', 'EUR €'),
                        AppChoice('GBP', 'GBP £'),
                        AppChoice('JPY', 'JPY ¥'),
                        AppChoice('BTC', 'BTC ₿'),
                      ],
                      onChanged: (v) =>
                          _choose((x) => currency = x, v, 'currency')),
                  const SizedBox(height: 18),
                  AppChoiceField<String>(
                      label: 'Market region',
                      value: region,
                      choices: const [
                        AppChoice('Global', 'Global', icon: Icons.public),
                        AppChoice('US', 'US'),
                        AppChoice('EU', 'EU'),
                        AppChoice('Asia', 'Asia'),
                        AppChoice('Offshore', 'Offshore'),
                      ],
                      onChanged: (v) =>
                          _choose((x) => region = x, v, 'region')),
                  const SizedBox(height: 8),
                  const _SettingsTile(
                      icon: Icons.shield_outlined,
                      title: 'Risk defaults',
                      subtitle: 'Position limits, drawdown and leverage'),
                ]),
            _Section(
                title: 'Notifications',
                icon: Icons.notifications_none_rounded,
                children: [
                  _SwitchTile(
                      icon: Icons.show_chart_rounded,
                      title: 'Price and strategy alerts',
                      value: priceAlerts,
                      onChanged: (v) =>
                          _toggle((x) => priceAlerts = x, v, 'priceAlerts')),
                  _SwitchTile(
                      icon: Icons.forum_outlined,
                      title: 'Social and room activity',
                      value: socialNotifications,
                      onChanged: (v) => _toggle((x) => socialNotifications = x,
                          v, 'socialNotifications')),
                  const SizedBox(height: 12),
                  AppChoiceField<String>(
                      label: 'Quiet hours',
                      hint: 'No notifications during these hours.',
                      value: quietHours,
                      choices: const [
                        AppChoice('Off', 'Off',
                            icon: Icons.notifications_active_outlined),
                        AppChoice('22:00–08:00', '22:00 – 08:00'),
                        AppChoice('23:00–07:00', '23:00 – 07:00'),
                        AppChoice('00:00–06:00', '00:00 – 06:00'),
                      ],
                      onChanged: (v) =>
                          _choose((x) => quietHours = x, v, 'quietHours')),
                  const SizedBox(height: 8),
                  _SettingsTile(
                      icon: Icons.notifications_active_outlined,
                      title: 'Push notifications on this device',
                      subtitle: 'Turn device notifications on or off',
                      onTap: () => _openAccount(AccountArea.account)),
                ]),
            _Section(
                title: 'Privacy & security',
                icon: Icons.lock_outline_rounded,
                children: [
                  _SwitchTile(
                      icon: Icons.fingerprint_rounded,
                      title: 'Biometric unlock',
                      value: biometrics,
                      onChanged: (v) =>
                          _toggle((x) => biometrics = x, v, 'biometrics')),
                  _SwitchTile(
                      icon: Icons.insights_rounded,
                      title: 'Share anonymous analytics',
                      value: analytics,
                      onChanged: (v) =>
                          _toggle((x) => analytics = x, v, 'analytics')),
                  _SettingsTile(
                      icon: Icons.password_rounded,
                      title: 'Password and sign-in',
                      subtitle: 'Change your password, username and email',
                      onTap: () => _openAccount(AccountArea.account)),
                  const _SettingsTile(
                      icon: Icons.key_outlined,
                      title: 'Passkeys and two-factor authentication'),
                  const _SettingsTile(
                      icon: Icons.devices_outlined,
                      title: 'Active sessions',
                      subtitle: 'Review devices signed into your account'),
                  const _SettingsTile(
                      icon: Icons.download_outlined, title: 'Export your data'),
                ]),
            _Section(
                title: 'Storage & data',
                icon: Icons.storage_outlined,
                children: [
                  AppChoiceField<String>(
                      label: 'Media upload quality',
                      value: mediaQuality,
                      choices: const [
                        AppChoice('Automatic', 'Automatic',
                            icon: Icons.auto_mode_rounded),
                        AppChoice('Original', 'Original'),
                        AppChoice('Data saver', 'Data saver'),
                      ],
                      onChanged: (v) =>
                          _choose((x) => mediaQuality = x, v, 'mediaQuality')),
                  const SizedBox(height: 8),
                  _SettingsTile(
                      icon: Icons.cleaning_services_outlined,
                      title: 'Clear local cache',
                      subtitle: 'Uses $_cacheSize on this device',
                      onTap: _confirmClearCache),
                ]),
          ]),
        ),
      ]),
    );
  }

  static const _accents = [
    Color(0xFF8B7BFF),
    Color(0xFF3F8CFF),
    Color(0xFF00A98F),
    Color(0xFFFF6B81),
    Color(0xFFFF8A3D),
    Color(0xFFB45CFF)
  ];
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({this.dependencies, required this.onManage});
  final AppDependencies? dependencies;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = dependencies?.sessionController.session;
    final handle = session?.handle ?? 'me';
    final accountId = session?.accountId ?? '';
    final initials =
        handle.isEmpty ? 'ME' : handle.substring(0, 1).toUpperCase();
    return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(AppShape.card),
        ),
        child: Row(children: [
          if (dependencies == null)
            CircleAvatar(
                radius: 30,
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)))
          else
            AvatarEditor(
              service: dependencies!.service,
              avatar: dependencies!.sessionController.avatar,
              initials: initials,
              filled: true,
              subject: 'profile picture',
              enabled: accountId.isNotEmpty,
              onChanged: dependencies!.sessionController.setAvatar,
            ),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('@$handle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: scheme.onPrimaryContainer)),
                Text(accountId.isEmpty ? 'Signed out' : accountId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color:
                            scheme.onPrimaryContainer.withValues(alpha: .75))),
              ])),
          const SizedBox(width: 8),
          FilledButton(
              onPressed: dependencies == null ? null : onManage,
              child: const Text('Manage')),
        ]));
  }
}

class _Section extends StatelessWidget {
  const _Section(
      {required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A Material (not a decorated box) so list tiles paint ink on it.
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppShape.card)),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: ShapeDecoration(
                    color: scheme.secondaryContainer,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
                child: Icon(icon, size: 21, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800)),
              )
            ]),
            const SizedBox(height: 16),
            ...children
          ]),
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
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)));
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile(
      {required this.icon,
      required this.title,
      required this.value,
      required this.onChanged,
      this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged);
}

/// A row that opens a related screen. Without [onTap] it is not available
/// yet, and says so instead of doing nothing when tapped.
class _SettingsTile extends StatelessWidget {
  const _SettingsTile(
      {required this.icon, required this.title, this.subtitle, this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
        contentPadding: EdgeInsets.zero,
        enabled: onTap != null,
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: onTap == null
            ? Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999)),
                child: Text('Soon',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)))
            : const Icon(Icons.chevron_right_rounded),
        onTap: onTap);
  }
}

class _AccentChoice extends StatelessWidget {
  const _AccentChoice(
      {required this.color, required this.selected, required this.onTap});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
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
                  width: 3)),
          child: selected
              ? const Icon(Icons.check_rounded, color: Colors.white)
              : null));
}
