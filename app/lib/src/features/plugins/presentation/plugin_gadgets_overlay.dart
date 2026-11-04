import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../app_dependencies.dart';
import '../data/plugins_api.dart';
import 'plugin_gadget.dart';
import 'plugin_gadgets_controller.dart';
import 'plugin_manager.dart';

/// App-wide host for account-scoped Creator plugins as universal floating
/// gadgets. Lives above the shell navigator so gadgets persist across home
/// tabs and while a workspace is open. It also carries the [PluginsEdgeHandle]
/// — the one shortcut to manage every plugin, on every page of the shell.
class PluginGadgetsOverlay extends StatefulWidget {
  const PluginGadgetsOverlay({
    super.key,
    required this.dependencies,
    required this.child,
  });

  final AppDependencies dependencies;
  final Widget child;

  @override
  State<PluginGadgetsOverlay> createState() => _PluginGadgetsOverlayState();
}

class _PluginGadgetsOverlayState extends State<PluginGadgetsOverlay> {
  late final PluginGadgetsController _controller =
      PluginGadgetsController(widget.dependencies);

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
    return PluginGadgetsScope(
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
                    child: PluginGadgetLayer(
                      dependencies: widget.dependencies,
                      controller: _controller,
                      plugins: universal,
                      dockAlignment: Alignment.bottomLeft,
                      pad: EdgeInsets.only(
                        left: 16,
                        bottom: 16 + MediaQuery.paddingOf(context).bottom,
                        right: 16,
                        top: 16,
                      ),
                    ),
                  ),
                ),
              if (_signedIn)
                PluginsEdgeHandle(
                  dependencies: widget.dependencies,
                  controller: _controller,
                  hostContext: context,
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

/// Mounts space-scoped gadgets for one [placement] onto a local Stack surface
/// (chat panel, left rail, or desk).
class PluginSurfaceGadgets extends StatelessWidget {
  const PluginSurfaceGadgets({
    super.key,
    required this.dependencies,
    required this.placement,
    this.spaceId = '',
    this.roomId = '',
    this.dockAlignment = Alignment.bottomRight,
    this.compact = false,
    this.pad = const EdgeInsets.all(8),
  });

  final AppDependencies dependencies;
  final PluginPlacement placement;
  final String spaceId;
  final String roomId;
  final Alignment dockAlignment;
  final bool compact;
  final EdgeInsets pad;

  @override
  Widget build(BuildContext context) {
    final controller = PluginGadgetsScope.maybeOf(context);
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
        final plugins = controller.forPlacement(placement);
        if (plugins.isEmpty) return const SizedBox.shrink();
        return _PassThrough(
          child: PluginGadgetLayer(
            dependencies: dependencies,
            controller: controller,
            plugins: plugins,
            spaceId: spaceId,
            roomId: roomId,
            dockAlignment: dockAlignment,
            compact: compact,
            pad: pad,
          ),
        );
      },
    );
  }
}
