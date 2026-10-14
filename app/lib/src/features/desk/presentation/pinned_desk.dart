import 'package:flutter/material.dart';

import '../domain/desk_models.dart';
import 'desk_controller.dart';
import 'tool_avatar.dart';

/// The pinned desk: card windows people pinned, kept as shortcuts, in a grid.
/// Each shows a live preview of its frontend; opening one puts it back on the
/// floating desk.
class PinnedDesk extends StatelessWidget {
  const PinnedDesk({
    super.key,
    required this.controller,
    required this.preview,
    this.bottomInset = 0,
  });

  final DeskController controller;

  /// The pinned window's frontend, as a preview.
  final Widget Function(DeskPin pin) preview;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pins = controller.state.pins;
    return Container(
      margin: EdgeInsets.fromLTRB(12, 12, 12, bottomInset),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: .18),
              blurRadius: 32,
              offset: const Offset(0, 12)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 12, 8),
            child: Row(children: [
              Icon(Icons.space_dashboard_rounded, color: scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Pinned desk',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    Text('Windows you pinned, ready to open again',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Back to the desk',
                onPressed: () => controller.setPinnedOpen(false),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
          ),
          Expanded(
            child: pins.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.push_pin_outlined,
                            size: 40, color: scheme.outline),
                        const SizedBox(height: 12),
                        Text('Nothing pinned yet',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text('Pin a window from its title bar to keep it here.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant)),
                      ]),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 320,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: .78,
                    ),
                    itemCount: pins.length,
                    itemBuilder: (context, i) => _PinTile(
                      key: ValueKey(pins[i].id),
                      pin: pins[i],
                      preview: preview(pins[i]),
                      onOpen: () {
                        controller.setPinnedOpen(false);
                        controller.openPin(pins[i]);
                      },
                      onUnpin: () => controller.unpin(pins[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PinTile extends StatefulWidget {
  const _PinTile({
    super.key,
    required this.pin,
    required this.preview,
    required this.onOpen,
    required this.onUnpin,
  });

  final DeskPin pin;
  final Widget preview;
  final VoidCallback onOpen;
  final VoidCallback onUnpin;

  @override
  State<_PinTile> createState() => _PinTileState();
}

class _PinTileState extends State<_PinTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pin = widget.pin;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.02 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: Material(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          elevation: _hover ? 6 : 1,
          shadowColor: Colors.black26,
          child: InkWell(
            onTap: widget.onOpen,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                  child: Row(children: [
                    ToolAvatar(tool: pin.tool, name: pin.name, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(pin.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          if (pin.argsSummary.isNotEmpty)
                            Text(pin.argsSummary,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Unpin',
                      visualDensity: VisualDensity.compact,
                      iconSize: 18,
                      onPressed: widget.onUnpin,
                      icon: Icon(Icons.push_pin, color: scheme.primary),
                    ),
                  ]),
                ),
                // A live preview of the window, scaled to the tile.
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: scheme.outlineVariant.withValues(alpha: .5)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: IgnorePointer(
                      child: FittedBox(
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          width: pin.size.width,
                          height: pin.size.height,
                          child: widget.preview,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: FilledButton.tonalIcon(
                    onPressed: widget.onOpen,
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open on desk'),
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
