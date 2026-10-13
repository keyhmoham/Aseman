import 'package:flutter/material.dart';

/// The app's signature segmented pill tab control (the same component used by
/// the search feed's Global / Following / Traders tabs). A rounded container
/// hosts a [TabBar] whose indicator is a soft pill; icons render on wide
/// screens and hide on compact ones. The controller is resolved from the
/// enclosing [DefaultTabController] unless one is passed explicitly.
///
/// The pill sizes to its tabs and scrolls horizontally when they overflow, so
/// captions always keep their natural size and every tab stays reachable.
///
/// This is the app's one tab bar style. Screens without a [TabController]
/// pass [selectedIndex] and [onTap] instead; the bar then keeps its own
/// controller and animates to each new selection.
class SegmentedTabBar extends StatefulWidget {
  const SegmentedTabBar({
    super.key,
    required this.labels,
    this.icons,
    this.controller,
    this.compact = false,
    this.alignment = Alignment.center,
    this.width,
    this.selectedIndex,
    this.onTap,
  });

  final List<String> labels;
  final List<IconData>? icons;
  final TabController? controller;
  final bool compact;
  final Alignment alignment;
  final double? width;

  /// The selected tab when neither [controller] nor an enclosing
  /// [DefaultTabController] drives the bar.
  final int? selectedIndex;
  final ValueChanged<int>? onTap;

  @override
  State<SegmentedTabBar> createState() => _SegmentedTabBarState();
}

class _SegmentedTabBarState extends State<SegmentedTabBar>
    with TickerProviderStateMixin {
  TabController? _own;

  /// Uses the given or inherited controller; only a bar with neither owns one.
  TabController _controller(BuildContext context) {
    final given = widget.controller ?? DefaultTabController.maybeOf(context);
    if (given != null) {
      _retire(_own);
      _own = null;
      return given;
    }
    final index =
        (widget.selectedIndex ?? 0).clamp(0, widget.labels.length - 1).toInt();
    final own = _own;
    if (own == null || own.length != widget.labels.length) {
      _retire(own);
      return _own = TabController(
          length: widget.labels.length, initialIndex: index, vsync: this);
    }
    if (own.index != index) own.animateTo(index);
    return own;
  }

  /// Disposes a replaced controller once the tab bar has let go of it.
  void _retire(TabController? old) {
    if (old == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tabs = _controller(context);
    final labels = widget.labels;
    final icons = widget.icons;
    final compact = widget.compact;
    final w = widget.width ?? (compact ? 320 : 440);
    return Align(
      alignment: widget.alignment,
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
          onTap: widget.onTap,
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
                  if (icons != null && icons.length > i && !compact) ...[
                    Icon(icons[i], size: 17),
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
