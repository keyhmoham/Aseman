import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';

/// Shared body chrome for modal panels (My bots, Market, Requests, …).
///
/// Composes a fixed [header], an optional [toolbar] (search / tabs / filters),
/// and an expanded [body] with consistent outer padding and section gaps.
class PanelScaffold extends StatelessWidget {
  const PanelScaffold({
    super.key,
    required this.header,
    required this.body,
    this.toolbar,
    this.compact,
  });

  final Widget header;

  /// Content between the header and the scrollable body (tabs, search, …).
  final Widget? toolbar;
  final Widget body;

  /// When null, compact mode is inferred from width &lt; 560.
  final bool? compact;

  @override
  Widget build(BuildContext context) {
    final isCompact =
        compact ?? MediaQuery.sizeOf(context).width < 560;
    return Padding(
      padding: AppSpacing.panelPadding(isCompact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (toolbar != null) ...[
            const SizedBox(height: AppSpacing.sm + 2),
            toolbar!,
            const SizedBox(height: AppSpacing.sm),
          ] else
            const SizedBox(height: AppSpacing.sm),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Quiet uppercase section caption used above grids and lists.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w800,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}
