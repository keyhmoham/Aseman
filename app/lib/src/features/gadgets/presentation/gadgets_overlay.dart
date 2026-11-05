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
      child: ListenableBuilder(
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
                  hostContext:
                      widget.navigatorKey.currentContext ?? context,
                ),
            ],
          );
        },
      ),
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
class WorkspaceGadgets extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final controller = GadgetsScope.maybeOf(context);
    if (controller == null || spaceId.isEmpty) {
      return const SizedBox.shrink();
    }
    if (controller.spaceId != spaceId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (controller.spaceId != spaceId) {
          controller.attach(spaceId: spaceId);
        }
      });
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final gadgets = controller.spaceFloaters;
        if (gadgets.isEmpty) return const SizedBox.shrink();
        return _PassThrough(
          child: GadgetLayer(
            dependencies: dependencies,
            controller: controller,
            gadgets: gadgets,
            spaceId: spaceId,
            roomId: roomId,
            compact: compact,
          ),
        );
      },
    );
  }
}
