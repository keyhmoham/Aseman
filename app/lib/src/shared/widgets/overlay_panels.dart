import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import 'glass_surface.dart';

/// Slide/scale transition used for every desktop modal: rises from below
/// while gently scaling in.
///
/// Deliberately avoids [Opacity] / [FadeTransition] — those force an
/// offscreen layer and make [BackdropFilter] glass look solid.
Widget desktopFloatingPanelTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child,
) {
  final eased = CurvedAnimation(
    parent: animation,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  final travel = math.min(240.0, MediaQuery.sizeOf(context).height * .28);
  return AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, panel) {
      final motion = eased.value.clamp(0.0, 1.08);
      final scale = .955 + .045 * motion.clamp(0.0, 1.0);
      return Transform.translate(
        offset: Offset(0, travel * (1 - motion)),
        child: Transform.scale(scale: scale, child: panel),
      );
    },
  );
}

/// Opens [builder]'s widget as a desktop modal with the shared bottom-to-top
/// motion. Prefer this over [showDialog] so every overlay matches.
///
/// When [frosted] is true (default) the dialog body is painted on
/// [GlassSurface]: [AlertDialog]s are flattened into the frost, plain content
/// is wrapped, and builders that already paint [FloatingPanelSurface] /
/// [GlassSurface] should pass `frosted: false`.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  String barrierLabel = 'Dismiss',
  bool frosted = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierLabel: barrierLabel,
  // Scrim is painted with the frost when [frosted]; otherwise the shared
  // barrier colour sits behind panels that already bring their own glass.
  barrierColor: frosted ? Colors.transparent : AppSurfaces.barrier,
  transitionDuration: const Duration(milliseconds: 420),
  pageBuilder: (routeContext, animation, __) {
    final built = builder(routeContext);
    if (!frosted) {
      return desktopFloatingPanelTransition(routeContext, animation, built);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // Dim + dismiss under the panel. Blur lives on the dialog shape
        // itself (see [_frostDialog]) so we do not Opacity-wrap a filter.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: barrierDismissible
              ? () => Navigator.of(routeContext).maybePop()
              : null,
          child: const ColoredBox(color: AppSurfaces.barrier),
        ),
        desktopFloatingPanelTransition(
          routeContext,
          animation,
          _frostDialog(routeContext, built),
        ),
      ],
    );
  },
  // Motion is applied in [pageBuilder] so the scrim stays put.
  transitionBuilder: (_, __, ___, child) => child,
);

/// Puts [child] on the shared frosted dialog chrome.
Widget _frostDialog(BuildContext context, Widget child) {
  final radius = BorderRadius.circular(AppShape.card);
  if (child is AlertDialog) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlpha,
        blur: AppSurfaces.blurSigma,
        borderRadius: radius,
        child: _AlertDialogPane(dialog: child),
      ),
    );
  }
  if (child is Dialog) {
    // Already a Dialog — keep positioning, force clear chrome, frost body.
    final body = child.child ?? const SizedBox.shrink();
    if (body is GlassSurface || body is FloatingPanelSurface) {
      return child;
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: child.insetPadding,
      alignment: child.alignment,
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlpha,
        blur: AppSurfaces.blurSigma,
        borderRadius: radius,
        child: body,
      ),
    );
  }
  // Custom widgets (often build an AlertDialog themselves): frost the
  // backdrop behind a translucent themed dialog so blur still reads.
  return BackdropFilter(
    filter: ImageFilter.blur(
      sigmaX: AppSurfaces.blurSigma,
      sigmaY: AppSurfaces.blurSigma,
    ),
    child: Theme(
      data: Theme.of(context).copyWith(
        dialogTheme: Theme.of(context).dialogTheme.copyWith(
          backgroundColor: AppSurfaces.overlay(Theme.of(context).colorScheme),
        ),
      ),
      child: child,
    ),
  );
}

/// AlertDialog layout without a nested [Dialog], so it can sit inside
/// [GlassSurface].
class _AlertDialogPane extends StatelessWidget {
  const _AlertDialogPane({required this.dialog});
  final AlertDialog dialog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = dialog.titleTextStyle ?? theme.textTheme.headlineSmall;
    final contentStyle = dialog.contentTextStyle ?? theme.textTheme.bodyMedium;
    final iconPadding =
        dialog.iconPadding ??
        const EdgeInsets.only(left: 24, top: 24, right: 24);
    final titlePadding =
        dialog.titlePadding ??
        EdgeInsets.fromLTRB(
          24,
          dialog.icon == null ? 24 : 0,
          24,
          dialog.content == null && dialog.actions == null ? 20 : 0,
        );
    final contentPadding =
        dialog.contentPadding ??
        EdgeInsets.fromLTRB(
          24,
          dialog.title == null && dialog.icon == null ? 20 : 16,
          24,
          dialog.actions == null ? 20 : 0,
        );
    final actionsPadding =
        dialog.actionsPadding ?? const EdgeInsets.fromLTRB(24, 16, 24, 16);
    final children = <Widget>[
      if (dialog.icon != null)
        Padding(
          padding: iconPadding,
          child: IconTheme.merge(
            data: IconThemeData(
              color: dialog.iconColor ?? theme.colorScheme.secondary,
              size: 24,
            ),
            child: dialog.icon!,
          ),
        ),
      if (dialog.title != null)
        Padding(
          padding: titlePadding,
          child: DefaultTextStyle(
            style: titleStyle!,
            textAlign: dialog.icon != null ? TextAlign.center : TextAlign.start,
            child: dialog.title!,
          ),
        ),
      if (dialog.content != null)
        Flexible(
          child: Padding(
            padding: contentPadding,
            child: DefaultTextStyle(
              style: contentStyle!,
              child: dialog.content!,
            ),
          ),
        ),
      if (dialog.actions != null && dialog.actions!.isNotEmpty)
        Padding(
          padding: actionsPadding,
          child: OverflowBar(
            alignment: dialog.actionsAlignment ?? MainAxisAlignment.end,
            spacing: 8,
            children: dialog.actions!,
          ),
        ),
    ];
    return ConstrainedBox(
      constraints:
          dialog.constraints ??
          const BoxConstraints(minWidth: 280, maxWidth: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// Marks the subtree as content of [showAppSheet]'s frosted chrome.
///
/// Content containers that paint their own glass as a body should pass
/// `embedded: AppSheetScope.inSheetOf(context)` (or an explicit
/// `inBottomSheet` flag) so the sheet owns the frost and the body stays
/// transparent.
class AppSheetScope extends InheritedWidget {
  const AppSheetScope({super.key, required super.child});

  /// Whether [context] sits inside a [showAppSheet] glass host.
  static bool inSheetOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppSheetScope>() != null;

  @override
  bool updateShouldNotify(covariant AppSheetScope oldWidget) => false;
}

/// Drag handle painted *inside* [GlassSurface] so it never sits on clear
/// Material chrome (Material's own handle is drawn above the builder).
class _AppSheetDragHandle extends StatelessWidget {
  const _AppSheetDragHandle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sheetTheme = theme.bottomSheetTheme;
    final size = sheetTheme.dragHandleSize ?? const Size(32, 4);
    final color =
        sheetTheme.dragHandleColor ??
        theme.colorScheme.onSurfaceVariant.withValues(alpha: .4);
    return SizedBox(
      height: kMinInteractiveDimension,
      width: double.infinity,
      child: Center(
        child: Semantics(
          label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
          container: true,
          child: Container(
            width: size.width,
            height: size.height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(size.height / 2),
            ),
          ),
        ),
      ),
    );
  }
}

/// Frosted sheet chrome: glass + optional handle wrap [child], and
/// [AppSheetScope] tells content containers to stay transparent.
///
/// The body sits in [_SheetScroll]. A short body stays short; a body taller
/// than the room under the handle scrolls instead of being clipped.
Widget _appSheetChrome({
  required Widget child,
  bool showDragHandle = true,
  bool expandBody = false,
}) {
  const radius = BorderRadius.vertical(top: Radius.circular(AppShape.card));
  final body = _SheetScroll(child: AppSheetScope(child: child));
  final column = Column(
    mainAxisSize: expandBody ? MainAxisSize.max : MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showDragHandle) const _AppSheetDragHandle(),
      // Loose fit: the body may be shorter than the leftover height, and it
      // is never taller, so the handle stays on screen while the body scrolls.
      if (expandBody) Expanded(child: body) else Flexible(child: body),
    ],
  );
  return GlassSurface(
    alpha: AppSurfaces.overlayAlpha,
    blur: AppSurfaces.blurSigma,
    borderRadius: radius,
    border: false,
    child: column,
  );
}

/// Hugs [child] when it fits. When [child] is taller than the height the sheet
/// can give, clips to that height and scrolls vertically.
///
/// A child that already flexes or scrolls (an [Expanded] column, a [ListView])
/// keeps a bounded height and scrolls itself. A plain column of tiles is laid
/// out at its full height and scrolled here.
class _SheetScroll extends SingleChildRenderObjectWidget {
  const _SheetScroll({required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSheetScroll();
}

class _RenderSheetScroll extends RenderProxyBox {
  VerticalDragGestureRecognizer? _drag;
  double _offset = 0;
  double _contentHeight = 0;
  bool _canScroll = false;

  double get _maxOffset => math.max(0, _contentHeight - size.height);

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (!_canScroll) return;
    if (event is PointerScrollEvent) {
      _setOffset(_offset + event.scrollDelta.dy);
      return;
    }
    if (event is PointerDownEvent) {
      _recognizer.addPointer(event);
    }
  }

  VerticalDragGestureRecognizer get _recognizer => _drag ??=
      VerticalDragGestureRecognizer(
          supportedDevices: const <PointerDeviceKind>{
            PointerDeviceKind.touch,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
          },
        )
        ..onUpdate = (details) {
          _setOffset(_offset - details.delta.dy);
        };

  void _setOffset(double next) {
    final clamped = next.clamp(0.0, _maxOffset);
    if (clamped == _offset) return;
    _offset = clamped;
    markNeedsPaint();
  }

  /// Flex children and real scroll views need the sheet's max height. A plain
  /// block of content reports its full height and can be scrolled here.
  bool _hasFlexOrViewport(RenderObject node) {
    var found = false;
    void walk(RenderObject current) {
      if (found) return;
      if (current is RenderViewport) {
        found = true;
        return;
      }
      if (current is RenderFlex) {
        current.visitChildren((child) {
          final data = child.parentData;
          if (data is FlexParentData && (data.flex ?? 0) > 0) found = true;
          if (!found) walk(child);
        });
        return;
      }
      current.visitChildren(walk);
    }

    walk(node);
    return found;
  }

  /// The height [node] would take if it were not clipped. Layout builders and
  /// viewports report nothing; the walk continues into a builder's child.
  double _contentExtent(RenderObject node, double width) {
    if (node is RenderViewport || width < 0) return 0;
    if (node is RenderBox) {
      try {
        final own = node.getMaxIntrinsicHeight(width);
        if (own.isFinite && own > 0) return own;
      } on FlutterError {
        return 0;
      }
    }
    var best = 0.0;
    node.visitChildren((child) {
      best = math.max(best, _contentExtent(child, width));
    });
    return best;
  }

  @override
  void performLayout() {
    final current = child;
    if (current == null) {
      size = constraints.smallest;
      _canScroll = false;
      _contentHeight = 0;
      return;
    }
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : constraints.minWidth;
    final maxH = constraints.maxHeight;
    final extent = _contentExtent(current, width);
    final flexing = _hasFlexOrViewport(current);
    if (!flexing && extent > maxH + 0.5 && maxH.isFinite) {
      // Give the child its full height so a tall column is not clipped, then
      // scroll that height inside the sheet.
      current.layout(
        BoxConstraints(minWidth: width, maxWidth: width, maxHeight: extent),
        parentUsesSize: true,
      );
    } else {
      current.layout(constraints, parentUsesSize: true);
      final revealed = _contentExtent(current, width);
      final revealedFlex = _hasFlexOrViewport(current);
      if (!revealedFlex && revealed > maxH + 0.5 && maxH.isFinite) {
        current.layout(
          BoxConstraints(minWidth: width, maxWidth: width, maxHeight: revealed),
          parentUsesSize: true,
        );
      }
    }
    final measured = current.size.height;
    _contentHeight = measured.isFinite ? measured : 0;
    size = constraints.constrain(
      Size(
        current.size.width.isFinite ? current.size.width : width,
        _contentHeight,
      ),
    );
    _canScroll = _contentHeight > size.height + 0.5;
    _offset = _canScroll ? _offset.clamp(0.0, _maxOffset) : 0;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final current = child;
    if (current == null) return false;
    return result.addWithPaintOffset(
      offset: Offset(0, -_offset),
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) {
        return current.hitTest(result, position: transformed);
      },
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(0, -_offset, 0, 1);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final current = child;
    if (current == null) return;
    if (!_canScroll) {
      context.paintChild(current, offset);
      return;
    }
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (
      PaintingContext context,
      Offset offset,
    ) {
      context.paintChild(current, offset + Offset(0, -_offset));
    });
  }

  @override
  void dispose() {
    _drag?.dispose();
    super.dispose();
  }
}

/// Desktop scrollbars are drawn on the trailing edge. A sheet often scrolls
/// as a whole and also contains a panel that scrolls on its own; without a
/// gutter those thumbs share one edge and the outer thumb takes the drag.
const _sheetScrollbarGutter = 14.0;

class _SheetScrollBehavior extends MaterialScrollBehavior {
  const _SheetScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) == Axis.horizontal) {
      return child;
    }
    switch (getPlatform(context)) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return Scrollbar(
          controller: details.controller,
          child: Padding(
            padding: const EdgeInsets.only(right: _sheetScrollbarGutter),
            child: child,
          ),
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return child;
    }
  }
}

/// Opens [child] as a frosted glass modal bottom sheet. The sheet itself
/// paints [GlassSurface] (including the drag handle); content containers
/// inside should pass `embedded: true` / read [AppSheetScope] so their
/// bodies stay transparent.
///
/// The sheet grows with [child] up to the screen. Past that, the body
/// scrolls vertically, so the rest of a tall sheet stays reachable. When
/// [heightFactor] is set the sheet is fixed at that share of the screen
/// and the body scrolls inside it.
///
/// [isScrollControlled] is accepted for existing callers. The sheet is
/// always scroll-controlled so it is not clipped at the default fraction
/// of the screen.
Future<T?> showAppSheet<T>(
  BuildContext context,
  Widget child, {
  double? heightFactor,
  bool isScrollControlled = false,
  bool showDragHandle = true,
}) => showModalBottomSheet<T>(
  context: context,
  backgroundColor: Colors.transparent,
  // Handle is drawn inside [_appSheetChrome] so it sits on glass.
  showDragHandle: false,
  // Always scroll-controlled: a tall body may use the full screen and then
  // scroll. [isScrollControlled] remains for existing callers.
  isScrollControlled: true,
  useSafeArea: true,
  clipBehavior: Clip.antiAlias,
  builder: (_) {
    final body = ScrollConfiguration(
      behavior: const _SheetScrollBehavior(),
      child: child,
    );
    if (heightFactor != null) {
      return FractionallySizedBox(
        heightFactor: heightFactor,
        widthFactor: 1,
        child: _appSheetChrome(
          showDragHandle: showDragHandle,
          expandBody: true,
          child: body,
        ),
      );
    }
    return _appSheetChrome(showDragHandle: showDragHandle, child: body);
  },
);

/// Opens [child] as a bottom sheet on compact widths and as an animated
/// theme-styled [Dialog] bounded by [maxWidth] x [maxHeight] elsewhere.
Future<T?> showAdaptivePanel<T>(
  BuildContext context,
  Widget child, {
  double maxWidth = 780,
  double maxHeight = 820,
  double breakpoint = 600,
  double heightFactor = .94,
}) {
  if (MediaQuery.sizeOf(context).width < breakpoint) {
    return showAppSheet<T>(context, child, heightFactor: heightFactor);
  }
  return showAppDialog<T>(
    context: context,
    frosted: false,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlpha,
        borderRadius: BorderRadius.circular(AppShape.card),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: child,
        ),
      ),
    ),
  );
}

/// Opens a compact picker or action list: a bottom sheet on phones and, on
/// desktop, a floating panel pinned to the control that opened it.
///
/// Pass [anchor] (the button / row) or [anchorRect] / [anchorPoint] (e.g. a
/// long-press). Without an anchor the panel stays centered, for callers that
/// have no clear trigger geometry.
Future<T?> showAppPicker<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double maxWidth = 420,
  double maxHeight = 480,
  bool isScrollControlled = false,
  bool showDragHandle = true,
  double breakpoint = 600,
  BuildContext? anchor,
  Rect? anchorRect,
  Offset? anchorPoint,
}) {
  if (MediaQuery.sizeOf(context).width < breakpoint) {
    return showAppSheet<T>(
      context,
      Builder(builder: builder),
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
    );
  }

  final resolved = _resolvePickerAnchor(
    anchor: anchor,
    anchorRect: anchorRect,
    anchorPoint: anchorPoint,
  );
  if (resolved == null) {
    return showAppDialog<T>(
      context: context,
      frosted: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassSurface(
          alpha: AppSurfaces.overlayAlpha,
          borderRadius: BorderRadius.circular(AppShape.card),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: builder(ctx),
          ),
        ),
      ),
    );
  }

  final mq = MediaQuery.of(context);
  final pad = EdgeInsets.only(
    left: math.max(12, mq.padding.left),
    right: math.max(12, mq.padding.right),
    top: math.max(12, mq.padding.top),
    bottom: math.max(12, mq.padding.bottom),
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: AppSurfaces.barrier,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (routeContext, __, ___) => CustomSingleChildLayout(
      delegate: _AnchoredPickerLayout(
        anchor: resolved,
        padding: pad,
        maxWidth: maxWidth,
        maxHeight: maxHeight,
      ),
      child: FloatingPanelSurface(
        elevation: 8,
        child: Material(
          type: MaterialType.transparency,
          child: builder(routeContext),
        ),
      ),
    ),
    transitionBuilder: (routeContext, animation, __, child) =>
        desktopFloatingPanelTransition(routeContext, animation, child),
  );
}

/// Frosted popup menu anchored like Material [showMenu]. Prefer this (or
/// [AppPopupMenuButton]) over raw [PopupMenuButton] so menus share glass.
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  double minWidth = 168,
  double maxWidth = 320,
}) {
  final mq = MediaQuery.of(context);
  final overlaySize = Overlay.of(context).context.size ?? mq.size;
  // [RelativeRect] is relative to the overlay; convert to a global anchor.
  final anchor = Rect.fromLTRB(
    position.left,
    position.top,
    overlaySize.width - position.right,
    overlaySize.height - position.bottom,
  );
  final pad = EdgeInsets.only(
    left: math.max(8, mq.padding.left),
    right: math.max(8, mq.padding.right),
    top: math.max(8, mq.padding.top),
    bottom: math.max(8, mq.padding.bottom),
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (routeContext, __, ___) => CustomSingleChildLayout(
      delegate: _AnchoredPickerLayout(
        anchor: anchor,
        padding: pad,
        maxWidth: maxWidth,
        maxHeight: math.min(480, mq.size.height - pad.vertical),
      ),
      child: FloatingPanelSurface(
        elevation: 4,
        child: Material(
          type: MaterialType.transparency,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: minWidth, maxWidth: maxWidth),
            child: Semantics(
              role: SemanticsRole.menu,
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ListBody(children: [for (final entry in items) entry]),
              ),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (routeContext, animation, __, child) =>
        desktopFloatingPanelTransition(routeContext, animation, child),
  );
}

/// Drop-in frosted replacement for [PopupMenuButton].
class AppPopupMenuButton<T> extends StatelessWidget {
  const AppPopupMenuButton({
    super.key,
    required this.itemBuilder,
    this.onSelected,
    this.onCanceled,
    this.tooltip,
    this.icon,
    this.iconSize,
    this.child,
    this.enabled = true,
    this.padding = const EdgeInsets.all(8),
    this.splashRadius,
    this.style,
  }) : assert(
         icon == null || child == null,
         'Only one of icon or child may be given.',
       );

  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  final PopupMenuCanceled? onCanceled;
  final String? tooltip;
  final Widget? icon;
  final double? iconSize;
  final Widget? child;
  final bool enabled;
  final EdgeInsetsGeometry padding;
  final double? splashRadius;
  final ButtonStyle? style;

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(topLeft, bottomRight),
      Offset.zero & overlay.size,
    );
    final value = await showAppMenu<T>(
      context: context,
      position: position,
      items: itemBuilder(context),
    );
    if (!context.mounted) return;
    if (value == null) {
      onCanceled?.call();
    } else {
      onSelected?.call(value);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (child != null) {
      return InkWell(
        onTap: enabled ? () => _open(context) : null,
        borderRadius: BorderRadius.circular(AppShape.control),
        child: child,
      );
    }
    return IconButton(
      onPressed: enabled ? () => _open(context) : null,
      tooltip: tooltip,
      padding: padding,
      splashRadius: splashRadius,
      iconSize: iconSize,
      style: style,
      icon: icon ?? const Icon(Icons.more_vert),
    );
  }
}

/// Global rect of the widget / point that opened a desktop picker.
Rect? _resolvePickerAnchor({
  BuildContext? anchor,
  Rect? anchorRect,
  Offset? anchorPoint,
}) {
  if (anchorRect != null) return anchorRect;
  if (anchorPoint != null) {
    return Rect.fromCenter(center: anchorPoint, width: 1, height: 1);
  }
  if (anchor == null || !anchor.mounted) return null;
  final box = anchor.findRenderObject();
  if (box is! RenderBox || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Places a picker under its anchor when there is room, otherwise above, and
/// keeps it on screen.
class _AnchoredPickerLayout extends SingleChildLayoutDelegate {
  _AnchoredPickerLayout({
    required this.anchor,
    required this.padding,
    required this.maxWidth,
    required this.maxHeight,
  });

  final Rect anchor;
  final EdgeInsets padding;
  final double maxWidth;
  final double maxHeight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final maxW = math.min(
      maxWidth,
      math.max(0.0, constraints.maxWidth - padding.horizontal),
    );
    final maxH = math.min(
      maxHeight,
      math.max(0.0, constraints.maxHeight - padding.vertical),
    );
    return BoxConstraints(maxWidth: maxW, maxHeight: maxH);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const gap = 6.0;
    final spaceBelow = size.height - padding.bottom - anchor.bottom - gap;
    final spaceAbove = anchor.top - padding.top - gap;
    final double top;
    if (childSize.height <= spaceBelow || spaceBelow >= spaceAbove) {
      top = anchor.bottom + gap;
    } else {
      top = anchor.top - childSize.height - gap;
    }
    // Prefer the anchor's leading edge; clamp so the panel stays on screen.
    final maxLeft = size.width - padding.right - childSize.width;
    final left = anchor.left
        .clamp(padding.left, math.max(padding.left, maxLeft))
        .toDouble();
    final maxTop = size.height - padding.bottom - childSize.height;
    final clampedTop = top
        .clamp(padding.top, math.max(padding.top, maxTop))
        .toDouble();
    return Offset(left, clampedTop);
  }

  @override
  bool shouldRelayout(covariant _AnchoredPickerLayout old) =>
      old.anchor != anchor ||
      old.padding != padding ||
      old.maxWidth != maxWidth ||
      old.maxHeight != maxHeight;
}

/// The frosted glass surface every floating panel sits on, matching sheets
/// and dialogs.
class FloatingPanelSurface extends StatelessWidget {
  const FloatingPanelSurface({super.key, required this.child, this.elevation});
  final Widget child;
  final double? elevation;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppShape.card);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .28),
            blurRadius: 40 + (elevation ?? 0) * 4,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlpha,
        blur: AppSurfaces.blurSigma,
        borderRadius: radius,
        child: child,
      ),
    );
  }
}

/// Shows [pageBuilder]'s widget as an animated floating panel over the
/// app's shared scrim.
Future<T?> showFloatingDialog<T>(
  BuildContext context, {
  required WidgetBuilder pageBuilder,
  String barrierLabel = 'Close panel',
}) => showAppDialog<T>(
  context: context,
  barrierLabel: barrierLabel,
  frosted: false,
  builder: pageBuilder,
);

/// Opens [child] as a responsive floating panel: a bottom sheet on compact
/// widths and a centered dialog on wider screens.
Future<void> showFloatingPanel(
  BuildContext context,
  Widget child, {
  double maxWidth = 1180,
  double maxHeight = 780,
  String barrierLabel = 'Close panel',
}) {
  if (MediaQuery.sizeOf(context).width < 820) {
    return showAppSheet<void>(context, child, heightFactor: .94);
  }
  return showFloatingDialog<void>(
    context,
    barrierLabel: barrierLabel,
    pageBuilder: (routeContext) {
      final size = MediaQuery.sizeOf(routeContext);
      return Align(
        alignment: Alignment.center,
        child: FloatingPanelSurface(
          child: SizedBox(
            width: math.min(maxWidth, size.width - 48),
            height: math.min(maxHeight, size.height - 48),
            child: child,
          ),
        ),
      );
    },
  );
}
