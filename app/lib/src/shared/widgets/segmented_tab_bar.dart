import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_surfaces.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/design_language.dart';
import '../../core/theme/theme_chrome.dart';

/// The app's signature segmented pill tab control (the same component used by
/// the search feed's Global / Following / People tabs). A rounded container
/// hosts a [TabBar] whose indicator is M3 secondary-container; icons render
/// on wide screens and hide on compact ones. The controller is resolved from
/// the enclosing [DefaultTabController] unless one is passed explicitly.
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
    // Never animate during build — chats poll updates unread labels
    // ("All" → "All · 2") and a mid-build animateTo can trip the framework
    // into an ErrorWidget under the filter row.
    if (own.index != index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final live = _own;
        if (live != null && live.index != index && live.length > index) {
          live.animateTo(index);
        }
      });
    }
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
    final tokens = AsemanTokens.maybeOf(context);
    final tabs = _controller(context);
    final labels = widget.labels;
    final icons = widget.icons;
    final compact = widget.compact;
    final w = widget.width ?? (compact ? 320 : 440);
    final base = Theme.of(context).textTheme.labelLarge ?? const TextStyle();
    final selectedStyle =
        base.copyWith(fontSize: 12.5, fontWeight: FontWeight.w800);
    final unselectedStyle =
        base.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500);
    final showIcons = icons != null && !compact;
    // The width the tabs need side by side: each label (measured bold, its
    // widest state), its icon and the tab's 16 px padding on both sides,
    // plus the pill's own padding and border.
    final scaler = MediaQuery.textScalerOf(context);
    var natural = 4.0 * 2 + 1 * 2 + 2;
    for (var i = 0; i < labels.length; i++) {
      final painter = TextPainter(
        text: TextSpan(text: labels[i], style: selectedStyle),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      natural += painter.width.ceilToDouble() + 32 + 1;
      if (showIcons && icons.length > i) natural += 17 + 7;
      painter.dispose();
    }
    return Align(
      alignment: widget.alignment,
      child: LayoutBuilder(builder: (context, constraints) {
        final room =
            constraints.hasBoundedWidth ? math.min(w, constraints.maxWidth) : w;
        // Shrink to the tabs when they fit; otherwise fill the room and
        // let the tabs scroll.
        final navH =
            tokens?.language.denseControlHeight ?? 40;
        final barH = navH + 12;
        final iconSz = (tokens?.language.iconSize ?? 22) - 5;
        return Container(
          width: math.min(natural, room),
          height: barH,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: tokens?.control('nav_pill').fill == FillKind.glass
                ? AppSurfaces.overlay(scheme, tokens: tokens)
                : AppSurfaces.card(scheme, tokens: tokens),
            borderRadius: context.navPillBorderRadius,
            border: Border.all(
              color: AppSurfaces.cardBorder(scheme).withValues(
                    alpha: tokens?.control('nav_pill').borderAlpha ?? 1,
                  ),
              width: (tokens?.control('nav_pill').borderWidth ?? 0) > 0
                  ? tokens!.control('nav_pill').borderWidth
                  : 1,
            ),
            boxShadow: (tokens?.control('nav_pill').elevation ?? 0) > 0 ||
                    tokens?.language.shadow.alpha != 0
                ? context.themeShadow(accent: scheme.primary)
                : null,
          ),
          child: TabBar(
            controller: tabs,
            onTap: widget.onTap,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            dividerColor: Colors.transparent,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: AppFab.tabIndicatorOf(scheme, tokens: tokens),
            labelColor: AppFab.tabIndicatorInkOf(scheme),
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: selectedStyle,
            unselectedLabelStyle: unselectedStyle,
            tabs: [
              for (var i = 0; i < labels.length; i++)
                Tab(
                  height: navH,
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (showIcons && icons.length > i) ...[
                      Icon(icons[i], size: iconSz),
                      const SizedBox(width: 7),
                    ],
                    Text(labels[i]),
                  ]),
                ),
            ],
          ),
        );
      }),
    );
  }
}
