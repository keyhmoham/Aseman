import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/fleet_metric.dart';
import '../../../shared/widgets/settings_kit.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../admin/presentation/admin_widgets.dart';
import 'account_panel.dart';

typedef AccountAction =
    Future<void> Function(
      String namespace,
      String action,
      Map<String, dynamic> initialBody,
    );

class AccountHubContent extends StatefulWidget {
  const AccountHubContent({
    super.key,
    required this.area,
    required this.results,
    required this.onAction,
    required this.onNotifications,
    required this.notificationsSupported,
    this.shrinkWrap = false,
  });
  final AccountArea area;
  final Map<String, dynamic> results;
  final AccountAction onAction;
  final ValueChanged<bool> onNotifications;
  final bool notificationsSupported;

  /// Size to the content so settings can scroll this area with the page.
  final bool shrinkWrap;

  @override
  State<AccountHubContent> createState() => _AccountHubContentState();
}

class _AccountHubContentState extends State<AccountHubContent> {
  @override
  Widget build(BuildContext context) {
    if (widget.shrinkWrap) {
      // Settings: phone-width groups that flow with the page.
      return Column(
        key: ValueKey(widget.area),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          switch (widget.area) {
            AccountArea.invitations => _invitations(),
            AccountArea.wallet => _walletGroups(),
            AccountArea.usage => _usageGroup(),
            AccountArea.account => _accountGroups(),
          },
        ],
      );
    }
    // A phone-width panel gets the same groups as settings, not the wide
    // tables (which clip and scroll sideways).
    if (MediaQuery.sizeOf(context).width < Breakpoints.compact &&
        widget.area != AccountArea.invitations) {
      return ListView(
        key: PageStorageKey('${widget.area.name}-compact'),
        padding: const EdgeInsets.only(top: 4, bottom: 28),
        children: [
          switch (widget.area) {
            AccountArea.wallet => _walletGroups(),
            AccountArea.usage => _usageGroup(),
            _ => _accountGroups(),
          },
        ],
      );
    }
    return _scrolling(context);
  }

  Widget _scrolling(BuildContext context) => ListView(
    key: PageStorageKey(widget.area.name),
    shrinkWrap: widget.shrinkWrap,
    physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
    padding: const EdgeInsets.only(top: 4, bottom: 28),
    children: [
      switch (widget.area) {
        AccountArea.invitations => _invitations(),
        AccountArea.wallet => _wallet(),
        AccountArea.usage => _usage(),
        AccountArea.account => _account(),
      },
    ],
  );

  // ---------------------------------------------------- settings: account

  Widget _accountGroups() {
    final me = _map(widget.results['auth.me']);
    final config = _map(widget.results['auth.config']);
    final scheme = Theme.of(context).colorScheme;
    final verified = me['email_verified'] == true;
    final providers = _list(config['providers']).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          caption: 'Identity',
          dividerIndent: AppSpacing.md,
          children: [
            SettingsInfoRow(
              label: 'Username',
              value: '@${me['handle'] ?? '—'}',
            ),
            SettingsInfoRow(label: 'Email', value: '${me['email'] ?? ''}'),
            SettingsInfoRow(
              label: 'Email status',
              trailing: SettingsPill(
                verified ? 'Verified' : 'Not verified',
                icon: verified
                    ? Icons.check_circle_outline_rounded
                    : Icons.error_outline_rounded,
                color: verified
                    ? AppColors.successOf(context)
                    : AppColors.warningOf(context),
              ),
            ),
            if (providers.isNotEmpty)
              SettingsInfoRow(label: 'Sign-in method', value: providers),
          ],
        ),
        SettingsGroup(
          caption: 'Manage',
          children: [
            if (!verified)
              QuietTile(
                icon: Icons.mark_email_unread_outlined,
                label: 'Send verification email',
                subtitle:
                    'Confirm that ${me['email'] ?? 'your email'} is yours',
                onTap: () =>
                    widget.onAction('auth', 'send_verification', const {}),
              ),
            QuietTile(
              icon: Icons.person_outline,
              label: 'Edit identity',
              subtitle: 'Username and email',
              onTap: () => widget.onAction('auth', 'profile_update', {
                '_mode': 'identity',
                'handle': me['handle'],
                'email': me['email'],
              }),
            ),
            QuietTile(
              icon: Icons.password_rounded,
              label: 'Change password',
              onTap: () => widget.onAction('auth', 'profile_update', const {
                '_mode': 'password',
              }),
            ),
          ],
        ),
        if (widget.notificationsSupported)
          SettingsGroup(
            caption: 'Push notifications',
            footer:
                'Keeps project invitations, direct messages and agent events '
                'in sync on this device.',
            children: [
              QuietTile(
                icon: Icons.notifications_active_outlined,
                label: 'Enable on this device',
                onTap: () => widget.onNotifications(true),
              ),
              QuietTile(
                icon: Icons.notifications_off_outlined,
                label: 'Disable on this device',
                accent: scheme.onSurfaceVariant,
                onTap: () => widget.onNotifications(false),
              ),
            ],
          ),
        SettingsGroup(
          caption: 'Danger zone',
          footer:
              'Permanently deletes your identity, projects owned only by '
              'you, and wallet access.',
          children: [
            QuietTile(
              icon: Icons.delete_forever_outlined,
              label: 'Delete account',
              danger: true,
              onTap: () => widget.onAction('auth', 'account_delete', {
                'confirmation': 'DELETE',
              }),
            ),
          ],
        ),
      ],
    );
  }

  // ----------------------------------------------------- settings: wallet

  Widget _walletGroups() {
    final scheme = Theme.of(context).colorScheme;
    final account = _map(widget.results['finance.account']);
    final wallet = _map(widget.results['finance.wallet_get']);
    final activity = _maps(account['transactions']);
    final purchases = _maps(
      _map(widget.results['finance.purchases_mine'])['purchases'],
    );
    final balance = wallet['balance'] ?? account['balance'];
    final expiring =
        activity
            .where((t) => '${t['expires_at'] ?? ''}'.isNotEmpty)
            .where((g) => '${g['grant_status']}' != 'expired')
            .toList()
          ..sort(
            (a, b) => '${a['expires_at']}'.compareTo('${b['expires_at']}'),
          );
    final requests = _maps(
      _map(widget.results['finance.credit_requests_mine'])['requests'],
    );
    final pending = requests.where((r) => '${r['status']}' == 'pending');
    const shown = 12;

    Widget stat(String label, String value) => Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Balance: the one number people come here for.
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: SoftCard(
            radius: AppShape.card,
            wash: true,
            padding: const EdgeInsets.all(AppSpacing.md + 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const EyebrowLabel('Available balance'),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _credits(balance),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                    height: 1.1,
                  ),
                ),
                Text(
                  _usd(balance),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                FilledButton.icon(
                  onPressed: () =>
                      widget.onAction('finance', 'purchase_confirm', const {}),
                  icon: const Icon(Icons.add_card_rounded, size: 18),
                  label: const Text('Add credits'),
                ),
                const SizedBox(height: AppSpacing.md),
                Divider(
                  height: 1,
                  color: scheme.outlineVariant.withValues(alpha: .5),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    stat(
                      'Locked',
                      _credits(wallet['locked'] ?? account['locked']),
                    ),
                    stat('Bought', _credits(account['bought'])),
                    stat('Spent', _credits(account['spent'])),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (expiring.isNotEmpty)
          SettingsGroup(
            caption: 'Credits that expire',
            footer:
                'Granted credits are used first and lapse on their date if any are left.',
            children: [
              for (final g in expiring)
                QuietTile(
                  icon: Icons.hourglass_bottom_rounded,
                  label: '${g['base_description'] ?? 'Granted credits'}',
                  subtitle: 'Expires ${_date(g['expires_at'])}',
                  trailing: Text(
                    _signedCredits(g['amount']),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
            ],
          ),
        SettingsGroup(
          children: [
            QuietTile(
              icon: Icons.volunteer_activism_outlined,
              label: 'Complimentary credits',
              subtitle: pending.isEmpty
                  ? 'Ask the node admin for free credits'
                  : 'Your request is waiting for review',
              trailing: pending.isEmpty ? null : const SettingsPill('Pending'),
              onTap: pending.isEmpty
                  ? () => widget.onAction('finance', 'credit_request', const {})
                  : null,
            ),
          ],
        ),
        SettingsGroup(
          caption: 'Activity',
          footer: activity.length > shown
              ? 'Latest $shown of ${activity.length} entries.'
              : null,
          children: activity.isEmpty
              ? const [
                  SettingsEmpty(
                    icon: Icons.receipt_long_outlined,
                    title: 'No wallet activity yet',
                    message: 'Top-ups, grants and spending will appear here.',
                  ),
                ]
              : [
                  for (final e in activity.take(shown))
                    QuietTile(
                      icon: _num(e['amount']) >= 0
                          ? Icons.south_west_rounded
                          : Icons.north_east_rounded,
                      accent: _num(e['amount']) >= 0
                          ? AppColors.successOf(context)
                          : null,
                      label: '${e['description'] ?? ''}'.isEmpty
                          ? 'Wallet entry'
                          : '${e['description']}',
                      subtitle: [
                        _date(e['created_at']),
                        if (e['grant_status'] == 'expired') 'expired',
                      ].join(' · '),
                      trailing: Text(
                        _signedCredits(e['amount']),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: _num(e['amount']) >= 0
                              ? AppColors.successOf(context)
                              : scheme.onSurface,
                        ),
                      ),
                    ),
                ],
        ),
        if (purchases.isNotEmpty)
          SettingsGroup(
            caption: 'Purchases',
            children: [
              for (final p in purchases)
                QuietTile(
                  icon: Icons.receipt_long_outlined,
                  label: '${p['product_id'] ?? p['product'] ?? 'Credit pack'}',
                  subtitle:
                      '${_date(p['created_at'])} · ${p['status'] ?? 'credited'}',
                  trailing: Text(
                    _credits(p['amount'] ?? p['credits']),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
            ],
          ),
        if (widget.results.containsKey('usage.projects')) _usageGroup(),
      ],
    );
  }

  Widget _usageGroup() {
    final usage = _maps(_map(widget.results['usage.projects'])['projects']);
    final totalSpend = usage.fold<double>(
      0,
      (sum, row) => sum + _num(row['spent']),
    );
    return SettingsGroup(
      caption: 'Usage by project',
      footer: usage.isEmpty
          ? null
          : 'Total ${_credits(totalSpend)} (${_usd(totalSpend)}) across '
                '${usage.length} projects.',
      children: usage.isEmpty
          ? const [
              SettingsEmpty(
                icon: Icons.query_stats_outlined,
                title: 'No project usage yet',
              ),
            ]
          : [
              for (final p in usage)
                QuietTile(
                  icon: Icons.folder_outlined,
                  label: '${p['space_name'] ?? p['name'] ?? 'Project'}',
                  subtitle:
                      'Agent ${_credits(p['agent_time'])} · '
                      'Models ${_credits(p['llm'])}',
                  trailing: Text(
                    _credits(p['spent']),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  onTap: () => widget.onAction('usage', 'summary', {
                    'space': p['space_id'],
                    'limit': 500,
                  }),
                ),
            ],
    );
  }

  Widget _invitations() {
    final response = _map(widget.results['spaces.invitations_list']);
    final rows = _maps(response['invitations']);
    if (rows.isEmpty)
      return const AdminEmptyState(
        'No invitations',
        'New project invitations will appear here.',
        icon: Icons.mark_email_read_outlined,
      );
    return Column(
      children: [
        for (final invite in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SoftCard(
              showOrb: false,
              padding: const EdgeInsets.all(AppSpacing.sm + 2),
              child: Row(
                children: [
                  Builder(
                    builder: (context) {
                      const radius = 20.0;
                      final size = radius * 2;
                      final corners = context.avatarBorderRadius(size);
                      final picture = Avatars.of(invite['space_avatar']);
                      return HaloRing(
                        borderRadius: corners,
                        child: AvatarFace(
                          size: size,
                          borderRadius: corners,
                          backgroundColor: ThemeRoles.wellFill(context),
                          foregroundImage: picture,
                          onImageError: picture == null ? null : (_, __) {},
                          child: Icon(
                            Icons.folder_shared_outlined,
                            color: ThemeRoles.wellInk(context),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_map(invite['space'])['name'] ?? invite['space_name'] ?? 'Project invitation'}',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          'Invited by @${invite['inviter_handle'] ?? _map(invite['inviter'])['handle'] ?? 'a teammate'} · ${_date(invite['created_at'])}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => widget.onAction(
                          'spaces',
                          'invitation_decline',
                          {'invitation': invite['id']},
                        ),
                        child: const Text('Decline'),
                      ),
                      FilledButton(
                        onPressed: () => widget.onAction(
                          'spaces',
                          'invitation_accept',
                          {'invitation': invite['id']},
                        ),
                        child: const Text('Accept'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _wallet() {
    final account = _map(widget.results['finance.account']);
    final wallet = _map(widget.results['finance.wallet_get']);
    // The caller's own wallet activity, signed from their side (finance.ledger_list
    // is the node's whole ledger, not this person's).
    final activity = _maps(account['transactions']);
    final purchases = _maps(
      _map(widget.results['finance.purchases_mine'])['purchases'],
    );
    final balance = wallet['balance'] ?? account['balance'];
    // Credits granted with an end date: finance.account marks the ledger
    // entries that added them with when they lapse (or lapsed).
    final active =
        activity
            .where((t) => '${t['expires_at'] ?? ''}'.isNotEmpty)
            .where((g) => '${g['grant_status']}' != 'expired')
            .toList()
          ..sort(
            (a, b) => '${a['expires_at']}'.compareTo('${b['expires_at']}'),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Available balance',
                value: _credits(balance),
                hint: _usd(balance),
                color: AppColors.primaryOf(context),
                live: true,
              ),
            ),
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Locked',
                value: _credits(wallet['locked'] ?? account['locked']),
                hint: 'Reserved for active work',
              ),
            ),
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Lifetime bought',
                value: _credits(account['bought']),
                hint: '${purchases.length} credit packs',
              ),
            ),
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Lifetime spent',
                value: _credits(account['spent']),
                hint: 'Across projects',
              ),
            ),
          ],
        ),
        if (active.isNotEmpty) ...[
          const SizedBox(height: 18),
          AdminSectionCard(
            title: 'Credits that expire',
            icon: Icons.hourglass_bottom_rounded,
            subtitle:
                'Granted credits are used first and lapse on their date if any are left.',
            child: Column(
              children: [
                for (final g in active)
                  AdminKeyValue(
                    '${g['base_description'] ?? 'Granted credits'} · ${_signedCredits(g['amount'])}',
                    'expires ${_date(g['expires_at'])}',
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        _creditRequests(),
        const SizedBox(height: 18),
        Row(
          children: [
            const Expanded(child: EyebrowLabel('Wallet activity')),
            FilledButton.icon(
              onPressed: () =>
                  widget.onAction('finance', 'purchase_confirm', const {}),
              icon: const Icon(Icons.add_card_rounded, size: 17),
              label: const Text('Add credits'),
            ),
          ],
        ),
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
                Text(
                  '${e['description'] ?? ''}'.isEmpty
                      ? 'Wallet entry'
                      : '${e['description']}',
                ),
                AdminStatusPill(
                  e['grant_status'] == 'expired'
                      ? 'expired'
                      : '${e['type'] ?? 'entry'}',
                ),
                Text(_signedCredits(e['amount']), textAlign: TextAlign.right),
              ],
          ],
        ),
        if (purchases.isNotEmpty) ...[
          const SizedBox(height: 18),
          SoftCard(
            showOrb: false,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EyebrowLabel('Purchases'),
                const SizedBox(height: AppSpacing.sm),
                QuietList(
                  children: [
                    for (final p in purchases)
                      QuietTile(
                        icon: Icons.receipt_long_outlined,
                        label:
                            '${p['product_id'] ?? p['product'] ?? 'Credit pack'}',
                        subtitle: _date(p['created_at']),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _credits(p['amount'] ?? p['credits']),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            AdminStatusPill('${p['status'] ?? 'credited'}'),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        // Usage is melted into the wallet so spend and balance live together.
        if (widget.results.containsKey('usage.projects')) ...[
          const SizedBox(height: 28),
          const EyebrowLabel('Usage'),
          const SizedBox(height: 12),
          _usage(),
        ],
      ],
    );
  }

  Widget _usage() {
    final response = _map(widget.results['usage.projects']);
    final rows = _maps(response['projects']);
    final total = rows.fold<double>(0, (sum, row) => sum + _num(row['spent']));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Total spend',
                value: _credits(total),
                hint: _usd(total),
                color: AppColors.primaryOf(context),
              ),
            ),
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Projects',
                value: '${rows.length}',
                hint: 'With recorded usage',
              ),
            ),
            SizedBox(
              width: 168,
              child: FleetMetric(
                label: 'Events',
                value: '${response['events'] ?? response['event_count'] ?? 0}',
                hint: 'Billable activity',
              ),
            ),
          ],
        ),
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
            AdminTableColumn('Details', width: 130, align: TextAlign.right),
          ],
          rows: [
            for (final p in rows)
              [
                _primary(
                  '${p['space_name'] ?? p['name'] ?? 'Project'}',
                  '${p['space_id'] ?? ''}',
                ),
                Text(_credits(p['agent_time']), textAlign: TextAlign.right),
                Text(_credits(p['compute']), textAlign: TextAlign.right),
                Text(_credits(p['tools']), textAlign: TextAlign.right),
                Text(_credits(p['llm']), textAlign: TextAlign.right),
                Text(_credits(p['spent']), textAlign: TextAlign.right),
                TextButton(
                  onPressed: () => widget.onAction('usage', 'summary', {
                    'space': p['space_id'],
                    'limit': 500,
                  }),
                  child: const Text('Open'),
                ),
              ],
          ],
        ),
      ],
    );
  }

  Widget _creditRequests() {
    final requests = _maps(
      _map(widget.results['finance.credit_requests_mine'])['requests'],
    );
    final pending = requests
        .where((r) => '${r['status']}' == 'pending')
        .toList();
    return AdminSectionCard(
      title: 'Complimentary credits',
      subtitle: pending.isEmpty
          ? 'Ask the node admin for free credits when you need them.'
          : 'You have a request waiting for review.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in pending.take(3))
            AdminKeyValue(
              '${r['reason'] ?? 'Credit request'}',
              'pending · ${_date(r['created_at'])}',
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: pending.isNotEmpty
                  ? null
                  : () =>
                        widget.onAction('finance', 'credit_request', const {}),
              icon: const Icon(Icons.volunteer_activism_outlined, size: 17),
              label: Text(
                pending.isNotEmpty ? 'Request pending' : 'Apply for credits',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _account() {
    final me = _map(widget.results['auth.me']);
    final config = _map(widget.results['auth.config']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionCard(
          title: 'Sign-in identity',
          child: Column(
            children: [
              AdminKeyValue('Username', '@${me['handle'] ?? '—'}'),
              AdminKeyValue('Email', '${me['email'] ?? '—'}'),
              AdminKeyValue(
                'Email status',
                me['email_verified'] == true ? 'Verified' : 'Not verified',
              ),
              AdminKeyValue(
                'Authentication',
                _list(config['providers']).join(', '),
              ),
              if (me['email_verified'] != true)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () =>
                        widget.onAction('auth', 'send_verification', const {}),
                    child: const Text('Send verification email'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AdminSectionCard(
          title: 'Profile and password',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => widget.onAction('auth', 'profile_update', {
                  '_mode': 'identity',
                  'handle': me['handle'],
                  'email': me['email'],
                }),
                icon: const Icon(Icons.person_outline, size: 17),
                label: const Text('Edit identity'),
              ),
              OutlinedButton.icon(
                onPressed: () => widget.onAction(
                  'auth',
                  'profile_update',
                  const {'_mode': 'password'},
                ),
                icon: const Icon(Icons.password_rounded, size: 17),
                label: const Text('Change password'),
              ),
            ],
          ),
        ),
        if (widget.notificationsSupported) ...[
          const SizedBox(height: 18),
          AdminSectionCard(
            title: 'Notifications',
            subtitle:
                'Keep project invitations, direct messages and agent events in sync.',
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => widget.onNotifications(true),
                  child: const Text('Enable notifications'),
                ),
                OutlinedButton(
                  onPressed: () => widget.onNotifications(false),
                  child: const Text('Disable'),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        AdminSectionCard(
          title: 'Danger zone',
          subtitle:
              'Permanently delete your identity, projects owned only by you, and wallet access.',
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.dangerOf(context),
              ),
              onPressed: () => widget.onAction('auth', 'account_delete', {
                'confirmation': 'DELETE',
              }),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Delete account'),
            ),
          ),
        ),
      ],
    );
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

Widget _primary(String a, String b) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(a, style: const TextStyle(fontWeight: FontWeight.w800)),
    if (b.isNotEmpty)
      Builder(
        builder: (context) => Text(
          b,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
  ],
);
