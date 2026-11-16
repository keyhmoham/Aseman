import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../data/gadgets_api.dart';
import 'gadgets_controller.dart';
import 'gadgets_panel.dart';

/// The gadgets handle: a bump centered on the screen's right edge, on every
/// page of the shell. Tapping it opens the [GadgetManager] — a bottom sheet
/// on phones, a floating panel beside the handle on desktop.
class GadgetsEdgeHandle extends StatelessWidget {
  const GadgetsEdgeHandle({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.navigatorKey,
    required this.hostContext,
  });

  final AppDependencies dependencies;
  final GadgetsController controller;
  final GlobalKey<NavigatorState> navigatorKey;

  /// A context under the shell's navigator, kept alive while the manager is
  /// open, used to open a gadget page once the manager closes.
  final BuildContext hostContext;

  static const _width = 28.0, _height = 120.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onScreen = controller.manageable
        .where((p) => controller.layoutOf(p.id).mode == GadgetMode.open)
        .length;
    return Positioned.fill(
      child: SafeArea(
        child: Align(
          alignment: Alignment.centerRight,
          child: Tooltip(
              message: 'Gadgets',
              child: Semantics(
                button: true,
                label: 'Manage gadgets',
                child: Builder(
                  builder: (anchor) => GestureDetector(
                    onTap: () => showGadgetManager(
                      anchor,
                      dependencies: dependencies,
                      controller: controller,
                      navigatorKey: navigatorKey,
                      hostContext:
                          navigatorKey.currentContext ?? hostContext,
                    ),
                    behavior: HitTestBehavior.opaque,
                    child: CustomPaint(
                      painter: EdgeBumpPainter(
                        fill: ThemeRoles.selectedFill(context),
                        shadow: scheme.shadow,
                      ),
                      child: SizedBox(
                        width: _width,
                        height: _height,
                        child: Align(
                          alignment: const Alignment(.35, 0),
                          child: Badge(
                            isLabelVisible: onScreen > 0,
                            smallSize: 7,
                            backgroundColor: ThemeRoles.selectedInk(context),
                            child: Icon(
                              Icons.extension_rounded,
                              size: 16,
                              color: ThemeRoles.selectedInk(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ),
      ),
    );
  }
}

/// Opens the gadget manager from [anchor] (the edge handle): a frosted
/// bottom sheet on compact widths, a floating panel beside the handle on
/// wider screens.
Future<void> showGadgetManager(
  BuildContext anchor, {
  required AppDependencies dependencies,
  required GadgetsController controller,
  required GlobalKey<NavigatorState> navigatorKey,
  required BuildContext hostContext,
}) {
  final size = MediaQuery.sizeOf(anchor);
  const panelHeight = 600.0;
  // Beside the handle, vertically centred on it, kept on screen by the
  // picker's layout.
  final box = anchor.findRenderObject();
  Offset? point;
  if (box is RenderBox && box.hasSize && box.attached) {
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    point = Offset(size.width, centre.dy - panelHeight / 2);
  }
  unawaited(controller.refresh());
  // The edge handle lives above the navigator; sheets/panels need a
  // context that has the navigator as an ancestor.
  final nav = navigatorKey.currentContext ?? hostContext;
  return showAppPicker<void>(
    context: nav,
    anchorPoint: point,
    maxWidth: 440,
    maxHeight: math.min(panelHeight, size.height - 24),
    isScrollControlled: true,
    builder: (_) => GadgetManager(
      dependencies: dependencies,
      controller: controller,
      hostContext: nav,
    ),
  );
}

enum _Filter { all, onScreen, minimised }

/// Manages the person's App UI gadgets in one place: the universal gadgets
/// of their account and the gadgets of the workspace they are in. Each one
/// can be put on screen, minimised (off screen, kept here), or (for its
/// owner) removed. Only people remove gadgets; agents only create them.
class GadgetManager extends StatefulWidget {
  const GadgetManager({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.hostContext,
  });

  final AppDependencies dependencies;
  final GadgetsController controller;
  final BuildContext hostContext;

  @override
  State<GadgetManager> createState() => _GadgetManagerState();
}

class _GadgetManagerState extends State<GadgetManager> {
  _Filter _filter = _Filter.all;

  GadgetsController get _c => widget.controller;

  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  /// A gadget's state on screen. Page gadgets of a space have no gadget.
  GadgetMode? _mode(GadgetInfo p) =>
      _isPage(p) ? null : _c.layoutOf(p.id).mode;

  bool _isPage(GadgetInfo p) =>
      !p.appWide && p.placement == GadgetPlacement.page;

  bool _passes(GadgetInfo p) => switch (_filter) {
        _Filter.all => true,
        _Filter.onScreen => _mode(p) == GadgetMode.open,
        _Filter.minimised => _mode(p) == GadgetMode.docked,
      };

  void _openPage(GadgetInfo p) {
    Navigator.of(context).maybePop();
    final host = widget.hostContext;
    if (!host.mounted) return;
    unawaited(
        openGadgetPage(host, widget.dependencies, p, spaceId: _c.spaceId));
  }

  Future<void> _remove(GadgetInfo p) async {
    final messenger = ScaffoldMessenger.maybeOf(widget.hostContext);
    try {
      await _c.remove(p.id);
      messenger?.showSnackBar(SnackBar(content: Text('${p.name} removed')));
    } catch (e) {
      messenger?.showSnackBar(
          SnackBar(content: Text('Could not remove ${p.name}: $e')));
    }
  }

  void _minimiseAll() {
    for (final p in _c.manageable) {
      if (_mode(p) == GadgetMode.open) _c.dock(p.id);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: _c,
        builder: (context, _) => _build(context),
      );

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final all = _c.manageable;
    final universal = [for (final p in all) if (p.appWide && _passes(p)) p];
    final space = [for (final p in all) if (!p.appWide && _passes(p)) p];
    final open =
        all.where((p) => _mode(p) == GadgetMode.open).length;
    final docked =
        all.where((p) => _mode(p) == GadgetMode.docked).length;

    final children = <Widget>[
      if (_c.error != null && all.isEmpty)
        _Notice(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load your gadgets',
          body: '${_c.error}',
          action: FilledButton.tonal(
              onPressed: () => _c.refresh(force: true),
              child: const Text('Retry')),
        )
      else if (all.isEmpty && !_c.loading)
        const _Notice(
          icon: Icons.auto_awesome_rounded,
          title: 'No gadgets yet',
          body:
              'Ask your Aseman, or an agent in a workspace, to make you one — '
              'a tracker, a board, a dashboard. It shows up here, ready to '
              'float on screen or tuck away.',
        )
      else if (universal.isEmpty && space.isEmpty)
        _Notice(
          icon: Icons.filter_alt_off_rounded,
          title: 'Nothing ${_filterLabel(_filter).toLowerCase()}',
          body: 'Try another filter to see the rest of your gadgets.',
        ),
      if (universal.isNotEmpty) ...[
        const _SectionLabel(
            icon: Icons.public_rounded,
            label: 'Universal',
            hint: 'Your account · everywhere'),
        for (final p in universal) _tile(p),
      ],
      if (space.isNotEmpty) ...[
        const _SectionLabel(
            icon: Icons.workspaces_rounded,
            label: 'This workspace',
            hint: 'Shared with its members'),
        for (final p in space) _tile(p),
      ],
    ];

    return Material(
      type: MaterialType.transparency,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 6),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: context.iconWellDecoration(size: 40),
                child: Icon(Icons.extension_rounded,
                    size: 20, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Gadgets',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.2)),
                    const SizedBox(height: 2),
                    Text(
                      all.isEmpty
                          ? 'Made for you in Creator mode'
                          : '$open on screen · $docked minimised',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (open > 0)
                IconButton(
                  tooltip: 'Minimise all',
                  onPressed: _minimiseAll,
                  icon: const Icon(Icons.close_fullscreen_rounded, size: 19),
                ),
              _c.loading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : IconButton(
                      tooltip: 'Refresh',
                      onPressed: () => unawaited(_c.refresh(force: true)),
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                    ),
            ]),
          ),
          if (all.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  for (final f in _Filter.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 3, vertical: 4),
                      child: ChoiceChip(
                        label: Text(_filterLabel(f)),
                        selected: _filter == f,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                    ),
                ],
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(
                  12, 4, 12, 16 + MediaQuery.paddingOf(context).bottom),
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  static String _filterLabel(_Filter f) => switch (f) {
        _Filter.all => 'All',
        _Filter.onScreen => 'On screen',
        _Filter.minimised => 'Minimised',
      };

  Widget _tile(GadgetInfo p) {
    final mode = _mode(p);
    return _GadgetTile(
      gadget: p,
      mode: mode,
      mine: p.ownerId == _me,
      onPrimary: () {
        if (mode == null) {
          _openPage(p);
        } else if (mode == GadgetMode.open) {
          _c.dock(p.id);
        } else {
          _c.open(p.id);
        }
      },
      onMinimise: mode == null || mode == GadgetMode.docked
          ? null
          : () => _c.dock(p.id),
      onOpenPage: () => _openPage(p),
      onRemove: () => _remove(p),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(
      {required this.icon, required this.label, required this.hint});

  final IconData icon;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
      child: Row(children: [
        Icon(icon, size: 14, color: scheme.primary),
        const SizedBox(width: 6),
        Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: scheme.primary)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ),
      ]),
    );
  }
}

/// One gadget: its mark, name and where it lives, its state on screen, a
/// primary action (show / minimise / open) and a menu.
class _GadgetTile extends StatelessWidget {
  const _GadgetTile({
    required this.gadget,
    required this.mode,
    required this.mine,
    required this.onPrimary,
    this.onMinimise,
    this.onOpenPage,
    this.onRemove,
  });

  final GadgetInfo gadget;

  /// Null for a page gadget (no gadget).
  final GadgetMode? mode;
  final bool mine;
  final VoidCallback onPrimary;
  final VoidCallback? onMinimise;
  final VoidCallback? onOpenPage;
  final VoidCallback? onRemove;

  String get _where {
    if (gadget.appWide) return 'Floats over home';
    return switch (gadget.placement) {
      GadgetPlacement.page => 'Own page',
      _ => 'Floats on workspace',
    };
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppShape.innerOf(context));
    final (String status, Color tone) = switch (mode) {
      GadgetMode.open => ('On screen', AppColors.successOf(context)),
      GadgetMode.docked => ('Minimised', scheme.primary),
      null => ('Page', scheme.primary),
    };
    final (IconData primaryIcon, String primaryTip) = switch (mode) {
      GadgetMode.open => (Icons.minimize_rounded, 'Minimise'),
      null => (Icons.open_in_new_rounded, 'Open'),
      GadgetMode.docked =>
        (Icons.open_in_full_rounded, 'Show on screen'),
    };
    final onScreen = mode == GadgetMode.open;

    final menu = <PopupMenuEntry<String>>[
      if (onMinimise != null)
        const PopupMenuItem(
            value: 'minimise',
            child: _MenuRow(Icons.minimize_rounded, 'Minimise')),
      if (onOpenPage != null && mode != null)
        const PopupMenuItem(
            value: 'page',
            child: _MenuRow(Icons.open_in_new_rounded, 'Open as page')),
      if (mine && onRemove != null) ...[
        const PopupMenuDivider(),
        PopupMenuItem(
            value: 'remove',
            child: _MenuRow(Icons.delete_outline_rounded, 'Remove',
                color: scheme.error)),
      ],
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: onScreen
            ? ThemeRoles.selectedFill(context)
            : scheme.surfaceContainerHighest.withValues(
                alpha: AppSurfaces.overlayAlphaOf(context) * .45),
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
              color: onScreen
                  ? ThemeRoles.selectedInk(context).withValues(alpha: .35)
                  : scheme.outlineVariant.withValues(alpha: .5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPrimary,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: context.iconWellDecoration(size: 40),
                child: Icon(
                    gadget.appWide
                        ? Icons.extension_rounded
                        : Icons.widgets_rounded,
                    size: 20,
                    color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(gadget.name.isEmpty ? 'Untitled gadget' : gadget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
                    if (gadget.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(gadget.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ],
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 4, children: [
                      _Meta(label: status, color: tone, dot: onScreen),
                      _Meta(label: _where, color: scheme.onSurfaceVariant),
                      if (gadget.web)
                        _Meta(label: 'Web', color: scheme.tertiary),
                    ]),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: primaryTip,
                visualDensity: VisualDensity.compact,
                onPressed: onPrimary,
                icon: Icon(primaryIcon, size: 18),
              ),
              if (menu.isNotEmpty)
                AppPopupMenuButton<String>(
                  tooltip: 'More',
                  icon: const Icon(Icons.more_vert_rounded, size: 20),
                  itemBuilder: (_) => menu,
                  onSelected: (v) {
                    switch (v) {
                      case 'minimise':
                        onMinimise?.call();
                      case 'page':
                        onOpenPage?.call();
                      case 'remove':
                        onRemove?.call();
                    }
                  },
                )
              else
                const SizedBox(width: 6),
            ]),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ]);
}

class _Meta extends StatelessWidget {
  const _Meta({required this.label, required this.color, this.dot = false});

  final String label;
  final Color color;
  final bool dot;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: context.metaChipDecoration(accent: color),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot) ...[
            Icon(Icons.circle, size: 6, color: color),
            const SizedBox(width: 5),
          ],
          Text(label,
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}

class _Notice extends StatelessWidget {
  const _Notice(
      {required this.icon, required this.title, required this.body, this.action});

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 52,
          height: 52,
          decoration: context.iconWellDecoration(size: 52),
          child: Icon(icon, size: 24, color: scheme.primary),
        ),
        const SizedBox(height: 12),
        Text(title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 6),
        Text(body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ]),
    );
  }
}
