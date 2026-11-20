import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_dependencies.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shape.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_surfaces.dart';
import '../../core/theme/aseman_tokens.dart';
import '../../core/theme/design_language.dart';
import '../../core/theme/halo_ring_cache.dart';
import '../../core/theme/shell_layout.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../core/theme/theme_ui_spec.dart';
import '../../data/models/space.dart';
import 'avatar_face.dart';
import 'glass_surface.dart';
import 'overlay_panels.dart';
import 'skeleton.dart';
import 'sky_ui.dart';

/// Layout numbers for the floating glass [WorkspaceHeader] so every host
/// page can reserve matching top space. Pass [compact] from the same
/// breakpoint the header uses (`width < Breakpoints.expanded`): phones keep a
/// near-edge pill;
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

  /// Distance from the screen's left/right edges to the pill. Aligns with the
  /// Material 3 page margin; on very wide windows [desktopMaxWidth] absorbs
  /// the extra width instead of stretching the bar.
  static double horizontalMargin(bool compact) => compact ? 16 : 24;

  /// Widest the desktop pill grows. Extra window width stays as side margin.
  static const double desktopMaxWidth = 1200;

  /// Top space hosts should reserve inside scrollable / page content so the
  /// first paint clears the bar; when that content scrolls, it passes under.
  static double contentInset(bool compact) =>
      topMargin(compact) + height + contentGap;

  /// Like [contentInset], but collapses when the active theme disables the
  /// floating workspace header / app bar slot.
  static double contentInsetOf(BuildContext context, bool compact) {
    final ui = AsemanTokens.maybeOf(context)?.ui;
    if (ui != null &&
        (ui.isDisabled(FeatureSlots.workspaceHeader) ||
            ui.isDisabled(ThemeChromeSlots.workspaceHeader) ||
            ui.isDisabled(ThemeChromeSlots.floatingAppBar))) {
      return contentGap;
    }
    return contentInset(compact);
  }

  static EdgeInsets margin(bool compact) => EdgeInsets.fromLTRB(
    horizontalMargin(compact),
    topMargin(compact),
    horizontalMargin(compact),
    0,
  );
}

/// Icon buttons inside the short pill: the theme's 48px target would force
/// the bar taller than the avatar. Shape / ink follow the active pack.
ButtonStyle _barIconStyle(BuildContext context) => context.barIconButtonStyle(
  iconSize: (AsemanTokens.maybeOf(context)?.language.iconSize ?? 22) - 4,
);

/// Shared floating top app bar of the workspace and the feed: a long glass
/// pill over the page. ASEMAN sits in the middle. On the right: the widgets /
/// windows library, and on wide screens the account avatar beside it. Phones
/// hide the avatar (profile lives in Home's You tab). On the workspace the
/// left edge is a Home pill that returns to the chats list. On the feed the
/// left edge holds the notifications. Hosts overlay this bar and use
/// [FloatingAppBarLayout.contentInset] so content starts clear of it.
/// Optional callbacks hide the corresponding controls.
class WorkspaceHeader extends StatelessWidget {
  /// The account button's label (its tooltip and what a screen reader says).
  static const profileTooltip = 'Your profile';

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
    this.onOpenProfile,
    this.onOpenWidgetsLibrary,
    this.onOpenLibrary,
    this.onOpenSpaceFeed,
    this.handle = '',
    this.accountId = '',
    this.avatar,
    this.anchored = false,
  });

  final String? room;
  final bool compact;

  /// Shown on the feed: the left edge holds the notifications instead.
  final bool feed;

  /// Opens the notifications (on the feed), badged with [unreadNotifications].
  final VoidCallback? onOpenNotifications;
  final int unreadNotifications;
  final String handle;

  /// Signed-in account id — binds the avatar ring in [HaloRingCache].
  final String accountId;

  /// The signed-in account's picture, shown over its initial (desktop only).
  final ImageProvider? avatar;

  /// Pops back to the search feed (Home); must not push or replace Home.
  final VoidCallback? onBackToFeed;
  final VoidCallback? onGoHome;
  final VoidCallback? onOpenAdmin;

  /// Opens the profile menu. Shown only on wide screens; phones use You.
  final void Function(BuildContext anchor)? onOpenProfile;

  /// Opens the widgets / windows library (sheet on phones, modal on desktop).
  final VoidCallback? onOpenWidgetsLibrary;

  /// Opens the rooms, agents and apps library as a floating card.
  final VoidCallback? onOpenLibrary;

  /// Opens the space feed when the desktop layout cannot dock it as a pane.
  final VoidCallback? onOpenSpaceFeed;

  /// Full-width Material bar. Desktop pages use this instead of the floating pill.
  final bool anchored;

  @override
  Widget build(BuildContext context) {
    if (anchored && !compact) {
      return _AnchoredWorkspaceBar(
        title: feed ? 'Home' : (room ?? 'Workspace'),
        room: room,
        onOpenNotifications: onOpenNotifications,
        unreadNotifications: unreadNotifications,
        onBackToFeed: onBackToFeed,
        onGoHome: onGoHome,
        onOpenAdmin: onOpenAdmin,
        onOpenProfile: onOpenProfile,
        onOpenWidgetsLibrary: onOpenWidgetsLibrary,
        onOpenLibrary: onOpenLibrary,
        onOpenSpaceFeed: onOpenSpaceFeed,
        handle: handle,
        accountId: accountId,
        avatar: avatar,
      );
    }
    final header = context.panelHeaderRecipe;
    final radius = header.shape == ShapeKind.stadium
        ? BorderRadius.circular(FloatingAppBarLayout.height)
        : header.borderRadius;
    final shape = RoundedRectangleBorder(borderRadius: radius);
    final iconStyle = _barIconStyle(context);
    // Material paints elevation shadows that follow [shape], so pack radii
    // apply to the floating bar's shadow — not only its glass fill.
    final atmospheric = ThemeChrome.paintsAtmosphere(context);
    final bar = Material(
      color: Colors.transparent,
      elevation: atmospheric
          ? math.max(header.elevation, 6)
          : header.elevation.clamp(0, 1).toDouble(),
      shadowColor: Colors.black.withValues(alpha: atmospheric ? .35 : .12),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: GlassSurface(
        alpha: AppSurfaces.cardAlphaOf(context),
        blur: AppSurfaces.blurSigmaOf(context),
        borderRadius: radius,
        border: !atmospheric,
        child: SizedBox(
          height: FloatingAppBarLayout.height,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (onOpenLibrary != null)
                        IconButton(
                          style: iconStyle,
                          tooltip: 'Library',
                          onPressed: onOpenLibrary,
                          icon: const Icon(Icons.menu_rounded),
                        ),
                      if (feed && onOpenNotifications != null)
                        IconButton(
                          style: iconStyle,
                          tooltip: 'Notifications',
                          onPressed: onOpenNotifications,
                          icon: Badge(
                            isLabelVisible: unreadNotifications > 0,
                            label: Text(
                              unreadNotifications > 99
                                  ? '99+'
                                  : '$unreadNotifications',
                            ),
                            child: const Icon(Icons.notifications_none_rounded),
                          ),
                        )
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
                            style: iconStyle,
                            onPressed: onGoHome,
                            tooltip: 'Workspace home',
                            icon: const Icon(Icons.home_outlined),
                          ),
                        Flexible(
                          child: Text(
                            room!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: compact ? 6 : 10),
                if (ThemeChrome.isKashi(context))
                  // Phones showing a room title keep the Latin mark only.
                  _KashiWordmark(persian: !(compact && room != null))
                else
                  Text(
                    'ASEMAN',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: compact ? 13.5 : 14.5,
                      fontWeight: ThemeChrome.isPaper(context)
                          ? FontWeight.w500
                          : FontWeight.w800,
                      letterSpacing: 1.4,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                SizedBox(width: compact ? 6 : 10),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (!compact && onOpenAdmin != null) ...[
                        IconButton.filledTonal(
                          style: iconStyle,
                          onPressed: onOpenAdmin,
                          icon: const Icon(Icons.space_dashboard_outlined),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (!compact && onOpenSpaceFeed != null) ...[
                        IconButton(
                          style: iconStyle,
                          tooltip: 'Space feed',
                          onPressed: onOpenSpaceFeed,
                          icon: const Icon(Icons.dynamic_feed_outlined),
                        ),
                        const SizedBox(width: 4),
                      ],
                      if (onOpenWidgetsLibrary != null)
                        IconButton(
                          style: iconStyle,
                          tooltip: 'Widgets & windows',
                          onPressed: onOpenWidgetsLibrary,
                          icon: const Icon(Icons.widgets_outlined),
                        ),
                      if (!compact && onOpenProfile != null) ...[
                        if (onOpenWidgetsLibrary != null)
                          const SizedBox(width: 4),
                        Builder(
                          builder: (context) {
                            final ar = FloatingAppBarLayout.avatarRadius;
                            final size = ar * 2;
                            final corners = context.avatarBorderRadius(size);
                            final circular = corners.topLeft.x >= ar * .95;
                            final face = AvatarFace(
                              size: size,
                              borderRadius: corners,
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: .18),
                              foregroundImage: avatar,
                              onImageError: avatar == null ? null : (_, __) {},
                              child: Text(
                                handle.isEmpty ? 'ME' : handle[0].toUpperCase(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  height: 1,
                                ),
                              ),
                            );
                            return Tooltip(
                              message: profileTooltip,
                              child: InkWell(
                                onTap: () => onOpenProfile!(context),
                                customBorder: circular
                                    ? const CircleBorder()
                                    : RoundedRectangleBorder(
                                        borderRadius: corners,
                                      ),
                                child: HaloRing(
                                  pad: 1.8,
                                  identity: HaloRingCache.person(accountId),
                                  borderRadius: corners,
                                  child: face,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
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

/// A 64dp Material bar for desktop pages. Actions stay; the floating pill does not.
class _AnchoredWorkspaceBar extends StatelessWidget {
  const _AnchoredWorkspaceBar({
    required this.title,
    required this.room,
    required this.unreadNotifications,
    required this.handle,
    required this.accountId,
    this.onOpenNotifications,
    this.onBackToFeed,
    this.onGoHome,
    this.onOpenAdmin,
    this.onOpenProfile,
    this.onOpenWidgetsLibrary,
    this.onOpenLibrary,
    this.onOpenSpaceFeed,
    this.avatar,
  });

  final String title;
  final String? room;
  final int unreadNotifications;
  final String handle;
  final String accountId;
  final VoidCallback? onOpenNotifications;
  final VoidCallback? onBackToFeed;
  final VoidCallback? onGoHome;
  final VoidCallback? onOpenAdmin;
  final void Function(BuildContext anchor)? onOpenProfile;
  final VoidCallback? onOpenWidgetsLibrary;
  final VoidCallback? onOpenLibrary;
  final VoidCallback? onOpenSpaceFeed;
  final ImageProvider? avatar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconStyle = _barIconStyle(context);
    return Material(
      color: scheme.surfaceContainer,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .5),
            ),
          ),
        ),
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (onOpenLibrary != null)
                  IconButton(
                    tooltip: 'Library',
                    onPressed: onOpenLibrary,
                    icon: const Icon(Icons.menu_rounded),
                  ),
                if (onBackToFeed != null)
                  IconButton(
                    tooltip: 'Home',
                    onPressed: onBackToFeed,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                if (onOpenNotifications != null)
                  IconButton(
                    style: iconStyle,
                    tooltip: 'Notifications',
                    onPressed: onOpenNotifications,
                    icon: Badge(
                      isLabelVisible: unreadNotifications > 0,
                      label: Text(
                        unreadNotifications > 99
                            ? '99+'
                            : '$unreadNotifications',
                      ),
                      child: const Icon(Icons.notifications_none_rounded),
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                if (room != null && onGoHome != null)
                  IconButton(
                    tooltip: 'Workspace home',
                    onPressed: onGoHome,
                    icon: const Icon(Icons.home_outlined),
                  ),
                if (onOpenAdmin != null)
                  IconButton.filledTonal(
                    style: iconStyle,
                    tooltip: 'Admin',
                    onPressed: onOpenAdmin,
                    icon: const Icon(Icons.space_dashboard_outlined),
                  ),
                if (onOpenSpaceFeed != null)
                  IconButton(
                    style: iconStyle,
                    tooltip: 'Space feed',
                    onPressed: onOpenSpaceFeed,
                    icon: const Icon(Icons.dynamic_feed_outlined),
                  ),
                if (onOpenWidgetsLibrary != null)
                  IconButton(
                    style: iconStyle,
                    tooltip: 'Widgets & windows',
                    onPressed: onOpenWidgetsLibrary,
                    icon: const Icon(Icons.widgets_outlined),
                  ),
                if (onOpenProfile != null)
                  Builder(
                    builder: (context) => Tooltip(
                      message: WorkspaceHeader.profileTooltip,
                      child: InkWell(
                        onTap: () => onOpenProfile!(context),
                        customBorder: const CircleBorder(),
                        child: HaloRing(
                          pad: 1.5,
                          identity: HaloRingCache.person(accountId),
                          borderRadius: BorderRadius.circular(16),
                          child: AvatarFace(
                            size: 32,
                            borderRadius: BorderRadius.circular(16),
                            backgroundColor: scheme.primary.withValues(
                              alpha: .18,
                            ),
                            foregroundImage: avatar,
                            onImageError: avatar == null ? null : (_, __) {},
                            child: Text(
                              handle.isEmpty ? 'ME' : handle[0].toUpperCase(),
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
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

/// Compact stadium back control that returns to the feed. Fixed height keeps
/// it vertically centered with the avatar and bar icon buttons inside the
/// short glass pill (a default [FilledButton] would grow to the full bar).
class _HomePill extends StatelessWidget {
  const _HomePill({required this.onPressed});
  final VoidCallback? onPressed;

  /// Matches the visual weight of [_barIconStyle] / the account avatar.
  static const double _height = 28;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final shape = context.buttonRecipe.border();
    return Tooltip(
      message: 'Home',
      child: SizedBox(
        height: _height,
        child: FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.standard,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const Size(_height, _height),
            maximumSize: const Size(double.infinity, _height),
            fixedSize: const Size.fromHeight(_height),
            padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            shape: shape,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_rounded, size: 15, color: onPrimary),
              const SizedBox(width: 5),
              Text(
                'Home',
                style: TextStyle(
                  color: onPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bell-shaped bump growing out of the right edge, tapering to nothing at
/// its top and bottom. Used by the gadgets handle.
/// Kashi top-bar wordmark: "aseman" with its Persian name, آسمان.
class _KashiWordmark extends StatelessWidget {
  const _KashiWordmark({this.persian = true});

  /// Show the Persian name beside the Latin one.
  final bool persian;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Aseman',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'aseman',
            maxLines: 1,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -.3,
              height: 1.1,
              color: scheme.onSurface,
            ),
          ),
          if (persian) ...[
          const SizedBox(width: 6),
          Text(
            'آسمان',
            maxLines: 1,
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              height: 1.1,
              color: scheme.onSurfaceVariant,
            ),
          ),
          ],
        ],
      ),
    );
  }
}

class EdgeBumpPainter extends CustomPainter {
  const EdgeBumpPainter({required this.fill, required this.shadow});
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
  bool shouldRepaint(covariant EdgeBumpPainter old) =>
      old.fill != fill || old.shadow != shadow;
}

/// Workspace switcher dialog/sheet with a searchable grid of the user's real
/// spaces. [dependencies] lists and creates spaces through the backend.
/// With [onOpenFeed] the grid starts with a Home tile that opens the feed.
/// With [embedded] it fills a home-shell tab (no close control).
/// With [inBottomSheet] (or under [AppSheetScope]) the body stays transparent
/// so the host sheet paints the glass.
/// With [dense] tiles and type shrink for a narrow desktop rail.
///
/// Visual language: celestial "sky portals" — soft atmospheric glow, a docked
/// current workspace, and luminous portal tiles with name-hashed accents.
class WorkspacePicker extends StatefulWidget {
  const WorkspacePicker({
    super.key,
    required this.current,
    required this.onPick,
    this.onOpenFeed,
    this.feedSelected = false,
    this.dependencies,
    this.onSettings,
    this.embedded = false,
    this.inBottomSheet = false,
    this.dense = false,
  });
  final String current;

  /// [spaceId] is set when the tile is a known project (preferred for loading).
  final void Function(String name, {String spaceId}) onPick;
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
    if (deps == null) return;
    final created = await promptCreateWorkspace(context, deps);
    if (created == null || !mounted) return;
    setState(() => spaces = [...spaces, created]);
    widget.onPick(created.name, spaceId: created.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.expanded;
    final embedded = widget.embedded;
    final inSheet = widget.inBottomSheet || AppSheetScope.inSheetOf(context);
    final dense = widget.dense;
    final names = _names;
    final showFeed = _showFeed;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final pad = dense
        ? AppSpacing.sm
        : (embedded || inSheet ? AppSpacing.md : AppSpacing.xl - 2);

    // Sheet / floating panel / embedded rail paint the frost; keep clear.
    final body = Material(
      color: Colors.transparent,
      child: SizedBox(
        width: embedded ? null : 780,
        child: ConstrainedBox(
          constraints: embedded
              ? const BoxConstraints.expand()
              : BoxConstraints(maxHeight: compact ? double.infinity : 640),
          child: Stack(
            children: [
              if (ThemeChrome.paintsAtmosphere(context))
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: SkyAtmospherePainter.of(scheme),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(pad),
                child: Column(
                  mainAxisSize: embedded || inSheet
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkySectionHeader(
                      icon: embedded
                          ? Icons.workspaces_rounded
                          : Icons.rocket_launch_rounded,
                      title: embedded ? 'Spaces' : 'Switch workspace',
                      subtitle: embedded
                          ? 'Open a workspace or start a new one'
                          : 'Drift between rooms, desks and feeds',
                      dense: dense,
                      onClose: embedded ? null : () => Navigator.pop(context),
                    ),
                    SizedBox(height: dense ? AppSpacing.sm : AppSpacing.md),
                    if (!dense) ...[
                      _DockedHere(
                        feedSelected: widget.feedSelected,
                        currentName: widget.current,
                        avatar: widget.feedSelected
                            ? null
                            : _avatarOf(widget.current),
                        roomCount: widget.feedSelected
                            ? null
                            : _roomCountFor(widget.current),
                        onOpenFeed: widget.onOpenFeed,
                        onOpenCurrent:
                            widget.feedSelected || widget.current.isEmpty
                            ? null
                            : () {
                                var id = '';
                                for (final s in spaces) {
                                  if (s.name == widget.current) {
                                    id = s.id;
                                    break;
                                  }
                                }
                                widget.onPick(widget.current, spaceId: id);
                              },
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    SoftSearchField(
                      dense: dense,
                      autofocus: !embedded,
                      hintText: 'Search workspaces…',
                      onChanged: (v) => setState(() => query = v),
                    ),
                    SizedBox(height: dense ? AppSpacing.sm : AppSpacing.md),
                    Flexible(
                      child: LayoutBuilder(
                        builder: (context, gridBox) {
                          final tileExtent = dense ? 126.0 : 168.0;
                          final maxCols = embedded ? 6 : 3;
                          final cols = math.max(
                            1,
                            (gridBox.maxWidth / (dense ? 132 : 176))
                                .floor()
                                .clamp(1, maxCols),
                          );
                          if (loading) {
                            return SkeletonGrid(
                              maxCrossAxisExtent: 220,
                              mainAxisExtent: tileExtent,
                            );
                          }
                          final count = names.length + 1 + (showFeed ? 1 : 0);
                          return GridView.builder(
                            shrinkWrap: !embedded,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: cols,
                                  mainAxisSpacing: dense ? 10 : 14,
                                  crossAxisSpacing: dense ? 10 : 14,
                                  mainAxisExtent: tileExtent,
                                ),
                            itemCount: count,
                            itemBuilder: (context, i) {
                              Widget tile;
                              var stagger = i;
                              if (showFeed) {
                                if (i == 0) {
                                  tile = _PortalTile(
                                    dense: dense,
                                    selected: widget.feedSelected,
                                    accent: scheme.primary,
                                    title: 'Home',
                                    subtitle: 'Your feed',
                                    icon: Icons.home_rounded,
                                    onTap: widget.onOpenFeed!,
                                  );
                                  return StaggerIn(
                                    index: 0,
                                    reduceMotion: reduceMotion,
                                    child: tile,
                                  );
                                }
                                i -= 1;
                              }
                              if (i == names.length) {
                                tile = _NewPortalTile(
                                  dense: dense,
                                  onTap: _create,
                                );
                                return StaggerIn(
                                  index: stagger,
                                  reduceMotion: reduceMotion,
                                  child: tile,
                                );
                              }
                              final name = names[i];
                              final selected =
                                  !widget.feedSelected &&
                                  name == widget.current;
                              final space = spaces.firstWhere(
                                (s) => s.name == name,
                                orElse: () =>
                                    Workspace(id: '', ownerId: '', name: name),
                              );
                              final accent = portalAccentFor(
                                name,
                                scheme,
                                context,
                              );
                              tile = _PortalTile(
                                dense: dense,
                                selected: selected,
                                accent: accent,
                                title: name,
                                subtitle: '${_roomCountFor(name)} rooms',
                                avatar: _avatarOf(name),
                                initials: name
                                    .substring(0, math.min(2, name.length))
                                    .toUpperCase(),
                                onTap: () =>
                                    widget.onPick(name, spaceId: space.id),
                                onSettings:
                                    widget.onSettings != null &&
                                        space.id.isNotEmpty
                                    ? () => widget.onSettings!(space)
                                    : null,
                                settingsTooltip: 'Settings for $name',
                              );
                              return StaggerIn(
                                index: stagger,
                                reduceMotion: reduceMotion,
                                child: tile,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

/// Slim "you're here" dock — current workspace or Home, with a halo ring.
class _DockedHere extends StatelessWidget {
  const _DockedHere({
    required this.feedSelected,
    required this.currentName,
    this.avatar,
    this.roomCount,
    this.onOpenFeed,
    this.onOpenCurrent,
  });

  final bool feedSelected;
  final String currentName;
  final ImageProvider? avatar;
  final int? roomCount;
  final VoidCallback? onOpenFeed;
  final VoidCallback? onOpenCurrent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isHome = feedSelected || currentName.isEmpty;
    final title = isHome ? 'Home' : currentName;
    final subtitle = isHome
        ? 'Your feed'
        : "${roomCount ?? 0} rooms · You're here";
    final accent = isHome
        ? scheme.primary
        : portalAccentFor(title, scheme, context);
    final onTap = isHome ? onOpenFeed : onOpenCurrent;

    const faceSize = 40.0;
    final faceCorners = context.avatarBorderRadius(faceSize);
    final avatarCore = HaloRing(
      accent: accent,
      borderRadius: faceCorners,
      child: isHome
          ? AvatarFace(
              size: faceSize,
              borderRadius: faceCorners,
              backgroundColor: accent.withValues(alpha: .2),
              child: Icon(Icons.home_rounded, color: accent),
            )
          : AvatarFace(
              size: faceSize,
              borderRadius: faceCorners,
              backgroundColor: accent.withValues(alpha: .18),
              foregroundImage: avatar,
              onImageError: avatar == null ? null : (_, __) {},
              child: Text(
                title.substring(0, math.min(2, title.length)).toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: accent,
                ),
              ),
            ),
    );

    final tileCorners = ThemeChrome.softCardCorners(context);
    final ringOuter = context.avatarBorderRadius(56);
    final ringInner = context.avatarBorderRadius(48);
    final paper = ThemeChrome.isPaper(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: tileCorners,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: tileCorners,
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                accent.withValues(alpha: .18),
                scheme.surfaceContainerHighest.withValues(alpha: .35),
              ],
            ),
            border: Border.all(color: accent.withValues(alpha: .35)),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: ringOuter,
                          border: Border.all(
                            color: paper
                                ? scheme.outlineVariant
                                : accent.withValues(alpha: .2),
                            width: paper ? 1 : 1.5,
                          ),
                        ),
                      ),
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          borderRadius: ringInner,
                          color: paper ? scheme.surface : null,
                          border: paper
                              ? Border.all(color: scheme.outline)
                              : null,
                          gradient: paper
                              ? null
                              : SweepGradient(
                                  colors: [
                                    accent,
                                    accent.withValues(alpha: .25),
                                    AppColors.cyanOf(context).withValues(
                                      alpha: .8,
                                    ),
                                    accent,
                                  ],
                                ),
                        ),
                        padding: const EdgeInsets.all(2.5),
                        child: ClipRRect(
                          borderRadius: faceCorners,
                          child: ColoredBox(
                            color: scheme.surface,
                            child: avatarCore,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NOW',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.4,
                          fontWeight: FontWeight.w800,
                          color: accent,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 15.5,
                          letterSpacing: -.2,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.north_east_rounded,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A luminous workspace (or Home) portal tile.
class _PortalTile extends StatelessWidget {
  const _PortalTile({
    required this.dense,
    required this.selected,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.avatar,
    this.initials,
    this.icon,
    this.onSettings,
    this.settingsTooltip,
  });

  final bool dense;
  final bool selected;
  final Color accent;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final ImageProvider? avatar;
  final String? initials;
  final IconData? icon;
  final VoidCallback? onSettings;
  final String? settingsTooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final corners = ThemeChrome.softCardCorners(
      context,
      dense ? AppShape.inner : AppShape.card,
    );
    final avatarR = dense ? 18.0 : 22.0;
    final glowCorners = context.avatarBorderRadius(72);
    final atmospheric = ThemeChrome.paintsAtmosphere(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: EdgeInsets.all(dense ? 12 : 16),
          decoration: atmospheric
              ? BoxDecoration(
                  borderRadius: corners,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: selected
                        ? [
                            accent.withValues(alpha: .18),
                            ThemeRoles.selectedFill(context),
                          ]
                        : [
                            scheme.surfaceContainerHighest.withValues(
                              alpha: .55,
                            ),
                            accent.withValues(alpha: .08),
                          ],
                  ),
                  border: Border.all(
                    color: selected
                        ? accent.withValues(alpha: .85)
                        : AppSurfaces.cardBorder(scheme),
                    width: selected ? 1.6 : 1,
                  ),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: .28),
                            blurRadius: 22,
                            offset: const Offset(0, 8),
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                )
              : BoxDecoration(
                  borderRadius: corners,
                  color: selected
                      ? scheme.surfaceContainerHigh
                      : scheme.surfaceContainer,
                  border: Border.all(
                    color: selected ? scheme.outline : scheme.outlineVariant,
                  ),
                ),
          child: Stack(
            children: [
              if (atmospheric)
                Positioned(
                  right: -18,
                  top: -22,
                  child: IgnorePointer(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        borderRadius: glowCorners,
                        gradient: RadialGradient(
                          colors: [
                            accent.withValues(alpha: selected ? .28 : .12),
                            accent.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Builder(
                        builder: (context) {
                          final size = avatarR * 2;
                          final faceCorners = context.avatarBorderRadius(size);
                          return HaloRing(
                            accent: accent,
                            borderRadius: faceCorners,
                            child: AvatarFace(
                              size: size,
                              borderRadius: faceCorners,
                              backgroundColor: scheme.surface,
                              foregroundImage: avatar,
                              onImageError: avatar == null ? null : (_, __) {},
                              child: icon != null
                                  ? Icon(
                                      icon,
                                      color: accent,
                                      size: dense ? 18 : 22,
                                    )
                                  : Text(
                                      initials ?? '?',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: dense ? 11 : 13,
                                        color: accent,
                                      ),
                                    ),
                            ),
                          );
                        },
                      ),
                      const Spacer(),
                      if (selected)
                        Icon(
                          Icons.check_circle_rounded,
                          size: dense ? 16 : 18,
                          color: accent,
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: dense ? 12.5 : 14.5,
                      letterSpacing: -.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: dense ? 9.5 : 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (onSettings != null)
                Positioned(
                  top: -4,
                  right: -4,
                  child: IconButton(
                    tooltip: settingsTooltip,
                    visualDensity: VisualDensity.compact,
                    onPressed: onSettings,
                    icon: Icon(
                      Icons.settings_outlined,
                      size: dense ? 15 : 17,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dashed "open a new portal" tile.
class _NewPortalTile extends StatelessWidget {
  const _NewPortalTile({required this.dense, required this.onTap});
  final bool dense;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final corners = ThemeChrome.softCardCorners(
      context,
      dense ? AppShape.inner : AppShape.card,
    );
    final iconSize = dense ? 36.0 : 44.0;
    final iconCorners = context.avatarBorderRadius(iconSize);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: CustomPaint(
          painter: _DashedRRectPainter(
            color: scheme.outlineVariant.withValues(alpha: .85),
            borderRadius: corners,
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: iconSize,
                  height: iconSize,
                  decoration: BoxDecoration(
                    borderRadius: iconCorners,
                    color: scheme.primary.withValues(alpha: .12),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    color: scheme.primary,
                    size: dense ? 20 : 24,
                  ),
                ),
                SizedBox(height: dense ? 8 : 10),
                Text(
                  'New workspace',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: dense ? 12 : 13.5,
                    letterSpacing: -.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Open a portal',
                  style: TextStyle(
                    fontSize: dense ? 9 : 10.5,
                    color: scheme.onSurfaceVariant,
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

class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({required this.color, required this.borderRadius});
  final Color color;
  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = borderRadius.toRRect(
      Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 6.0;
      const gap = 5.0;
      while (distance < metric.length) {
        final next = math.min(distance + dash, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color || old.borderRadius != borderRadius;
}

/// Asks for a workspace name and creates it — the same flow as the
/// switcher's **New workspace** tile. Returns null if cancelled or create
/// failed (failure shows a snackbar).
Future<Workspace?> promptCreateWorkspace(
  BuildContext context,
  AppDependencies dependencies,
) async {
  final name = await showAppDialog<String>(
    context: context,
    builder: (_) => const _CreateWorkspaceDialog(),
  );
  if (name == null || name.trim().isEmpty || !context.mounted) return null;
  try {
    return await dependencies.service.createSpace(name.trim(), '');
  } catch (e) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Create failed: $e')));
    return null;
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
          child: const Text('Cancel'),
        ),
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
