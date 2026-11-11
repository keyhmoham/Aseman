import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app_dependencies.dart';
import 'gadget.dart';
import 'gadget_manager.dart';
import 'gadgets_controller.dart';

/// App-wide host for account-scoped App UI gadgets as universal floating
/// gadgets. Mounted above the shell navigator (see [AsemanApp]) so gadgets
/// and the [GadgetsEdgeHandle] persist across every home tab (Chats /
/// Explore / You) and every pushed workspace route — one shared layer, not
/// per-tab.
class GadgetsOverlay extends StatefulWidget {
  const GadgetsOverlay({
    super.key,
    required this.dependencies,
    required this.navigatorKey,
    required this.child,
  });

  final AppDependencies dependencies;

  /// The app navigator — the overlay wraps it, so sheets and gadget pages
  /// use this key rather than an ancestor lookup.
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  @override
  State<GadgetsOverlay> createState() => _GadgetsOverlayState();
}

class _GadgetsOverlayState extends State<GadgetsOverlay> {
  late final GadgetsController _controller =
      GadgetsController(widget.dependencies);

  @override
  void initState() {
    super.initState();
    widget.dependencies.sessionController.addListener(_onSession);
    _controller.attach();
  }

  bool get _signedIn =>
      (widget.dependencies.sessionController.session?.accountId ?? '')
          .isNotEmpty;

  void _onSession() => _controller.attach(spaceId: _controller.spaceId);

  /// The layer's one entry: the navigator, the gadgets and the edge handle.
  /// This layer sits above the navigator (MaterialApp.builder), so it brings
  /// its own [Overlay]: tooltips, menus and other floating widgets of the
  /// gadgets and the handle need one above them.
  late final OverlayEntry _layer = OverlayEntry(builder: _buildLayer);

  @override
  void didUpdateWidget(covariant GadgetsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The entry builds from [widget]: a new navigator child rebuilds it.
    _layer.markNeedsBuild();
  }

  @override
  void dispose() {
    widget.dependencies.sessionController.removeListener(_onSession);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GadgetsScope(
      controller: _controller,
      child: Overlay(initialEntries: [_layer]),
    );
  }

  Widget _buildLayer(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final universal = _controller.universal;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (universal.isNotEmpty)
              Positioned.fill(
                child: _PassThrough(
                  child: GadgetLayer(
                    dependencies: widget.dependencies,
                    controller: _controller,
                    gadgets: universal,
                  ),
                ),
              ),
            if (_signedIn)
              GadgetsEdgeHandle(
                dependencies: widget.dependencies,
                controller: _controller,
                navigatorKey: widget.navigatorKey,
                // Navigator is a child of this overlay (MaterialApp.builder),
                // so dialogs and gadget pages use its key context.
                hostContext: widget.navigatorKey.currentContext ?? context,
              ),
          ],
        );
      },
    );
  }
}

/// Hit-tests only opaque descendants; empty regions pass through to the shell.
class _PassThrough extends SingleChildRenderObjectWidget {
  const _PassThrough({required Widget child}) : super(child: child);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPassThrough();
}

class _RenderPassThrough extends RenderProxyBox {
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    // Only claim hits that land on a descendant that accepts them.
    return hitTestChildren(result, position: position);
  }
}

/// Mounts every space floater of [spaceId] on one shared Stack layer that
/// covers the whole workspace (left panel, chat and desk) — or a full-page
/// chat outside the workspace shell. Placement no longer confines the host.
class WorkspaceGadgets extends StatefulWidget {
  const WorkspaceGadgets({
    super.key,
    required this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.compact = false,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final bool compact;

  @override
  State<WorkspaceGadgets> createState() => _WorkspaceGadgetsState();
}

class _WorkspaceGadgetsState extends State<WorkspaceGadgets> {
  GadgetsController? _controller;
  GadgetsLease? _lease;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = GadgetsScope.maybeOf(context);
    if (controller != _controller) {
      _releaseLater();
      _controller = controller;
      _claim();
    }
  }

  @override
  void didUpdateWidget(covariant WorkspaceGadgets oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spaceId != widget.spaceId) {
      _releaseLater();
      _claim();
    }
  }

  @override
  void dispose() {
    _releaseLater();
    super.dispose();
  }

  /// Claims the controller for this space once the frame is built (the
  /// claim loads and notifies, which must not happen during a build).
  void _claim() {
    final controller = _controller;
    final spaceId = widget.spaceId;
    if (controller == null || spaceId.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _controller != controller || widget.spaceId != spaceId) {
        return;
      }
      _lease = controller.lease(spaceId);
    });
  }

  /// Gives the controller back after this frame (unmounting must not
  /// notify the widgets being torn down with it).
  void _releaseLater() {
    final lease = _lease;
    _lease = null;
    if (lease != null) scheduleMicrotask(lease.release);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null || widget.spaceId.isEmpty) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Only the surface the controller serves shows its gadgets: under a
        // direct chat floating over a workspace, the workspace's step aside.
        if (controller.spaceId != widget.spaceId) {
          return const SizedBox.shrink();
        }
        final gadgets = controller.spaceFloaters;
        if (gadgets.isEmpty) return const SizedBox.shrink();
        return _PassThrough(
          child: GadgetLayer(
            dependencies: widget.dependencies,
            controller: controller,
            gadgets: gadgets,
            spaceId: widget.spaceId,
            roomId: widget.roomId,
            compact: widget.compact,
          ),
        );
      },
    );
  }
}
