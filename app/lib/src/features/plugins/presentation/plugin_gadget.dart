import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../data/plugins_api.dart';
import 'plugin_gadgets_controller.dart';
import 'plugins_panel.dart';

/// A floating Creator-plugin gadget: glass chrome, drag by the title bar,
/// minimise (back to the plugins manager), optional resize grip. A minimised
/// gadget draws nothing.
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

  /// Smaller chrome for rail / narrow panels.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final layout = controller.layoutOf(plugin.id);
    if (layout.mode != PluginGadgetMode.open) return const SizedBox.shrink();
    return _FloatingWindow(
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

class _FloatingWindow extends StatefulWidget {
  const _FloatingWindow({
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
  State<_FloatingWindow> createState() => _FloatingWindowState();
}

class _FloatingWindowState extends State<_FloatingWindow> {
  late Offset _offset = widget.layout.offset;
  late Size _size = widget.layout.size;

  @override
  void didUpdateWidget(covariant _FloatingWindow old) {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppShape.cardOf(context));
    final barH = widget.compact ? 36.0 : 42.0;

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
            child: Material(
              color: Colors.transparent,
              child: GlassSurface(
                alpha: AppSurfaces.overlayAlphaOf(context),
                blur: AppSurfaces.blurSigmaOf(context),
                borderRadius: radius,
                child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) {
                        setState(() {
                          _offset += d.delta;
                          _clamp(bounds);
                        });
                      },
                      onPanEnd: (_) =>
                          widget.controller.move(widget.plugin.id, _offset),
                      child: SizedBox(
                        height: barH,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              Icon(Icons.extension_rounded,
                                  size: 16, color: scheme.primary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  widget.plugin.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: widget.compact ? 12.5 : 13.5,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Minimise (reopen from Plugins)',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: () =>
                                    widget.controller.dock(widget.plugin.id),
                                icon: const Icon(Icons.minimize_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Divider(height: 1, color: scheme.outlineVariant),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(AppShape.cardOf(context)),
                        ),
                        child: PluginView(
                          dependencies: widget.dependencies,
                          plugin: widget.plugin,
                          spaceId: widget.spaceId,
                          roomId: widget.roomId,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            left: _offset.dx + _size.width - 18,
            top: _offset.dy + _size.height - 18,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (d) {
                setState(() {
                  _size = Size(
                    (_size.width + d.delta.dx).clamp(200, 720),
                    (_size.height + d.delta.dy).clamp(160, 900),
                  );
                  _clamp(bounds);
                });
              },
              onPanEnd: (_) =>
                  widget.controller.resize(widget.plugin.id, _size),
              child: const SizedBox(
                width: 18,
                height: 18,
                child: Icon(Icons.drag_handle_rounded, size: 14),
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
