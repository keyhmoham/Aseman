import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../data/plugins_api.dart';
import 'plugin_gadgets_controller.dart';
import 'plugins_panel.dart';

/// A floating Creator-plugin gadget: glass chrome, drag by the title bar,
/// collapse to a dock chip, optional resize grip.
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
    if (layout.mode == PluginGadgetMode.hidden) {
      return const SizedBox.shrink();
    }
    if (layout.mode == PluginGadgetMode.docked) {
      return _DockChip(
        plugin: plugin,
        onOpen: () => controller.open(plugin.id),
        onHide: () => controller.hide(plugin.id),
      );
    }
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

class _DockChip extends StatelessWidget {
  const _DockChip({
    required this.plugin,
    required this.onOpen,
    required this.onHide,
  });

  final PluginInfo plugin;
  final VoidCallback onOpen;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(999);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        onLongPress: onHide,
        borderRadius: radius,
        child: GlassSurface(
          alpha: AppSurfaces.overlayAlphaOf(context),
          blur: AppSurfaces.blurSigmaOf(context),
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  plugin.appWide
                      ? Icons.extension_rounded
                      : Icons.widgets_outlined,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    plugin.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
                                tooltip: 'Dock',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: () =>
                                    widget.controller.dock(widget.plugin.id),
                                icon: const Icon(Icons.minimize_rounded),
                              ),
                              IconButton(
                                tooltip: 'Hide',
                                visualDensity: VisualDensity.compact,
                                iconSize: 18,
                                onPressed: () =>
                                    widget.controller.hide(widget.plugin.id),
                                icon: const Icon(Icons.close_rounded),
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

/// Dock chips and open floaters for one surface. Empty areas do not absorb
/// pointer events — only chips and open windows participate in hit testing.
class PluginGadgetLayer extends StatelessWidget {
  const PluginGadgetLayer({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.plugins,
    this.spaceId = '',
    this.roomId = '',
    this.dockAlignment = Alignment.bottomRight,
    this.compact = false,
    this.pad = const EdgeInsets.all(10),
  });

  final AppDependencies dependencies;
  final PluginGadgetsController controller;
  final List<PluginInfo> plugins;
  final String spaceId;
  final String roomId;
  final Alignment dockAlignment;
  final bool compact;
  final EdgeInsets pad;

  @override
  Widget build(BuildContext context) {
    if (plugins.isEmpty) return const SizedBox.shrink();
    final docked = [
      for (final p in plugins)
        if (controller.layoutOf(p.id).mode == PluginGadgetMode.docked) p
    ];
    final open = [
      for (final p in plugins)
        if (controller.layoutOf(p.id).mode == PluginGadgetMode.open) p
    ];
    final hiddenCount = plugins
        .where((p) => controller.layoutOf(p.id).mode == PluginGadgetMode.hidden)
        .length;

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
        if (docked.isNotEmpty || hiddenCount > 0)
          Positioned(
            left: dockAlignment.x <= 0 ? pad.left : null,
            right: dockAlignment.x >= 0 ? pad.right : null,
            top: dockAlignment.y <= 0 ? pad.top : null,
            bottom: dockAlignment.y >= 0 ? pad.bottom : null,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [
                for (final p in docked)
                  PluginGadget(
                    dependencies: dependencies,
                    plugin: p,
                    controller: controller,
                    spaceId: spaceId,
                    roomId: roomId,
                    compact: compact,
                  ),
                if (hiddenCount > 0)
                  ActionChip(
                    avatar: const Icon(Icons.visibility_outlined, size: 16),
                    label: Text('+$hiddenCount'),
                    onPressed: () {
                      for (final p in plugins) {
                        if (controller.layoutOf(p.id).mode ==
                            PluginGadgetMode.hidden) {
                          controller.dock(p.id);
                        }
                      }
                    },
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
