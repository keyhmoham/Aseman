import 'dart:ui';

import 'package:flutter/material.dart';

import 'desk_controller.dart';
import 'tool_avatar.dart';

/// The dock pinned to the bottom of the desk: the pinned desk, then the
/// tools with windows open. A tool shows only its windows (again: all of
/// them); its close (hover, right-click or long-press) closes all its windows
/// at once.
class DeskDock extends StatelessWidget {
  const DeskDock({super.key, required this.controller, this.compact = false});

  final DeskController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tools = controller.state.openTools;
    final focus = controller.focusTool;
    final item = compact ? 42.0 : 48.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(40),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding:
              EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: .88),
            borderRadius: BorderRadius.circular(40),
            border:
                Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DockButton(
                  size: item,
                  icon: Icons.space_dashboard_rounded,
                  tooltip: 'Pinned desk',
                  badge: controller.state.pins.length,
                  selected: controller.pinnedOpen,
                  onTap: () => controller.setPinnedOpen(!controller.pinnedOpen),
                ),
                Container(
                  width: 1,
                  height: item * .7,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: scheme.outlineVariant,
                ),
                if (tools.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('Open tools show up here',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                for (final (tool, name, count) in tools)
                  _DockTool(
                    key: ValueKey(tool),
                    size: item,
                    tool: tool,
                    name: name,
                    count: count,
                    selected: focus == tool,
                    dimmed: focus != null && focus != tool,
                    onTap: () => controller.focusOn(tool),
                    onClose: () => controller.closeTool(tool),
                  ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  child: focus == null
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: _DockButton(
                            size: item,
                            icon: Icons.view_quilt_rounded,
                            tooltip: 'Show all windows',
                            onTap: () => controller.focusOn(null),
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

class _DockButton extends StatefulWidget {
  const _DockButton({
    required this.size,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
    this.selected = false,
  });

  final double size;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;
  final bool selected;

  @override
  State<_DockButton> createState() => _DockButtonState();
}

class _DockButtonState extends State<_DockButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.size;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: _hover ? 1.12 : 1,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutBack,
            child: Badge(
              isLabelVisible: widget.badge > 0,
              label: Text('${widget.badge}'),
              backgroundColor: scheme.tertiary,
              textColor: scheme.onTertiary,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutBack,
                width: s,
                height: s,
                decoration: BoxDecoration(
                  color: widget.selected
                      ? scheme.primary
                      : scheme.secondaryContainer,
                  borderRadius:
                      BorderRadius.circular(widget.selected ? s * .3 : s / 2),
                ),
                child: Icon(widget.icon,
                    size: s * .5,
                    color: widget.selected
                        ? scheme.onPrimary
                        : scheme.onSecondaryContainer),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockTool extends StatefulWidget {
  const _DockTool({
    super.key,
    required this.size,
    required this.tool,
    required this.name,
    required this.count,
    required this.selected,
    required this.dimmed,
    required this.onTap,
    required this.onClose,
  });

  final double size;
  final String tool;
  final String name;
  final int count;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  State<_DockTool> createState() => _DockToolState();
}

class _DockToolState extends State<_DockTool> {
  bool _hover = false;

  Future<void> _menu(Offset at) async {
    final windows = widget.count == 1 ? '1 window' : '${widget.count} windows';
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy - 120, at.dx, at.dy),
      items: [
        PopupMenuItem(
          value: 'focus',
          child: ListTile(
            dense: true,
            leading: Icon(widget.selected
                ? Icons.view_quilt_rounded
                : Icons.filter_center_focus_rounded),
            title: Text(widget.selected
                ? 'Show all windows'
                : 'Show only ${widget.name}'),
          ),
        ),
        PopupMenuItem(
          value: 'close',
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.close_rounded),
            title: Text('Close $windows'),
          ),
        ),
      ],
    );
    if (choice == 'focus') widget.onTap();
    if (choice == 'close') widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.size;
    final lifted = _hover || widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message:
            '${widget.name} · ${widget.count == 1 ? '1 window' : '${widget.count} windows'}',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPressStart: (d) => _menu(d.globalPosition),
            onSecondaryTapDown: (d) => _menu(d.globalPosition),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 260),
              opacity: widget.dimmed && !_hover ? .55 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSlide(
                    offset: Offset(0, lifted ? -.08 : 0),
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutBack,
                    child: AnimatedScale(
                      scale: _hover ? 1.18 : 1,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutBack,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ToolAvatar(
                              tool: widget.tool,
                              name: widget.name,
                              size: s,
                              selected: widget.selected),
                          // Close every window of the tool.
                          Positioned(
                            top: -4,
                            right: -4,
                            child: AnimatedScale(
                              scale: _hover ? 1 : 0,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOutBack,
                              child: Material(
                                color: scheme.inverseSurface,
                                shape: const CircleBorder(),
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: widget.onClose,
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: Icon(Icons.close_rounded,
                                        size: 13,
                                        color: scheme.onInverseSurface),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // One dot per window (up to three); a pill when shown alone.
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutBack,
                    width: widget.selected
                        ? 18
                        : (widget.count.clamp(1, 3) * 6.0 + 2),
                    height: 4,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      color: widget.selected ? scheme.primary : null,
                    ),
                    child: widget.selected
                        ? null
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (var i = 0; i < widget.count.clamp(1, 3); i++)
                                Container(
                                  width: 4,
                                  height: 4,
                                  margin:
                                      const EdgeInsets.symmetric(horizontal: 1),
                                  decoration: BoxDecoration(
                                      color: scheme.onSurfaceVariant,
                                      shape: BoxShape.circle),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
