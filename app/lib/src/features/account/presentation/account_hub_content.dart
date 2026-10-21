import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/avatar.dart';
import '../../admin/presentation/admin_widgets.dart';
import 'account_panel.dart';

typedef AccountAction = Future<void> Function(
    String namespace, String action, Map<String, dynamic> initialBody);

class AccountHubContent extends StatefulWidget {
  const AccountHubContent({
    super.key,
    required this.area,
    required this.results,
    required this.onAction,
    required this.onNotifications,
    required this.notificationsSupported,
  });
  final AccountArea area;
  final Map<String, dynamic> results;
  final AccountAction onAction;
  final ValueChanged<bool> onNotifications;
  final bool notificationsSupported;

  @override
  State<AccountHubContent> createState() => _AccountHubContentState();
}

class _AccountHubContentState extends State<AccountHubContent> {
  @override
  Widget build(BuildContext context) => ListView(
        key: PageStorageKey(widget.area.name),
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          switch (widget.area) {
            AccountArea.invitations => _invitations(),
            AccountArea.wallet => _wallet(),
            AccountArea.usage => _usage(),
            AccountArea.account => _account(),
          }
        ],
      );

  Widget _invitations() {
    final response = _map(widget.results['spaces.invitations_list']);
    final rows = _maps(response['invitations']);
    if (rows.isEmpty)
      return const AdminEmptyState(
          'No invitations', 'New project invitations will appear here.',
          icon: Icons.mark_email_read_outlined);
    return Column(children: [
      for (final invite in rows)
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: ListTile(
            contentPadding: const EdgeInsets.all(14),
            leading: CircleAvatar(
                foregroundImage: Avatars.of(invite['space_avatar']),
                onForegroundImageError:
                    Avatars.of(invite['space_avatar']) == null
                        ? null
                        : (_, __) {},
                child: const Icon(Icons.folder_shared_outlined)),
            title: Text(
                '${_map(invite['space'])['name'] ?? invite['space_name'] ?? 'Project invitation'}',
                style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text(
                'Invited by @${invite['inviter_handle'] ?? _map(invite['inviter'])['handle'] ?? 'a teammate'} · ${_date(invite['created_at'])}'),
            trailing: Wrap(spacing: 8, children: [
              OutlinedButton(
                  onPressed: () => widget.onAction('spaces',
                      'invitation_decline', {'invitation': invite['id']}),
                  child: const Text('Decline')),
              FilledButton(
                  onPressed: () => widget.onAction('spaces',
                      'invitation_accept', {'invitation': invite['id']}),
                  child: const Text('Accept')),
            ]),
          ),
        ),
    ]);
  }

  Widget _wallet() {
    final account = _map(widget.results['finance.account']);
    final wallet = _map(widget.results['finance.wallet_get']);
    // The caller's own wallet activity, signed from their side (finance.ledger_list
    // is the node's whole ledger, not this person's).
    final activity = _maps(account['transactions']);
    final purchases =
        _maps(_map(widget.results['finance.purchases_mine'])['purchases']);
    final balance = wallet['balance'] ?? account['balance'];
    // Credits granted with an end date: finance.account marks the ledger
    // entries that added them with when they lapse (or lapsed).
    final active = activity
        .where((t) => '${t['expires_at'] ?? ''}'.isNotEmpty)
        .where((g) => '${g['grant_status']}' != 'expired')
        .toList()
      ..sort((a, b) => '${a['expires_at']}'.compareTo('${b['expires_at']}'));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(minTileWidth: 150, children: [
        AdminStatCard(
            label: 'Available balance',
            value: _credits(balance),
            hint: _usd(balance),
            icon: Icons.account_balance_wallet_outlined,
            tone: AppColors.success),
        AdminStatCard(
            label: 'Locked',
            value: _credits(wallet['locked'] ?? account['locked']),
            hint: 'Reserved for active work',
            icon: Icons.lock_clock_outlined),
        AdminStatCard(
            label: 'Lifetime bought',
            value: _credits(account['bought']),
            hint: '${purchases.length} credit packs',
            icon: Icons.shopping_bag_outlined),
        AdminStatCard(
            label: 'Lifetime spent',
            value: _credits(account['spent']),
            hint: 'Across projects',
            icon: Icons.query_stats_outlined),
      ]),
      if (active.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'Credits that expire',
            icon: Icons.hourglass_bottom_rounded,
            subtitle:
                'Granted credits are used first and lapse on their date if any are left.',
            child: Column(children: [
              for (final g in active)
                AdminKeyValue(
                    '${g['base_description'] ?? 'Granted credits'} · ${_signedCredits(g['amount'])}',
                    'expires ${_date(g['expires_at'])}'),
            ])),
      ],
      const SizedBox(height: 18),
      Row(children: [
        Expanded(
            child: Text('WALLET ACTIVITY',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                    color: Theme.of(context).colorScheme.onSurfaceVariant))),
        FilledButton.icon(
            onPressed: () =>
                widget.onAction('finance', 'purchase_confirm', const {}),
            icon: const Icon(Icons.add_card_rounded, size: 17),
            label: const Text('Add credits')),
      ]),
      const SizedBox(height: 9),
      AdminDataTable(
        empty: 'No wallet activity yet.',
        columns: const [
          AdminTableColumn('When', width: 170),
          AdminTableColumn('Description', width: 340),
          AdminTableColumn('Type', width: 130),
          AdminTableColumn('Amount', width: 130, align: TextAlign.right),
        ],
        rows: [
          for (final e in activity)
            [
              Text(_date(e['created_at'])),
              Text('${e['description'] ?? ''}'.isEmpty
                  ? 'Wallet entry'
                  : '${e['description']}'),
              AdminStatusPill(e['grant_status'] == 'expired'
                  ? 'expired'
                  : '${e['type'] ?? 'entry'}'),
              Text(_signedCredits(e['amount']), textAlign: TextAlign.right),
            ]
        ],
      ),
      if (purchases.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'Purchases',
            child: Column(children: [
              for (final p in purchases)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.receipt_long_outlined),
                    title: Text(
                        '${p['product_id'] ?? p['product'] ?? 'Credit pack'}'),
                    subtitle: Text(_date(p['created_at'])),
                    trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_credits(p['amount'] ?? p['credits']),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800)),
                          AdminStatusPill('${p['status'] ?? 'credited'}')
                        ]))
            ])),
      ],
    ]);
  }

  Widget _usage() {
    final response = _map(widget.results['usage.projects']);
    final rows = _maps(response['projects']);
    final total = rows.fold<double>(0, (sum, row) => sum + _num(row['spent']));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminGrid(minTileWidth: 150, children: [
        AdminStatCard(
            label: 'Total spend',
            value: _credits(total),
            hint: _usd(total),
            icon: Icons.query_stats_rounded),
        AdminStatCard(
            label: 'Projects',
            value: '${rows.length}',
            hint: 'With recorded usage',
            icon: Icons.folder_outlined),
        AdminStatCard(
            label: 'Events',
            value: '${response['events'] ?? response['event_count'] ?? 0}',
            hint: 'Billable activity',
            icon: Icons.bolt_outlined),
      ]),
      const SizedBox(height: 18),
      AdminDataTable(
        empty: 'No project usage yet.',
        columns: const [
          AdminTableColumn('Project', width: 260),
          AdminTableColumn('Agent', width: 120, align: TextAlign.right),
          AdminTableColumn('Compute', width: 120, align: TextAlign.right),
          AdminTableColumn('Apps', width: 120, align: TextAlign.right),
          AdminTableColumn('Models', width: 120, align: TextAlign.right),
          AdminTableColumn('Total', width: 130, align: TextAlign.right),
          AdminTableColumn('Details', width: 130, align: TextAlign.right)
        ],
        rows: [
          for (final p in rows)
            [
              _primary('${p['space_name'] ?? p['name'] ?? 'Project'}',
                  '${p['space_id'] ?? ''}'),
              Text(_credits(p['agent_time']), textAlign: TextAlign.right),
              Text(_credits(p['compute']), textAlign: TextAlign.right),
              Text(_credits(p['tools']), textAlign: TextAlign.right),
              Text(_credits(p['llm']), textAlign: TextAlign.right),
              Text(_credits(p['spent']), textAlign: TextAlign.right),
              TextButton(
                  onPressed: () => widget.onAction('usage', 'summary',
                      {'space': p['space_id'], 'limit': 500}),
                  child: const Text('Open'))
            ]
        ],
      ),
    ]);
  }

  Widget _account() {
    final me = _map(widget.results['auth.me']);
    final config = _map(widget.results['auth.config']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSectionCard(
          title: 'Sign-in identity',
          child: Column(children: [
            AdminKeyValue('Username', '@${me['handle'] ?? '—'}'),
            AdminKeyValue('Email', '${me['email'] ?? '—'}'),
            AdminKeyValue('Email status',
                me['email_verified'] == true ? 'Verified' : 'Not verified'),
            AdminKeyValue(
                'Authentication', _list(config['providers']).join(', ')),
            if (me['email_verified'] != true)
              Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                      onPressed: () => widget
                          .onAction('auth', 'send_verification', const {}),
                      child: const Text('Send verification email'))),
          ])),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Profile and password',
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
                onPressed: () => widget.onAction('auth', 'profile_update', {
                      '_mode': 'identity',
                      'handle': me['handle'],
                      'email': me['email'],
                    }),
                icon: const Icon(Icons.person_outline, size: 17),
                label: const Text('Edit identity')),
            OutlinedButton.icon(
                onPressed: () => widget.onAction(
                    'auth', 'profile_update', const {'_mode': 'password'}),
                icon: const Icon(Icons.password_rounded, size: 17),
                label: const Text('Change password')),
          ])),
      if (widget.notificationsSupported) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'Notifications',
            subtitle:
                'Keep project invitations, direct messages and agent events in sync.',
            child: Wrap(spacing: 8, children: [
              FilledButton.tonal(
                  onPressed: () => widget.onNotifications(true),
                  child: const Text('Enable notifications')),
              OutlinedButton(
                  onPressed: () => widget.onNotifications(false),
                  child: const Text('Disable'))
            ])),
      ],
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Danger zone',
          subtitle:
              'Permanently delete your identity, projects owned only by you, and wallet access.',
          child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.danger),
                  onPressed: () => widget.onAction(
                      'auth', 'account_delete', {'confirmation': 'DELETE'}),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('Delete account')))),
    ]);
  }
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : {};
List<dynamic> _list(dynamic v) => v is List ? v : const [];
List<Map<String, dynamic>> _maps(dynamic v) =>
    _list(v).whereType<Map<dynamic, dynamic>>().map(_map).toList();
double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
String _credits(dynamic v) =>
    v == null ? '—' : formatLedgerCredits(_num(v), exact: true);
String _signedCredits(dynamic v) =>
    '${_num(v) >= 0 ? '+' : ''}${formatLedgerCredits(_num(v), exact: true)}';
String _usd(dynamic v) => formatLedgerUsd(_num(v));
String _date(dynamic v) {
  if (v == null || '$v'.isEmpty) return '—';
  final d = DateTime.tryParse('$v');
  if (d == null) return '$v';
  final x = d.toLocal();
  return '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')} ${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
}

Widget _primary(String a, String b) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(a, style: const TextStyle(fontWeight: FontWeight.w800)),
      if (b.isNotEmpty)
        Builder(
            builder: (context) => Text(b,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)))
    ]);
