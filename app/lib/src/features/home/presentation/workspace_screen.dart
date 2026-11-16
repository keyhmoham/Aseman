import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../../agui/agui.dart';
import '../../../app_dependencies.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/halo_ring_cache.dart';
import '../../../core/theme/shell_layout.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../core/theme/theme_ui_spec.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/post.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/space.dart';
import '../../../data/models/uploaded_file.dart';
import '../../../data/services/aseman_service.dart';
import '../../../elpian/core/media.dart' show ElpianMediaScope;
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/theme_slot_host.dart';
import '../../../shared/widgets/user_profile_sheet.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../../shared/widgets/workspace_panel_motion.dart';
import '../../computer/computer_view.dart';
import '../../computer/preview_view.dart';
import '../../desk/domain/desk_models.dart';
import '../../desk/presentation/compact_desk.dart';
import '../../desk/presentation/compact_summary.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../desk/presentation/floating_desk.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../../desk/presentation/widgets_library.dart';
import '../../files/domain/file_types.dart';
import '../../files/presentation/file_tree.dart';
import '../../files/presentation/file_viewer.dart';
import '../../gadgets/presentation/gadgets_controller.dart';
import '../../gadgets/presentation/gadgets_overlay.dart';
import '../../messenger/presentation/chat_page.dart';
import '../../messenger/presentation/report_dialog.dart';
import '../../rooms/presentation/widgets/attachment_bubble.dart';
import '../../rooms/presentation/widgets/new_room_dialog.dart';
import '../../rooms/presentation/widgets/orbit_strip.dart';
import '../../rooms/presentation/widgets/room_chat.dart';
import '../../rooms/presentation/widgets/shared_file_viewer.dart';
import '../../search_feed/presentation/feed_post_card.dart';
import '../../search_feed/presentation/post_editor.dart';
import '../../search_feed/presentation/rich_post_content.dart';
import '../../search_feed/presentation/rich_post_parser.dart'
    show markupPreview;
import '../../search_feed/presentation/search_feed_view_model.dart'
    show feedPostFromServer;
import '../../tools/connect/add_app.dart';
import '../../tools/connect/mcp_connect_dialog.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/domain/tool_models.dart';
import '../../tools/elpian_app/elpian_app_view.dart';
import '../../tools/presentation/app_frontend_screen.dart';
import '../../tools/presentation/mcp_app_view.dart';
import '../../tools/presentation/tool_frontend_view.dart';
import '../../tools/presentation/tool_screen.dart';
import '../../tools/runtime/tool_media.dart';
import 'space_settings_panel.dart';
import 'widgets/space_facility_tabs.dart';
import 'workspace_controller.dart';

part 'workspace_explore.dart';
part 'workspace_profile.dart';
part 'workspace_library.dart';
part 'workspace_desk.dart';
part 'workspace_social.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.dependencies,
    this.initialWorkspace = 'Home',
    this.initialSpaceId,
    this.initialRoom,
    this.initialRoomId,
    this.onBackToFeed,
    this.onWorkspaceChanged,
    this.desktopShell = false,
  });
  final AppDependencies dependencies;
  final String initialWorkspace;

  /// The shell already docked a navigation rail and owns the window chrome.
  /// The workspace then always uses a desktop pane layout, even when the
  /// remaining content box is narrower than the compact breakpoint.
  final bool desktopShell;

  /// Space id when opening from chats (preferred over [initialWorkspace] name).
  final String? initialSpaceId;

  /// Room to open once this workspace's rooms have loaded. [initialRoomId]
  /// wins when it matches; [initialRoom] is the room's name.
  final String? initialRoom;
  final String? initialRoomId;
  final VoidCallback? onBackToFeed;
  final ValueChanged<String>? onWorkspaceChanged;
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with SingleTickerProviderStateMixin {
  static const hallRoom = WorkspaceController.hallRoom;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final mobilePages = PageController();
  bool _libraryOpen = false;
  late final WorkspaceController session;
  Offset pointer = Offset.zero;
  // Starts away: the workspace arrives the way a switched-to one does.
  late final AnimationController workspaceMotion = workspaceMotionController(
    this,
    value: 0,
  );

  /// True only for the compact phone shell. A desktop shell keeps the
  /// workspace in its pane layout even when the rail leaves less than 840px.
  bool get _compact =>
      !widget.desktopShell &&
      MediaQuery.sizeOf(context).width < Breakpoints.expanded;

  // Convenience accessors so build/parts keep short field names.
  String get workspace => session.workspace;
  String? get room => session.room;
  int get libraryTab => session.libraryTab;
  int get mobilePage => session.mobilePage;
  List<Bot> get bots => session.bots;
  List<Bot> get spaceBots => session.spaceBots;
  DeskController get deskController => session.deskController;
  List<String> get rooms => session.rooms;
  List<RoomMessage> get chatMessages => session.chatMessages;
  bool get chatHasMore => session.chatHasMore;
  bool get chatLoadingOlder => session.chatLoadingOlder;

  @override
  void initState() {
    super.initState();
    session = WorkspaceController(
      dependencies: widget.dependencies,
      initialWorkspace: widget.initialWorkspace,
      initialSpaceId: widget.initialSpaceId,
      initialRoom: widget.initialRoom,
      initialRoomId: widget.initialRoomId,
      onWorkspaceChanged: widget.onWorkspaceChanged,
      onAttachGadgets: _attachGadgets,
    );
    session.addListener(_onSession);
    session.start();
    workspaceMotion.forward();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  /// Leaves for the feed the way a workspace switch leaves: the panels move
  /// out, then the feed moves in.
  Future<void> _leaveToFeed() async {
    final toFeed = widget.onBackToFeed;
    if (toFeed == null || workspaceMotion.isAnimating) return;
    await workspaceMotion.reverse();
    if (mounted) toFeed();
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    session.dispose();
    mobilePages.dispose();
    workspaceMotion.dispose();
    super.dispose();
  }

  /// Point the gadgets edge manager at this workspace: universal + space.
  void _attachGadgets() {
    if (!mounted) return;
    final id = session.spaceFor(session.workspace)?.id ?? '';
    if (id.isEmpty) return;
    GadgetsScope.maybeOf(context)?.attach(spaceId: id);
  }

  /// Connects (or reconnects) the caller's own account to an app of the
  /// workspace that each person signs in to.
  Future<void> _connectApp(Bot bot, bool reconnect) async {
    final sp = session.spaceFor(session.workspace);
    if (sp == null) return;
    final connected = await connectMcpTool(
      context,
      widget.dependencies.service,
      botId: bot.id,
      spaceId: sp.id,
      name: bot.name,
      reconnect: reconnect,
    );
    if (connected && mounted) await session.loadSpaceBots();
  }

  Future<void> _addBotToWorkspace(Bot bot) async {
    final sp = session.spaceFor(session.workspace);
    if (sp == null) return;
    final err = await session.addBotToWorkspace(bot);
    if (err != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    // A tool each person connects with their own account asks for it now,
    // as it is added, rather than failing at its first use.
    if (bot.kind == 'tool' && mounted) {
      await connectMcpToolIfNeeded(
        context,
        widget.dependencies.service,
        botId: bot.id,
        spaceId: sp.id,
        name: bot.name,
      );
    }
  }

  Future<void> _addAppToWorkspace() async {
    final sp = session.spaceFor(session.workspace);
    if (sp == null) return;
    final added = await showAddApp(
      context,
      widget.dependencies.service,
      spaceId: sp.id,
    );
    if (added && mounted) await session.loadSpaceBots();
  }

  Future<void> _removeBotFromWorkspace(Bot bot) async {
    final err = await session.removeBotFromWorkspace(bot);
    if (err != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<void> _sendRoomMessage(
    String body,
    List<String> mentions,
    List<String> attachments, {
    String replyTo = '',
  }) async {
    try {
      await session.sendRoomMessage(
        body,
        mentions,
        attachments,
        replyTo: replyTo,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
      rethrow;
    }
  }

  // Changing, deleting and reporting a message of the open room, then
  // reloading it so the change shows at once.
  Future<void> _editRoomMessage(RoomMessage m, String body) async {
    try {
      await session.editRoomMessage(m, body);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not change it: $e')));
      }
      rethrow;
    }
  }

  Future<void> _deleteRoomMessage(RoomMessage m) async {
    try {
      await session.deleteRoomMessage(m);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not change it: $e')));
      }
      rethrow;
    }
  }

  Future<void> _reportRoomMessage(RoomMessage m) async {
    await reportToAdmins(
      context,
      widget.dependencies.service,
      spaceId: m.spaceId,
      roomId: m.roomId,
      messageId: m.id,
    );
  }

  Future<void> _createRoom() async {
    final room = await showAppDialog<NewRoom>(
      context: context,
      builder: (_) => const NewRoomDialog(),
    );
    if (room == null || !mounted) return;
    try {
      await session.createRoom(
        name: room.name,
        purpose: room.purpose,
        icon: room.icon,
        color: room.color,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Create room failed: $e')));
    }
  }

  void openApp(Bot bot) {
    final spaceId = session.spaceFor(session.workspace)?.id ?? '';
    if (bot.isUnifiedTool && spaceId.isNotEmpty) {
      // On the desk, as a card window (its dock entry gathers it): a static
      // frontend runs in-app.
      session.deskController.open(bot.id, title: bot.name);
      if (_compact && session.mobilePage != 0) {
        session.setMobilePage(0);
        mobilePages.animateToPage(
          0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
      }
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => bot.isUnifiedTool
            // A tool, through its static or generated frontend, in this space.
            ? ToolScreen(
                dependencies: widget.dependencies,
                bot: bot,
                spaceId: spaceId,
              )
            : AppFrontendScreen(
                dependencies: widget.dependencies,
                bot: bot,
                spaceId: spaceId,
              ),
      ),
    );
  }

  /// Opens a workspace file: as a card window on the desk, or straight in
  /// a bottom sheet on a phone.
  void _openFile(String path) {
    final spaceId = session.spaceFor(session.workspace)?.id ?? '';
    if (spaceId.isEmpty) return;
    session.setOpenFilePath(path);
    if (_compact) {
      showWorkspaceFileSheet(
        context,
        service: widget.dependencies.service,
        spaceId: spaceId,
        path: path,
      );
      return;
    }
    session.deskController.openFile(path);
  }

  void openRoom(String value) => session.openRoom(value);

  /// The space feed when the desktop layout is too narrow to dock it as a
  /// third pane (expanded windows).
  void _openSpaceFeed() {
    final spaceId = session.spaceFor(workspace)?.id ?? '';
    showFloatingPanel(
      context,
      _SocialFeed(
        workspace: workspace,
        dependencies: widget.dependencies,
        spaceId: spaceId,
        flat: true,
      ),
      maxWidth: 760,
      maxHeight: 820,
      barrierLabel: 'Close space feed',
    );
  }

  void goHome() => session.goHome();

  Future<void> switchWorkspace(String value, {String spaceId = ''}) async {
    final same = spaceId.isNotEmpty
        ? spaceId == session.activeSpaceId
        : value == session.workspace;
    if (same || workspaceMotion.isAnimating) return;
    // Refresh the spaces list so a freshly created workspace resolves to its
    // id (otherwise the desk feed falls back to the global feed and hides the
    // composer because spaceFor() cannot find the new workspace).
    await session.refreshSpaces();
    if (!mounted) return;
    final stillSame = spaceId.isNotEmpty
        ? spaceId == session.activeSpaceId
        : value == session.workspace;
    if (stillSame) return;
    await workspaceMotion.reverse();
    if (!mounted) return;
    session.selectWorkspace(value, spaceId: spaceId);
    _attachGadgets();
    await session.loadRooms();
    await session.loadSpaceBots();
    session.attachDesk();
    await workspaceMotion.forward();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = _compact;
    // The desk is reachable from the chat (pages agents share open on it).
    return DeskScope(
      controller: deskController,
      child: MouseRegion(
        onHover: (e) => setState(() => pointer = e.position),
        child: Scaffold(
          key: scaffoldKey,
          drawer: compact
              ? Drawer(
                  backgroundColor: Colors.transparent,
                  width: math.min(340, MediaQuery.sizeOf(context).width * .88),
                  child: GlassDrawerSurface(
                    child: SafeArea(child: _libraryPanel(floating: false)),
                  ),
                )
              : null,
          body: Stack(
            children: [
              if (compact && ThemeChrome.paintsAtmosphere(context))
                Positioned.fill(
                  child: CustomPaint(
                    painter: GlowPainter(colors.primary, colors.tertiary),
                  ),
                ),
              // Content fills the safe area; desk / feed / chat reserve the
              // floating app-bar inset inside themselves so scroll passes under.
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final appBarInset = FloatingAppBarLayout.contentInsetOf(
                      context,
                      compact,
                    );
                    final usePanes =
                        !compact &&
                        box.maxWidth >= 720 &&
                        !AppHeightClass.fromHeight(box.maxHeight).isCompact;
                    if (!usePanes) {
                      return WorkspacePanelMotion(
                        animation: workspaceMotion,
                        hiddenOffset: WorkspacePanelMotions.mobileOffset,
                        scaleFrom: WorkspacePanelMotions.mobileScale,
                        child: _mobile(appBarInset: appBarInset),
                      );
                    }
                    final inner = box.maxWidth;
                    // The library opens from the bar. Its old column is
                    // part of the chat. The desk stays on the right.
                    final deskWidth = AppLayout.roomDeskPaneWidth(
                      innerWidth: inner,
                      libraryWidth: 0,
                    );
                    final spaceId = session.spaceFor(workspace)?.id ?? '';
                    final social = room == null
                        ? _SocialFeed(
                            key: ValueKey('space-feed-$spaceId'),
                            workspace: workspace,
                            dependencies: widget.dependencies,
                            spaceId: spaceId,
                            flat: true,
                          )
                        : RoomChat(
                            key: ValueKey('$spaceId/${session.currentRoomId}'),
                            room: room!,
                            messages: chatMessages,
                            working: session.workingAgent,
                            workingDetail: session.workingDetail,
                            me:
                                widget
                                    .dependencies
                                    .sessionController
                                    .session
                                    ?.accountId ??
                                '',
                            dependencies: widget.dependencies,
                            spaceId: spaceId,
                            roomId: session.chatRoomId,
                            suggestions:
                                session.spaceFor(workspace)?.home ?? false,
                            threadRoomId: session.currentRoomId,
                            threadTitle:
                                session
                                    .roomThreads[session.currentRoomId]
                                    ?.title ??
                                '',
                            onThread: session.switchThread,
                            mentionable: spaceBots
                                .where((b) => b.isAgent)
                                .toList(),
                            onSend: _sendRoomMessage,
                            onEdit: _editRoomMessage,
                            onDelete: _deleteRoomMessage,
                            onReport: _reportRoomMessage,
                            canModerate: session.canManageTasks,
                            hasMore: chatHasMore,
                            loadingOlder: chatLoadingOlder,
                            onLoadOlder: session.loadOlderRoomMessages,
                            flat: true,
                          );
                    final desk = _CenterDesk(
                      workspace: workspace,
                      room: room,
                      pointer: pointer,
                      controller: deskController,
                      dependencies: widget.dependencies,
                      spaceId: spaceId,
                      roomId: session.currentRoomId,
                      board: true,
                    );
                    return _DeskWindowPortal(
                      layer: _DeskFloatLayer(
                        controller: deskController,
                        dependencies: widget.dependencies,
                        spaceId: spaceId,
                        roomId: session.currentRoomId,
                      ),
                      child: Column(
                        children: [
                          _workspaceHeader(context, compact, anchored: true),
                          Expanded(
                            child: Stack(
                              children: [
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(child: AppPane(child: social)),
                                    const PaneDivider(),
                                    AppPane(width: deskWidth, child: desk),
                                  ],
                                ),
                                SpaceLibraryFlyout(
                                  open: _libraryOpen,
                                  onDismiss: () =>
                                      setState(() => _libraryOpen = false),
                                  builder: (_) => _libraryPanel(floating: true),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Space gadgets float over left panel, chat and desk together —
              // one shared layer, not clipped to a single panel.
              if ((session.spaceFor(workspace)?.id ?? '').isNotEmpty)
                Positioned.fill(
                  child: WorkspaceGadgets(
                    dependencies: widget.dependencies,
                    spaceId: session.spaceFor(workspace)!.id,
                    roomId: session.currentRoomId,
                  ),
                ),
              if (compact ||
                  MediaQuery.sizeOf(context).width < 720 ||
                  AppHeightClass.fromHeight(
                    MediaQuery.sizeOf(context).height,
                  ).isCompact)
                SafeArea(
                  bottom: false,
                  child: _workspaceHeader(context, compact),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The rooms, agents and apps library. [floating] draws it as the card
  /// that opens from the desktop bar; the phone drawer keeps it flat.
  Widget _libraryPanel({required bool floating}) {
    void close() {
      if (floating) {
        setState(() => _libraryOpen = false);
      } else {
        Navigator.pop(context);
      }
    }

    return ThemeSlotHost(
      slot: FeatureSlots.workspaceRail,
      child: ThemeSlotHost(
        slot: ThemeChromeSlots.workspaceRail,
        child: _LibraryPanel(
          room: room,
          workspace: workspace,
          rooms: rooms,
          bots: bots,
          spaceBots: spaceBots,
          allBots: bots,
          tab: libraryTab,
          flat: !floating,
          onOpenSettings: session.spaceFor(workspace) == null
              ? null
              : () {
                  close();
                  _openSpaceSettings();
                },
          dependencies: widget.dependencies,
          spaceId: session.spaceFor(workspace)?.id ?? '',
          roomId: session.currentRoomId,
          fileRevision: session.fileRevision,
          onTab: session.setLibraryTab,
          onOpenApp: (bot) {
            close();
            openApp(bot);
          },
          onOpenFile: (path) {
            close();
            _openFile(path);
          },
          openFilePath: session.openFilePath,
          onCreateRoom: () {
            close();
            _createRoom();
          },
          onSearch: () {
            close();
            _search(context);
          },
          onAddBot: _addBotToWorkspace,
          onRemoveBot: _removeBotFromWorkspace,
          onAddApp: _addAppToWorkspace,
          appConnections: session.currentAppConnections,
          onConnectApp: _connectApp,
          openRoom: (value) {
            close();
            openRoom(value);
          },
        ),
      ),
    );
  }

  Widget _workspaceHeader(
    BuildContext context,
    bool compact, {
    bool anchored = false,
  }) {
    return ThemeSlotHost(
      slot: ThemeChromeSlots.floatingAppBar,
      child: ThemeSlotHost(
        slot: FeatureSlots.workspaceHeader,
        child: ListenableBuilder(
          listenable: widget.dependencies.sessionController,
          builder: (context, _) => WorkspaceHeader(
            room: room,
            compact: compact,
            anchored: anchored,
            handle: widget.dependencies.sessionController.session?.handle ?? '',
            accountId:
                widget.dependencies.sessionController.session?.accountId ?? '',
            avatar: widget.dependencies.service.avatarImage(
              widget.dependencies.sessionController.avatar,
            ),
            onBackToFeed: widget.onBackToFeed == null ? null : _leaveToFeed,
            onGoHome: goHome,
            onOpenWidgetsLibrary: () => showWidgetsLibrary(
              context,
              widget.dependencies,
              onOpenSpace: (name) => unawaited(switchWorkspace(name)),
            ),
            onOpenLibrary: compact
                ? null
                : () => setState(() => _libraryOpen = !_libraryOpen),
            onOpenSpaceFeed: !compact && MediaQuery.sizeOf(context).width < 720
                ? _openSpaceFeed
                : null,
            onOpenProfile: compact
                ? null
                : (anchor) => showProfileMenu(
                    context,
                    widget.dependencies,
                    anchor: anchor,
                  ),
          ),
        ),
      ),
    );
  }

  /// Space under the floating app bar reserved for the Desk / Feed|Chat tabs.
  static const _mobileTabsInset = 62.0;

  Widget _mobile({required double appBarInset}) {
    final contentInset = appBarInset + _mobileTabsInset;
    return Stack(
      children: [
        Positioned.fill(
          child: PageView(
            controller: mobilePages,
            onPageChanged: session.setMobilePage,
            children: [
              _CenterDesk(
                workspace: workspace,
                room: room,
                pointer: pointer,
                controller: deskController,
                dependencies: widget.dependencies,
                spaceId: session.spaceFor(workspace)?.id ?? '',
                roomId: session.currentRoomId,
                topContentInset: contentInset,
              ),
              room == null
                  ? _SocialFeed(
                      key: ValueKey(
                        'space-feed-m-${session.spaceFor(workspace)?.id ?? workspace}',
                      ),
                      workspace: workspace,
                      flat: true,
                      topContentInset: contentInset,
                      dependencies: widget.dependencies,
                      spaceId: session.spaceFor(workspace)?.id ?? '',
                    )
                  : RoomChat(
                      key: ValueKey(
                        '${session.spaceFor(workspace)?.id}/${session.currentRoomId}',
                      ),
                      room: room!,
                      messages: chatMessages,
                      working: session.workingAgent,
                      workingDetail: session.workingDetail,
                      me:
                          widget
                              .dependencies
                              .sessionController
                              .session
                              ?.accountId ??
                          '',
                      dependencies: widget.dependencies,
                      spaceId: session.spaceFor(workspace)?.id ?? '',
                      roomId: session.chatRoomId,
                      suggestions: session.spaceFor(workspace)?.home ?? false,
                      threadRoomId: session.currentRoomId,
                      threadTitle:
                          session.roomThreads[session.currentRoomId]?.title ??
                          '',
                      onThread: session.switchThread,
                      mentionable: spaceBots.where((b) => b.isAgent).toList(),
                      onSend: _sendRoomMessage,
                      onEdit: _editRoomMessage,
                      onDelete: _deleteRoomMessage,
                      onReport: _reportRoomMessage,
                      canModerate: session.canManageTasks,
                      hasMore: chatHasMore,
                      loadingOlder: chatLoadingOlder,
                      onLoadOlder: session.loadOlderRoomMessages,
                      flat: true,
                      topContentInset: contentInset,
                    ),
            ],
          ),
        ),
        Positioned(
          top: appBarInset + 5,
          left: 0,
          right: 0,
          child: Center(
            child: _MobileTabs(
              selected: mobilePage,
              room: room,
              onSelect: (value) {
                session.setMobilePage(value);
                mobilePages.animateToPage(
                  value,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                );
              },
            ),
          ),
        ),
        // Below the app bar: opens the rooms / library drawer.
        Positioned(
          top: appBarInset + 12,
          left: 12,
          child: GlassSurface(
            alpha: AppSurfaces.overlayAlphaOf(context),
            blur: AppSurfaces.blurSigmaOf(context),
            borderRadius: AppShape.borderRadius(context, 24),
            child: IconButton(
              tooltip: 'Rooms and workspace',
              onPressed: () => scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            ),
          ),
        ),
      ],
    );
  }

  void _search(BuildContext context) => _sheet(
    context,
    _SearchPanel(
      workspace: workspace,
      spaceId: session.spaceFor(workspace)?.id ?? '',
      dependencies: widget.dependencies,
    ),
    maxWidth: 920,
  );
  void _sheet(BuildContext context, Widget child, {double maxWidth = 1180}) =>
      showFloatingPanel(context, child, maxWidth: maxWidth);

  void _openSpaceSettings() {
    final sp = session.spaceFor(workspace);
    if (sp == null) return;
    _sheet(
      context,
      SpaceSettingsPanel(
        dependencies: widget.dependencies,
        space: sp,
        onUpdated: (updated) {
          session.loadWorkspaces();
          if (updated.id != session.activeSpaceId && mounted) {
            switchWorkspace(updated.name, spaceId: updated.id);
          }
        },
        onExit: () {
          Navigator.of(context).pop();
          session.loadWorkspaces();
        },
      ),
      maxWidth: 720,
    );
  }
}

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 60) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${t.day}/${t.month}';
}

String _short(String s, int n) => s.length <= n ? s : s.substring(0, n);

String _fmtDuration(int sec) {
  if (sec < 60) return '${sec}s';
  if (sec < 3600) return '${(sec / 60).floor()}m';
  if (sec < 86400) return '${(sec / 3600).floor()}h';
  return '${(sec / 86400).floor()}d';
}

/// The library card that floats over the chat from the space bar.
///
/// It keeps the pane's width. It fades and scales from the bar button,
/// and tapping the chat behind it closes it.
class SpaceLibraryFlyout extends StatefulWidget {
  const SpaceLibraryFlyout({
    super.key,
    required this.open,
    required this.onDismiss,
    required this.builder,
    this.top = 0,
  });

  final bool open;
  final VoidCallback onDismiss;
  final WidgetBuilder builder;
  final double top;

  @override
  State<SpaceLibraryFlyout> createState() => _SpaceLibraryFlyoutState();
}

class _SpaceLibraryFlyoutState extends State<SpaceLibraryFlyout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion;
  late final Animation<double> _fade;
  late final Animation<double> _scale;
  bool _present = false;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    final curve = CurvedAnimation(
      parent: _motion,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _fade = curve;
    _scale = Tween<double>(begin: 0.94, end: 1).animate(curve);
    if (widget.open) {
      _present = true;
      _motion.value = 1;
    }
  }

  @override
  void didUpdateWidget(SpaceLibraryFlyout old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) {
      _present = true;
      _motion.forward();
    } else if (!widget.open && old.open) {
      _motion.reverse().whenComplete(() {
        if (mounted && !widget.open) setState(() => _present = false);
      });
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_present) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: widget.top),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.min(
            AppLayout.listPaneWidth,
            math.max(280.0, constraints.maxWidth - 24),
          );
          return Stack(
            children: [
              Positioned.fill(
                child: FadeTransition(
                  opacity: _fade,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDismiss,
                    child: const ColoredBox(color: Color(0x14000000)),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 8,
                bottom: 12,
                width: width,
                child: FadeTransition(
                  opacity: _fade,
                  child: ScaleTransition(
                    alignment: Alignment.topLeft,
                    scale: _scale,
                    child: GestureDetector(
                      onTap: () {},
                      child: widget.builder(context),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.flat = false});
  final Widget child;
  final bool flat;
  @override
  Widget build(BuildContext context) {
    if (flat) {
      return Material(type: MaterialType.transparency, child: child);
    }
    final radius = ThemeChrome.softCardCorners(context, AppShape.card);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .12),
            blurRadius: 30,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: GlassSurface(
        alpha: AppSurfaces.overlayAlphaOf(context),
        blur: AppSurfaces.blurSigmaOf(context),
        borderRadius: radius,
        child: child,
      ),
    );
  }
}

class _WorkspacePatternPainter extends CustomPainter {
  const _WorkspacePatternPainter(this.workspace);
  final String workspace;
  @override
  void paint(Canvas canvas, Size size) {
    final seed = workspace.codeUnits.fold(17, (a, b) => a * 31 + b);
    final random = math.Random(seed);
    final primary = [
      const Color(0xFF8B7BFF),
      const Color(0xFF24B8A6),
      const Color(0xFFFF8A5B),
      const Color(0xFF4997FF),
    ][workspace.length % 4];
    for (var i = 0; i < 4; i++) {
      final center = Offset(
        size.width * random.nextDouble(),
        size.height * random.nextDouble(),
      );
      final radius = size.shortestSide * (.22 + random.nextDouble() * .28);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              primary.withValues(alpha: .065),
              primary.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
    for (var i = 0; i < 3; i++) {
      final y = size.height * (.12 + random.nextDouble() * .76);
      final path = Path()..moveTo(-40, y);
      path.cubicTo(
        size.width * .22,
        y + random.nextDouble() * 150 - 75,
        size.width * .65,
        y + random.nextDouble() * 180 - 90,
        size.width + 40,
        y + random.nextDouble() * 100 - 50,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = primary.withValues(alpha: .075 - i * .012)
          ..strokeWidth = 1.2 + i * .8
          ..style = PaintingStyle.stroke,
      );
    }
    final nodes = <Offset>[];
    for (
      var i = 0;
      i < math.max(18, (size.width * size.height / 36000).round());
      i++
    ) {
      final point = Offset(
        size.width * random.nextDouble(),
        size.height * random.nextDouble(),
      );
      nodes.add(point);
      final radius = 2 + random.nextDouble() * 5;
      canvas.drawCircle(
        point,
        radius,
        Paint()
          ..color = primary.withValues(alpha: .035 + random.nextDouble() * .07),
      );
      if (i > 0 && random.nextDouble() > .38)
        canvas.drawLine(
          nodes[random.nextInt(i)],
          point,
          Paint()
            ..color = primary.withValues(alpha: .035)
            ..strokeWidth = .7,
        );
    }
    for (var i = 0; i < 10; i++) {
      final center = Offset(
        size.width * random.nextDouble(),
        size.height * random.nextDouble(),
      );
      final radius = 16 + random.nextDouble() * 52;
      final sides = 3 + random.nextInt(4);
      final rotation = random.nextDouble() * math.pi;
      final path = Path();
      for (var side = 0; side < sides; side++) {
        final angle = rotation + math.pi * 2 * side / sides;
        final point =
            center + Offset(math.cos(angle), math.sin(angle)) * radius;
        if (side == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = primary.withValues(alpha: .018 + random.nextDouble() * .025)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = primary.withValues(alpha: .055)
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspacePatternPainter old) =>
      old.workspace != workspace;
}
