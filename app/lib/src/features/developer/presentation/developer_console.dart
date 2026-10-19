import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/app_inputs.dart';

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
  final TraderaService service;

  @override
  State<DeveloperConsole> createState() => _DeveloperConsoleState();
}

class _DeveloperConsoleState extends State<DeveloperConsole> {
  List<_Json> _orgs = const [];
  List<_Json> _invites = const [];
  String _org = 'personal';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadOrgs();
  }

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

  @override
  Widget build(BuildContext context) {
    const tabs = [
      ('Overview', Icons.space_dashboard_outlined),
      ('API keys', Icons.key_outlined),
      ('Usage', Icons.query_stats_outlined),
      ('Logs', Icons.receipt_long_outlined),
      ('Models', Icons.memory_outlined),
      ('Playground', Icons.science_outlined),
      ('Computers', Icons.computer_outlined),
      ('Storage', Icons.cloud_outlined),
      ('Team', Icons.group_outlined),
    ];
    final org = _org;
    final personal = org == 'personal';
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Developer API'),
          actions: [
            if (_orgs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: DropdownButton<String>(
                  value: org,
                  underline: const SizedBox(),
                  onChanged: (v) {
                    if (v == '+') {
                      _createOrg();
                    } else if (v != null) {
                      setState(() => _org = v);
                    }
                  },
                  items: [
                    for (final o in _orgs)
                      DropdownMenuItem(
                          value: '${o['id']}', child: Text('${o['name']}')),
                    const DropdownMenuItem(
                        value: '+', child: Text('+ New organization')),
                  ],
                ),
              ),
          ],
          bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            for (final (label, icon) in tabs) Tab(icon: Icon(icon), text: label),
          ]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text('Could not load: $_error'))
                : Column(children: [
                    for (final invite in _invites)
                      MaterialBanner(
                        content: Text(
                            '${invite['invitedBy']} invited you to ${invite['name']} as ${invite['role']}.'),
                        actions: [
                          TextButton(
                              onPressed: () => _respond(invite, false),
                              child: const Text('Decline')),
                          FilledButton(
                              onPressed: () => _respond(invite, true),
                              child: const Text('Join')),
                        ],
                      ),
                    Expanded(
                      child: TabBarView(children: [
                        _Overview(
                            key: ValueKey('overview$org'),
                            service: widget.service,
                            org: org,
                            personal: personal,
                            role: '${_current['role'] ?? 'owner'}',
                            onOrgsChanged: _loadOrgs),
                        _Keys(
                            key: ValueKey('keys$org'),
                            service: widget.service,
                            org: org),
                        _Usage(
                            key: ValueKey('usage$org'),
                            service: widget.service,
                            org: org),
                        _Logs(
                            key: ValueKey('logs$org'),
                            service: widget.service,
                            org: org),
                        _Models(service: widget.service),
                        _Playground(
                            key: ValueKey('play$org'),
                            service: widget.service,
                            org: org),
                        _Computers(
                            key: ValueKey('computers$org'),
                            service: widget.service,
                            org: org),
                        _Storage(
                            key: ValueKey('storage$org'),
                            service: widget.service,
                            org: org),
                        _Team(
                            key: ValueKey('team$org'),
                            service: widget.service,
                            org: org,
                            personal: personal),
                      ]),
                    ),
                  ]),
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
  final value = await showDialog<String>(
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
  final ok = await showDialog<bool>(
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
  final TraderaService service;
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
    if (loading) return const Center(child: CircularProgressIndicator());
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
          constraints: const BoxConstraints(maxWidth: 980),
          child: content(context),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(AppShape.card)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800))),
          if (trailing != null) trailing!,
        ]),
        const SizedBox(height: 10),
        child,
      ]),
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
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        Text(value,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        if (hint.isNotEmpty)
          Text(hint,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ]),
    );
  }
}

Widget _empty(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Text(text,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)));

// ── overview ─────────────────────────────────────────────────────────────────

class _Overview extends _Loaded {
  const _Overview(
      {super.key,
      required super.service,
      required super.org,
      required this.personal,
      required this.role,
      required this.onOrgsChanged});
  final bool personal;
  final String role;
  final Future<void> Function() onOrgsChanged;

  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends _LoadedState<_Overview> {
  @override
  Future<_Json> fetch() async {
    final results = await Future.wait([
      call('wallet_get'),
      call('settings_get'),
      call('usage_report', {'days': 30}),
    ]);
    return {'wallet': results[0], 'settings': results[1], 'usage': results[2]};
  }

  Future<void> _fund() async {
    final raw = await _ask(context, 'Add funds', 'Amount in dollars',
        hint: '10', action: 'Add');
    final usd = double.tryParse('${raw ?? ''}'.trim());
    if (usd == null || usd <= 0) return;
    await change(
        () => call('wallet_fund', {'amount': usdToLedger(usd)}));
  }

  Future<void> _cap() async {
    final settings = _map(data['settings']);
    final raw = await _ask(context, 'Monthly spending cap',
        'Dollars a month (0: no cap)',
        initial: _num(settings['accountMonthlyCap']) > 0
            ? compactDecimal(ledgerToUsd(_num(settings['accountMonthlyCap'])))
            : '');
    if (raw == null) return;
    final usd = double.tryParse(raw.trim().isEmpty ? '0' : raw.trim());
    if (usd == null || usd < 0) return;
    await change(() => call('settings_save', {
          'settings': {...settings, 'accountMonthlyCap': usdToLedger(usd)}
        }));
  }

  Future<void> _rename() async {
    final name = await _ask(context, 'Rename organization', 'Name');
    if (name == null || name.trim().isEmpty) return;
    try {
      await call('org_rename', {'name': name.trim()});
      await widget.onOrgsChanged();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  Future<void> _delete() async {
    if (!await _confirm(context, 'Delete this organization?',
        'Its keys stop working and its balance returns to you.',
        action: 'Delete')) {
      return;
    }
    try {
      await call('org_delete');
      await widget.onOrgsChanged();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  @override
  Widget content(BuildContext context) {
    final wallet = _map(data['wallet']);
    final settings = _map(data['settings']);
    final total = _map(_map(data['usage'])['total']);
    final cap = _num(settings['accountMonthlyCap']);
    final owner = widget.role == 'owner';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'Calling the API',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (kDeveloperApiBase.isNotEmpty) ...[
            Row(children: [
              const Expanded(
                  child: SelectableText(kDeveloperApiBase,
                      style: TextStyle(fontFamily: 'monospace'))),
              IconButton(
                  tooltip: 'Copy base URL',
                  onPressed: () => Clipboard.setData(
                      const ClipboardData(text: kDeveloperApiBase)),
                  icon: const Icon(Icons.copy_rounded, size: 18)),
            ]),
            const SizedBox(height: 6),
          ],
          Text(
              'OpenAI-compatible: send Authorization: Bearer <key> to /v1/chat/completions, /v1/embeddings, /v1/images/generations, /v1/models and more${kDeveloperApiBase.isEmpty ? ' on your node\'s developer host' : ''}.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
      _Card(
        title: 'Money',
        trailing: Wrap(spacing: 8, children: [
          if (!widget.personal)
            FilledButton.tonalIcon(
                onPressed: _fund,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Add funds')),
          OutlinedButton(onPressed: _cap, child: const Text('Monthly cap')),
        ]),
        child: Wrap(spacing: 24, runSpacing: 16, children: [
          _Figure('Balance', _usd(wallet['balance']),
              hint: widget.personal ? 'Your own wallet' : 'This organization'),
          _Figure('This month', _usd(settings['spentMonth']),
              hint: cap > 0 ? 'of a ${_usd(cap)} cap' : 'No cap'),
          _Figure('Last 30 days', _usd(total['spend']),
              hint:
                  '${_count(total['requests'])} requests · ${_count(total['errors'])} failed'),
        ]),
      ),
      if (_maps(wallet['entries']).isNotEmpty)
        _Card(
          title: 'Recent movements',
          child: Column(children: [
            for (final e in _maps(wallet['entries']).take(10))
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text('${e['description']}'),
                subtitle: Text(_date(e['at'])),
                trailing: Text(_usd(e['amount']),
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      if (!widget.personal && owner)
        _Card(
          title: 'Organization',
          child: Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: _rename, child: const Text('Rename')),
            OutlinedButton(
                onPressed: _delete, child: const Text('Delete organization')),
          ]),
        ),
    ]);
  }
}

// ── keys ─────────────────────────────────────────────────────────────────────

class _Keys extends _Loaded {
  const _Keys({super.key, required super.service, required super.org});
  @override
  State<_Keys> createState() => _KeysState();
}

class _KeysState extends _LoadedState<_Keys> {
  @override
  Future<_Json> fetch() => call('keys_list');

  Future<void> _create() async {
    final input = await showDialog<_Json>(
        context: context, builder: (_) => const _KeyDialog());
    if (input == null) return;
    try {
      final r = await call('key_create', {'input': input});
      if (!mounted) return;
      await _showSecret(context, '${r['secret'] ?? ''}');
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
    await reload();
  }

  @override
  Widget content(BuildContext context) {
    final keys = _maps(data['keys']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'API keys',
        trailing: FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New key')),
        child: keys.isEmpty
            ? _empty(context, 'No keys yet. Make one to call the API.')
            : Column(children: [
                for (final k in keys)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(k['status'] == 'active'
                        ? Icons.key_rounded
                        : Icons.key_off_rounded),
                    title: Text('${k['name']}'),
                    subtitle: Text(
                        '${k['prefix']}…${k['last4']} · ${k['status']} · ${_usd(k['spentMonth'])} this month · ${_count(k['requests'])} requests · last used ${_date(k['lastUsedAt'])}'),
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Key options',
                      onSelected: (v) async {
                        if (v == 'revoke' &&
                            await _confirm(context, 'Revoke ${k['name']}?',
                                'Calls with it stop working at once.',
                                action: 'Revoke')) {
                          await change(() => call('key_revoke', {'id': k['id']}));
                        }
                        if (v == 'delete' &&
                            context.mounted &&
                            await _confirm(context, 'Delete ${k['name']}?',
                                'It is removed with its history.',
                                action: 'Delete')) {
                          await change(() => call('key_delete', {'id': k['id']}));
                        }
                      },
                      itemBuilder: (_) => [
                        if (k['status'] == 'active')
                          const PopupMenuItem(
                              value: 'revoke', child: Text('Revoke')),
                        const PopupMenuItem(
                            value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  ),
              ]),
      ),
    ]);
  }
}

Future<void> _showSecret(BuildContext context, String secret) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.key_rounded),
        title: const Text('Copy your key now'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('It is shown only this once.'),
          const SizedBox(height: 12),
          SelectableText(secret,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
        ]),
        actions: [
          TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: secret)),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy')),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
    );

class _KeyDialog extends StatefulWidget {
  const _KeyDialog();
  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _name = TextEditingController();
  final _cap = TextEditingController();
  final _rpm = TextEditingController();
  final perms = <String, String>{
    'models': 'read',
    'chat': 'write',
    'computers': 'none',
    'files': 'none',
    'usage': 'read',
  };
  static const levels = {
    'models': ['none', 'read'],
    'chat': ['none', 'write'],
    'computers': ['none', 'read', 'write'],
    'files': ['none', 'read', 'write'],
    'usage': ['none', 'read'],
  };
  static const labels = {
    'models': 'Models',
    'chat': 'Model calls',
    'computers': 'Computers',
    'files': 'Files',
    'usage': 'Usage',
  };

  @override
  void dispose() {
    _name.dispose();
    _cap.dispose();
    _rpm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New API key'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                      controller: _name,
                      decoration: const InputDecoration(
                          labelText: 'Name',
                          hintText: 'Production server',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 16),
                  for (final e in levels.entries) ...[
                    AppChoiceField<String>(
                      label: labels[e.key]!,
                      value: perms[e.key],
                      onChanged: (v) => setState(() => perms[e.key] = v),
                      choices: [
                        for (final l in e.value)
                          AppChoice(l, l[0].toUpperCase() + l.substring(1)),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(children: [
                    Expanded(
                        child: TextField(
                            controller: _cap,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Monthly cap (\$)',
                                hintText: 'none',
                                border: OutlineInputBorder()))),
                    const SizedBox(width: 12),
                    Expanded(
                        child: TextField(
                            controller: _rpm,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: 'Requests a minute',
                                hintText: 'default',
                                border: OutlineInputBorder()))),
                  ]),
                ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, {
                    'name': _name.text.trim(),
                    'permissions': perms,
                    'limits': {
                      'monthlyCap': usdToLedger(
                          double.tryParse(_cap.text.trim()) ?? 0),
                      'rpm': int.tryParse(_rpm.text.trim()) ?? 0,
                      'models': <String>[],
                      'providers': <String>[],
                    },
                  }),
              child: const Text('Create key')),
        ],
      );
}

// ── usage ────────────────────────────────────────────────────────────────────

class _Usage extends _Loaded {
  const _Usage({super.key, required super.service, required super.org});
  @override
  State<_Usage> createState() => _UsageState();
}

class _UsageState extends _LoadedState<_Usage> {
  int days = 30;

  @override
  Future<_Json> fetch() => call('usage_report',
      {'days': days, 'tz': DateTime.now().timeZoneOffset.inMinutes});

  Widget _rows(String title, List<_Json> rows) => _Card(
        title: title,
        child: rows.isEmpty
            ? _empty(context, 'Nothing yet.')
            : Column(children: [
                for (final r in rows)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${r['name']}'),
                    subtitle: Text(
                        '${_count(r['requests'])} requests · ${_count(r['tokens'])} tokens'),
                    trailing: Text(_usd(r['spend']),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
              ]),
      );

  @override
  Widget content(BuildContext context) {
    final total = _map(data['total']);
    final points = _maps(data['days']);
    final top = points.fold<double>(0, (m, p) => _num(p['spend']) > m ? _num(p['spend']) : m);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(spacing: 8, children: [
        for (final d in const [7, 30, 90])
          ChoiceChip(
              label: Text('$d days'),
              selected: days == d,
              onSelected: (_) {
                setState(() => days = d);
                reload();
              }),
      ]),
      const SizedBox(height: 12),
      _Card(
        title: 'Last $days days',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 24, runSpacing: 16, children: [
            _Figure('Spend', _usd(total['spend'])),
            _Figure('Requests', _count(total['requests']),
                hint: '${_count(total['errors'])} failed'),
            _Figure('Tokens',
                '${_count(total['tokensIn'])} / ${_count(total['tokensOut'])}',
                hint: 'in / out'),
          ]),
          if (points.isNotEmpty) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 80,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final p in points)
                  Expanded(
                    child: Tooltip(
                      message: '${p['day']}: ${_usd(p['spend'])}',
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        height: top == 0 ? 2 : 2 + 76 * _num(p['spend']) / top,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
              ]),
            ),
          ],
        ]),
      ),
      _rows('By model', _maps(data['byModel'])),
      _rows('By key', _maps(data['byKey'])),
      _rows('By service', _maps(data['byService'])),
    ]);
  }
}

// ── logs ─────────────────────────────────────────────────────────────────────

class _Logs extends _Loaded {
  const _Logs({super.key, required super.service, required super.org});
  @override
  State<_Logs> createState() => _LogsState();
}

class _LogsState extends _LoadedState<_Logs> {
  String status = '';
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Future<_Json> fetch() => call('logs_list', {
        'limit': 100,
        'filter': {'status': status, 'query': query.text.trim()},
      });

  void _open(_Json l) {
    String pretty(dynamic v) =>
        v == null ? '—' : const JsonEncoder.withIndent('  ').convert(v);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${l['method']} ${l['path']}'),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: SelectableText(
                'Status ${l['status']} · ${l['latencyMs']} ms · ${_usd(l['cost'])}\n'
                'Model ${l['model'] ?? '—'}${l['requestedModel'] != null && l['requestedModel'] != l['model'] ? ' (asked for ${l['requestedModel']})' : ''}\n'
                'Key ${l['keyName']} · ${_date(l['at'])}\n'
                '${'${l['error'] ?? ''}'.isEmpty ? '' : 'Error ${l['error']}\n'}'
                '\nRequest\n${pretty(l['request'])}\n\nResponse\n${pretty(l['response'])}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget content(BuildContext context) {
    final logs = _maps(data['logs']);
    final scheme = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: TextField(
            controller: query,
            onSubmitted: (_) => reload(),
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search path, model or key'),
          ),
        ),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: status,
          onChanged: (v) {
            setState(() => status = v ?? '');
            reload();
          },
          items: const [
            DropdownMenuItem(value: '', child: Text('All')),
            DropdownMenuItem(value: 'success', child: Text('Succeeded')),
            DropdownMenuItem(value: 'error', child: Text('Failed')),
          ],
        ),
      ]),
      const SizedBox(height: 12),
      if (logs.isEmpty) _empty(context, 'No requests yet.'),
      for (final l in logs)
        ListTile(
          contentPadding: EdgeInsets.zero,
          onTap: () => _open(l),
          leading: Icon(
              _num(l['status']) >= 400
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              color: _num(l['status']) >= 400 ? scheme.error : scheme.primary),
          title: Text('${l['method']} ${l['path']}'),
          subtitle: Text(
              '${_date(l['at'])} · ${l['model'] ?? '—'} · ${l['keyName']} · ${l['latencyMs']} ms'),
          trailing: Text(_usd(l['cost'])),
        ),
    ]);
  }
}

// ── models ───────────────────────────────────────────────────────────────────

class _Models extends _Loaded {
  const _Models({required super.service});
  @override
  State<_Models> createState() => _ModelsState();
}

class _ModelsState extends _LoadedState<_Models> {
  final search = TextEditingController();
  String type = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Future<_Json> fetch() => widget.service.developer('models');

  static String price(_Json line) {
    final usd = _num(line['units']) / ledgerUnitsPerUsd;
    final text = usd >= 1
        ? usd.toStringAsFixed(2)
        : compactDecimal(usd, decimals: 8);
    return '${line['label']} \$$text / ${line['per']}';
  }

  @override
  Widget content(BuildContext context) {
    final all = _maps(data['models']);
    final types = {for (final m in all) '${m['type']}'}.toList()..sort();
    final q = search.text.toLowerCase().trim();
    final shown = all
        .where((m) =>
            (type == 'all' || m['type'] == type) &&
            (q.isEmpty ||
                '${m['id']} ${m['name']} ${m['creator']}'
                    .toLowerCase()
                    .contains(q)))
        .toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      TextField(
          controller: search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: 'Search models')),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final t in ['all', ...types])
          ChoiceChip(
              label: Text(t),
              selected: type == t,
              onSelected: (_) => setState(() => type = t)),
      ]),
      const SizedBox(height: 10),
      if (shown.isEmpty) _empty(context, 'No models match.'),
      for (final m in shown)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('${m['name'] ?? m['id']}'),
          subtitle: Text([
            '${m['id']}',
            '${m['type']}',
            if (_num(m['contextWindow']) > 0)
              '${_count(m['contextWindow'])} context',
            for (final e in _maps(m['endpoints']).take(1))
              for (final p in _maps(e['prices'])) price(p),
          ].join(' · ')),
          trailing: IconButton(
              tooltip: 'Copy model id',
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: '${m['id']}')),
              icon: const Icon(Icons.copy_rounded, size: 18)),
        ),
    ]);
  }
}

// ── playground ───────────────────────────────────────────────────────────────

class _Playground extends _Loaded {
  const _Playground({super.key, required super.service, required super.org});
  @override
  State<_Playground> createState() => _PlaygroundState();
}

class _PlaygroundState extends _LoadedState<_Playground> {
  final prompt = TextEditingController();
  String model = '';
  bool running = false;
  _Json? result;

  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  @override
  Future<_Json> fetch() => widget.service.developer('models');

  Future<void> _run() async {
    if (model.isEmpty || prompt.text.trim().isEmpty) return;
    setState(() {
      running = true;
      result = null;
    });
    try {
      final r = await call('run', {
        'request': {
          'type': 'language',
          'model': model,
          'messages': [
            {'role': 'user', 'content': prompt.text.trim()}
          ],
        }
      });
      if (mounted) setState(() => result = r);
    } catch (e) {
      if (mounted) _snack(context, '$e');
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget content(BuildContext context) {
    final chat =
        _maps(data['models']).where((m) => m['type'] == 'language').toList();
    if (model.isEmpty && chat.isNotEmpty) model = '${chat.first['id']}';
    final r = result;
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'Try a model',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (chat.isEmpty)
            _empty(context, 'No language model is offered yet.')
          else
            DropdownButtonFormField<String>(
              initialValue: model,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Model', border: OutlineInputBorder()),
              items: [
                for (final m in chat)
                  DropdownMenuItem(
                      value: '${m['id']}',
                      child: Text('${m['name'] ?? m['id']}',
                          overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => model = v ?? model),
            ),
          const SizedBox(height: 12),
          TextField(
              controller: prompt,
              minLines: 3,
              maxLines: 10,
              decoration: const InputDecoration(
                  labelText: 'Message', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: running || chat.isEmpty ? null : _run,
              icon: running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.play_arrow_rounded),
              label: const Text('Run')),
          const SizedBox(height: 6),
          Text('Charged to this organization like any API call.',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ]),
      ),
      if (r != null)
        _Card(
          title: '${r['model'] ?? model}',
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if ('${r['error'] ?? ''}'.isNotEmpty)
              Text('${r['error']}',
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else
              SelectableText('${r['text'] ?? ''}'),
            const SizedBox(height: 10),
            Text(
                '${_count(r['tokensIn'])} in · ${_count(r['tokensOut'])} out · ${_usd(r['cost'])} · ${r['latencyMs']} ms',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ]),
        ),
    ]);
  }
}

// ── computers ────────────────────────────────────────────────────────────────

class _Computers extends _Loaded {
  const _Computers({super.key, required super.service, required super.org});
  @override
  State<_Computers> createState() => _ComputersState();
}

class _ComputersState extends _LoadedState<_Computers> {
  @override
  Future<_Json> fetch() async {
    final results =
        await Future.wait([call('computers_list'), call('computers_options')]);
    return {'list': results[0]['computers'], 'options': results[1]};
  }

  Future<void> _create() async {
    final input = await showDialog<_Json>(
        context: context,
        builder: (_) => _ComputerDialog(options: _map(data['options'])));
    if (input == null) return;
    await change(() => call('computer_create', {'input': input}));
  }

  Future<void> _exec(_Json c) async {
    final command = await _ask(context, 'Run on ${c['name']}', 'Command',
        hint: 'ls -la /workspace', action: 'Run');
    if (command == null || command.trim().isEmpty) return;
    try {
      final r = await call('computer_exec', {'id': c['id'], 'command': command});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Exit ${r['exitCode']} · ${r['ms']} ms'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: SelectableText(
                  '${r['stdout'] ?? ''}${'${r['stderr'] ?? ''}'.isEmpty ? '' : '\n--- stderr ---\n${r['stderr']}'}',
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  @override
  Widget content(BuildContext context) {
    final list = _maps(data['list']);
    final options = _map(data['options']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'Computers',
        trailing: FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New computer')),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              'Linux machines your code drives through the API. A running one is billed by the minute and stops after ${options['idleStopMin'] ?? 30} idle minutes.',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (list.isEmpty) _empty(context, 'No computers yet.'),
          for (final c in list)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(c['status'] == 'running'
                  ? Icons.computer_rounded
                  : Icons.desktop_access_disabled_outlined),
              title: Text('${c['name']}'),
              subtitle: Text(
                  '${c['status']} · ${compactDecimal(_num(_map(c['spec'])['cpu']))} vCPU · ${(_num(_map(c['spec'])['memoryMb']) / 1024).toStringAsFixed(1)} GB · ${c['image']} · ${compactDecimal(_num(c['minutes']), decimals: 1)} min'),
              trailing: Wrap(children: [
                if (c['status'] == 'running')
                  IconButton(
                      tooltip: 'Run a command',
                      onPressed: () => _exec(c),
                      icon: const Icon(Icons.terminal_rounded)),
                IconButton(
                    tooltip: c['status'] == 'running' ? 'Stop' : 'Start',
                    onPressed: () => change(() => call('computer_status', {
                          'id': c['id'],
                          'status':
                              c['status'] == 'running' ? 'stopped' : 'running'
                        })),
                    icon: Icon(c['status'] == 'running'
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded)),
                IconButton(
                    tooltip: 'Delete',
                    onPressed: () async {
                      if (await _confirm(context, 'Delete ${c['name']}?',
                          'The computer and its files are removed.',
                          action: 'Delete')) {
                        await change(
                            () => call('computer_delete', {'id': c['id']}));
                      }
                    },
                    icon: const Icon(Icons.delete_outline_rounded)),
              ]),
            ),
        ]),
      ),
    ]);
  }
}

class _ComputerDialog extends StatefulWidget {
  const _ComputerDialog({required this.options});
  final _Json options;
  @override
  State<_ComputerDialog> createState() => _ComputerDialogState();
}

class _ComputerDialogState extends State<_ComputerDialog> {
  final name = TextEditingController();
  late final images = _maps(widget.options['images']);
  late String image = images.isEmpty ? '' : '${images.first['id']}';
  late double cpu =
      _num(_map(widget.options['cpu'])['default']).clamp(.25, 64).toDouble();
  late double memory = _num(_map(widget.options['memoryMb'])['default'])
      .clamp(512, 1 << 20)
      .toDouble();

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cpuRange = _map(widget.options['cpu']);
    final memRange = _map(widget.options['memoryMb']);
    final maxCpu = _num(cpuRange['max']) < .25 ? .25 : _num(cpuRange['max']);
    final maxMem = _num(memRange['max']) < 512 ? 512.0 : _num(memRange['max']);
    return AlertDialog(
      title: const Text('New computer'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(
                        labelText: 'Name', border: OutlineInputBorder())),
                if (images.length > 1) ...[
                  const SizedBox(height: 14),
                  AppChoiceField<String>(
                    label: 'Image',
                    value: image,
                    onChanged: (v) => setState(() => image = v),
                    choices: [
                      for (final i in images)
                        AppChoice('${i['id']}', '${i['name']}',
                            hint: '${i['description'] ?? ''}'),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Text('${compactDecimal(cpu)} vCPU'),
                Slider(
                    value: cpu.clamp(.25, maxCpu),
                    min: .25,
                    max: maxCpu,
                    divisions: ((maxCpu - .25) / .25).round().clamp(1, 256),
                    onChanged: (v) => setState(() => cpu = v)),
                Text('${(memory / 1024).toStringAsFixed(2)} GB memory'),
                Slider(
                    value: memory.clamp(512, maxMem),
                    min: 512,
                    max: maxMem,
                    divisions: ((maxMem - 512) / 256).round().clamp(1, 512),
                    onChanged: (v) => setState(() => memory = v)),
              ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, {
                  'name': name.text.trim(),
                  'image': image,
                  'spec': {'cpu': cpu, 'memoryMb': memory.round()},
                }),
            child: const Text('Create and start')),
      ],
    );
  }
}

// ── storage ──────────────────────────────────────────────────────────────────

class _Storage extends _Loaded {
  const _Storage({super.key, required super.service, required super.org});
  @override
  State<_Storage> createState() => _StorageState();
}

class _StorageState extends _LoadedState<_Storage> {
  @override
  Future<_Json> fetch() async {
    final results = await Future.wait([call('storage_info'), call('files_list')]);
    return {'info': results[0], 'files': results[1]['files']};
  }

  static String bytes(dynamic v) {
    var n = _num(v);
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var u = 0;
    while (n >= 1024 && u < units.length - 1) {
      n /= 1024;
      u++;
    }
    return '${n.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
  }

  @override
  Widget content(BuildContext context) {
    final info = _map(data['info']);
    final files = _maps(data['files']);
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'Storage',
        child: Wrap(spacing: 24, runSpacing: 16, children: [
          _Figure('Stored', bytes(info['usedBytes']),
              hint: '${_count(info['files'])} files'),
          _Figure('A month', _usd(info['perMonth']),
              hint: '${_usd(info['priceGbMonth'])} per GB'),
          _Figure('Largest file', bytes(info['maxFileBytes'])),
        ]),
      ),
      _Card(
        title: 'Files',
        child: files.isEmpty
            ? _empty(context,
                'Files your code uploads through the API (/v1/files) show up here.')
            : Column(children: [
                for (final f in files)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text('${f['name']}'),
                    subtitle: Text(
                        '${bytes(f['size'])} · ${f['mime']} · ${_date(f['createdAt'])}'),
                    trailing: IconButton(
                        tooltip: 'Delete file',
                        onPressed: () async {
                          if (await _confirm(context, 'Delete ${f['name']}?',
                              'The file is removed for good.',
                              action: 'Delete')) {
                            await change(
                                () => call('file_delete', {'id': f['id']}));
                          }
                        },
                        icon: const Icon(Icons.delete_outline_rounded)),
                  ),
              ]),
      ),
    ]);
  }
}

// ── team ─────────────────────────────────────────────────────────────────────

class _Team extends _Loaded {
  const _Team(
      {super.key,
      required super.service,
      required super.org,
      required this.personal});
  final bool personal;
  @override
  State<_Team> createState() => _TeamState();
}

class _TeamState extends _LoadedState<_Team> {
  static const roles = ['admin', 'developer', 'viewer'];

  @override
  Future<_Json> fetch() async =>
      widget.personal ? const {} : await call('members_list');

  Future<void> _invite() async {
    final handle = await _ask(context, 'Invite someone', 'Username',
        hint: 'ada', action: 'Next');
    if (handle == null || handle.trim().isEmpty || !mounted) return;
    final role = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('@${handle.trim().replaceFirst('@', '')} joins as'),
        children: [
          for (final r in roles)
            SimpleDialogOption(
                onPressed: () => Navigator.pop(context, r), child: Text(r)),
        ],
      ),
    );
    if (role == null) return;
    await change(() => call('member_invite',
        {'handle': handle.trim().replaceFirst('@', ''), 'role': role}));
  }

  @override
  Widget content(BuildContext context) {
    if (widget.personal) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        _Card(
          title: 'Your personal organization',
          child: _empty(context,
              'It is yours alone and uses your own balance. Create an organization from the menu above to work with others and keep a separate balance.'),
        ),
      ]);
    }
    final members = _maps(data['members']);
    final manage = data['role'] == 'owner' || data['role'] == 'admin';
    return ListView(padding: const EdgeInsets.all(16), children: [
      _Card(
        title: 'People',
        trailing: manage
            ? FilledButton.icon(
                onPressed: _invite,
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: const Text('Invite'))
            : null,
        child: Column(children: [
          for (final m in members)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.person_outline_rounded),
              title: Text('${m['name'] ?? m['handle']}${m['you'] == true ? ' (you)' : ''}'),
              subtitle: Text('@${m['handle']} · ${m['role']} · ${m['status']}'),
              trailing: manage && m['role'] != 'owner'
                  ? PopupMenuButton<String>(
                      tooltip: 'Member options',
                      onSelected: (v) => change(() => v == 'remove'
                          ? call('member_remove', {'member': m['id']})
                          : call('member_role', {'member': m['id'], 'role': v})),
                      itemBuilder: (_) => [
                        for (final r in roles)
                          if (r != m['role'])
                            PopupMenuItem(value: r, child: Text('Make $r')),
                        const PopupMenuItem(
                            value: 'remove', child: Text('Remove')),
                      ],
                    )
                  : m['you'] == true && m['role'] != 'owner'
                      ? TextButton(
                          onPressed: () => change(
                              () => call('member_remove', {'member': m['id']})),
                          child: const Text('Leave'))
                      : null,
            ),
        ]),
      ),
    ]);
  }
}
