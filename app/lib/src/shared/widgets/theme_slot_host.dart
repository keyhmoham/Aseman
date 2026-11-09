import 'package:flutter/material.dart';

import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/theme_ui_spec.dart';
import 'theme_elpian_surface.dart' deferred as theme_surface;

/// Reads the active pack's [ThemeUiSpec].
ThemeUiSpec themeUiOf(BuildContext context) =>
    AsemanTokens.maybeOf(context)?.ui ?? const ThemeUiSpec();

bool themeSlotDisabled(BuildContext context, String slot) =>
    AsemanTokens.maybeOf(context)?.slotDisabled(slot) ?? false;

ThemeSurfaceSpec? themeSlotSurface(BuildContext context, String slot) =>
    AsemanTokens.maybeOf(context)?.slotSurface(slot);

ThemeIslandSpec? themeIslandOf(BuildContext context, String id) =>
    themeUiOf(context).islandFor(id);

/// Composes a built-in UI [child] with optional theme disable / Elpian attach.
///
/// The Elpian engine library is deferred: default packs (no slot surfaces)
/// never download it on the critical path.
class ThemeSlotHost extends StatelessWidget {
  const ThemeSlotHost({
    super.key,
    required this.slot,
    required this.child,
    this.elpianPadding,
    this.spaceId = '',
    this.roomId = '',
  });

  final String slot;
  final Widget child;
  final EdgeInsetsGeometry? elpianPadding;
  final String spaceId;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final tokens = AsemanTokens.maybeOf(context);
    final ui = tokens?.ui ?? const ThemeUiSpec();
    if (ui.isDisabled(slot)) return const SizedBox.shrink();

    final surface = ui.surfaceFor(slot);
    if (surface == null || surface.isEmpty) return child;

    return _DeferredThemePanel(
      surface: surface,
      slot: slot,
      elpianPadding: elpianPadding,
      spaceId: spaceId,
      roomId: roomId,
      child: child,
    );
  }
}

class _DeferredThemePanel extends StatefulWidget {
  const _DeferredThemePanel({
    required this.surface,
    required this.slot,
    required this.child,
    this.elpianPadding,
    this.spaceId = '',
    this.roomId = '',
  });

  final ThemeSurfaceSpec surface;
  final String slot;
  final Widget child;
  final EdgeInsetsGeometry? elpianPadding;
  final String spaceId;
  final String roomId;

  @override
  State<_DeferredThemePanel> createState() => _DeferredThemePanelState();
}

class _DeferredThemePanelState extends State<_DeferredThemePanel> {
  bool _ready = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await theme_surface.loadLibrary();
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return widget.child;
    if (!_ready) return widget.child;

    final surface = widget.surface;
    final panel = theme_surface.ThemeElpianSurface(
      source: surface.elpian,
      slot: widget.slot,
      hostChild: surface.mode == ThemeSurfaceMode.wrap ? widget.child : null,
      padding: widget.elpianPadding,
      spaceId: widget.spaceId,
      roomId: widget.roomId,
    );

    return switch (surface.mode) {
      ThemeSurfaceMode.replace => panel,
      ThemeSurfaceMode.before => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [panel, widget.child],
        ),
      ThemeSurfaceMode.after => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [widget.child, panel],
        ),
      ThemeSurfaceMode.wrap => _WrapWithHostFallback(
          panel: panel,
          child: widget.child,
          source: surface.elpian,
        ),
    };
  }
}

class _WrapWithHostFallback extends StatelessWidget {
  const _WrapWithHostFallback({
    required this.panel,
    required this.child,
    required this.source,
  });

  final Widget panel;
  final Widget child;
  final ThemeElpianSource source;

  bool get _declaresHost {
    final inline = source.inline;
    if (inline == null) return false;
    return _treeDeclaresHost(inline);
  }

  static bool _treeDeclaresHost(Map<String, dynamic> node) {
    final type = '${node['type'] ?? ''}'.toLowerCase();
    if (type == 'themehostchild' ||
        type == 'hostchild' ||
        type == 'theme_host_child') {
      return true;
    }
    final props = node['props'];
    if (props is Map && '${props['slot'] ?? ''}'.toLowerCase() == 'host') {
      return true;
    }
    final children = node['children'];
    if (children is List) {
      for (final c in children) {
        if (c is Map && _treeDeclaresHost(Map<String, dynamic>.from(c))) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_declaresHost || source.hasProgram) return panel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [panel, child],
    );
  }
}

/// Full-screen / section host for a theme island plugin.
class ThemeIslandHost extends StatelessWidget {
  const ThemeIslandHost({
    super.key,
    required this.island,
    this.spaceId = '',
    this.roomId = '',
    this.padding,
  });

  final ThemeIslandSpec island;
  final String spaceId;
  final String roomId;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (themeSlotDisabled(context, island.id)) {
      return const SizedBox.shrink();
    }
    return _DeferredThemeIsland(
      island: island,
      spaceId: spaceId,
      roomId: roomId,
      padding: padding,
    );
  }
}

class _DeferredThemeIsland extends StatefulWidget {
  const _DeferredThemeIsland({
    required this.island,
    this.spaceId = '',
    this.roomId = '',
    this.padding,
  });

  final ThemeIslandSpec island;
  final String spaceId;
  final String roomId;
  final EdgeInsetsGeometry? padding;

  @override
  State<_DeferredThemeIsland> createState() => _DeferredThemeIslandState();
}

class _DeferredThemeIslandState extends State<_DeferredThemeIsland> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    theme_surface.loadLibrary().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return theme_surface.ThemeElpianSurface(
      source: widget.island.elpian,
      slot: widget.island.id,
      spaceId: widget.spaceId,
      roomId: widget.roomId,
      padding: widget.padding,
    );
  }
}

/// Filters [slots] removing those disabled by the active theme.
List<String> themeEnabledSlots(
  BuildContext context,
  Iterable<String> slots,
) {
  final ui = themeUiOf(context);
  return [for (final s in slots) if (!ui.isDisabled(s)) s];
}

/// Opens a theme island as a full page.
Future<void> openThemeIslandPage(
  BuildContext context,
  ThemeIslandSpec island, {
  String spaceId = '',
  String roomId = '',
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(island.title)),
        body: SafeArea(
          child: ThemeIslandHost(
            island: island,
            spaceId: spaceId,
            roomId: roomId,
          ),
        ),
      ),
    ),
  );
}
