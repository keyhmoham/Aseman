import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../data/plugins_api.dart';
import 'plugin_gadgets_controller.dart';
import 'plugins_panel.dart';

/// A floating plugin gadget: the same content stack as an App UI, but
/// **frameless** (no window chrome, glass pad or title bar) so the screen can
/// take any custom shape. Right-click or long-press opens the window menu
/// (minimise, close, open as page, …). Free-positioned over desk / chat /
/// left rail, or as a universal overlay for account plugins.
class PluginGadget extends StatelessWidget {
  const PluginGadget({
    super.key,
    required this.dependencies,
    required this.plugin,
    required this.controller,
    this.spaceId = '',
    this.roomId = '',
    this.constrainToParent = true,
    this.compact = false,
  });

  final AppDependencies dependencies;
  final PluginInfo plugin;
  final PluginGadgetsController controller;
  final String spaceId;
  final String roomId;

  /// Keep the window inside its Stack parent (surface hosts).
  final bool constrainToParent;

  /// Smaller default size for rail / narrow panels (layout only; no chrome).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layoutOf(plugin.id);
    if (layout.mode != PluginGadgetMode.open) return const SizedBox.shrink();
    return _FloatingPlugin(
      dependencies: dependencies,
      plugin: plugin,
      controller: controller,
      layout: layout,
      spaceId: spaceId,
      roomId: roomId,
      constrainToParent: constrainToParent,
      compact: compact,
    );
  }
}

class _FloatingPlugin extends StatefulWidget {
  const _FloatingPlugin({
    required this.dependencies,
    required this.plugin,
    required this.controller,
    required this.layout,
    required this.spaceId,
    required this.roomId,
    required this.constrainToParent,
    required this.compact,
  });

  final AppDependencies dependencies;
  final PluginInfo plugin;
  final PluginGadgetsController controller;
  final PluginGadgetState layout;
  final String spaceId;
  final String roomId;
  final bool constrainToParent;
  final bool compact;

  @override
  State<_FloatingPlugin> createState() => _FloatingPluginState();
}

class _FloatingPluginState extends State<_FloatingPlugin> {
  late Offset _offset = widget.layout.offset;
  late Size _size = widget.layout.size;
  bool _moving = false;

  @override
  void didUpdateWidget(covariant _FloatingPlugin old) {
    super.didUpdateWidget(old);
    if (old.layout.offset != widget.layout.offset) {
      _offset = widget.layout.offset;
    }
    if (old.layout.size != widget.layout.size) {
      _size = widget.layout.size;
    }
  }

  void _clamp(Size bounds) {
    if (!widget.constrainToParent || bounds == Size.zero) return;
    final maxX = (bounds.width - _size.width).clamp(0.0, bounds.width);
    final maxY = (bounds.height - _size.height).clamp(0.0, bounds.height);
    _offset = Offset(
      _offset.dx.clamp(0.0, maxX),
      _offset.dy.clamp(0.0, maxY),
    );
  }

  Future<void> _menu(Offset global) async {
    final box = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = box?.size ?? MediaQuery.sizeOf(context);
    final local = box?.globalToLocal(global) ?? global;
    final choice = await showAppMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        local.dx,
        local.dy,
        size.width - local.dx,
        size.height - local.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'minimise',
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.minimize_rounded),
            title: const Text('Minimise'),
            subtitle: Text('Reopen from Plugins',
                style: Theme.of(context).textTheme.labelSmall),
          ),
        ),
        const PopupMenuItem(
          value: 'page',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.open_in_full_rounded),
            title: Text('Open as page'),
          ),
        ),
        PopupMenuItem(
          value: 'move',
          child: ListTile(
            dense: true,
            leading: Icon(_moving ? Icons.done_rounded : Icons.open_with_rounded),
            title: Text(_moving ? 'Done moving' : 'Move'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'close',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.close_rounded),
            title: Text('Close'),
          ),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'minimise' || choice == 'close') {
      widget.controller.dock(widget.plugin.id);
    } else if (choice == 'page') {
      await openPluginPage(
        context,
        widget.dependencies,
        widget.plugin,
        spaceId: widget.spaceId,
        roomId: widget.roomId,
      );
    } else if (choice == 'move') {
      setState(() => _moving = !_moving);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final bounds = Size(
        box.maxWidth.isFinite ? box.maxWidth : MediaQuery.sizeOf(context).width,
        box.maxHeight.isFinite
            ? box.maxHeight
            : MediaQuery.sizeOf(context).height,
      );
      _clamp(bounds);
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: _offset.dx,
            top: _offset.dy,
            width: _size.width,
            height: _size.height,
            // Frameless: no glass pad / window frame — the app draws its own
            // shape. Hit-testing stays on the content bounds.
            child: Material(
              type: MaterialType.transparency,
              child: Listener(
                onPointerDown: (e) {
                  if (e.buttons == kSecondaryMouseButton) {
                    _menu(e.position);
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.deferToChild,
                  onLongPressStart: (d) => _menu(d.globalPosition),
                  onPanUpdate: _moving
                      ? (d) {
                          setState(() {
                            _offset += d.delta;
                            _clamp(bounds);
                          });
                        }
                      : null,
                  onPanEnd: _moving
                      ? (_) =>
                          widget.controller.move(widget.plugin.id, _offset)
                      : null,
                  child: DecoratedBox(
                    decoration: _moving
                        ? BoxDecoration(
                            border: Border.all(
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: .45),
                              width: 1.5,
                            ),
                          )
                        : const BoxDecoration(),
                    child: PluginView(
                      dependencies: widget.dependencies,
                      plugin: widget.plugin,
                      spaceId: widget.spaceId,
                      roomId: widget.roomId,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// The open floaters of one surface. Minimised gadgets draw nothing (the
/// plugins manager lists them), and empty areas do not absorb pointer events.
class PluginGadgetLayer extends StatelessWidget {
  const PluginGadgetLayer({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.plugins,
    this.spaceId = '',
    this.roomId = '',
    this.compact = false,
  });

  final AppDependencies dependencies;
  final PluginGadgetsController controller;
  final List<PluginInfo> plugins;
  final String spaceId;
  final String roomId;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final open = [
      for (final p in plugins)
        if (controller.layoutOf(p.id).mode == PluginGadgetMode.open) p
    ];
    if (open.isEmpty) return const SizedBox.shrink();
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final p in open)
          Positioned.fill(
            child: PluginGadget(
              dependencies: dependencies,
              plugin: p,
              controller: controller,
              spaceId: spaceId,
              roomId: roomId,
              compact: compact,
            ),
          ),
      ],
    );
  }
}
