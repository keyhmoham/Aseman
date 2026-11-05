import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../tools/elpian_app/elpian_app_view.dart';

part 'developer_pages.dart';
part 'developer_platform.dart';

/// Where the developer API answers, set at build time
/// (`--dart-define=DEVELOPER_API_BASE=https://api.example.com/v1`). Empty
/// when the node's admin has not given it its own host.
const String kDeveloperApiBase = String.fromEnvironment('DEVELOPER_API_BASE');

typedef _Json = Map<String, dynamic>;

_Json _map(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : <String, dynamic>{};
List<_Json> _maps(dynamic v) =>
    v is List ? [for (final x in v) if (x is Map) _map(x)] : const [];
double _num(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
String _usd(dynamic units) => formatLedgerUsd(_num(units));
String _count(dynamic v) {
  final n = _num(v);
  if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(1)}M';
  if (n >= 1e3) return '${(n / 1e3).toStringAsFixed(1)}K';
  return n.round().toString();
}

String _date(dynamic v) {
  final t = DateTime.tryParse('${v ?? ''}')?.toLocal();
  if (t == null || t.year < 2000) return '—';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// The developer console: the person's organizations and, for the one
/// picked, its API keys, usage, request logs, models, team, computers,
/// storage and a playground. It talks to the `developer` namespace signed in
/// as the person; the API itself is called with the keys made here.
class DeveloperConsole extends StatefulWidget {
  const DeveloperConsole({super.key, required this.service});
  final AsemanService service;

  @override
  State<DeveloperConsole> createState() => _DeveloperConsoleState();
}

class _DevPage {
  const _DevPage(this.label, this.hint, this.icon, this.selectedIcon);
  final String label;
  final String hint;
  final IconData icon;
  final IconData selectedIcon;
}

class _DevSection {
  const _DevSection(this.label, this.pages);
  final String label;
  final List<_DevPage> pages;
}

class _DeveloperConsoleState extends State<DeveloperConsole> {
  static const _sections = [
    _DevSection('Workspace', [
      _DevPage('Overview', 'Balance, caps and how to call the API',
          Icons.space_dashboard_outlined, Icons.space_dashboard_rounded),
      _DevPage('API keys', 'Secrets that call the developer host',
          Icons.key_outlined, Icons.key_rounded),
      _DevPage('Team', 'People in this organization', Icons.group_outlined,
          Icons.group_rounded),
    ]),
    _DevSection('Metering', [
      _DevPage('Usage', 'Spend and volume over time',
          Icons.query_stats_outlined, Icons.query_stats_rounded),
      _DevPage('Logs', 'Recent requests for this organization',
          Icons.receipt_long_outlined, Icons.receipt_long_rounded),
    ]),
    _DevSection('Models', [
      _DevPage('Catalog', 'Models this node offers', Icons.memory_outlined,
          Icons.memory_rounded),
      _DevPage('Playground', 'Try a model against this organization',
          Icons.science_outlined, Icons.science_rounded),
    ]),
    _DevSection('Compute', [
      _DevPage('Computers', 'Linux machines driven through the API',
          Icons.computer_outlined, Icons.computer_rounded),
      _DevPage('Storage', 'Files uploaded through the API',
          Icons.cloud_outlined, Icons.cloud_rounded),
    ]),
    _DevSection('Build', [
      _DevPage(
          'Sub-platform',
          'Your isolated product environment and its users',
          Icons.layers_outlined,
          Icons.layers_rounded),
      _DevPage(
          'Platform API',
          'Every non-admin action for a full Aseman client',
          Icons.hub_outlined,
          Icons.hub_rounded),
    ]),
  ];

  List<_Json> _orgs = const [];
  List<_Json> _invites = const [];
  String _org = 'personal';
  bool _loading = true;
  String? _error;
  int _section = 0;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _loadOrgs();
  }

  void _select(int section, int page) {
    setState(() {
      _section = section;
      _page = page;
    });
  }

  _DevPage get _currentPage => _sections[_section].pages[_page];

  Future<void> _loadOrgs() async {
    try {
      final r = await widget.service.developer('orgs_list');
      if (!mounted) return;
      setState(() {
        _orgs = _maps(r['orgs']);
        _invites = _maps(r['invites']);
        if (!_orgs.any((o) => '${o['id']}' == _org)) _org = 'personal';
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  _Json get _current =>
      _orgs.firstWhere((o) => '${o['id']}' == _org, orElse: () => const {});

  Future<void> _createOrg() async {
    final name = await _ask(context, 'New organization', 'Name',
        hint: 'Acme Labs', action: 'Create');
    if (name == null || name.trim().isEmpty) return;
    try {
      final r = await widget.service
          .developer('org_create', {'name': name.trim()});
      _org = '${_map(r['org'])['id']}';
      await _loadOrgs();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  Future<void> _respond(_Json invite, bool accept) async {
    try {
      await widget.service.developer(
          'invite_respond', {'org': invite['org'], 'accept': accept});
      await _loadOrgs();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  Widget _pageBody(String org, bool personal) {
    final role = '${_current['role'] ?? 'owner'}';
    return switch (('$_section', '$_page')) {
      ('0', '0') => _Overview(
          key: ValueKey('overview$org'),
          service: widget.service,
          org: org,
          personal: personal,
          role: role,
          onOrgsChanged: _loadOrgs),
      ('0', '1') =>
        _Keys(key: ValueKey('keys$org'), service: widget.service, org: org),
      ('0', '2') => _Team(
          key: ValueKey('team$org'),
          service: widget.service,
          org: org,
          personal: personal),
      ('1', '0') =>
        _Usage(key: ValueKey('usage$org'), service: widget.service, org: org),
      ('1', '1') =>
        _Logs(key: ValueKey('logs$org'), service: widget.service, org: org),
      ('2', '0') => _Models(service: widget.service),
      ('2', '1') => _Playground(
          key: ValueKey('play$org'), service: widget.service, org: org),
      ('3', '0') => _Computers(
          key: ValueKey('computers$org'), service: widget.service, org: org),
      ('3', '1') => _Storage(
          key: ValueKey('storage$org'), service: widget.service, org: org),
      ('4', '0') => _SubPlatform(
          key: ValueKey('subplatform$org'),
          service: widget.service,
          org: org),
      ('4', '1') => _Platform(service: widget.service),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _orgPicker() {
    if (_orgs.isEmpty) return const SizedBox.shrink();
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: _org,
        borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
        onChanged: (v) {
          if (v == '+') {
            _createOrg();
          } else if (v != null) {
            setState(() => _org = v);
          }
        },
        items: [
          for (final o in _orgs)
            DropdownMenuItem(value: '${o['id']}', child: Text('${o['name']}')),
          const DropdownMenuItem(
              value: '+', child: Text('+ New organization')),
        ],
      ),
    );
  }

  Widget _invitesBanner(ColorScheme scheme) {
    if (_invites.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
      child: Column(
        children: [
          for (final invite in _invites)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: SoftCard(
                wash: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${invite['invitedBy']} invited you to ${invite['name']} as ${invite['role']}.',
                        style: TextStyle(
                            fontSize: 13.5, color: scheme.onSurface),
                      ),
                    ),
                    TextButton(
                        onPressed: () => _respond(invite, false),
                        child: const Text('Decline')),
                    const SizedBox(width: AppSpacing.xs),
                    FilledButton(
                        onPressed: () => _respond(invite, true),
                        child: const Text('Join')),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final org = _org;
    final personal = org == 'personal';
    final scheme = Theme.of(context).colorScheme;
    final wide = MediaQuery.sizeOf(context).width >= 980;
    final page = _currentPage;
    final body = _loading
        ? const SkeletonPage()
        : _error != null
            ? Center(
                child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text('Could not load: $_error',
                        textAlign: TextAlign.center)))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _invitesBanner(scheme),
                  Expanded(child: _pageBody(org, personal)),
                ],
              );

    Widget contentChrome(Widget child) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.sm),
            child: SkySectionHeader(
              icon: page.selectedIcon,
              title: page.label,
              subtitle: page.hint,
              dense: wide,
              actions: [
                _orgPicker(),
                if (Navigator.of(context).canPop())
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
      );
    }

    if (!wide) {
      final flat = [
        for (var s = 0; s < _sections.length; s++)
          for (var p = 0; p < _sections[s].pages.length; p++) (s, p),
      ];
      final selected = flat
          .indexWhere((e) => e.$1 == _section && e.$2 == _page)
          .clamp(0, flat.length - 1);
      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, 0),
                child: Row(
                  children: [
                    if (Navigator.of(context).canPop())
                      IconButton(
                        tooltip: 'Back',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    const Expanded(
                      child: SkySectionHeader(
                        icon: Icons.api_rounded,
                        title: 'Developer API',
                        subtitle: 'Keys, models and the platform collection',
                        dense: true,
                      ),
                    ),
                    _orgPicker(),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.xs),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SegmentedTabBar(
                    alignment: Alignment.centerLeft,
                    labels: [
                      for (final e in flat)
                        _sections[e.$1].pages[e.$2].label,
                    ],
                    icons: [
                      for (final e in flat)
                        _sections[e.$1].pages[e.$2].icon,
                    ],
                    selectedIndex: selected,
                    onTap: (i) {
                      final e = flat[i];
                      _select(e.$1, e.$2);
                    },
                  ),
                ),
              ),
              if (!_loading && _error == null) _invitesBanner(scheme),
              Expanded(
                child: _loading || _error != null
                    ? body
                    : _pageBody(org, personal),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: scheme.surfaceContainerLowest,
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 288,
              child: GlassSurface(
                alpha: AppSurfaces.overlayAlphaOf(context),
                borderRadius: BorderRadius.zero,
                border: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 24),
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: SkySectionHeader(
                        icon: Icons.api_rounded,
                        title: 'Developer API',
                        subtitle: 'Build on this node',
                        dense: true,
                      ),
                    ),
                    for (var s = 0; s < _sections.length; s++) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
                        child: EyebrowLabel(_sections[s].label,
                            color: scheme.primary),
                      ),
                      for (var p = 0; p < _sections[s].pages.length; p++)
                        _DevNavTile(
                          page: _sections[s].pages[p],
                          selected: s == _section && p == _page,
                          onTap: () => _select(s, p),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                child: Material(
                  color: scheme.surface,
                  clipBehavior: Clip.antiAlias,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppShape.cardOf(context) + 4),
                    side: BorderSide(color: AppSurfaces.cardBorder(scheme)),
                  ),
                  child: contentChrome(body),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DevNavTile extends StatelessWidget {
  const _DevNavTile({
    required this.page,
    required this.selected,
    required this.onTap,
  });
  final _DevPage page;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? ThemeRoles.selectedInk(context)
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected ? ThemeRoles.selectedFill(context) : Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 48,
            child: Row(
              children: [
                const SizedBox(width: 16),
                Icon(selected ? page.selectedIcon : page.icon,
                    size: 22, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    page.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: selected ? color : scheme.onSurface,
                      fontWeight:
                          selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── shared bits ──────────────────────────────────────────────────────────────

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

Future<String?> _ask(BuildContext context, String title, String label,
    {String hint = '', String action = 'Save', String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final value = await showAppDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              border: const OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v)),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(action)),
      ],
    ),
  );
  controller.dispose();
  return value;
}

Future<bool> _confirm(BuildContext context, String title, String body,
    {String action = 'Continue'}) async {
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// Loads one view of the console and shows it once it is there.
abstract class _Loaded extends StatefulWidget {
  const _Loaded({super.key, required this.service, this.org = 'personal'});
  final AsemanService service;
  final String org;
}

abstract class _LoadedState<T extends _Loaded> extends State<T> {
  _Json data = const {};
  bool loading = true;
  String? error;

  Future<_Json> fetch();
  Widget content(BuildContext context);

  Future<_Json> call(String action, [_Json body = const {}]) =>
      widget.service.developer(action, {'org': widget.org, ...body});

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final d = await fetch();
      if (!mounted) return;
      setState(() {
        data = d;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  /// Runs a change, reports its error, and reloads.
  Future<void> change(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
    await reload();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonList();
    if (error != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(error!, textAlign: TextAlign.center)));
    }
    return RefreshIndicator(
      onRefresh: reload,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: content(context),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing, this.icon});
  final String title;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: SoftCard(
        radius: AppShape.card,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (icon != null) ...[
              SkyIconBadge(icon: icon!, size: 34),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
                child: Text(title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800, letterSpacing: -.2))),
            if (trailing != null) trailing!,
          ]),
          const SizedBox(height: AppSpacing.sm),
          child,
        ]),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.hint = ''});
  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        Text(value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800, letterSpacing: -.4)),
        if (hint.isNotEmpty)
          Text(hint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

Widget _empty(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
    child: Text(text,
        style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.35)));

