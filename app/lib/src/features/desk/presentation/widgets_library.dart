import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../data/desk_api.dart';
import '../domain/desk_models.dart';
import 'tool_avatar.dart';

/// A pinned window from one room in a workspace's vault.
class WidgetsLibraryPin {
  const WidgetsLibraryPin({
    required this.spaceId,
    required this.spaceName,
    required this.roomId,
    required this.roomName,
    required this.pin,
  });

  final String spaceId;
  final String spaceName;
  final String roomId;
  final String roomName;
  final DeskPin pin;

  String get label => pin.label.isEmpty ? 'Window' : pin.label;
}

/// Opens the widgets / windows library: a bottom sheet on phones, a
/// full-height sheet stuck to the trailing edge on desktop. Tabs are one
/// per workspace; each tab is a grid
/// of that space's pinned desk widgets and windows.
Future<void> showWidgetsLibrary(
  BuildContext context,
  AppDependencies dependencies, {
  ValueChanged<String>? onOpenSpace,
}) {
  return showFloatingPanel(
    context,
    _WidgetsLibraryPanel(
      dependencies: dependencies,
      onOpenSpace: onOpenSpace,
    ),
    maxWidth: 980,
    maxHeight: 760,
    barrierLabel: 'Close widgets library',
  );
}

class _WidgetsLibraryPanel extends StatefulWidget {
  const _WidgetsLibraryPanel({
    required this.dependencies,
    this.onOpenSpace,
  });

  final AppDependencies dependencies;
  final ValueChanged<String>? onOpenSpace;

  @override
  State<_WidgetsLibraryPanel> createState() => _WidgetsLibraryPanelState();
}

class _WidgetsLibraryPanelState extends State<_WidgetsLibraryPanel>
    with SingleTickerProviderStateMixin {
  List<Workspace> spaces = const [];
  Map<String, List<WidgetsLibraryPin>> pinsBySpace = const {};
  bool loading = true;
  String? error;
  TabController? tabs;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    tabs?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final listed = await widget.dependencies.service.fetchSpaces();
      final found = await Future.wait(listed.map(_pinsOf));
      if (!mounted) return;
      final bySpace = <String, List<WidgetsLibraryPin>>{
        for (var i = 0; i < listed.length; i++) listed[i].id: found[i],
      };
      tabs?.dispose();
      final next = listed.isEmpty
          ? null
          : (TabController(length: listed.length, vsync: this)
            ..addListener(() {
              if (!(tabs?.indexIsChanging ?? true)) setState(() {});
            }));
      tabs = next;
      setState(() {
        spaces = listed;
        pinsBySpace = bySpace;
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = 'Could not load workspaces';
      });
    }
  }

  Future<List<WidgetsLibraryPin>> _pinsOf(Workspace space) async {
    final rooms = <(String, String)>[('home', 'Hall')];
    try {
      final listed =
          await widget.dependencies.service.fetchRoomsForSpace(space.id);
      for (final room in listed) {
        if (room.id.isEmpty) continue;
        rooms.add((room.id, room.name.isEmpty ? 'Room' : room.name));
      }
    } catch (_) {}
    final api = DeskApi.of(widget.dependencies.service);
    final out = <WidgetsLibraryPin>[];
    await Future.wait(
      rooms.map((room) async {
        try {
          final desk = await api.get(
            space.id,
            room.$1,
            timeout: const Duration(milliseconds: 1200),
          );
          for (final pin in desk.pins) {
            if (pin.id.isEmpty) continue;
            out.add(
              WidgetsLibraryPin(
                spaceId: space.id,
                spaceName: space.name,
                roomId: room.$1,
                roomName: room.$2,
                pin: pin,
              ),
            );
          }
        } catch (_) {}
      }),
    );
    out.sort((a, b) {
      final byRoom = a.roomName.compareTo(b.roomName);
      if (byRoom != 0) return byRoom;
      return a.label.compareTo(b.label);
    });
    return out;
  }

  void _openSpace(String name) {
    Navigator.of(context).maybePop();
    widget.onOpenSpace?.call(name);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.expanded;
    return Material(
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 20,
              compact ? 8 : 16,
              8,
              0,
            ),
            child: PanelHeader(
              icon: Icons.widgets_rounded,
              title: 'Widgets & windows',
              subtitle: 'Pinned widgets and windows from every workspace vault',
              onClose: () => Navigator.of(context).maybePop(),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: loading ? null : _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (error != null && spaces.isEmpty) {
      return PanelEmpty(
        icon: Icons.cloud_off_outlined,
        title: 'Could not load',
        message: error!,
      );
    }
    if (loading && spaces.isEmpty) {
      return const SkeletonList(itemCount: 6);
    }
    if (spaces.isEmpty) {
      return const PanelEmpty(
        icon: Icons.widgets_outlined,
        title: 'No workspaces yet',
        message: 'Join or create a workspace to pin widgets and windows.',
      );
    }
    final controller = tabs;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SegmentedTabBar(
            controller: controller,
            compact: MediaQuery.sizeOf(context).width < Breakpoints.expanded,
            labels: [for (final s in spaces) s.name],
            icons: [
              for (final _ in spaces) Icons.workspaces_outline,
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              for (final space in spaces)
                _SpacePinsGrid(
                  space: space,
                  pins: pinsBySpace[space.id] ?? const [],
                  loading: loading,
                  onOpenSpace: () => _openSpace(space.name),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SpacePinsGrid extends StatelessWidget {
  const _SpacePinsGrid({
    required this.space,
    required this.pins,
    required this.loading,
    required this.onOpenSpace,
  });

  final Workspace space;
  final List<WidgetsLibraryPin> pins;
  final bool loading;
  final VoidCallback onOpenSpace;

  @override
  Widget build(BuildContext context) {
    if (pins.isEmpty) {
      return PanelEmpty(
        icon: Icons.push_pin_outlined,
        title: loading ? 'Loading pinned windows…' : 'Nothing pinned yet',
        message: loading
            ? 'Looking through ${space.name}…'
            : 'Pin a window from a desk in ${space.name} to keep it here.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${pins.length} pinned in ${space.name}',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              TextButton.icon(
                onPressed: onOpenSpace,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Open workspace'),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: .92,
            ),
            itemCount: pins.length,
            itemBuilder: (context, i) => _PinCard(
              item: pins[i],
              onOpen: onOpenSpace,
            ),
          ),
        ),
      ],
    );
  }
}

class _PinCard extends StatelessWidget {
  const _PinCard({required this.item, required this.onOpen});

  final WidgetsLibraryPin item;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail = [
      if (item.roomName.isNotEmpty) item.roomName,
      if (item.pin.argsSummary.isNotEmpty) item.pin.argsSummary,
    ].join(' · ');
    final shape = ThemeChrome.cardShape(context);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: ToolAvatar(
                  tool: item.pin.tool,
                  name: item.pin.name,
                  size: 40,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                item.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
              const Spacer(),
              Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  Icons.push_pin_rounded,
                  size: 16,
                  color: scheme.primary.withValues(alpha: .85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
