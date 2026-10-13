import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';

/// Wallet — a modal panel (dialog on desktop, bottom sheet on mobile) showing
/// the balance from `finance.wallet_get`, the ledger feed from
/// `finance.ledger_list`, demo credits via the faucet and peer transfers.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  static const _pageSize = 40;
  Wallet? _wallet;
  List<Map<String, dynamic>> _ledger = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || !_hasMore || _loading) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final offset = more ? _offset : 0;
      final ledger = await widget.dependencies.service
          .fetchLedger(limit: _pageSize, offset: offset);
      if (!mounted) return;
      setState(() {
        if (more) {
          _ledger = [..._ledger, ...ledger];
          _offset += ledger.length;
        } else {
          _ledger = ledger;
          _offset = ledger.length;
        }
        _hasMore = ledger.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
      if (!more) {
        final wallet = await widget.dependencies.service.fetchWallet();
        if (mounted) setState(() => _wallet = wallet);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _addFunds() async {
    try {
      final amount = await widget.dependencies.service.claimFaucet();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Claimed ${formatLedgerCredits(amount)}')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Faucet: $e')));
    }
  }

  Future<void> _transfer() async {
    final result = await showAppForm<(String, int)>(
        context,
        _TransferForm(
            service: widget.dependencies.service,
            available: _wallet?.balance ?? 0));
    if (result == null || !mounted) return;
    final (to, amount) = result;
    if (amount <= 0) return;
    try {
      await widget.dependencies.service.transferCredits(to, amount);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sent ${formatLedgerCredits(amount)}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Transfer failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final wallet = _wallet;
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    final mine =
        _ledger.where((e) => e['from_id'] == me || e['to_id'] == me).toList();
    return DefaultTabController(
      length: 2,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            compact ? 16 : 26, compact ? 16 : 22, compact ? 16 : 26, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PanelHeader(
            icon: Icons.account_balance_wallet_outlined,
            title: 'Wallet',
            subtitle: 'Fund your account and track platform usage',
            onClose: () => Navigator.pop(context),
            actions: [
              FilledButton.icon(
                onPressed: _loading ? null : _addFunds,
                icon: const Icon(Icons.water_drop_outlined, size: 18),
                label: const Text('Add funds'),
              ),
              IconButton(
                  tooltip: 'Transfer',
                  onPressed: _loading ? null : _transfer,
                  icon: const Icon(Icons.send_outlined)),
              IconButton(
                  tooltip: 'Refresh',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded)),
            ],
          ),
          const SizedBox(height: 14),
          SegmentedTabBar(
            compact: compact,
            alignment: Alignment.centerLeft,
            labels: const ['Overview', 'Transactions'],
            icons: const [Icons.dashboard_outlined, Icons.receipt_long_rounded],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : TabBarView(children: [
                        _OverviewTab(wallet: wallet!, onClaim: _addFunds),
                        _TransactionsTab(
                            entries: mine,
                            me: me,
                            hasMore: _hasMore,
                            loadingMore: _loadingMore,
                            onLoadMore: () => _load(more: true)),
                      ]),
          ),
        ]),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.wallet, this.onClaim});

  final Wallet wallet;
  final VoidCallback? onClaim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 18),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF153B68), Color(0xFF18254C)]),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.primary.withValues(alpha: .4)),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('AVAILABLE BALANCE',
                style: TextStyle(
                    color: scheme.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(formatLedgerCredits(wallet.available),
                style:
                    const TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
            Text(
                '${formatLedgerUsd(wallet.available)} · '
                '${formatLedgerCredits(wallet.locked)} locked',
                style: const TextStyle(fontSize: 11, color: AppColors.muted)),
          ]),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, box) {
          final columns = box.maxWidth >= 520
              ? 3
              : box.maxWidth >= 360
                  ? 2
                  : 1;
          final width = (box.maxWidth - (columns - 1) * 10) / columns;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            SizedBox(
              width: width,
              child: _Metric(
                  label: 'Balance',
                  value: formatLedgerCredits(wallet.balance),
                  color: AppColors.primary),
            ),
            SizedBox(
              width: width,
              child: _Metric(
                  label: 'Locked',
                  value: formatLedgerCredits(wallet.locked),
                  color: AppColors.warning),
            ),
            SizedBox(
              width: width,
              child: _Metric(
                  label: 'Available',
                  value: formatLedgerCredits(wallet.available),
                  color: AppColors.success),
            ),
          ]);
        }),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: .45),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.water_drop_outlined,
                  size: 19, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Demo faucet',
                        style: TextStyle(fontWeight: FontWeight.w800)),
                    Text(
                        'Claim free credits once per minute to test the platform.',
                        style: TextStyle(fontSize: 10)),
                  ]),
            ),
            FilledButton.tonal(
              onPressed: onClaim,
              child: const Text('Claim'),
            ),
          ]),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
      ]),
    );
  }
}

class _TransactionsTab extends StatelessWidget {
  const _TransactionsTab(
      {required this.entries,
      required this.me,
      this.hasMore = false,
      this.loadingMore = false,
      this.onLoadMore});

  final List<Map<String, dynamic>> entries;
  final String me;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (entries.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.receipt_long_rounded,
              size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text('No transactions yet — tap "Add funds".',
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      );
    }
    return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (hasMore && !loadingMore && n.metrics.extentAfter < 250) {
            onLoadMore?.call();
          }
          return false;
        },
        child: ListView.separated(
          padding: const EdgeInsets.only(top: 4, bottom: 18),
          itemCount: entries.length + (hasMore || loadingMore ? 1 : 0),
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            if (i >= entries.length) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.5))),
              );
            }
            return _Transaction(entry: entries[i], me: me);
          },
        ));
  }
}

class _Transaction extends StatelessWidget {
  const _Transaction({required this.entry, required this.me});

  final Map<String, dynamic> entry;
  final String me;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final from = entry['from_id'] as String? ?? '';
    final to = entry['to_id'] as String? ?? '';
    final amount = (entry['amount'] as num?)?.toInt() ?? 0;
    final incoming = to == me && from != me;
    final description = (entry['description'] as String?) ?? 'transfer';
    final createdAt = DateTime.tryParse(entry['created_at'] as String? ?? '');
    final time = createdAt == null
        ? ''
        : '${createdAt.month}/${createdAt.day} · ${createdAt.hour}:${createdAt.minute.toString().padLeft(2, '0')}';
    final peer = incoming ? from : to;
    final color = incoming ? AppColors.success : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(
            incoming ? Icons.south_west_rounded : Icons.north_east_rounded,
            size: 18,
            color: color,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(
              '${incoming ? 'from' : 'to'} @${peer.isEmpty ? '?' : peer.substring(0, 10)}${time.isEmpty ? '' : ' · $time'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
        Text('${incoming ? '+' : '−'}${formatLedgerCredits(amount)}',
            style: TextStyle(color: color, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// Sends credits to someone found by name, with the amount picked on a
/// slider capped at the balance.
class _TransferForm extends StatefulWidget {
  const _TransferForm({required this.service, required this.available});
  final TraderaService service;

  /// Balance in ledger units.
  final num available;

  @override
  State<_TransferForm> createState() => _TransferFormState();
}

class _TransferFormState extends State<_TransferForm> {
  final query = TextEditingController();
  List<AccountSummary> results = const [];
  AccountSummary? recipient;
  bool searching = false;
  Timer? debounce;
  late final double max =
      ledgerToCredits(widget.available).floorToDouble().clamp(0, 1e9);
  late double credits = max >= 10 ? 10 : max;

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void _search(String text) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = text.trim().replaceFirst(RegExp(r'^@+'), '');
      if (q.isEmpty) {
        if (mounted) setState(() => results = const []);
        return;
      }
      setState(() => searching = true);
      try {
        final found = await widget.service.searchUsers(q, limit: 6);
        if (mounted) setState(() => results = found);
      } catch (_) {
        if (mounted) setState(() => results = const []);
      } finally {
        if (mounted) setState(() => searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = query.text.trim();
    // A pasted 32-character account id works without a search match.
    final pastedId = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(raw);
    final to = recipient?.id ?? (pastedId ? raw : null);
    return AppFormFrame(
      icon: Icons.send_rounded,
      title: 'Send credits',
      subtitle: 'Moves credits from your wallet to another person right away.',
      submit: 'Send ${compactDecimal(credits)} credits',
      onSubmit: to == null || credits <= 0
          ? null
          : () => Navigator.pop(context, (to, creditsToLedger(credits))),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppFieldLabel('To'),
          if (recipient != null)
            InputChip(
              avatar: CircleAvatar(
                  child: Text(recipient!.handle.isEmpty
                      ? '?'
                      : recipient!.handle[0].toUpperCase())),
              label: Text('@${recipient!.handle}'),
              onDeleted: () => setState(() => recipient = null),
            )
          else ...[
            TextField(
              controller: query,
              autofocus: true,
              onChanged: (v) {
                setState(() {});
                _search(v);
              },
              decoration: InputDecoration(
                hintText: 'Search by @handle or email',
                prefixIcon: const Icon(Icons.person_search_rounded),
                suffixIcon: searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
            ),
            for (final r in results)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppShape.control)),
                leading: CircleAvatar(
                    child: Text(
                        r.handle.isEmpty ? '?' : r.handle[0].toUpperCase())),
                title: Text('@${r.handle}'),
                subtitle: Text(r.kind),
                onTap: () => setState(() => recipient = r),
              ),
            if (pastedId)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Sending to account $raw',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ),
          ],
        ]),
        AppAmountField(
          label: 'Amount',
          hint: '${compactDecimal(max)} credits available',
          value: credits.clamp(0, max <= 0 ? 0 : max).toDouble(),
          max: max <= 0 ? 1 : max,
          step: max >= 500 ? 10 : 1,
          decimals: 0,
          unit: 'credits',
          presets: [
            for (final p in const [10.0, 50.0, 100.0, 500.0])
              if (p <= max) p,
          ],
          presetLabel: compactDecimal,
          format: (v) => '${compactDecimal(v)} credits',
          onChanged: (v) => setState(() => credits = v),
        ),
      ],
    );
  }
}
