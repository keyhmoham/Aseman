import 'package:flutter/material.dart';

import '../../shared/widgets/overlay_panels.dart';
import '../../shared/widgets/panel_header.dart';
import '../../shared/widgets/panel_scaffold.dart';

/// Short public marketing blurbs (Pricing / How it works).
Future<void> showMarketingPage(
  BuildContext context, {
  required String title,
  required String body,
}) =>
    showFloatingPanel(
      context,
      PanelScaffold(
        header: PanelHeader(
          title: title,
          subtitle: 'About Aseman',
          icon: Icons.info_outline_rounded,
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            Text(body, style: const TextStyle(height: 1.45, fontSize: 15)),
          ],
        ),
      ),
      maxWidth: 480,
    );

const pricingBlurb =
    'Aseman is free to start. Buy credits for agent work, models and compute. '
    'Granted and purchased credits appear in your wallet; projects spend from '
    'the balance of whoever pays for the work.';

const howItWorksBlurb =
    'Create a project, add agents and apps, and work in rooms and chats. '
    'Your personal Decillion assistant has a chat of its own. Invite people, share files, '
    'and let agents handle research and routine work with your approval.';

/// Compact text links for the signed-out auth shell.
class MarketingLinkRow extends StatelessWidget {
  const MarketingLinkRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      children: [
        TextButton(
          onPressed: () => showMarketingPage(context,
              title: 'Pricing', body: pricingBlurb),
          child: const Text('Pricing'),
        ),
        TextButton(
          onPressed: () => showMarketingPage(context,
              title: 'How it works', body: howItWorksBlurb),
          child: const Text('How it works'),
        ),
      ],
    );
  }
}
