import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app_dependencies.dart';
import '../../../core/settings/app_settings.dart';

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

  Future<void> _pickCurrency() async {
    const options = ['USD', 'EUR', 'GBP', 'JPY', 'BTC'];
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Default currency'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option),
              child: Text(option),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => currency = selected);
    unawaited(_save('currency', selected));
  }

  Future<void> _pickRegion() async {
    const options = ['Global', 'US', 'EU', 'Asia', 'Offshore'];
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Market region'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option),
              child: Text(option),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => region = selected);
    unawaited(_save('region', selected));
  }

  Future<void> _pickQuietHours() async {
    const options = ['23:00–07:00', '22:00–08:00', '00:00–06:00', 'Off'];
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Quiet hours'),
        children: [
          for (final option in options)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, option),
              child: Text(option),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    setState(() => quietHours = selected);
    unawaited(_save('quietHours', selected));
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsScope.of(context);
    return Scaffold(
      appBar:
          AppBar(title: const Text('Settings'), centerTitle: false, actions: [
        IconButton(
            onPressed: () {},
            tooltip: 'Search settings',
            icon: const Icon(Icons.search_rounded)),
        const SizedBox(width: 8)
      ]),
      body: ListView(
          padding: EdgeInsets.symmetric(
              horizontal: MediaQuery.sizeOf(context).width > 900 ? 80 : 16,
              vertical: 20),
          children: [
            _AccountCard(dependencies: widget.dependencies),
            const SizedBox(height: 24),
            _Section(
                title: 'Appearance',
                icon: Icons.palette_outlined,
                children: [
                  const _Label('Theme'),
                  SegmentedButton<ThemeMode>(
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
                  const SizedBox(height: 20),
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
                  const SizedBox(height: 14),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Reduce motion'),
                      subtitle: const Text('Use simpler interface transitions'),
                      value: reducedMotion,
                      onChanged: (v) => _toggle(
                          (x) => reducedMotion = x, v, 'reducedMotion')),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Compact market numbers'),
                      value: compactNumbers,
                      onChanged: (v) => _toggle(
                          (x) => compactNumbers = x, v, 'compactNumbers')),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Text size'),
                      subtitle: Slider(
                          value: textScale,
                          min: .85,
                          max: 1.3,
                          divisions: 3,
                          label: '${(textScale * 100).round()}%',
                          onChanged: (v) {
                            setState(() => textScale = v);
                            _save('textScale', v);
                          })),
                ]),
            const _Section(
                title: 'Account & identity',
                icon: Icons.manage_accounts_outlined,
                children: const [
                  _SettingsTile(
                      icon: Icons.person_outline,
                      title: 'Profile information',
                      subtitle: 'Name, username, bio and profile media'),
                  _SettingsTile(
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Trading accounts',
                      subtitle: 'Exchanges, brokers and wallets'),
                  _SettingsTile(
                      icon: Icons.workspace_premium_outlined,
                      title: 'Plan and billing',
                      subtitle: 'Subscription, invoices and usage'),
                ]),
            _Section(
                title: 'Trading & agents',
                icon: Icons.candlestick_chart,
                children: [
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Confirm trade execution'),
                      subtitle: const Text(
                          'Require confirmation before an agent submits an order'),
                      value: tradeConfirmations,
                      onChanged: (v) => _toggle((x) => tradeConfirmations = x,
                          v, 'tradeConfirmations')),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Approve new agent permissions'),
                      value: agentApprovals,
                      onChanged: (v) => _toggle(
                          (x) => agentApprovals = x, v, 'agentApprovals')),
                  _SettingsTile(
                      icon: Icons.currency_exchange,
                      title: 'Default currency',
                      trailing: currency,
                      onTap: () => _pickCurrency()),
                  _SettingsTile(
                      icon: Icons.public,
                      title: 'Market region',
                      trailing: region,
                      onTap: () => _pickRegion()),
                  const _SettingsTile(
                      icon: Icons.shield_outlined,
                      title: 'Risk defaults',
                      subtitle: 'Position limits, drawdown and leverage'),
                ]),
            _Section(
                title: 'Notifications',
                icon: Icons.notifications_none_rounded,
                children: [
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Price and strategy alerts'),
                      value: priceAlerts,
                      onChanged: (v) =>
                          _toggle((x) => priceAlerts = x, v, 'priceAlerts')),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Social and room activity'),
                      value: socialNotifications,
                      onChanged: (v) => _toggle((x) => socialNotifications = x,
                          v, 'socialNotifications')),
                  _SettingsTile(
                      icon: Icons.schedule_outlined,
                      title: 'Quiet hours',
                      trailing: quietHours,
                      onTap: () => _pickQuietHours()),
                  const _SettingsTile(
                      icon: Icons.notifications_active_outlined,
                      title: 'Notification channels',
                      subtitle: 'Push, email, desktop and sound'),
                ]),
            _Section(
                title: 'Privacy & security',
                icon: Icons.lock_outline_rounded,
                children: [
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Biometric unlock'),
                      value: biometrics,
                      onChanged: (v) =>
                          _toggle((x) => biometrics = x, v, 'biometrics')),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Share anonymous analytics'),
                      value: analytics,
                      onChanged: (v) =>
                          _toggle((x) => analytics = x, v, 'analytics')),
                  const _SettingsTile(
                      icon: Icons.key_outlined,
                      title: 'Passkeys and two-factor authentication'),
                  const _SettingsTile(
                      icon: Icons.devices_outlined,
                      title: 'Active sessions',
                      subtitle: 'Review devices signed into your account'),
                  const _SettingsTile(
                      icon: Icons.visibility_outlined,
                      title: 'Profile and post visibility'),
                  const _SettingsTile(
                      icon: Icons.download_outlined, title: 'Export your data'),
                ]),
            _Section(
                title: 'Storage & data',
                icon: Icons.storage_outlined,
                children: [
                  const _SettingsTile(
                      icon: Icons.cloud_sync_outlined,
                      title: 'Workspace synchronization',
                      trailing: 'On'),
                  const _SettingsTile(
                      icon: Icons.high_quality_outlined,
                      title: 'Media upload quality',
                      trailing: 'Automatic'),
                  _SettingsTile(
                      icon: Icons.cleaning_services_outlined,
                      title: 'Clear local cache',
                      trailing: _cacheSize,
                      onTap: _clearCache),
                ]),
            const SizedBox(height: 20),
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
  const _AccountCard({this.dependencies});
  final AppDependencies? dependencies;

  @override
  Widget build(BuildContext context) {
    final session = dependencies?.sessionController.session;
    final handle = session?.handle ?? 'me';
    final accountId = session?.accountId ?? '';
    final initials =
        handle.isEmpty ? 'ME' : handle.substring(0, 1).toUpperCase();
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(children: [
              CircleAvatar(radius: 31, child: Text(initials)),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(handle,
                        style: const TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w900)),
                    Text(
                        accountId.isEmpty
                            ? 'Signed out'
                            : '@$handle · $accountId',
                        style: const TextStyle(fontSize: 11)),
                  ])),
              FilledButton.tonal(onPressed: () {}, child: const Text('Manage'))
            ])));
  }
}

class _Section extends StatelessWidget {
  const _Section(
      {required this.title, required this.icon, required this.children});
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
          padding: const EdgeInsets.all(18),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Text(title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w900))
            ]),
            const Divider(height: 28),
            ...children
          ])));
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Text(text,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)));
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile(
      {required this.icon,
      required this.title,
      this.subtitle,
      this.trailing,
      this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle, trailing;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (trailing != null)
          Text(trailing!,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(width: 5),
        const Icon(Icons.chevron_right_rounded)
      ]),
      onTap: onTap);
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
