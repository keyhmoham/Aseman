import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_surfaces.dart';
import '../../data/models/space.dart';
import 'glass_surface.dart';
import 'overlay_panels.dart';
import 'skeleton.dart';

/// Layout numbers for the floating glass [WorkspaceHeader] so every host
/// page can reserve matching top space. Pass [compact] from the same
/// breakpoint the header uses (`width < 820`): phones keep a near-edge pill;
/// desktop keeps a wide gutter and caps the pill at [desktopMaxWidth] so it
/// stays compact instead of stretching across the screen.
abstract final class FloatingAppBarLayout {
  /// Inner height of the glass pill (not including outer margins).
  /// Short enough to sit with the other floating sections; the account
  /// avatar ([avatarRadius]) is what sets this.
  static const double height = 40;

  /// Account avatar radius. Smaller than a default [CircleAvatar] so the
  /// pill can stay short.
  static const double avatarRadius = 13;

  /// Small gap under the pill before content feels clear of it.
  static const double contentGap = 8;

  /// Distance from the safe-area top to the pill.
  static double topMargin(bool compact) => compact ? 16 : 20;

  /// Distance from the screen's left/right edges to the pill. Desktop keeps
  /// a wide gutter; on very wide windows [desktopMaxWidth] adds still more.
  static double horizontalMargin(bool compact) => compact ? 16 : 128;

  /// Widest the desktop pill grows. Extra window width stays as side margin.
  static const double desktopMaxWidth = 840;

  /// Top space hosts should reserve inside scrollable / page content so the
  /// first paint clears the bar; when that content scrolls, it passes under.
  static double contentInset(bool compact) =>
      topMargin(compact) + height + contentGap;

  static EdgeInsets margin(bool compact) => EdgeInsets.fromLTRB(
      horizontalMargin(compact), topMargin(compact), horizontalMargin(compact), 0);
}

/// Icon buttons inside the short pill: the theme's 48px target would force
/// the bar taller than the avatar.
ButtonStyle _barIconStyle() => IconButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(32, 32),
      padding: const EdgeInsets.all(4),
      iconSize: 18,
    );

/// Shared floating top app bar of the workspace and the feed: a long glass
/// pill over the page. ASEMAN sits in the middle, the account avatar (its
/// menu) on the right. On the workspace the left edge is a Home pill that
/// returns to the feed. On phones the navigation drawer opens from a menu on
/// the desk below this bar, not from here. On the feed the left edge holds
/// the notifications. On the workspace the switcher opens from the
/// [SwitcherEdgeHandle] (hidden on the feed). Hosts overlay this bar and use
/// [FloatingAppBarLayout.contentInset] so content starts clear of it.
/// Optional callbacks hide the corresponding controls.
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
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(FloatingAppBarLayout.height);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: GlassSurface(
        alpha: AppSurfaces.cardAlpha,
        blur: AppSurfaces.blurSigma,
        borderRadius: radius,
        child: SizedBox(
          height: FloatingAppBarLayout.height,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
            child: Row(children: [
              Expanded(
                  child: Row(children: [
                if (feed && onOpenNotifications != null)
                  IconButton(
                      style: _barIconStyle(),
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
                // Room path (hall shortcut + room title) is desktop-only;
                // on phones the Desk / Feed|Chat tabs already cover
                // navigation.
                if (room != null && !compact) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 18),
                  if (onGoHome != null)
                    IconButton(
                        style: _barIconStyle(),
                        onPressed: onGoHome,
                        tooltip: 'Workspace home',
                        icon: const Icon(Icons.home_outlined)),
                  Flexible(
                      child: Text(room!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)))
                ],
              ])),
              SizedBox(width: compact ? 6 : 10),
              const Text('ASEMAN',
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2)),
              SizedBox(width: compact ? 6 : 10),
              Expanded(
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                    if (!compact) ...[
                      const Flexible(child: _LivePill()),
                      const SizedBox(width: 6),
                    ],
                    if (!compact && onOpenAdmin != null) ...[
                      IconButton.filledTonal(
                          style: _barIconStyle(),
                          onPressed: onOpenAdmin,
                          icon: const Icon(Icons.space_dashboard_outlined)),
                      const SizedBox(width: 6),
                    ],
                    InkWell(
                        onTap: onOpenProfile,
                        customBorder: const CircleBorder(),
                        child: CircleAvatar(
                            radius: FloatingAppBarLayout.avatarRadius,
                            foregroundImage: avatar,
                            onForegroundImageError:
                                avatar == null ? null : (_, __) {},
                            child: Text(
                                handle.isEmpty ? 'ME' : handle[0].toUpperCase(),
                                style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    height: 1))))
                  ])),
            ]),
          ),
        ),
      ),
    );
    return Padding(
      padding: FloatingAppBarLayout.margin(compact),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: compact
                ? double.infinity
                : FloatingAppBarLayout.desktopMaxWidth,
          ),
          child: bar,
        ),
      ),
    );
  }
}

/// Filled stadium control that returns to the feed from any workspace.
class _HomePill extends StatelessWidget {
  const _HomePill({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.arrow_back_rounded, size: 16),
      label: const Text('Home'),
      style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 28),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          textStyle: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(fontWeight: FontWeight.w600, fontSize: 13)));
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
/// With [embedded] it fills a home-shell tab (no close control).
/// With [inBottomSheet] (or under [AppSheetScope]) the body stays transparent
/// so the host sheet paints the glass.
/// With [dense] tiles and type shrink for a narrow desktop rail.
class WorkspacePicker extends StatefulWidget {
  const WorkspacePicker(
      {super.key,
      required this.current,
      required this.onPick,
      this.onOpenFeed,
      this.feedSelected = false,
      this.dependencies,
      this.onSettings,
      this.embedded = false,
      this.inBottomSheet = false,
      this.dense = false});
  final String current;
  final ValueChanged<String> onPick;
  final VoidCallback? onOpenFeed;

  /// The feed is open now: its tile is the selected one.
  final bool feedSelected;
  final AppDependencies? dependencies;
  final void Function(Workspace space)? onSettings;

  /// Home-shell tab: no close, fills its parent.
  final bool embedded;

  /// Body stays clear; [showAppSheet] owns the frosted chrome.
  final bool inBottomSheet;

  /// Compact chrome for a desktop side rail; leave false on mobile.
  final bool dense;
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
    final inSheet =
        widget.inBottomSheet || AppSheetScope.inSheetOf(context);
    final dense = widget.dense;
    final names = _names;
    final showFeed = _showFeed;
    // Sheet / floating panel / embedded rail paint the frost; keep clear.
    final body = Material(
        color: Colors.transparent,
        child: Container(
          width: embedded ? null : 760,
          constraints: embedded
              ? const BoxConstraints.expand()
              : BoxConstraints(maxHeight: compact ? double.infinity : 620),
          padding: EdgeInsets.all(dense ? 12 : (embedded || inSheet ? 16 : 26)),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppShape.card)),
          child: Column(
              mainAxisSize: embedded || inSheet
                  ? MainAxisSize.max
                  : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(
                      embedded
                          ? Icons.workspaces_outline
                          : Icons.blur_on_rounded,
                      size: dense ? 22 : 30),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(embedded ? 'Spaces' : 'Switch workspace',
                            style: TextStyle(
                                fontSize: dense ? 17 : 23,
                                fontWeight: FontWeight.w900)),
                        Text(
                            embedded
                                ? 'Open a workspace or start a new one'
                                : 'Every workspace has its own rooms, desks and feed',
                            style: TextStyle(fontSize: dense ? 10 : 11))
                      ])),
                  if (!embedded)
                    IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close))
                ]),
                SizedBox(height: dense ? 12 : 18),
                TextField(
                    autofocus: !embedded,
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search_rounded),
                        hintText: 'Search workspaces…')),
                SizedBox(height: dense ? 12 : 18),
                Flexible(
                    child: LayoutBuilder(builder: (context, gridBox) {
                  // Size columns to this panel, not the whole window — side
                  // rails are much narrower than a phone or the modal sheet.
                  final tileExtent = dense ? 118.0 : 154.0;
                  final cols = math.max(
                      1,
                      (gridBox.maxWidth / (dense ? 140 : 180))
                          .floor()
                          .clamp(1, 3));
                  if (loading) {
                    return SkeletonGrid(
                        maxCrossAxisExtent: 220, mainAxisExtent: tileExtent);
                  }
                  return GridView.builder(
                            shrinkWrap: !embedded,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: cols,
                                    mainAxisSpacing: dense ? 8 : 12,
                                    crossAxisSpacing: dense ? 8 : 12,
                                    mainAxisExtent: tileExtent),
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
                              final radius = dense ? 18.0 : 24.0;
                              return InkWell(
                                  onTap: () => widget.onPick(name),
                                  borderRadius: BorderRadius.circular(radius),
                                  child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      padding: EdgeInsets.all(dense ? 10 : 16),
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
                                              BorderRadius.circular(radius),
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
                                                  radius: dense ? 16 : 20,
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
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      fontSize:
                                                          dense ? 12 : 14)),
                                              Text(
                                                  '${_roomCountFor(name)} rooms',
                                                  style: TextStyle(
                                                      fontSize:
                                                          dense ? 9 : 10)),
                                              if (selected)
                                                Align(
                                                    alignment:
                                                        Alignment.bottomRight,
                                                    child: Icon(
                                                        Icons
                                                            .check_circle_rounded,
                                                        size: dense
                                                            ? 14
                                                            : 17))
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
                                                  icon: Icon(
                                                      Icons.settings_outlined,
                                                      size: dense
                                                          ? 16
                                                          : 18)))
                                      ])));
                            });
                })),
              ]),
        ));
    if (embedded || inSheet) return body;
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
