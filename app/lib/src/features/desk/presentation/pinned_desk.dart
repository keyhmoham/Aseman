import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/sky_ui.dart';
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

  /// Cap how wide the panel grows so it does not stretch across the desk.
  static const double maxWidth = 520;

  @override
  Widget build(BuildContext context) {
    final pins = controller.state.pins;
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, bottomInset),
          child: SoftCard(
            elevated: true,
            wash: true,
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.md + 2, AppSpacing.sm, AppSpacing.xs),
                  child: SkySectionHeader(
                    icon: Icons.space_dashboard_rounded,
                    title: 'Pinned desk',
                    subtitle: 'Windows you pinned, ready to open again',
                    dense: true,
                    onClose: () => controller.setPinnedOpen(false),
                  ),
                ),
                Expanded(
                  child: pins.isEmpty
                      ? const PanelEmpty(
                          icon: Icons.push_pin_outlined,
                          title: 'Nothing pinned yet',
                          message:
                              'Pin a window from its title bar to keep it here.',
                        )
                      : GridView.builder(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.md + 4,
                              AppSpacing.xs,
                              AppSpacing.md + 4,
                              AppSpacing.md + 4),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 240,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
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
          ),
        ),
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
    final accent = portalAccentFor(pin.tool, scheme, context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.02 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutBack,
        child: SoftCard(
          onTap: widget.onOpen,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.sm, AppSpacing.sm - 2, 4, AppSpacing.xs - 2),
                child: Row(children: [
                  ToolAvatar(tool: pin.tool, name: pin.name, size: 30),
                  const SizedBox(width: AppSpacing.sm - 2),
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
                    icon: Icon(Icons.push_pin, color: accent),
                  ),
                ]),
              ),
              // A live preview of the window, scaled to the tile.
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Material(
                    color: scheme.surface.withValues(alpha: .72),
                    shape: ThemeChrome.cardShape(context),
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
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm - 2),
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
    );
  }
}
