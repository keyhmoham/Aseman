import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../admin/presentation/admin_widgets.dart';

typedef AccountAction = Future<void> Function(
    String namespace, String action, Map<String, dynamic> initialBody);

class AccountHubContent extends StatefulWidget {
  const AccountHubContent({
    super.key,
    required this.area,
    required this.results,
    required this.onAction,
    required this.onUpload,
    required this.onNotifications,
    required this.notificationsSupported,
  });
  final String area;
  final Map<String, dynamic> results;
  final AccountAction onAction;
  final VoidCallback onUpload;
  final ValueChanged<bool> onNotifications;
  final bool notificationsSupported;

  @override
  State<AccountHubContent> createState() => _AccountHubContentState();
}

class _AccountHubContentState extends State<AccountHubContent> {
  final search = TextEditingController();
  @override
  void didUpdateWidget(covariant AccountHubContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.area != widget.area) search.clear();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        key: PageStorageKey(widget.area),
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          switch (widget.area) {
            'Invitations' => _invitations(),
            'Messages' => _messages(),
            'Billing' => _billing(),
            'Payout' => _payout(),
            'Usage' => _usage(),
            'Profile' => _profile(),
            'Account' => _account(),
            _ => const SizedBox.shrink(),
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
            leading:
                const CircleAvatar(child: Icon(Icons.folder_shared_outlined)),
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

  Widget _messages() {
    final rows = _maps(_map(widget.results['users.dm_threads'])['threads']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AdminSearchField(
          controller: search,
          hint: 'Search conversations',
          onChanged: (_) => setState(() {}),
          trailing: FilledButton.icon(
              onPressed: () => widget.onAction('users', 'dm_send', const {}),
              icon: const Icon(Icons.edit_square, size: 17),
              label: const Text('New message'))),
      const SizedBox(height: 14),
      if (rows.isEmpty)
        const AdminEmptyState('No messages',
            'Direct conversations with people and agents appear here.',
            icon: Icons.forum_outlined)
      else
        AdminSectionCard(
          title: 'Conversations',
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (final thread in rows.where((t) =>
                search.text.isEmpty ||
                '${t['handle']} ${t['name']} ${t['last_message']}'
                    .toLowerCase()
                    .contains(search.text.toLowerCase())))
              ListTile(
                leading: CircleAvatar(
                    child: Text('${thread['handle'] ?? thread['name'] ?? '?'}'
                        .characters
                        .first
                        .toUpperCase())),
                title: Text(
                    '${thread['name'] ?? '@${thread['handle'] ?? 'conversation'}'}',
                    style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: Text(
                    '${thread['last_message'] ?? 'Open the conversation'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(_date(thread['updated_at'] ?? thread['last_at']),
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.muted)),
                      if (_num(thread['unread']) > 0)
                        Badge(label: Text('${_num(thread['unread']).round()}')),
                    ]),
                onTap: () => widget.onAction('users', 'dm_list', {
                  'peer':
                      thread['peer_id'] ?? thread['account_id'] ?? thread['id']
                }),
              ),
          ]),
        ),
    ]);
  }

  Widget _billing() {
    final account = _map(widget.results['finance.account']);
    final wallet = _map(widget.results['finance.wallet_get']);
    final ledger = _maps(
        _map(widget.results['finance.ledger_list'])['entries'] ??
            _map(widget.results['finance.ledger_list'])['ledger']);
    final purchases =
        _maps(_map(widget.results['finance.purchases_mine'])['purchases']);
    final balance = wallet['balance'] ?? account['balance'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Available balance',
                value: _credits(balance),
                hint: _usd(balance),
                icon: Icons.account_balance_wallet_outlined,
                tone: AppColors.success)),
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Locked',
                value: _credits(wallet['locked'] ?? account['locked']),
                hint: 'Reserved for active work',
                icon: Icons.lock_clock_outlined)),
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Lifetime bought',
                value: _credits(account['bought']),
                hint: '${purchases.length} credit packs',
                icon: Icons.shopping_bag_outlined)),
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Lifetime spent',
                value: _credits(account['spent']),
                hint: 'Across projects',
                icon: Icons.query_stats_outlined)),
      ]),
      const SizedBox(height: 18),
      Row(children: [
        const Expanded(
            child: Text('WALLET ACTIVITY',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w900,
                    letterSpacing: .8,
                    color: AppColors.muted))),
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
          AdminTableColumn('Description', width: 300),
          AdminTableColumn('Type', width: 130),
          AdminTableColumn('Amount', width: 130, align: TextAlign.right),
          AdminTableColumn('Balance', width: 130, align: TextAlign.right),
        ],
        rows: [
          for (final e in ledger)
            [
              Text(_date(e['created_at'])),
              Text(
                  '${e['description'] ?? e['reason'] ?? e['kind'] ?? 'Wallet entry'}'),
              AdminStatusPill('${e['kind'] ?? e['type'] ?? 'entry'}'),
              Text(_signedCredits(e['amount']), textAlign: TextAlign.right),
              Text(_credits(e['balance']), textAlign: TextAlign.right)
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

  Widget _payout() {
    final account = _map(widget.results['finance.account']);
    final payouts = _maps(account['payouts']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        SizedBox(
            width: 230,
            child: AdminStatCard(
                label: 'Creator earnings',
                value: _credits(account['earned']),
                hint: _usd(account['earned']),
                icon: Icons.auto_graph_rounded,
                tone: AppColors.success)),
        SizedBox(
            width: 230,
            child: AdminStatCard(
                label: 'Available to withdraw',
                value:
                    _credits(account['withdrawable'] ?? account['available']),
                hint: 'After pending reservations',
                icon: Icons.payments_outlined)),
        SizedBox(
            width: 230,
            child: AdminStatCard(
                label: 'Pending payout',
                value: _credits(account['payout_pending']),
                hint: 'Awaiting operator settlement',
                icon: Icons.hourglass_top_rounded,
                tone: AppColors.warning)),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
        title: 'Withdraw earnings',
        subtitle:
            'Choose your method and destination. The amount stays reserved until the operator pays or rejects it.',
        child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
                onPressed: () =>
                    widget.onAction('finance', 'payout_request', const {}),
                icon: const Icon(Icons.north_east_rounded, size: 17),
                label: const Text('Request payout'))),
      ),
      const SizedBox(height: 18),
      AdminDataTable(
        empty: 'No payout requests yet.',
        columns: const [
          AdminTableColumn('Requested', width: 170),
          AdminTableColumn('Method', width: 150),
          AdminTableColumn('Amount', width: 130, align: TextAlign.right),
          AdminTableColumn('Status', width: 130),
          AdminTableColumn('Reference', width: 220)
        ],
        rows: [
          for (final p in payouts)
            [
              Text(_date(p['created_at'])),
              Text('${p['method'] ?? 'external'}'),
              Text(_credits(p['amount']), textAlign: TextAlign.right),
              AdminStatusPill('${p['status'] ?? 'pending'}'),
              Text('${p['provider_reference'] ?? '—'}')
            ]
        ],
      ),
    ]);
  }

  Widget _usage() {
    final response = _map(widget.results['usage.projects']);
    final rows = _maps(response['projects']);
    final total = rows.fold<double>(0, (sum, row) => sum + _num(row['spent']));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Total spend',
                value: _credits(total),
                hint: _usd(total),
                icon: Icons.query_stats_rounded)),
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Projects',
                value: '${rows.length}',
                hint: 'With recorded usage',
                icon: Icons.folder_outlined)),
        SizedBox(
            width: 220,
            child: AdminStatCard(
                label: 'Events',
                value: '${response['events'] ?? response['event_count'] ?? 0}',
                hint: 'Billable activity',
                icon: Icons.bolt_outlined)),
      ]),
      const SizedBox(height: 18),
      AdminDataTable(
        empty: 'No project usage yet.',
        columns: const [
          AdminTableColumn('Project', width: 260),
          AdminTableColumn('Agent', width: 120, align: TextAlign.right),
          AdminTableColumn('Compute', width: 120, align: TextAlign.right),
          AdminTableColumn('Tools', width: 120, align: TextAlign.right),
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

  Widget _profile() {
    final me = _map(widget.results['auth.me']);
    final profile = _map(me['profile']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
                radius: 38,
                backgroundImage: '${profile['avatar_url'] ?? ''}'.isEmpty
                    ? null
                    : NetworkImage('${profile['avatar_url']}'),
                child: '${profile['avatar_url'] ?? ''}'.isEmpty
                    ? Text(
                        '${me['handle'] ?? '?'}'.characters.first.toUpperCase(),
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w900))
                    : null),
            const SizedBox(width: 18),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(_name(me),
                      style: const TextStyle(
                          fontSize: 21, fontWeight: FontWeight.w900)),
                  Text('@${me['handle'] ?? ''}',
                      style: const TextStyle(color: AppColors.muted)),
                  if ('${profile['bio'] ?? ''}'.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text('${profile['bio']}')
                  ],
                  const SizedBox(height: 12),
                  Wrap(spacing: 14, children: [
                    Text('${me['followers'] ?? 0} followers'),
                    Text('${me['following'] ?? 0} following'),
                    Text('${me['posts'] ?? 0} posts')
                  ]),
                  const SizedBox(height: 14),
                  FilledButton.tonalIcon(
                      onPressed: () => widget.onAction(
                          'auth', 'profile_update', {'profile': profile}),
                      icon: const Icon(Icons.edit_outlined, size: 17),
                      label: const Text('Edit profile')),
                ])),
          ]),
        ),
      ),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Profile files',
          subtitle: 'Documents and media attached to your public identity.',
          child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                  onPressed: widget.onUpload,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Upload profile file')))),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Public metadata',
          child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                  onPressed: () =>
                      widget.onAction('users', 'metadata_public', const {}),
                  child: const Text('Edit public metadata')))),
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
                onPressed: () => widget.onAction('auth', 'profile_update',
                    {'profile': me['profile'] ?? <String, dynamic>{}}),
                icon: const Icon(Icons.person_outline, size: 17),
                label: const Text('Edit identity')),
            OutlinedButton.icon(
                onPressed: () =>
                    widget.onAction('auth', 'profile_update', const {}),
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

String _name(Map<String, dynamic> me) {
  final p = _map(me['profile']);
  final n = [p['firstName'] ?? p['first_name'], p['lastName'] ?? p['last_name']]
      .where((x) => x != null && '$x'.trim().isNotEmpty)
      .join(' ');
  return n.isEmpty ? '${me['handle'] ?? 'User'}' : n;
}

Widget _primary(String a, String b) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(a, style: const TextStyle(fontWeight: FontWeight.w800)),
      if (b.isNotEmpty)
        Text(b, style: const TextStyle(fontSize: 10, color: AppColors.muted))
    ]);
