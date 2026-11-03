import 'package:flutter/material.dart';

import '../../../../core/formatting/billing_units.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/avatar.dart';

class TopBar extends StatelessWidget {
  const TopBar({super.key, this.balance = 0, this.handle = 'me'});
  final int balance;
  final String handle;
  @override
  Widget build(BuildContext context) => Container(
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant))),
      child: Row(children: [
        Expanded(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: const TextField(
                    decoration: InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search rooms, agents, people, or apps',
                        isDense: true)))),
        const Spacer(),
        Icon(Icons.notifications_none_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant),
        const SizedBox(width: 22),
        Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('Wallet balance',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 11)),
              Text(formatLedgerCredits(balance),
                  style: const TextStyle(fontWeight: FontWeight.w700))
            ]),
        const SizedBox(width: 18),
        AppAvatar(handle.isEmpty ? 'ME' : handle[0].toUpperCase(),
            color: AppColors.primaryOf(context)),
        const SizedBox(width: 10),
        Text('@$handle', style: const TextStyle(fontWeight: FontWeight.w700)),
      ]));
}
