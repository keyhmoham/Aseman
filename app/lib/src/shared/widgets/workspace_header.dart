import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import '../../data/models/space.dart';
import 'skeleton.dart';
import 'overlay_panels.dart';

/// Shared top app bar of the workspace and the feed: the ASEMAN name in the
/// middle, the account avatar (its menu) on the right edge. On the workspace
/// the left edge is a Home pill that returns to the feed. On phones the
/// navigation drawer opens from a menu on the desk below this bar, not from
/// here. On the feed the left edge holds the notifications. On the workspace
/// the switcher opens from the [SwitcherEdgeHandle] (hidden on the feed). No
/// background, border or shadow: the page's glow shows through. Optional
/// callbacks hide the corresponding controls.
class WorkspaceHeader extends StatelessWidget {
  const WorkspaceHeader({
    super.key,
    required this.compact,
    this.feed = false,
    this.room,
    this.onOpenNotifications,
    this.unreadNotifications = 0,
    this.onBackToFeed,
    this.onGoHome,
    this.onOpenAdmin,
    required this.onOpenProfile,
    this.handle = '',
    this.avatar,
  });

  final String? room;
  final bool compact;

  /// Shown on the feed: the left edge holds the notifications instead.
  final bool feed;

  /// Opens the notifications (on the feed), badged with [unreadNotifications].
  final VoidCallback? onOpenNotifications;
  final int unreadNotifications;
  final String handle;

  /// The signed-in account's picture, shown over its initial.
  final ImageProvider? avatar;

  /// Leaves the workspace for the search feed (Home).
  final VoidCallback? onBackToFeed;
  final VoidCallback? onGoHome;
  final VoidCallback? onOpenAdmin;
  final VoidCallback onOpenProfile;

  @override
  Widget build(BuildContext context) => Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 24, vertical: 10),
      child: Row(children: [
        Expanded(
            child: Row(children: [
          if (feed && onOpenNotifications != null)
            IconButton(
                visualDensity: compact ? VisualDensity.compact : null,
                tooltip: 'Notifications',
                onPressed: onOpenNotifications,
                icon: Badge(
                    isLabelVisible: unreadNotifications > 0,
                    label: Text(unreadNotifications > 99
                        ? '99+'
                        : '$unreadNotifications'),
                    child: const Icon(Icons.notifications_none_rounded)))
          else if (onBackToFeed != null)
            _HomePill(onPressed: onBackToFeed),
          // Room path (hall shortcut + room title) is desktop-only; on phones
          // the Desk / Feed|Chat tabs already cover navigation.
          if (room != null && !compact) ...[
            const SizedBox(width: 6),
            const Icon(Icons.chevron_right_rounded),
            if (onGoHome != null)
              IconButton(
                  onPressed: onGoHome,
                  tooltip: 'Workspace home',
                  icon: const Icon(Icons.home_outlined, size: 18)),
            Flexible(
                child: Text(room!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)))
          ],
        ])),
        SizedBox(width: compact ? 6 : 12),
        const Text('ASEMAN',
            maxLines: 1,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 2)),
        SizedBox(width: compact ? 6 : 12),
        Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (!compact) ...[
            const Flexible(child: _LivePill()),
            const SizedBox(width: 8),
          ],
          if (!compact && onOpenAdmin != null) ...[
            IconButton.filledTonal(
                onPressed: onOpenAdmin,
                icon: const Icon(Icons.space_dashboard_outlined)),
            const SizedBox(width: 8),
          ],
          InkWell(
              onTap: onOpenProfile,
              customBorder: const CircleBorder(),
              child: CircleAvatar(
                  foregroundImage: avatar,
                  onForegroundImageError: avatar == null ? null : (_, __) {},
                  child:
                      Text(handle.isEmpty ? 'ME' : handle[0].toUpperCase())))
        ])),
      ]));
}

/// Filled stadium control that returns to the feed from any workspace.
class _HomePill extends StatelessWidget {
  const _HomePill({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.arrow_back_rounded, size: 18),
      label: const Text('Home'),
      style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          textStyle: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w700, fontSize: 13)));
}

/// The workspace switcher's handle: a bump stuck to the screen's right edge,
/// centered vertically, with a rocket in it. Tapping it opens the switcher.
class SwitcherEdgeHandle extends StatelessWidget {
  const SwitcherEdgeHandle({super.key, required this.onTap});
  final VoidCallback onTap;

  static const _width = 30.0, _height = 168.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fill(
        child: SafeArea(
            child: Align(
                alignment: Alignment.centerRight,
                child: Tooltip(
                    message: 'Switch workspace',
                    child: Semantics(
                        button: true,
                        label: 'Switch workspace',
                        child: GestureDetector(
                            onTap: onTap,
                            behavior: HitTestBehavior.opaque,
                            child: CustomPaint(
                                painter: _BumpPainter(
                                    fill: scheme.primaryContainer,
                                    shadow: scheme.shadow),
                                child: SizedBox(
                                    width: _width,
                                    height: _height,
                                    child: Align(
                                        alignment: const Alignment(.3, 0),
                                        child: Icon(
                                            Icons.rocket_launch_rounded,
                                            size: 17,
                                            color: scheme
                                                .onPrimaryContainer)))))))))); 
  }
}

/// A bell-shaped bump growing out of the right edge, tapering to nothing at
/// its top and bottom.
class _BumpPainter extends CustomPainter {
  const _BumpPainter({required this.fill, required this.shadow});
  final Color fill;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w, 0)
      ..cubicTo(w, h * .3, 0, h * .3, 0, h / 2)
      ..cubicTo(0, h * .7, w, h * .7, w, h)
      ..close();
    canvas.drawShadow(path, shadow.withValues(alpha: .5), 3, false);
    canvas.drawPath(path, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(covariant _BumpPainter old) =>
      old.fill != fill || old.shadow != shadow;
}

class _LivePill extends StatelessWidget {
  const _LivePill();
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(20)),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, color: Colors.greenAccent, size: 8),
        SizedBox(width: 7),
        Text('Markets live',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700))
      ]));
}

/// Workspace switcher dialog/sheet with a searchable grid of the user's real
/// spaces. [dependencies] lists and creates spaces through the backend.
/// With [onOpenFeed] the grid starts with a Home tile that opens the feed.
/// With [embedded] it fills a mobile home tab (no close control).
class WorkspacePicker extends StatefulWidget {
  const WorkspacePicker(
      {super.key,
      required this.current,
      required this.onPick,
      this.onOpenFeed,
      this.feedSelected = false,
      this.dependencies,
      this.onSettings,
      this.embedded = false});
  final String current;
  final ValueChanged<String> onPick;
  final VoidCallback? onOpenFeed;

  /// The feed is open now: its tile is the selected one.
  final bool feedSelected;
  final AppDependencies? dependencies;
  final void Function(Workspace space)? onSettings;

  /// Full-page tab on the mobile home shell: no close, fills its parent.
  final bool embedded;
  @override
  State<WorkspacePicker> createState() => _WorkspacePickerState();
}

class _WorkspacePickerState extends State<WorkspacePicker> {
  String query = '';
  List<Workspace> spaces = [];
  final Map<String, int> _roomCounts = {};
  bool loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => loading = true);
    try {
      final list = await deps.service.fetchSpaces();
      final counts = <String, int>{};
      for (final sp in list) {
        try {
          final rooms = await deps.service.fetchRoomsForSpace(sp.id);
          counts[sp.name] = rooms.length;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        spaces = list;
        _roomCounts.addAll(counts);
        loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  /// The picture of the workspace called [name], if it has one.
  ImageProvider? _avatarOf(String name) {
    final deps = widget.dependencies;
    if (deps == null) return null;
    for (final sp in spaces) {
      if (sp.name == name) return deps.service.avatarImage(sp.avatar);
    }
    return null;
  }

  List<String> get _names {
    final filtered = spaces
        .map((s) => s.name)
        .where((e) => e.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return filtered;
  }

  Future<void> _create() async {
    final deps = widget.dependencies;
    final name = await showAppDialog<String>(
      context: context,
      builder: (_) => const _CreateWorkspaceDialog(),
    );
    if (name == null || name.trim().isEmpty || deps == null || !mounted) return;
    try {
      final created = await deps.service.createSpace(name.trim(), '');
      setState(() => spaces = [...spaces, created]);
      widget.onPick(created.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 820;
    final embedded = widget.embedded;
    final names = _names;
    final showFeed = _showFeed;
    final body = Material(
        color: Colors.transparent,
        child: Container(
          width: embedded ? null : 760,
          constraints: embedded
              ? const BoxConstraints.expand()
              : BoxConstraints(maxHeight: compact ? double.infinity : 620),
          padding: EdgeInsets.all(embedded ? 16 : 26),
          // In a bottom sheet the sheet already paints the surface;
          // floating on desktop it matches every other modal panel.
          decoration: BoxDecoration(
              color: compact || embedded
                  ? null
                  : AppSurfaces.overlay(Theme.of(context).colorScheme),
              borderRadius: BorderRadius.circular(AppShape.card),
              boxShadow: compact || embedded
                  ? null
                  : const [
                      BoxShadow(
                          color: Colors.black38,
                          blurRadius: 60,
                          offset: Offset(0, 22))
                    ]),
          child: Column(
              mainAxisSize: embedded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                      embedded
                          ? Icons.workspaces_outline
                          : Icons.blur_on_rounded,
                      size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(embedded ? 'Spaces' : 'Switch workspace',
                            style: const TextStyle(
                                fontSize: 23, fontWeight: FontWeight.w900)),
                        Text(
                            embedded
                                ? 'Open a workspace or start a new one'
                                : 'Every workspace has its own rooms, desks and feed',
                            style: const TextStyle(fontSize: 11))
                      ])),
                  if (!embedded)
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))
                ]),
                const SizedBox(height: 18),
                TextField(
                    autofocus: !embedded,
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search workspaces…')),
                const SizedBox(height: 18),
                Flexible(
                    child: loading
                        ? const SkeletonGrid(
                            maxCrossAxisExtent: 220, mainAxisExtent: 154)
                        : GridView.builder(
                            shrinkWrap: !embedded,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: compact
                                        ? math.max(
                                            1,
                                            (MediaQuery.sizeOf(context).width /
                                                    180)
                                                .floor())
                                        : 3,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    mainAxisExtent: 154),
                            itemCount: names.length + 1 + (showFeed ? 1 : 0),
                            itemBuilder: (context, i) {
                              if (showFeed) {
                                if (i == 0) {
                                  return _FeedTile(
                                      selected: widget.feedSelected,
                                      onTap: widget.onOpenFeed!);
                                }
                                i -= 1;
                              }
                              if (i == names.length) {
                                return InkWell(
                                    onTap: _create,
                                    borderRadius: BorderRadius.circular(24),
                                    child: Container(
                                        decoration: BoxDecoration(
                                            border: Border.all(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .outlineVariant),
                                            borderRadius:
                                                BorderRadius.circular(24)),
                                        child: const Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons
                                                  .add_circle_outline_rounded),
                                              SizedBox(height: 8),
                                              Text('New workspace',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700))
                                            ])));
                              }
                              final name = names[i];
                              final selected =
                                  !widget.feedSelected && name == widget.current;
                              final space = spaces.firstWhere(
                                  (s) => s.name == name,
                                  orElse: () => Workspace(
                                      id: '', ownerId: '', name: name));
                              return InkWell(
                                  onTap: () => widget.onPick(name),
                                  borderRadius: BorderRadius.circular(24),
                                  child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                          color: selected
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .primaryContainer
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest
                                                  .withValues(alpha: .6),
                                          borderRadius:
                                              BorderRadius.circular(24),
                                          border: Border.all(
                                              color: selected
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .primary
                                                  : Colors.transparent)),
                                      child: Stack(children: [
                                        Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              CircleAvatar(
                                                  foregroundImage:
                                                      _avatarOf(name),
                                                  onForegroundImageError:
                                                      _avatarOf(name) == null
                                                          ? null
                                                          : (_, __) {},
                                                  child: Text(name
                                                      .substring(
                                                          0,
                                                          math.min(
                                                              2, name.length))
                                                      .toUpperCase())),
                                              const Spacer(),
                                              Text(name,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900)),
                                              Text(
                                                  '${_roomCountFor(name)} rooms',
                                                  style: const TextStyle(
                                                      fontSize: 10)),
                                              if (selected)
                                                const Align(
                                                    alignment:
                                                        Alignment.bottomRight,
                                                    child: Icon(
                                                        Icons
                                                            .check_circle_rounded,
                                                        size: 17))
                                            ]),
                                        if (widget.onSettings != null &&
                                            space.id.isNotEmpty)
                                          Positioned(
                                              top: 0,
                                              right: 0,
                                              child: IconButton(
                                                  tooltip:
                                                      'Settings for $name',
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  onPressed: () =>
                                                      widget.onSettings!(space),
                                                  icon: const Icon(
                                                      Icons.settings_outlined,
                                                      size: 18)))
                                      ])));
                            })),
              ]),
        ));
    if (embedded) return body;
    return SafeArea(child: Center(child: body));
  }

  int _roomCountFor(String name) => _roomCounts[name] ?? 0;

  bool get _showFeed {
    if (widget.onOpenFeed == null) return false;
    final q = query.trim().toLowerCase();
    return q.isEmpty || 'home feed'.contains(q);
  }
}

/// The feed's shortcut in the workspace switcher, laid out like a space.
class _FeedTile extends StatelessWidget {
  const _FeedTile({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: selected
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: selected ? scheme.primary : Colors.transparent)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                      backgroundColor: scheme.primary,
                      child: Icon(Icons.home_rounded, color: scheme.onPrimary)),
                  const Spacer(),
                  const Text('Home',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                  const Text('Your feed', style: TextStyle(fontSize: 10)),
                  if (selected)
                    const Align(
                        alignment: Alignment.bottomRight,
                        child: Icon(Icons.check_circle_rounded, size: 17))
                ])));
  }
}

class _CreateWorkspaceDialog extends StatefulWidget {
  const _CreateWorkspaceDialog();
  @override
  State<_CreateWorkspaceDialog> createState() => _CreateWorkspaceDialogState();
}

class _CreateWorkspaceDialogState extends State<_CreateWorkspaceDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New workspace'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
          decoration: const InputDecoration(labelText: 'Workspace name'),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final v = controller.text.trim();
            if (v.isNotEmpty) Navigator.pop(context, v);
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
