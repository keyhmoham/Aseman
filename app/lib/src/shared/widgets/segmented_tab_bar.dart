import 'package:flutter/material.dart';

/// The app's signature segmented pill tab control (the same component used by
/// the search feed's Global / Following / Traders tabs). A rounded container
/// hosts a [TabBar] whose indicator is a soft pill; icons render on wide
/// screens and hide on compact ones. The controller is resolved from the
/// enclosing [DefaultTabController] unless one is passed explicitly.
///
/// The pill sizes to its tabs and scrolls horizontally when they overflow, so
/// captions always keep their natural size and every tab stays reachable.
class SegmentedTabBar extends StatelessWidget {
  const SegmentedTabBar({
    super.key,
    required this.labels,
    this.icons,
    this.controller,
    this.compact = false,
    this.alignment = Alignment.center,
    this.width,
  });

  final List<String> labels;
  final List<IconData>? icons;
  final TabController? controller;
  final bool compact;
  final Alignment alignment;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = controller ?? DefaultTabController.of(context);
    final w = width ?? (compact ? 320 : 440);
    return Align(
      alignment: alignment,
      child: Container(
        constraints: BoxConstraints(maxWidth: w),
        height: 52,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(26),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: .12),
                blurRadius: 18,
                offset: const Offset(0, 7)),
          ],
        ),
        child: TabBar(
          controller: tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          dividerColor: Colors.transparent,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                  color: scheme.primary.withValues(alpha: .15), blurRadius: 10),
            ],
          ),
          labelColor: scheme.onPrimaryContainer,
          unselectedLabelColor: scheme.onSurfaceVariant,
          labelStyle:
              const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          unselectedLabelStyle:
              const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          tabs: [
            for (var i = 0; i < labels.length; i++)
              Tab(
                height: 40,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (icons != null && icons!.length > i && !compact) ...[
                    Icon(icons![i], size: 17),
                    const SizedBox(width: 7),
                  ],
                  Text(labels[i]),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
