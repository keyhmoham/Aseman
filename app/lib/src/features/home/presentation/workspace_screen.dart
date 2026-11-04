import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../../agui/agui.dart';
import '../../../app_dependencies.dart';
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
import '../../admin/presentation/admin_screen.dart';
import '../../computer/computer_view.dart';
import '../../computer/preview_view.dart';
import '../../desk/data/desk_api.dart';
import '../../desk/domain/desk_models.dart';
import '../../desk/presentation/compact_desk.dart';
import '../../desk/presentation/compact_summary.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../desk/presentation/floating_desk.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../../desk/presentation/tool_avatar.dart';
import '../../desk/presentation/widgets_library.dart';
import '../../files/domain/file_types.dart';
import '../../files/presentation/file_tree.dart';
import '../../files/presentation/file_viewer.dart';
import '../../messenger/presentation/chat_page.dart';
import '../../messenger/presentation/report_dialog.dart';
import '../../plugins/data/plugins_api.dart';
import '../../plugins/presentation/plugin_gadgets_overlay.dart';
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

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.dependencies,
    this.initialWorkspace = 'Home',
    this.initialRoom,
    this.initialRoomId,
    this.onBackToFeed,
    this.onWorkspaceChanged,
  });
  final AppDependencies dependencies;
  final String initialWorkspace;

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
  static const hallRoom = 'Hall room';
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final mobilePages = PageController();
  String workspace = 'Home';
  String? room;
  int libraryTab = 0;

  /// True after the room requested at open has been applied (or ruled out).
  bool _appliedInitialRoom = false;

  /// The workspace file opened last, highlighted in the Files tab.
  String _openFilePath = '';
  int mobilePage = 0;
  Offset pointer = Offset.zero;
  List<Bot> bots = [];
  final Map<String, List<Bot>> _spaceBots = {};
  List<Workspace> spaces = [];
  List<WorkspaceRoom> currentRooms = [];
  final Map<String, List<RoomMessage>> roomMessages = {};

  /// Whether older messages than what [roomMessages] holds still exist, by
  /// workspace/room scope.
  final Map<String, bool> roomHasMore = {};

  /// The open thread of each room (by room id); a room not listed shows its
  /// main thread.
  final Map<String, RoomThread> _roomThreads = {};
  final Set<String> _loadingOlder = {};

  /// The desk of the room on screen: tools' card windows.
  late final DeskController deskController = DeskController(
    DeskApi.of(widget.dependencies.service),
  );
  Timer? _roomTimer;
  int _fileRevision = 0;
  String _workingAgent = '';
  String _workingDetail = '';
  final Set<String> _messageLoads = {};
  // Starts away: the workspace arrives the way a switched-to one does.
  late final AnimationController workspaceMotion = workspaceMotionController(
    this,
    value: 0,
  );

  @override
  void initState() {
    super.initState();
    workspace = widget.initialWorkspace;
    _loadWorkspaces();
    _loadBots();
    _loadSpaceBots();
    // Async messaging: agent replies (and aseman's message/log flow) arrive
    // after a message is sent, so the open room is polled frequently and new
    // content shows up live without needing another message to trigger it.
    _roomTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (room != null) _loadRoomMessages(room!);
    });
    workspaceMotion.forward();
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
    deskController.dispose();
    _roomTimer?.cancel();
    mobilePages.dispose();
    workspaceMotion.dispose();
    super.dispose();
  }

  Future<void> _loadBots() async {
    try {
      final loaded = await widget.dependencies.service.fetchBots();
      if (mounted) setState(() => bots = loaded);
    } catch (_) {}
  }

  /// Bots explicitly installed in the current workspace. Agents and apps
  /// are only shown (and usable) here once added via [addBotToSpace].
  List<Bot> get spaceBots => _spaceBots[workspace] ?? const [];

  /// Whether each app of a workspace needs each person's own account, and
  /// whether the caller has connected theirs, by bot id.
  final Map<String, Map<String, ({String auth, bool connected, String name})>>
  _appConnections = {};

  Future<void> _loadSpaceBots() async {
    final requestedWorkspace = workspace;
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      final list = await widget.dependencies.service.fetchSpaceBots(sp.id);
      ToolAvatar.remember({for (final b in list) b.id: b.avatar});
      if (mounted) setState(() => _spaceBots[requestedWorkspace] = list);
    } catch (_) {}
    try {
      final connections = await widget.dependencies.service.toolConnections(
        sp.id,
      );
      if (mounted) {
        setState(() => _appConnections[requestedWorkspace] = connections);
      }
    } catch (_) {}
  }

  /// Connects (or reconnects) the caller's own account to an app of the
  /// workspace that each person signs in to.
  Future<void> _connectApp(Bot bot, bool reconnect) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    final connected = await connectMcpTool(
      context,
      widget.dependencies.service,
      botId: bot.id,
      spaceId: sp.id,
      name: bot.name,
      reconnect: reconnect,
    );
    if (connected && mounted) await _loadSpaceBots();
  }

  Future<void> _addBotToWorkspace(Bot bot) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.addBotToSpace(sp.id, bot.id);
      await _loadSpaceBots();
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Add failed: $e')));
    }
  }

  Future<void> _addAppToWorkspace() async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    final added = await showAddApp(
      context,
      widget.dependencies.service,
      spaceId: sp.id,
    );
    if (added && mounted) await _loadSpaceBots();
  }

  Future<void> _removeBotFromWorkspace(Bot bot) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.removeBotFromSpace(sp.id, bot.id);
      await _loadSpaceBots();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Remove failed: $e')));
    }
  }

  Future<void> _loadWorkspaces() async {
    try {
      final sp = await widget.dependencies.service.fetchSpaces();
      if (!mounted) return;
      setState(() {
        spaces = sp;
        if (sp.isNotEmpty && !sp.any((s) => s.name == workspace)) {
          final home = sp.firstWhere((s) => s.home, orElse: () => sp.first);
          workspace = home.name;
        }
      });
      await _loadRooms();
      _attachDesk();
      await _loadSpaceBots();
    } catch (_) {
      // Spaces failed to load; the workspace keeps its current name.
    }
  }

  Future<void> _loadRooms() async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      final rooms = await widget.dependencies.service.fetchRoomsForSpace(sp.id);
      if (!mounted || _spaceFor(workspace)?.id != sp.id) return;
      var openedInitial = false;
      setState(() {
        currentRooms = rooms;
        roomMessages.removeWhere((key, _) => key.startsWith('$workspace/'));
        roomHasMore.removeWhere((key, _) => key.startsWith('$workspace/'));
        openedInitial = _applyInitialRoom(rooms);
      });
      _attachDesk();
      if (openedInitial && room != null) unawaited(_loadRoomMessages(room!));
    } catch (_) {}
  }

  /// Selects the room this workspace was opened with, once, after its rooms
  /// have loaded. The id matches across a rename; the name is the fallback.
  bool _applyInitialRoom(List<WorkspaceRoom> rooms) {
    if (_appliedInitialRoom) return false;
    _appliedInitialRoom = true;
    final id = widget.initialRoomId ?? '';
    final name = widget.initialRoom ?? '';
    WorkspaceRoom? match;
    if (id.isNotEmpty) {
      for (final candidate in rooms) {
        if (candidate.id == id) {
          match = candidate;
          break;
        }
      }
    } else if (name.isNotEmpty) {
      for (final candidate in rooms) {
        if (candidate.name == name) {
          match = candidate;
          break;
        }
      }
    }
    if (match == null) return false;
    room = match.name;
    _workingAgent = '';
    _workingDetail = '';
    return true;
  }

  Workspace? _spaceFor(String name) {
    for (final s in spaces) {
      if (s.name == name) return s;
    }
    return null;
  }

  Future<void> _loadRoomMessages(String roomName) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    final r = currentRooms.where((x) => x.name == roomName).toList();
    if (r.isEmpty) return;
    final requestedWorkspace = workspace;
    final requestedScope = '$requestedWorkspace/$roomName';
    final thread = _messageRoom(r.first.id);
    final requestKey = '${sp.id}/$thread';
    if (!_messageLoads.add(requestKey)) return;
    try {
      final res = await widget.dependencies.service.fetchRoomMessages(
        sp.id,
        thread,
      );
      if (!mounted ||
          workspace != requestedWorkspace ||
          room != roomName ||
          _currentRoomId != r.first.id ||
          _messageRoom(r.first.id) != thread)
        return;
      // Keep any older pages already loaded; only refresh the newest window
      // so scrolling back through history is not wiped every few seconds.
      final prev = roomMessages[requestedScope] ?? const <RoomMessage>[];
      final msgs = mergeNewestRoomMessages(prev, res.messages);
      // The newest page's has_more is only about history before that page.
      // Once older pages are already held, keep the flag from load-older.
      final holdsOlder = msgs.length > res.messages.length;
      final hasMore = holdsOlder
          ? (roomHasMore[requestedScope] ?? false)
          : res.hasMore;
      final changed =
          prev.length != msgs.length ||
          List.generate(msgs.length, (index) => index).any(
            (index) =>
                index >= prev.length ||
                !prev[index].hasSameContentAs(msgs[index]),
          ) ||
          _workingAgent != res.working ||
          _workingDetail != res.workingDetail ||
          (roomHasMore[requestedScope] ?? false) != hasMore;
      if (changed) {
        setState(() {
          final oldFiles = {
            for (final message in prev)
              ...message.attachments.map((file) => file.id),
          };
          final newFiles = {
            for (final message in msgs)
              ...message.attachments.map((file) => file.id),
          };
          if (!setEquals(oldFiles, newFiles)) _fileRevision++;
          roomMessages[requestedScope] = List.unmodifiable(msgs);
          roomHasMore[requestedScope] = hasMore;
          _workingAgent = res.working;
          _workingDetail = res.workingDetail;
        });
      }
    } catch (_) {
      // The next poll can recover without clearing the conversation.
    } finally {
      _messageLoads.remove(requestKey);
    }
  }

  /// Loads the next older page when the user scrolls to the top of the chat.
  Future<void> _loadOlderRoomMessages() async {
    final roomName = room;
    final sp = _spaceFor(workspace);
    if (roomName == null || sp == null) return;
    final r = currentRooms.where((x) => x.name == roomName).toList();
    if (r.isEmpty) return;
    final requestedWorkspace = workspace;
    final requestedScope = '$requestedWorkspace/$roomName';
    if (!(roomHasMore[requestedScope] ?? false)) return;
    final prev = roomMessages[requestedScope] ?? const <RoomMessage>[];
    if (prev.isEmpty) return;
    final thread = _messageRoom(r.first.id);
    final requestKey = 'older:${sp.id}/$thread';
    if (!_loadingOlder.add(requestKey)) return;
    setState(() {});
    try {
      final oldest = prev.first;
      final res = await widget.dependencies.service.fetchRoomMessages(
        sp.id,
        thread,
        before: oldest.createdAt,
      );
      if (!mounted ||
          workspace != requestedWorkspace ||
          room != roomName ||
          _currentRoomId != r.first.id ||
          _messageRoom(r.first.id) != thread)
        return;
      // Merge into whatever the poll may have refreshed while we waited.
      final current = roomMessages[requestedScope] ?? prev;
      final msgs = mergeOlderRoomMessages(current, res.messages);
      setState(() {
        roomMessages[requestedScope] = List.unmodifiable(msgs);
        roomHasMore[requestedScope] = res.hasMore;
      });
    } catch (_) {
      // Leave hasMore as-is so the user can try again.
    } finally {
      _loadingOlder.remove(requestKey);
      if (mounted) setState(() {});
    }
  }

  Future<void> _sendRoomMessage(
    String body,
    List<String> mentions,
    List<String> attachments, {
    String replyTo = '',
  }) async {
    final sp = _spaceFor(workspace);
    final r = room == null
        ? null
        : currentRooms.where((x) => x.name == room).toList();
    if (sp == null || r == null || r.isEmpty) return;
    try {
      await widget.dependencies.service.sendRoomMessage(
        sp.id,
        _messageRoom(r.first.id),
        body,
        mentions: mentions,
        attachments: attachments,
        replyTo: replyTo,
      );
      if (!mounted) return;
      // Bump so the left-panel file library (Docs/GIFs/Media/Audio) reloads and
      // shows the newly attached files.
      if (attachments.isNotEmpty) _fileRevision++;
      await _loadRoomMessages(r.first.name);
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
  Future<void> _messageChange(Future<void> Function() change) async {
    try {
      await change();
      if (room != null) await _loadRoomMessages(room!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not change it: $e')));
      }
      rethrow;
    }
  }

  Future<void> _editRoomMessage(RoomMessage m, String body) => _messageChange(
    () => widget.dependencies.service.editRoomMessage(m.id, body),
  );

  Future<void> _deleteRoomMessage(RoomMessage m) => _messageChange(
    () => widget.dependencies.service.deleteRoomMessage(m.spaceId, m.id),
  );

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
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.createRoom(
        sp.id,
        room.name,
        '',
        purpose: room.purpose,
        icon: room.icon,
        color: room.color,
      );
      await _loadRooms();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Create room failed: $e')));
    }
  }

  void openApp(Bot bot) {
    final spaceId = _spaceFor(workspace)?.id ?? '';
    if (bot.isUnifiedTool && spaceId.isNotEmpty) {
      // On the desk, as a card window (its dock entry gathers it): a static
      // frontend runs in-app.
      deskController.open(bot.id, title: bot.name);
      if (MediaQuery.sizeOf(context).width < 820 && mobilePage != 0) {
        setState(() => mobilePage = 0);
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
    final spaceId = _spaceFor(workspace)?.id ?? '';
    if (spaceId.isEmpty) return;
    setState(() => _openFilePath = path);
    if (MediaQuery.sizeOf(context).width < 820) {
      showWorkspaceFileSheet(
        context,
        service: widget.dependencies.service,
        spaceId: spaceId,
        path: path,
      );
      return;
    }
    deskController.openFile(path);
  }

  bool get _canManageTasks {
    final space = _spaceFor(workspace);
    final account = widget.dependencies.sessionController.session?.accountId;
    return space != null &&
        account != null &&
        (space.isOwner || space.role == 'admin' || space.ownerId == account);
  }

  String get scopeKey => '$workspace/${room ?? 'home'}';
  List<String> get rooms {
    if (currentRooms.isNotEmpty) {
      return [hallRoom, ...currentRooms.map((r) => r.name)];
    }
    return const [hallRoom];
  }

  /// Shows the desk of the room on screen (the space's own on the hall).
  void _attachDesk() => deskController.attach(
    _spaceFor(workspace)?.id ?? '',
    _currentRoomId.isEmpty ? 'home' : _currentRoomId,
  );
  List<RoomMessage> get chatMessages => roomMessages[scopeKey] ?? const [];
  bool get chatHasMore => roomHasMore[scopeKey] ?? false;
  bool get chatLoadingOlder =>
      _currentRoomId.isNotEmpty &&
      _loadingOlder.contains(
        'older:${_spaceFor(workspace)?.id ?? ''}/$_chatRoomId',
      );

  String get _currentRoomId {
    if (room == null) return '';
    final matches = currentRooms.where((r) => r.name == room).toList();
    return matches.isEmpty ? '' : matches.first.id;
  }

  /// Where a room's open conversation lives: its open thread, else the room.
  String _messageRoom(String roomId) => _roomThreads[roomId]?.id ?? roomId;

  /// The open room's conversation (its thread, else the room itself).
  String get _chatRoomId =>
      _currentRoomId.isEmpty ? '' : _messageRoom(_currentRoomId);

  /// Switches the open room's chat to another of its threads, loaded fresh.
  void _switchThread(RoomThread thread) {
    final roomId = _currentRoomId;
    final roomName = room;
    if (roomId.isEmpty || roomName == null) return;
    setState(() {
      if (thread.isMain || thread.id == roomId) {
        _roomThreads.remove(roomId);
      } else {
        _roomThreads[roomId] = thread;
      }
      roomMessages.remove('$workspace/$roomName');
      roomHasMore.remove('$workspace/$roomName');
      _workingAgent = '';
      _workingDetail = '';
    });
    unawaited(_loadRoomMessages(roomName));
  }

  void openRoom(String value) {
    if (value == hallRoom) {
      goHome();
      return;
    }
    setState(() {
      room = value;
      _workingAgent = '';
      _workingDetail = '';
    });
    _loadRoomMessages(value);
    _attachDesk();
  }

  void goHome() {
    setState(() {
      room = null;
      _workingAgent = '';
      _workingDetail = '';
    });
    _attachDesk();
  }

  Future<void> switchWorkspace(String value) async {
    if (value == workspace || workspaceMotion.isAnimating) return;
    // Refresh the spaces list so a freshly created workspace resolves to its
    // id (otherwise the desk feed falls back to the global feed and hides the
    // composer because _spaceFor() cannot find the new workspace).
    try {
      final sp = await widget.dependencies.service.fetchSpaces();
      if (mounted) setState(() => spaces = sp);
    } catch (_) {}
    if (!mounted || value == workspace) return;
    await workspaceMotion.reverse();
    if (!mounted) return;
    setState(() {
      workspace = value;
      room = null;
      _workingAgent = '';
      _workingDetail = '';
    });
    widget.onWorkspaceChanged?.call(value);
    await _loadRooms();
    await _loadSpaceBots();
    _attachDesk();
    await workspaceMotion.forward();
  }

  /// Room chat with space chat-placement plugins as floating gadgets.
  Widget _chatGadgetHost(Widget chat) {
    final spaceId = _spaceFor(workspace)?.id ?? '';
    if (spaceId.isEmpty) return chat;
    return Stack(
      fit: StackFit.expand,
      children: [
        chat,
        PluginSurfaceGadgets(
          dependencies: widget.dependencies,
          placement: PluginPlacement.chat,
          spaceId: spaceId,
          roomId: _chatRoomId,
          compact: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 820;
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
                    child: SafeArea(
                      child: ThemeSlotHost(
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
                            flat: true,
                            onOpenSettings: _spaceFor(workspace) == null
                                ? null
                                : () {
                                    Navigator.pop(context);
                                    _openSpaceSettings();
                                  },
                            dependencies: widget.dependencies,
                            spaceId: _spaceFor(workspace)?.id ?? '',
                            roomId: _currentRoomId,
                            fileRevision: _fileRevision,
                            onTab: (v) => setState(() => libraryTab = v),
                            onOpenApp: openApp,
                            onOpenFile: _openFile,
                            openFilePath: _openFilePath,
                            onCreateRoom: _createRoom,
                            onSearch: () => _search(context),
                            onAddBot: _addBotToWorkspace,
                            onRemoveBot: _removeBotFromWorkspace,
                            onAddApp: _addAppToWorkspace,
                            appConnections:
                                _appConnections[workspace] ?? const {},
                            onConnectApp: _connectApp,
                            openRoom: (value) {
                              Navigator.pop(context);
                              openRoom(value);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                )
              : null,
          body: Stack(
            children: [
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
                    if (box.maxWidth < 820) {
                      return WorkspacePanelMotion(
                        animation: workspaceMotion,
                        hiddenOffset: WorkspacePanelMotions.mobileOffset,
                        scaleFrom: WorkspacePanelMotions.mobileScale,
                        child: _mobile(appBarInset: appBarInset),
                      );
                    }
                    // Desk fills the row; left/right panels sit under the card
                    // windows so windows can float over them on desktop.
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                      child: _CenterDesk(
                        workspace: workspace,
                        room: room,
                        pointer: pointer,
                        controller: deskController,
                        dependencies: widget.dependencies,
                        spaceId: _spaceFor(workspace)?.id ?? '',
                        roomId: _currentRoomId,
                        topContentInset: appBarInset,
                        underlay: Padding(
                          padding: EdgeInsets.only(top: appBarInset),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              WorkspacePanelMotion(
                                animation: workspaceMotion,
                                hiddenOffset: WorkspacePanelMotions.left,
                                child: SizedBox(
                                  width: math.min(286, box.maxWidth * .22),
                                  height: math.max(
                                    0,
                                    box.maxHeight * .82 - appBarInset,
                                  ),
                                  child: ThemeSlotHost(
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
                                        dependencies: widget.dependencies,
                                        spaceId:
                                            _spaceFor(workspace)?.id ?? '',
                                        roomId: _currentRoomId,
                                        fileRevision: _fileRevision,
                                        onTab: (v) =>
                                            setState(() => libraryTab = v),
                                        onOpenSettings:
                                            _spaceFor(workspace) == null
                                                ? null
                                                : _openSpaceSettings,
                                        onOpenApp: openApp,
                                        onOpenFile: _openFile,
                                        openFilePath: _openFilePath,
                                        onCreateRoom: _createRoom,
                                        onSearch: () => _search(context),
                                        onAddBot: _addBotToWorkspace,
                                        onRemoveBot: _removeBotFromWorkspace,
                                        onAddApp: _addAppToWorkspace,
                                        appConnections:
                                            _appConnections[workspace] ??
                                                const {},
                                        onConnectApp: _connectApp,
                                        openRoom: openRoom,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const Expanded(
                                child: IgnorePointer(child: SizedBox.expand()),
                              ),
                              WorkspacePanelMotion(
                                animation: workspaceMotion,
                                hiddenOffset: WorkspacePanelMotions.right,
                                child: SizedBox(
                                  width: math.min(330, box.maxWidth * .25),
                                  height: math.max(
                                    0,
                                    box.maxHeight * .88 - appBarInset,
                                  ),
                                  child: room == null
                                      ? _SocialFeed(
                                          key: ValueKey(
                                            'space-feed-${_spaceFor(workspace)?.id ?? workspace}',
                                          ),
                                          workspace: workspace,
                                          dependencies: widget.dependencies,
                                          spaceId:
                                              _spaceFor(workspace)?.id ?? '',
                                        )
                                      : _chatGadgetHost(
                                          RoomChat(
                                            key: ValueKey(
                                              '${_spaceFor(workspace)?.id}/$_currentRoomId',
                                            ),
                                            room: room!,
                                            messages: chatMessages,
                                            working: _workingAgent,
                                            workingDetail: _workingDetail,
                                            me:
                                                widget
                                                    .dependencies
                                                    .sessionController
                                                    .session
                                                    ?.accountId ??
                                                '',
                                            dependencies: widget.dependencies,
                                            spaceId:
                                                _spaceFor(workspace)?.id ?? '',
                                            roomId: _chatRoomId,
                                            suggestions:
                                                _spaceFor(workspace)?.home ??
                                                false,
                                            threadRoomId: _currentRoomId,
                                            threadTitle:
                                                _roomThreads[_currentRoomId]
                                                    ?.title ??
                                                '',
                                            onThread: _switchThread,
                                            mentionable: spaceBots
                                                .where((b) => b.isAgent)
                                                .toList(),
                                            onSend: _sendRoomMessage,
                                            onEdit: _editRoomMessage,
                                            onDelete: _deleteRoomMessage,
                                            onReport: _reportRoomMessage,
                                            canModerate: _canManageTasks,
                                            hasMore: chatHasMore,
                                            loadingOlder: chatLoadingOlder,
                                            onLoadOlder: _loadOlderRoomMessages,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              // Floating glass app bar over desk / feed / chat.
              SafeArea(
                bottom: false,
                child: ThemeSlotHost(
                  slot: ThemeChromeSlots.floatingAppBar,
                  child: ThemeSlotHost(
                    slot: FeatureSlots.workspaceHeader,
                    child: ListenableBuilder(
                      listenable: widget.dependencies.sessionController,
                      builder: (context, _) => WorkspaceHeader(
                        room: room,
                        compact: compact,
                        handle: widget.dependencies.sessionController.session
                                ?.handle ??
                            '',
                        accountId: widget.dependencies.sessionController.session
                                ?.accountId ??
                            '',
                        avatar: widget.dependencies.service.avatarImage(
                          widget.dependencies.sessionController.avatar,
                        ),
                        onBackToFeed: widget.onBackToFeed == null
                            ? null
                            : _leaveToFeed,
                        onGoHome: goHome,
                        onOpenAdmin:
                            !widget.dependencies.sessionController.isAdmin
                                ? null
                                : () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => AdminScreen(
                                        dependencies: widget.dependencies,
                                      ),
                                    ),
                                  ),
                        onOpenWidgetsLibrary: () => showWidgetsLibrary(
                          context,
                          widget.dependencies,
                          onOpenSpace: (name) =>
                              unawaited(switchWorkspace(name)),
                        ),
                        onOpenProfile: compact
                            ? null
                            : () => showProfileMenu(
                                  context,
                                  widget.dependencies,
                                  showMessages: true,
                                ),
                      ),
                    ),
                  ),
                ),
              ),
              SwitcherEdgeHandle(onTap: () => _workspacePicker(context)),
            ],
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
            onPageChanged: (value) => setState(() => mobilePage = value),
            children: [
              _CenterDesk(
                workspace: workspace,
                room: room,
                pointer: pointer,
                controller: deskController,
                dependencies: widget.dependencies,
                spaceId: _spaceFor(workspace)?.id ?? '',
                roomId: _currentRoomId,
                topContentInset: contentInset,
              ),
              room == null
                  ? _SocialFeed(
                      key: ValueKey(
                        'space-feed-m-${_spaceFor(workspace)?.id ?? workspace}',
                      ),
                      workspace: workspace,
                      flat: true,
                      topContentInset: contentInset,
                      dependencies: widget.dependencies,
                      spaceId: _spaceFor(workspace)?.id ?? '',
                    )
                  : _chatGadgetHost(
                      RoomChat(
                        key: ValueKey(
                          '${_spaceFor(workspace)?.id}/$_currentRoomId',
                        ),
                        room: room!,
                        messages: chatMessages,
                        working: _workingAgent,
                        workingDetail: _workingDetail,
                        me:
                            widget
                                .dependencies
                                .sessionController
                                .session
                                ?.accountId ??
                            '',
                        dependencies: widget.dependencies,
                        spaceId: _spaceFor(workspace)?.id ?? '',
                        roomId: _chatRoomId,
                        suggestions: _spaceFor(workspace)?.home ?? false,
                        threadRoomId: _currentRoomId,
                        threadTitle: _roomThreads[_currentRoomId]?.title ?? '',
                        onThread: _switchThread,
                        mentionable: spaceBots.where((b) => b.isAgent).toList(),
                        onSend: _sendRoomMessage,
                        onEdit: _editRoomMessage,
                        onDelete: _deleteRoomMessage,
                        onReport: _reportRoomMessage,
                        canModerate: _canManageTasks,
                        hasMore: chatHasMore,
                        loadingOlder: chatLoadingOlder,
                        onLoadOlder: _loadOlderRoomMessages,
                        flat: true,
                        topContentInset: contentInset,
                      ),
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
                setState(() => mobilePage = value);
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
      spaceId: _spaceFor(workspace)?.id ?? '',
      dependencies: widget.dependencies,
    ),
    maxWidth: 920,
  );
  void _sheet(BuildContext context, Widget child, {double maxWidth = 1180}) =>
      showFloatingPanel(context, child, maxWidth: maxWidth);

  void _workspacePicker(BuildContext context) {
    final sheet = MediaQuery.sizeOf(context).width < 820;
    final picker = WorkspacePicker(
      current: workspace,
      dependencies: widget.dependencies,
      inBottomSheet: sheet,
      onOpenFeed: widget.onBackToFeed == null
          ? null
          : () async {
              Navigator.pop(context);
              await Future<void>.delayed(const Duration(milliseconds: 320));
              if (mounted) await _leaveToFeed();
            },
      onSettings: (space) {
        Navigator.pop(context);
        Future<void>.delayed(const Duration(milliseconds: 320), () {
          if (!mounted) return;
          _sheet(
            context,
            SpaceSettingsPanel(
              dependencies: widget.dependencies,
              space: space,
              onUpdated: (updated) {
                _loadWorkspaces();
                if (updated.name != workspace && mounted) {
                  switchWorkspace(updated.name);
                }
              },
              onExit: () {
                Navigator.of(context).pop();
                _loadWorkspaces();
              },
            ),
            maxWidth: 720,
          );
        });
      },
      onPick: (value) async {
        Navigator.pop(context);
        await Future<void>.delayed(const Duration(milliseconds: 320));
        if (mounted) await switchWorkspace(value);
      },
    );
    if (sheet) {
      showAppSheet<void>(context, picker, heightFactor: .82);
      return;
    }
    showFloatingDialog<void>(
      context,
      barrierLabel: 'Workspaces',
      pageBuilder: (_) => FloatingPanelSurface(child: picker),
    );
  }

  void _openSpaceSettings() {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    _sheet(
      context,
      SpaceSettingsPanel(
        dependencies: widget.dependencies,
        space: sp,
        onUpdated: (updated) {
          _loadWorkspaces();
          if (updated.name != workspace && mounted) {
            switchWorkspace(updated.name);
          }
        },
        onExit: () {
          Navigator.of(context).pop();
          _loadWorkspaces();
        },
      ),
      maxWidth: 720,
    );
  }
}

class _MobileTabs extends StatelessWidget {
  const _MobileTabs({
    required this.selected,
    required this.room,
    required this.onSelect,
  });
  final int selected;
  final String? room;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SegmentedTabBar(
    selectedIndex: selected,
    onTap: onSelect,
    labels: ['Desk', room == null ? 'Feed' : 'Chat'],
    icons: [
      Icons.dashboard_customize_outlined,
      room == null ? Icons.dynamic_feed_outlined : Icons.forum_outlined,
    ],
  );
}

class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel({
    required this.room,
    required this.workspace,
    required this.rooms,
    required this.tab,
    this.bots = const [],
    this.spaceBots = const [],
    this.allBots = const [],
    this.flat = false,
    this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.fileRevision = 0,
    required this.onTab,
    this.onOpenApp,
    this.onOpenFile,
    this.openFilePath = '',
    this.onCreateRoom,
    this.onSearch,
    this.onAddBot,
    this.onRemoveBot,
    this.onAddApp,
    this.appConnections = const {},
    this.onConnectApp,
    this.onOpenSettings,
    required this.openRoom,
  });
  final String? room;
  final String workspace;
  final List<String> rooms;
  final List<Bot> bots;
  final List<Bot> spaceBots;
  final List<Bot> allBots;
  final int tab;
  final bool flat;
  final AppDependencies? dependencies;
  final String spaceId;
  final String roomId;

  /// Bumped whenever files are uploaded/attached so the file library tabs
  /// (Docs/GIFs/Media/Audio) reload.
  final int fileRevision;
  final ValueChanged<int> onTab;
  final ValueChanged<String> openRoom;
  final ValueChanged<Bot>? onOpenApp;

  /// Opens a workspace file (`/workspace/…`) from the Files tab.
  final ValueChanged<String>? onOpenFile;

  /// The file open now, highlighted in the Files tab.
  final String openFilePath;
  final VoidCallback? onCreateRoom;
  final VoidCallback? onSearch;
  final ValueChanged<Bot>? onAddBot;
  final ValueChanged<Bot>? onRemoveBot;

  /// Adds an MCP app (from the catalog or by its address) to the space.
  final VoidCallback? onAddApp;

  /// Each app's sign-in state here, by bot id: an app each person connects
  /// with their own account offers Connect, or Reconnect once connected.
  final Map<String, ({String auth, bool connected, String name})>
  appConnections;
  final void Function(Bot bot, bool reconnect)? onConnectApp;

  /// Opens the space's settings, from the button under the tabs.
  final VoidCallback? onOpenSettings;

  /// The first of the space's facility tabs (Files, Computer, Memory,
  /// Previews), which follow the library tabs.
  static const facilitiesTab = 8;
  static const icons = [
    Icons.forum_outlined,
    Icons.smart_toy_outlined,
    Icons.extension_outlined,
    Icons.description_outlined,
    Icons.link,
    Icons.gif_box_outlined,
    Icons.perm_media_outlined,
    Icons.graphic_eq_rounded,
    Icons.folder_copy_outlined,
    Icons.desktop_windows_outlined,
    Icons.psychology_outlined,
    Icons.open_in_browser_outlined,
  ];
  static const labels = [
    'Rooms',
    'Agents',
    'Apps',
    'Docs',
    'Links',
    'GIFs',
    'Media',
    'Audio',
    'Files',
    'Computer',
    'Memory',
    'Previews',
  ];
  @override
  Widget build(BuildContext context) => _Panel(
    flat: flat,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Row(
      children: [
        Container(
          width: 58,
          margin: const EdgeInsets.fromLTRB(8, 10, 6, 10),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: .58),
            borderRadius: ThemeChrome.softCardCorners(context, AppShape.inner),
          ),
          // The library tabs, then (past a divider) the space's
          // facilities; the rail scrolls when the panel is short. The
          // space's settings stay pinned under them.
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < icons.length; i++) ...[
                          // Rooms, the library, then the space's facilities.
                          if (i == 1 || i == facilitiesTab)
                            Container(
                              width: 26,
                              height: 1,
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Tooltip(
                              message: labels[i],
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => onTab(i),
                                  borderRadius: AppShape.borderRadius(context, 16),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 240),
                                    curve: Curves.easeOutCubic,
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: i == tab
                                          ? ThemeRoles.selectedFill(context)
                                          : Colors.transparent,
                                      borderRadius: AppShape.borderRadius(context, 16),
                                    ),
                                    child: Icon(
                                      icons[i],
                                      size: 20,
                                      color: i == tab
                                          ? ThemeRoles.selectedInk(context)
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (onOpenSettings != null) ...[
                Container(
                  width: 26,
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                IconButton(
                  tooltip: 'Workspace settings',
                  onPressed: onOpenSettings,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            labels[tab],
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            room ?? workspace,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // A facility tab carries its own actions.
                    if (tab < facilitiesTab) ...[
                      IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Find ${labels[tab].toLowerCase()}',
                        onPressed: onSearch,
                        icon: const Icon(Icons.search_rounded, size: 18),
                      ),
                      const SizedBox(width: 3),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: tab == 0 ? 'New room' : 'Add',
                        onPressed: tab == 0 ? onCreateRoom : null,
                        icon: const Icon(Icons.add_rounded, size: 19),
                      ),
                    ],
                  ],
                ),
                if (spaceBots.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OrbitStrip(
                    agents: spaceBots.where((b) => b.isAgent).toList(),
                    tools: spaceBots
                        .where((b) => b.isTool && !b.isSandbox)
                        .toList(),
                    userId: dependencies
                            ?.sessionController.session?.accountId ??
                        '',
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: KeyedSubtree(
                      key: ValueKey('$workspace-$room-$tab'),
                      child: _libraryContent(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
        ),
        if (dependencies != null && spaceId.isNotEmpty)
          PluginSurfaceGadgets(
            dependencies: dependencies!,
            placement: PluginPlacement.rail,
            spaceId: spaceId,
            roomId: roomId,
            dockAlignment: Alignment.bottomCenter,
            compact: true,
          ),
      ],
    ),
  );
  Widget _libraryContent(BuildContext context) {
    if (tab == 0) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: rooms.length,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          final name = rooms[index];
          return _LibraryRoomCard(
            name: name,
            index: index,
            selected: name == (room ?? _WorkspaceScreenState.hallRoom),
            dependencies: dependencies,
            spaceId: spaceId,
            onTap: () => openRoom(name),
          );
        },
      );
    }
    if (tab >= facilitiesTab) {
      final deps = dependencies;
      if (deps == null || spaceId.isEmpty) {
        return const _LibraryEmpty(
          icon: Icons.cloud_off_outlined,
          message: 'Open a workspace to manage its facilities.',
        );
      }
      if (tab == facilitiesTab) {
        return WorkspaceFileTree(
          service: deps.service,
          spaceId: spaceId,
          selected: openFilePath,
          onOpen: (e) => onOpenFile?.call(e.path),
        );
      }
      if (tab == facilitiesTab + 1) {
        return SpaceComputerTab(dependencies: deps, spaceId: spaceId);
      }
      if (tab == facilitiesTab + 2) {
        return SpaceMemoryTab(
          dependencies: deps,
          spaceId: spaceId,
          agents: spaceBots.where((b) => b.isAgent).toList(),
        );
      }
      return SpacePreviewsTab(dependencies: deps, spaceId: spaceId);
    }
    if (tab >= 3) {
      // Docs / Links / GIFs / Media / Audio are backed by the space's file
      // library (spaces.file_list), filtered by mime type.
      return _LibraryFilesList(
        spaceId: spaceId,
        roomId: roomId,
        kind: tab,
        fileRevision: fileRevision,
        dependencies: dependencies,
      );
    }
    if (tab == 1) {
      // Only agents explicitly added to this workspace are shown.
      final agents = spaceBots.where((b) => b.isAgent).toList();
      final candidates = allBots
          .where((b) => b.isAgent && !spaceBots.any((s) => s.id == b.id))
          .toList();
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: agents.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (index == agents.length) {
            return _AddBotTile(
              label: 'Add agent',
              icon: Icons.smart_toy_outlined,
              candidates: candidates,
              userId: dependencies
                      ?.sessionController.session?.accountId ??
                  '',
              onAdd: (b) => onAddBot?.call(b),
            );
          }
          final bot = agents[index];
          return _LibraryBotCard(
            bot: bot,
            dependencies: dependencies,
            spaceId: spaceId,
            onRemove: onRemoveBot == null ? null : () => onRemoveBot!(bot),
          );
        },
      );
    }
    if (tab == 2) {
      // Only apps explicitly added to this workspace are shown.
      // The space's own computer is its Files tab, not an app.
      final tools = spaceBots.where((b) => b.isTool && !b.isSandbox).toList();
      final addApp = onAddApp;
      // "Add an app" offers the person's own apps too; the plain picker is
      // only for when it is not available.
      final candidates = addApp != null
          ? const <Bot>[]
          : allBots
                .where(
                  (b) =>
                      b.isTool &&
                      !b.isSandbox &&
                      !spaceBots.any((s) => s.id == b.id),
                )
                .toList();
      if (tools.isEmpty && candidates.isEmpty && addApp == null) {
        return const _LibraryEmpty(
          icon: Icons.widgets_outlined,
          message: 'No apps in this workspace yet — add one.',
        );
      }
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount:
            tools.length +
            (candidates.isEmpty ? 0 : 1) +
            (addApp == null ? 0 : 1),
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (addApp != null && index == tools.length) {
            return _AddAppTile(onTap: addApp);
          }
          if (index == tools.length) {
            return _AddBotTile(
              label: 'Add app',
              icon: Icons.widgets_outlined,
              candidates: candidates,
              userId: dependencies
                      ?.sessionController.session?.accountId ??
                  '',
              onAdd: (b) => onAddBot?.call(b),
            );
          }
          final bot = tools[index];
          final connection = appConnections[bot.id];
          final connect = onConnectApp;
          return _LibraryToolCard(
            bot: bot,
            label: bot.name,
            subtitle:
                personalApp(connection?.auth ?? '') && !connection!.connected
                ? 'Needs your sign-in'
                : '${bot.toolModeLabel} · ${bot.status}',
            icon: Icons.widgets_outlined,
            dependencies: dependencies,
            spaceId: spaceId,
            connected: connection?.connected ?? true,
            onConnect: connect == null || !personalApp(connection?.auth ?? '')
                ? null
                : () => connect(bot, connection!.connected),
            onTap: () => onOpenApp?.call(bot),
            onRemove: onRemoveBot == null ? null : () => onRemoveBot!(bot),
          );
        },
      );
    }
    return const _LibraryEmpty(
      icon: Icons.folder_outlined,
      message: 'Nothing here yet. Upload files to your workspace.',
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => PanelEmpty(
        compact: true,
        icon: icon,
        title: 'Nothing here',
        message: message,
      );
}

/// File-backed library content for the Docs/Links/GIFs/Media/Audio tabs.
class _LibraryFilesList extends StatefulWidget {
  const _LibraryFilesList({
    required this.spaceId,
    required this.roomId,
    required this.kind,
    this.fileRevision = 0,
    this.dependencies,
  });
  final String spaceId;
  final String roomId;
  final int kind;
  final int fileRevision;
  final AppDependencies? dependencies;
  @override
  State<_LibraryFilesList> createState() => _LibraryFilesListState();
}

class _LibraryFilesListState extends State<_LibraryFilesList> {
  static const _pageSize = 50;
  List<Map<String, dynamic>> _files = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LibraryFilesList old) {
    super.didUpdateWidget(old);
    if (old.spaceId != widget.spaceId ||
        old.roomId != widget.roomId ||
        old.kind != widget.kind ||
        old.fileRevision != widget.fileRevision) {
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    final deps = widget.dependencies;
    if (deps == null || widget.spaceId.isEmpty) {
      setState(() {
        _files = const [];
        _loading = false;
      });
      return;
    }
    if (more) {
      if (_loadingMore || !_hasMore || _loading) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() => _loading = true);
    }
    try {
      final offset = more ? _offset : 0;
      final all = await deps.service.fetchFiles(
        widget.spaceId,
        roomId: widget.roomId,
        limit: _pageSize,
        offset: offset,
      );
      final files = all.where(_matchesKind).toList();
      if (!mounted) return;
      setState(() {
        if (more) {
          _files = [..._files, ...files];
          _offset += all.length;
        } else {
          _files = files;
          _offset = all.length;
        }
        _hasMore = all.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _files = const [];
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool _matchesKind(Map<String, dynamic> file) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (widget.kind) {
      case 3: // Docs
        return mime.contains('pdf') ||
            mime.contains('text') ||
            mime.contains('markdown') ||
            mime.contains('doc');
      case 4: // Links
        return mime.contains('html') || mime.contains('url');
      case 5: // GIFs
        return mime == 'image/gif';
      case 6: // Media
        return mime.startsWith('image/') || mime.startsWith('video/');
      case 7: // Audio
        return mime.startsWith('audio/');
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonList();
    if (_files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            'No files in this workspace yet. Upload one to see it here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_hasMore && !_loadingMore && n.metrics.extentAfter < 250) {
          unawaited(_load(more: true));
        }
        return false;
      },
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: _files.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (index >= _files.length) {
            return const SkeletonListTile();
          }
          final file = _files[index];
          final name = file['name'] as String? ?? 'file';
          final mime = file['mime'] as String? ?? '';
          final size = (file['size'] as num?)?.toInt() ?? 0;
          return _LibraryListCard(
            label: name,
            icon: _iconFor(mime),
            kind: 3,
            index: index,
            subtitle: '$mime · ${_humanSize(size)}',
            dependencies: widget.dependencies,
          );
        },
      ),
    );
  }

  IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.graphic_eq_rounded;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _humanSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

class _LibraryRoomCard extends StatelessWidget {
  const _LibraryRoomCard({
    required this.name,
    required this.index,
    required this.selected,
    required this.onTap,
    this.dependencies,
    this.spaceId = '',
  });
  final String name;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) {
    final hall = name == _WorkspaceScreenState.hallRoom;
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context, selected: selected),
      borderRadius: corners,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.tertiary,
                    ],
                  ),
                  borderRadius: well,
                ),
                child: Center(
                  child: hall
                      ? const Icon(
                          Icons.dynamic_feed_rounded,
                          color: Colors.white,
                          size: 19,
                        )
                      : Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: AppColors.successOf(context),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            hall
                                ? 'Workspace feed · live now'
                                : '${4 + index * 3} active · ${12 + index} new',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Room profile',
                onPressed: () => _openEntityProfile(
                  context,
                  'Rooms',
                  name,
                  dependencies,
                  spaceId,
                ),
                icon: const Icon(Icons.info_outline_rounded, size: 17),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryListCard extends StatelessWidget {
  const _LibraryListCard({
    required this.label,
    required this.icon,
    required this.kind,
    required this.index,
    this.subtitle,
    this.dependencies,
  });
  final String label;
  final IconData icon;
  final int kind, index;
  final String? subtitle;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    child: InkWell(
      onTap: kind == 1 || kind == 2
          ? () => _openEntityProfile(
              context,
              kind == 1 ? 'Agents' : 'Apps',
              label,
              dependencies,
            )
          : null,
      borderRadius: corners,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: well,
              ),
              child: Icon(icon, size: 17),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle ??
                        (kind == 1
                            ? (index == 0
                                  ? 'Running · 4 tasks'
                                  : 'Ready to deploy')
                            : kind == 7
                            ? '${index + 1}:${20 + index * 7} · voice note'
                            : kind == 3
                            ? '${2 + index * 3} pages · edited today'
                            : 'Saved in this workspace'),
                    style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {},
              icon: const Icon(Icons.more_horiz_rounded, size: 17),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _LibraryBotCard extends StatelessWidget {
  const _LibraryBotCard({
    required this.bot,
    this.dependencies,
    this.spaceId = '',
    this.onRemove,
  });
  final Bot bot;
  final AppDependencies? dependencies;
  final String spaceId;
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: () => _openEntityProfile(
          context,
          'Agents',
          bot.name,
          dependencies,
          spaceId,
        ),
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              BotAvatar(
                bot: bot,
                radius: 18,
                userId: dependencies
                        ?.sessionController.session?.accountId ??
                    '',
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bot.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${bot.kind} · ${bot.vmType} · ${bot.status}',
                      style: TextStyle(
                        fontSize: 9,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove from workspace',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile that opens a picker of candidate bots (not yet in the workspace) and
/// adds the selected one.
/// Opens "Add an app": an MCP server from the catalog or by its address,
/// with each person's sign-in right after when it needs one.
class _AddAppTile extends StatelessWidget {
  const _AddAppTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: well,
                ),
                child: Icon(
                  Icons.add_link_rounded,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add an app',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'MCP server, with sign-in',
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddBotTile extends StatelessWidget {
  const _AddBotTile({
    required this.label,
    required this.icon,
    required this.candidates,
    required this.onAdd,
    this.userId = '',
  });
  final String label;
  final IconData icon;
  final List<Bot> candidates;
  final ValueChanged<Bot> onAdd;
  final String userId;

  void _pick(BuildContext context) {
    if (candidates.isEmpty) {
      showAppDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nothing to add'),
          content: const Text(
            'No bots of this type are available yet. Create one in My bots or install from the market.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    showAppPicker<Bot>(
      context: context,
      anchor: context,
      showDragHandle: false,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Add $label',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: candidates.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final b = candidates[i];
                    return ListTile(
                      leading: BotAvatar(
                        bot: b,
                        radius: 16,
                        userId: userId,
                      ),
                      title: Text(b.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${b.kind} · ${b.vmType}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: () => Navigator.pop(context, b),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((b) {
      if (b != null) onAdd(b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: () => _pick(context),
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .14),
                  borderRadius: well,
                ),
                child:
                    Icon(icon, size: 19, color: AppColors.primaryOf(context)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Icon(Icons.add_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryToolCard extends StatelessWidget {
  const _LibraryToolCard({
    required this.label,
    required this.icon,
    this.bot,
    this.subtitle,
    this.onTap,
    this.onRemove,
    this.onConnect,
    this.connected = true,
    this.dependencies,
    this.spaceId = '',
  });
  final String label;
  final IconData icon;
  final Bot? bot;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// Signs the caller's own account in to an app each person connects;
  /// null for an app everyone shares.
  final VoidCallback? onConnect;
  final bool connected;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    child: InkWell(
      onTap:
          onTap ??
          () =>
              _openEntityProfile(context, 'Apps', label, dependencies, spaceId),
      borderRadius: corners,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            if (bot != null)
              BotAvatar(
                bot: bot!,
                radius: 18,
                userId: dependencies
                        ?.sessionController.session?.accountId ??
                    '',
              )
            else
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .14),
                  borderRadius: well,
                ),
                child: Icon(icon, size: 19, color: AppColors.primaryOf(context)),
              ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: connected
                              ? AppColors.successOf(context)
                              : AppColors.warningOf(context),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          subtitle ?? 'Connected',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onConnect != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: connected
                    ? 'Reconnect your account'
                    : 'Connect your account',
                onPressed: onConnect,
                icon: Icon(
                  connected ? Icons.sync_rounded : Icons.login_rounded,
                  size: 17,
                  color: connected ? null : AppColors.warningOf(context),
                ),
              ),
            if (onRemove != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove from workspace',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded, size: 17),
              ),
          ],
        ),
      ),
    ),
    );
  }
}

/// The room's desk: tools' frontends as floating card windows (opened by
/// people from the library and by agents showing results) and the dock. An
/// empty desk shows the machine. On desktop, [underlay] holds the left/right
/// panels under the windows so cards can float over them.
class _CenterDesk extends StatelessWidget {
  const _CenterDesk({
    required this.workspace,
    required this.room,
    required this.pointer,
    required this.controller,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    this.underlay,
    this.topContentInset = 0,
  });
  final String workspace;
  final String? room;
  final Offset pointer;
  final DeskController controller;
  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final Widget? underlay;
  final double topContentInset;

  Widget _frontend(String tool, ShownResult? shown) => ToolFrontendView(
    key: ValueKey('$tool/${shown?.microtool}/${shown?.args}'),
    api: ToolsApi.of(dependencies.service),
    botId: tool,
    spaceId: spaceId,
    roomId: roomId,
    userId: dependencies.sessionController.session?.accountId ?? '',
    shown: shown,
  );

  /// A window's frontend, whatever its kind; the enclosing
  /// [FrontendPresentation] says whether in full or as a compact widget.
  Widget _windowContent(BuildContext context, DeskWindow w) =>
      DeskSurfaceContent(
        dependencies: dependencies,
        spaceId: spaceId,
        roomId: roomId,
        window: w,
      );

  Widget _pinPreview(DeskPin p) => p.isWeb
      ? _WebPinPreview(title: p.label)
      : p.isAgui
      ? CompactSummaryView(
          summary: CompactSummary(
            title: p.label.isEmpty ? 'Visualization' : p.label,
            caption: 'AG-UI',
            icon: 'dashboard',
          ),
        )
      : p.isComputer
      ? const CompactSummaryView(
          summary: CompactSummary(
            title: 'Computer',
            caption: 'The project’s desktop',
            icon: 'computer',
          ),
        )
      : p.isFile
      ? _FilePreview(path: p.fileId.isEmpty ? p.filePath : p.label)
      : p.isApp
      ? _AppPinPreview(name: p.name)
      : _frontend(p.tool, p.shown);

  Widget _emptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 150, child: _MachineFace(pointer: pointer)),
            const SizedBox(height: 8),
            Text(
              room == null ? 'My desk' : '$room desk',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                'App results open here as windows. Ask an agent, or open an app from the library.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _WorkspacePatternPainter(workspace)),
            ),
          ),
          Positioned.fill(
            // Every window's images, videos and audio load from the space's
            // project files, stored files and the node, as this person.
            child: ElpianMediaScope(
              resolver: ToolMedia.forSpace(dependencies.service, spaceId).call,
              // Phones: the windows as compact widgets on a board, each
              // opened in a bottom sheet; wider screens: floating card windows.
              child: LayoutBuilder(
                builder: (context, box) => box.maxWidth < compactDeskWidth
                    ? CompactDesk(
                        controller: controller,
                        topInset: topContentInset,
                        windowContent: _windowContent,
                        pinPreview: _pinPreview,
                        emptyState: _emptyState(context),
                      )
                    : FloatingDesk(
                        controller: controller,
                        topInset: topContentInset,
                        underlay: underlay,
                        windowContent: _windowContent,
                        pinPreview: _pinPreview,
                        emptyState: _emptyState(context),
                      ),
              ),
            ),
          ),
          if (spaceId.isNotEmpty)
            Positioned.fill(
              child: PluginSurfaceGadgets(
                dependencies: dependencies,
                placement: PluginPlacement.desk,
                spaceId: spaceId,
                roomId: roomId,
                dockAlignment: Alignment.bottomCenter,
                pad: EdgeInsets.fromLTRB(16, 16, 16, 24 + topContentInset),
              ),
            ),
        ],
      ),
    );
  }
}

/// A desk window's frontend, in full or as the compact widget the enclosing
/// [FrontendPresentation] asks for. Shared by a room desk and the feed canvas.
class DeskSurfaceContent extends StatelessWidget {
  const DeskSurfaceContent({
    super.key,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.window,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final DeskWindow window;

  Widget _frontend(String tool, ShownResult? shown) => ToolFrontendView(
    key: ValueKey('$tool/${shown?.microtool}/${shown?.args}'),
    api: ToolsApi.of(dependencies.service),
    botId: tool,
    spaceId: spaceId,
    roomId: roomId,
    userId: dependencies.sessionController.session?.accountId ?? '',
    shown: shown,
  );

  /// A web page window: the page itself, or, as a phone-board widget, a
  /// summary that opens it. An Elpian app ([elpian], its program) runs
  /// natively instead of as a web page.
  Widget _page(
    BuildContext context,
    String id,
    String page,
    String title, {
    String elpian = '',
    String widget = '',
  }) => FrontendPresentation.isCompact(context)
      ? (widget.isEmpty
            ? CompactSummaryView(
                summary: CompactSummary(
                  title: title.isEmpty ? 'Web page' : title,
                  caption: 'Tap to open',
                  icon: 'language',
                ),
              )
            : LivePreview(
                key: ValueKey('widget-$id-$page-$widget'),
                service: dependencies.service,
                spaceId: spaceId,
                title: title,
                page: page,
                compact: true,
                content: (_) => IgnorePointer(
                  child: ElpianAppView(
                    key: ValueKey('elpian-widget-$id-$page-$widget'),
                    service: dependencies.service,
                    page: page,
                    entry: widget,
                    spaceId: spaceId,
                    roomId: roomId,
                    title: title,
                  ),
                ),
              ))
      : LivePreview(
          key: ValueKey('web-$id-$page-$elpian'),
          service: dependencies.service,
          spaceId: spaceId,
          title: title,
          page: page,
          content: elpian.isEmpty
              ? null
              : (_) => ElpianAppView(
                  key: ValueKey('elpian-$id-$page-$elpian'),
                  service: dependencies.service,
                  page: page,
                  entry: elpian,
                  spaceId: spaceId,
                  roomId: roomId,
                  title: title,
                ),
        );

  Widget _agui(BuildContext context, DeskWindow w) {
    if (FrontendPresentation.isCompact(context)) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: w.label.isEmpty ? 'Visualization' : w.label,
          caption: 'AG-UI · tap to open',
          icon: 'dashboard',
        ),
      );
    }
    final raw = w.aguiSurface;
    if (raw == null) {
      return const Center(child: Text('Empty AG-UI surface'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: AgUiSurfaceView(
        key: ValueKey('agui-${w.id}'),
        surface: AgUiSurface.fromJson(raw),
        compact: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = window;
    return w.isWeb
        ? _page(
            context,
            w.id,
            w.page,
            w.label,
            elpian: w.elpian,
            widget: w.widget,
          )
        : w.isAgui
        ? _agui(context, w)
        : w.isComputer
        ? (FrontendPresentation.isCompact(context)
              ? const CompactSummaryView(
                  summary: CompactSummary(
                    title: 'Computer',
                    caption: 'Tap to open',
                    icon: 'computer',
                  ),
                )
              : ComputerSession(
                  key: ValueKey('computer-${w.id}'),
                  service: dependencies.service,
                  spaceId: spaceId,
                ))
        : w.isFile
        ? (FrontendPresentation.isCompact(context)
              ? _FilePreview(path: w.fileId.isEmpty ? w.filePath : w.label)
              : w.fileId.isNotEmpty
              ? SharedFileWindow(
                  key: ValueKey('shared-${w.id}-${w.fileId}'),
                  service: dependencies.service,
                  fileId: w.fileId,
                )
              : WorkspaceFileViewer(
                  key: ValueKey('file-${w.id}-${w.filePath}'),
                  service: dependencies.service,
                  spaceId: spaceId,
                  path: w.filePath,
                  showHeader: false,
                ))
        : w.isApp
        ? (FrontendPresentation.isCompact(context)
              ? CompactSummaryView(
                  summary: CompactSummary(
                    title: w.microtool.isEmpty ? w.name : w.microtool,
                    caption: w.argsSummary,
                    icon: 'apps',
                  ),
                )
              : McpAppView(
                  key: ValueKey('app-${w.id}'),
                  api: ToolsApi.of(dependencies.service),
                  botId: w.tool,
                  spaceId: spaceId,
                  roomId: roomId,
                  microtool: w.microtool,
                  args: w.args,
                ))
        : _frontend(w.tool, w.shown);
  }
}

/// A pinned result shown with a tool's app: the app runs once the pin is
/// opened, not in the preview.
/// A pinned web page: it loads when opened, not in the preview.
class _WebPinPreview extends StatelessWidget {
  const _WebPinPreview({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.language_rounded, color: scheme.primary, size: 32),
          const SizedBox(height: 8),
          Text(
            title.isEmpty ? 'Web page' : title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'An interactive page of the space',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A workspace file's icon, name and folder: a pinned file, or a file
/// window as a phone-board widget.
class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = path.split('/').last;
    final type = FileType.of(name);
    final folder = path.substring(0, path.length - name.length);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(type.icon, color: type.color, size: 32),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                folder,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppPinPreview extends StatelessWidget {
  const _AppPinPreview({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.widgets_outlined, color: scheme.primary, size: 32),
          const SizedBox(height: 8),
          Text(
            name.isEmpty ? 'This app' : name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'Opens with its own interface',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MachineFace extends StatelessWidget {
  const _MachineFace({required this.pointer});
  final Offset pointer;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dx = ((pointer.dx - size.width / 2) / size.width).clamp(-.5, .5) * 18;
    final dy =
        ((pointer.dy - size.height / 3) / size.height).clamp(-.4, .4) * 12;
    return Center(
      child: Transform.translate(
        offset: Offset(dx, dy),
        child: Transform.rotate(
          angle: dx / 800,
          child: Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .28),
                  blurRadius: 48,
                ),
              ],
            ),
            child: Image.asset('assets/images/only_orb.png'),
          ),
        ),
      ),
    );
  }
}

class _SocialFeed extends StatefulWidget {
  const _SocialFeed({
    super.key,
    required this.workspace,
    this.dependencies,
    this.spaceId = '',
    this.flat = false,
    this.topContentInset = 0,
  });
  final String workspace;
  final AppDependencies? dependencies;
  final String spaceId;
  final bool flat;
  final double topContentInset;
  @override
  State<_SocialFeed> createState() => _SocialFeedState();
}

class _SocialFeedState extends State<_SocialFeed> {
  static const _pageSize = 20;
  List<SocialPost> posts = [];
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = true;
  int _offset = 0;
  bool _publishing = false;

  /// Bumps when the feed's space changes so a late response for the previous
  /// space (or the unfiltered global feed) cannot paint over the new one.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    // Wait for the workspace's space id; fetching with an empty id returns
    // the global/following feed and flashes the wrong posts.
    if (widget.spaceId.isNotEmpty) _load();
  }

  @override
  void didUpdateWidget(covariant _SocialFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace ||
        oldWidget.spaceId != widget.spaceId) {
      posts = [];
      _offset = 0;
      hasMore = true;
      loading = true;
      loadingMore = false;
      _loadGen++;
      if (widget.spaceId.isNotEmpty) {
        _load();
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _publish([String body = '']) async {
    final md = (body.isEmpty ? null : body) ?? '';
    final deps = widget.dependencies;
    if (md.trim().isEmpty ||
        _publishing ||
        deps == null ||
        widget.spaceId.isEmpty) {
      return;
    }
    setState(() => _publishing = true);
    try {
      await deps.service.createPost(md.trim(), spaceId: widget.spaceId);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Posted to this workspace')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Post failed: $e')));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _openComposer() async {
    final md = await showPostEditor(
      context,
      hint: 'Write to ${widget.workspace}…',
    );
    if (md == null || md.trim().isEmpty) return;
    await _publish(md);
  }

  Future<void> _load({bool more = false}) async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => loading = false);
      return;
    }
    // Spaces list is still resolving; keep the skeleton up.
    if (widget.spaceId.isEmpty) {
      if (!more && mounted) setState(() => loading = true);
      return;
    }
    if (more) {
      if (loadingMore || !hasMore || loading) return;
      setState(() => loadingMore = true);
    } else {
      setState(() => loading = true);
    }
    final gen = _loadGen;
    final spaceId = widget.spaceId;
    try {
      final offset = more ? _offset : 0;
      final feed = await deps.service.fetchFeed(
        spaceId: spaceId,
        limit: _pageSize,
        offset: offset,
      );
      if (!mounted || gen != _loadGen || widget.spaceId != spaceId) return;
      setState(() {
        if (more) {
          posts.addAll(feed);
          _offset += feed.length;
        } else {
          posts = feed;
          _offset = feed.length;
        }
        hasMore = feed.length >= _pageSize;
        loading = false;
        loadingMore = false;
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        loading = false;
        loadingMore = false;
      });
    }
  }

  void _replace(String id, SocialPost Function(SocialPost) change) {
    final i = posts.indexWhere((p) => p.id == id);
    if (i >= 0) setState(() => posts[i] = change(posts[i]));
  }

  Future<void> _toggleLike(SocialPost post) async {
    final deps = widget.dependencies;
    if (deps == null || post.id.isEmpty) return;
    final index = posts.indexWhere((p) => p.id == post.id);
    if (index < 0) return;
    final liked = !post.likedByMe;
    setState(() {
      posts[index] = post.withLike(
        likes: post.likes + (liked ? 1 : -1),
        likedByMe: liked,
      );
    });
    try {
      if (liked) {
        await deps.service.likePost(post.id);
      } else {
        await deps.service.unlikePost(post.id);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        posts[index] = post;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final header = Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace == 'Home' ? 'Universal feed' : '$workspace feed',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  workspace == 'Home'
                      ? 'Public platform posts'
                      : 'Posts from this workspace',
                  style: const TextStyle(fontSize: 9),
                ),
              ],
            ),
          ),
          const Icon(Icons.tune, size: 18),
        ],
      ),
    );
    final postWidgets = [if (widget.spaceId.isNotEmpty) _composer(context)];
    if (loading) {
      postWidgets.add(const SkeletonList(itemCount: 3, item: SkeletonPost()));
    } else if (posts.isEmpty) {
      postWidgets.add(
        Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Text(
              'No posts in this workspace yet.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    } else {
      final deps = widget.dependencies;
      postWidgets.addAll(
        posts.map(
          (p) => deps == null
              ? const SizedBox.shrink()
              : FeedPostCard(
                  key: ValueKey('space-post-${p.id}'),
                  post: feedPostFromServer(p),
                  dependencies: deps,
                  onToggleLike: () => _toggleLike(p),
                  onEdited: (body) => _replace(
                    p.id,
                    (old) => old.copyWith(body: body, editedAt: DateTime.now()),
                  ),
                  onDeleted: () => setState(
                    () => posts.removeWhere((old) => old.id == p.id),
                  ),
                  onShared: _load,
                ),
        ),
      );
    }
    if (loadingMore) {
      postWidgets.add(const SkeletonPost());
    }
    final body = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (hasMore &&
            !loadingMore &&
            n.metrics.extentAfter < 250 &&
            n.metrics.maxScrollExtent > 0) {
          unawaited(_load(more: true));
        }
        return false;
      },
      child: widget.flat
          ? ListView(
              padding: EdgeInsets.fromLTRB(12, widget.topContentInset, 12, 24),
              children: [header, ...postWidgets],
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: postWidgets,
            ),
    );
    if (widget.flat) return _Panel(flat: true, child: body);
    return _Panel(
      flat: widget.flat,
      child: Column(
        children: [
          header,
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final shell = ThemeChrome.inputShell(context);
    return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: EdgeInsets.symmetric(
      horizontal: shell.padding.horizontal / 2,
      vertical: 4,
    ),
    decoration: BoxDecoration(
      color: shell.color,
      borderRadius: shell.radius,
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: InkWell(
      onTap: _publishing ? null : _openComposer,
      borderRadius: shell.radius,
      child: Row(
        children: [
          const Icon(Icons.edit_note_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _publishing ? 'Publishing…' : 'Write a post for this workspace…',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            onPressed: _publishing ? null : _openComposer,
            icon: _publishing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 20),
          ),
        ],
      ),
    ),
  );
  }
}

/// Opens Explore from the feed: a search across Aseman with no space scope,
/// so it has no "in this space" tab. [onOpenSpace] opens a space the user is
/// a member of by name.
Future<void> showExplore(
  BuildContext context,
  AppDependencies dependencies, {
  String query = '',
  ValueChanged<String>? onOpenSpace,
}) => showFloatingPanel(
  context,
  _SearchPanel(
    workspace: '',
    dependencies: dependencies,
    feed: true,
    initialQuery: query,
    onOpenSpace: onOpenSpace,
  ),
  maxWidth: 920,
  barrierLabel: 'Close explore',
);

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({
    required this.workspace,
    this.spaceId = '',
    this.dependencies,
    this.feed = false,
    this.initialQuery = '',
    this.onOpenSpace,
  });
  final String workspace;
  final String spaceId;
  final AppDependencies? dependencies;

  /// Opened from the feed, outside any space: only the platform-wide
  /// sections, without the space/explore tab bar.
  final bool feed;
  final String initialQuery;
  final ValueChanged<String>? onOpenSpace;
  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  int localSection = 0;
  int globalSection = 0;
  late String query = widget.initialQuery;
  late final searchField = TextEditingController(text: widget.initialQuery);
  static const local = [
    'Users',
    'Agents',
    'Apps',
    'Media',
    'Documents',
    'Links',
    'GIFs',
    'Messages',
  ];
  static const global = ['Users', 'Agents', 'Apps', 'Posts', 'Workspaces'];

  /// What the feed's search covers: people, the user's and public spaces,
  /// the posts of their Following feed, their direct chats and the market's
  /// agents and apps.
  static const feedSections = [
    'Users',
    'Spaces',
    'Posts',
    'Chats',
    'Agents',
    'Apps',
  ];
  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this, initialIndex: 0)
      ..addListener(() {
        if (!tabs.indexIsChanging) setState(() {});
      });
  }

  @override
  void dispose() {
    searchField.dispose();
    tabs.dispose();
    super.dispose();
  }

  /// Whether the results are the space's own (the first tab inside a space).
  bool get _local => !widget.feed && tabs.index == 0;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final sections = widget.feed
        ? feedSections
        : _local
        ? local
        : global;
    final selected = _local ? localSection : globalSection;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 24,
        18,
        compact ? 14 : 24,
        12,
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore_rounded, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.feed
                      ? 'Explore'
                      : compact
                      ? 'Discover'
                      : 'Search & discover',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            controller: searchField,
            autofocus: true,
            onChanged: (value) => setState(() => query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: _local
                  ? 'Search ${widget.workspace}…'
                  : 'Search all of Aseman…',
            ),
          ),
          const SizedBox(height: 9),
          _SearchSectionNav(
            sections: sections,
            selected: selected,
            onSelect: (value) => setState(() {
              if (_local) {
                localSection = value;
              } else {
                globalSection = value;
              }
            }),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: _SearchResults(
                key: ValueKey('${tabs.index}-$selected-$query'),
                section: sections[selected],
                global: !_local,
                feed: widget.feed,
                workspace: widget.workspace,
                spaceId: widget.spaceId,
                query: query,
                onOpenSpace: widget.onOpenSpace,
                dependencies: widget.dependencies,
              ),
            ),
          ),
          // Outside a space there is nothing to scope the search to.
          if (!widget.feed) ...[
            const SizedBox(height: 9),
            SegmentedTabBar(
              controller: tabs,
              compact: compact,
              labels: ['In ${widget.workspace}', 'Explore Aseman'],
              icons: const [Icons.hub_outlined, Icons.travel_explore_rounded],
            ),
          ],
        ],
      ),
    );
  }
}

class _SearchSectionNav extends StatelessWidget {
  const _SearchSectionNav({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });
  final List<String> sections;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SegmentedTabBar(
      key: ValueKey(sections.join('-')),
      width: box.maxWidth,
      selectedIndex: selected,
      onTap: onSelect,
      labels: sections,
      icons: [for (final section in sections) _sectionIcon(section)],
    ),
  );
}

IconData _sectionIcon(String section) => switch (section) {
  'Users' => Icons.people_outline,
  'Agents' => Icons.smart_toy_outlined,
  'Apps' => Icons.extension_outlined,
  'Media' => Icons.perm_media_outlined,
  'Documents' => Icons.description_outlined,
  'Links' => Icons.link_rounded,
  'GIFs' => Icons.gif_box_outlined,
  'Messages' => Icons.chat_bubble_outline_rounded,
  'Posts' => Icons.dynamic_feed_outlined,
  'Rooms' => Icons.forum_outlined,
  'Workspaces' || 'Spaces' => Icons.hub_outlined,
  'Chats' => Icons.forum_outlined,
  _ => Icons.search_rounded,
};

/// One search result: what its card shows, the entity's id when known, and
/// the record it came from (a chat, a post, a space row).
class _SearchHit {
  const _SearchHit(
    this.title, {
    this.subtitle,
    this.id = '',
    this.payload,
    this.avatar = '',
  });
  final String title;
  final String? subtitle;
  final String id;
  final Object? payload;

  /// The picture of the person, workspace, agent or app found ("" if none).
  final String avatar;
}

class _SearchResults extends StatefulWidget {
  const _SearchResults({
    super.key,
    required this.section,
    required this.global,
    this.feed = false,
    required this.workspace,
    required this.spaceId,
    required this.query,
    this.onOpenSpace,
    this.dependencies,
  });
  final String section;
  final bool global;
  final bool feed;
  final ValueChanged<String>? onOpenSpace;
  final String workspace;
  final String spaceId;
  final String query;
  final AppDependencies? dependencies;
  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

/// Scope + paginated search results. The in-workspace tab searches only the
/// current space (members, installed agents/tools, space files/messages) while
/// the Explore tab searches the whole platform, loading more on scroll.
class _SearchResultsState extends State<_SearchResults> {
  static const _pageSize = 24;
  final ScrollController _scroll = ScrollController();
  List<_SearchHit> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void didUpdateWidget(covariant _SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query ||
        old.section != widget.section ||
        old.global != widget.global ||
        old.spaceId != widget.spaceId) {
      _load();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 300) return;
    unawaited(_loadMore());
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() {
        _items = const [];
        _loading = false;
        _hasMore = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _items = const [];
      _offset = 0;
      _hasMore = true;
    });
    try {
      final page = await _fetchPage(deps, 0);
      if (!mounted) return;
      setState(() {
        _items = page;
        _offset = page.length;
        _hasMore = page.length >= _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(deps, _offset);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page];
        _offset += page.length;
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  /// Fetches one page of results for the active tab + scope.
  Future<List<_SearchHit>> _fetchPage(AppDependencies deps, int offset) async {
    if (widget.feed) return _fetchFeedPage(deps, offset);
    return _fetchTitles(deps, offset);
  }

  /// The feed's search: everything is the server's own search.
  Future<List<_SearchHit>> _fetchFeedPage(
    AppDependencies deps,
    int offset,
  ) async {
    final q = widget.query.trim();
    final service = deps.service;
    switch (widget.section) {
      case 'Users':
        final users = await service.searchUsers(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final u in users)
            _SearchHit(
              u.handle,
              id: u.id,
              subtitle: '@${u.handle}',
              avatar: u.avatar,
            ),
        ];
      case 'Spaces':
        final spaces = await service.searchSpaces(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final sp in spaces)
            _SearchHit(
              '${sp['name'] ?? ''}',
              id: '${sp['id'] ?? ''}',
              subtitle: [
                if ('${sp['description'] ?? ''}'.isNotEmpty)
                  '${sp['description']}',
                sp['member'] == false ? 'Public space' : 'Your space',
              ].join(' · '),
              payload: sp,
              avatar: '${sp['avatar'] ?? ''}',
            ),
        ];
      case 'Posts':
        final posts = await service.searchPosts(
          q,
          following: true,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final p in posts)
            _SearchHit(
              _firstLine(p.body),
              id: p.id,
              subtitle: _afterFirstLine(p.body),
              payload: p,
            ),
        ];
      case 'Chats':
        // The chat list is not paged: one page holds every match.
        if (offset > 0) return const [];
        final chats = await service.fetchChats(kind: 'direct', query: q);
        return [
          for (final c in chats)
            _SearchHit(
              c.title,
              id: c.spaceId,
              subtitle: c.lastBody.isEmpty
                  ? 'Direct chat'
                  : markupPreview(c.lastBody),
              payload: c,
              avatar: c.peer?.avatar ?? '',
            ),
        ];
      case 'Agents':
      case 'Apps':
        final listings = await service.fetchMarket(
          type: widget.section == 'Apps' ? 'tool' : 'agent',
          query: q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final l in listings)
            _SearchHit(
              l.name,
              id: l.botId,
              subtitle: l.description.isEmpty
                  ? 'In the market · ${l.kindLabel}'
                  : l.description,
              payload: l,
              avatar: l.avatar,
            ),
        ];
      default:
        return const [];
    }
  }

  /// A post's text after its first line, for the card's blurb.
  static String _afterFirstLine(String body) {
    final rest = body.trim().split('\n').skip(1).join(' ').trim();
    return rest.isEmpty ? 'From your Following feed' : rest;
  }

  static String _firstLine(String body) {
    final line = body
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^[#>*\-\s]+'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => 'Post');
    return line.length > 90 ? '${line.substring(0, 90)}…' : line;
  }

  /// Opens a result: a chat, a post, a space the user is in, or a profile.
  VoidCallback? _opener(_SearchHit hit) {
    final deps = widget.dependencies;
    final payload = hit.payload;
    if (payload is ChatSummary && deps != null) {
      return () => showChat(context, deps, payload);
    }
    if (payload is SocialPost) {
      return () => showFloatingPanel(
        context,
        _PostPreview(post: payload, dependencies: deps),
        maxWidth: 640,
        maxHeight: 700,
        barrierLabel: 'Close post',
      );
    }
    if (widget.section == 'Spaces' &&
        payload is Map &&
        payload['member'] != false &&
        widget.onOpenSpace != null) {
      return () {
        Navigator.of(context).pop();
        widget.onOpenSpace!(hit.title);
      };
    }
    if (const [
      'Users',
      'Agents',
      'Apps',
      'Workspaces',
      'Spaces',
      'Rooms',
    ].contains(widget.section)) {
      return () => _openEntityProfile(
        context,
        widget.section,
        hit.title,
        deps,
        widget.spaceId,
        hit.id,
      );
    }
    return null;
  }

  /// One page of results inside a space or across Aseman.
  Future<List<_SearchHit>> _fetchTitles(
    AppDependencies deps,
    int offset,
  ) async {
    final q = widget.query.trim().toLowerCase();
    final space = widget.spaceId;
    List<_SearchHit> titles(Iterable<String> all) => [
      for (final t in all) _SearchHit(t),
    ];
    switch (widget.section) {
      case 'Users':
        if (widget.global) {
          final users = await deps.service.searchUsers(
            q,
            limit: _pageSize,
            offset: offset,
          );
          return [
            for (final u in users) _SearchHit(u.handle, avatar: u.avatar),
          ];
        }
        if (space.isEmpty) return const [];
        final mems = await deps.service.fetchSpaceMembers(
          space,
          kind: 'user',
          limit: _pageSize,
          offset: offset,
        );
        return [
              for (final m in mems)
                _SearchHit(
                  (m['handle'] as String?) ?? (m['member_id'] as String? ?? ''),
                  avatar: '${m['avatar'] ?? ''}',
                ),
            ]
            .where(
              (h) => h.title.isNotEmpty && h.title.toLowerCase().contains(q),
            )
            .toList();
      case 'Agents':
      case 'Apps':
        final isTool = widget.section == 'Apps';
        if (widget.global) {
          final kinds = isTool ? 'tool' : 'agent';
          final bots = await deps.service.searchBots(
            q,
            kind: kinds,
            limit: _pageSize,
            offset: offset,
          );
          return [
                for (final b in bots)
                  _SearchHit(
                    b['name'] as String? ?? '',
                    avatar: '${b['avatar'] ?? ''}',
                  ),
              ]
              .where(
                (h) => h.title.isNotEmpty && h.title.toLowerCase().contains(q),
              )
              .toList();
        }
        if (space.isEmpty) return const [];
        final sb = await deps.service.fetchSpaceBots(space);
        return sb
            .where((b) => isTool ? (b.isTool && !b.isSandbox) : b.isAgent)
            .where((b) => b.name.toLowerCase().contains(q))
            .skip(offset)
            .take(_pageSize)
            .map((b) => _SearchHit(b.name, avatar: b.avatar))
            .toList();
      case 'Workspaces':
        if (!widget.global) return const [];
        final spaces = await deps.service.searchSpaces(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final s in spaces)
            _SearchHit(
              s['name'] as String? ?? '',
              avatar: '${s['avatar'] ?? ''}',
            ),
        ];
      case 'Posts':
        if (!widget.global) return const [];
        final posts = await deps.service.searchPosts(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final p in posts)
            _SearchHit(_firstLine(p.body), id: p.id, payload: p),
        ];
      case 'Messages':
        if (space.isEmpty) return const [];
        final msgs = await deps.service.searchSpaceMessages(
          space,
          query: q,
          limit: _pageSize,
          offset: offset,
        );
        return titles(
          msgs
              .map((m) => m['body'] as String? ?? '')
              .where((n) => n.isNotEmpty),
        );
      case 'Media':
      case 'Documents':
      case 'Links':
      case 'GIFs':
        if (space.isEmpty) return const [];
        final files = await deps.service.fetchFiles(
          space,
          limit: _pageSize,
          offset: offset,
        );
        // Each file shows as its own card: a player, a picture, a link or
        // a document.
        return [
          for (final f in files)
            if (_fileMatchesSection(f, widget.section))
              _SearchHit(
                f['name'] as String? ?? 'file',
                id: '${f['file_id'] ?? f['id'] ?? ''}',
                payload: UploadedFile.fromJson(f),
              ),
        ].where((h) => h.title.toLowerCase().contains(q)).toList();
      default:
        return const [];
    }
  }

  static String _feedScope(String section) => switch (section) {
    'Spaces' => 'Your spaces and public spaces',
    'Posts' => 'Posts of the people you follow and your spaces',
    'Chats' => 'Your direct chats, by who they are with',
    'Agents' || 'Apps' => 'From the market',
    _ => 'Discover across the platform',
  };

  static bool _fileMatchesSection(Map<String, dynamic> file, String section) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (section) {
      case 'Media':
        return (mime.startsWith('image/') && mime != 'image/gif') ||
            mime.startsWith('video/') ||
            mime.startsWith('audio/');
      case 'Documents':
        return mime.contains('pdf') ||
            mime.contains('text') ||
            mime.contains('markdown') ||
            mime.contains('doc');
      case 'Links':
        return mime.contains('html') || mime.contains('url');
      case 'GIFs':
        return mime == 'image/gif';
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final count = _loading ? null : _items.length;
    final deps = widget.dependencies;
    // The results that are rows (not posts or files) share one card.
    final rows = _items
        .where((h) => h.payload is! SocialPost && h.payload is! UploadedFile)
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(_sectionIcon(section), size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      widget.feed
                          ? _feedScope(section)
                          : widget.global
                          ? 'Discover across the platform'
                          : 'Results from ${widget.workspace} workspace',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (count != null)
                Chip(
                  avatar: const Icon(Icons.auto_awesome_rounded, size: 13),
                  label: Text(
                    '$count found',
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_loading) return const SkeletonList();
              if (_items.isEmpty) {
                return const PanelEmpty(
                  icon: Icons.search_off_rounded,
                  title: 'No matching results',
                  message: 'Try another query or clear filters.',
                );
              }
              return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return const SkeletonListTile();
                  }
                  final hit = _items[index];
                  final payload = hit.payload;
                  // A post shows in full, as the feed shows it.
                  if (payload is SocialPost && deps != null) {
                    return _SearchPostCard(
                      key: ValueKey('post-${payload.id}'),
                      post: payload,
                      dependencies: deps,
                    );
                  }
                  // A file shows as its own card: a player, a picture, a link
                  // or a document.
                  if (payload is UploadedFile && deps != null) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SearchMediaCard(
                        file: payload,
                        service: deps.service,
                      ),
                    );
                  }
                  // People, agents, apps, spaces and messages sit together on
                  // one card, a row each.
                  final first = identical(rows.first, hit);
                  final last = identical(rows.last, hit);
                  final r = Radius.circular(AppShape.cardOf(context) - 2);
                  return Container(
                    margin: EdgeInsets.only(bottom: last ? 10 : 0),
                    padding: EdgeInsets.fromLTRB(
                      8,
                      first ? 8 : 0,
                      8,
                      last ? 8 : 0,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.vertical(
                        top: first ? r : Radius.zero,
                        bottom: last ? r : Radius.zero,
                      ),
                    ),
                    child: _SearchResultCard(
                      section: section,
                      title: hit.title,
                      avatar: hit.avatar,
                      subtitle: hit.subtitle,
                      feed: widget.feed,
                      spaceId: widget.spaceId,
                      index: index,
                      onOpen: widget.feed ? _opener(hit) : null,
                      dependencies: widget.dependencies,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A post found by search, in full as the feed shows it; liking it here
/// likes it.
class _SearchPostCard extends StatefulWidget {
  const _SearchPostCard({
    super.key,
    required this.post,
    required this.dependencies,
  });
  final SocialPost post;
  final AppDependencies dependencies;

  @override
  State<_SearchPostCard> createState() => _SearchPostCardState();
}

class _SearchPostCardState extends State<_SearchPostCard> {
  late SocialPost _post = widget.post;
  bool _deleted = false;

  Future<void> _toggleLike() async {
    final was = _post;
    final liked = !was.likedByMe;
    setState(
      () => _post = was.withLike(
        likes: liked ? was.likes + 1 : (was.likes > 0 ? was.likes - 1 : 0),
        likedByMe: liked,
      ),
    );
    try {
      if (liked) {
        await widget.dependencies.service.likePost(was.id);
      } else {
        await widget.dependencies.service.unlikePost(was.id);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _post = was);
    }
  }

  @override
  Widget build(BuildContext context) => _deleted
      ? const SizedBox.shrink()
      : FeedPostCard(
          post: feedPostFromServer(_post),
          dependencies: widget.dependencies,
          onToggleLike: _toggleLike,
          onEdited: (body) => setState(
            () => _post = _post.copyWith(body: body, editedAt: DateTime.now()),
          ),
          onDeleted: () => setState(() => _deleted = true),
        );
}

/// A file found by search, on a card made for its kind: a video under a
/// play button, audio with its waveform, a picture or GIF, a link or a
/// document; with its name and when it was shared.
class _SearchMediaCard extends StatelessWidget {
  const _SearchMediaCard({required this.file, required this.service});
  final UploadedFile file;
  final AsemanService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = FileType.of(file.name);
    final kind = file.isGif
        ? 'GIF'
        : file.isImage
        ? 'Image'
        : file.isVideo
        ? 'Video'
        : file.isPlayableAudio
        ? 'Audio'
        : type.kind.name[0].toUpperCase() + type.kind.name.substring(1);
    final when = file.createdAt == null ? '' : _timeAgo(file.createdAt!);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.cardOf(context)- 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    file.isVideo
                        ? Icons.movie_rounded
                        : file.isPlayableAudio
                        ? Icons.graphic_eq_rounded
                        : file.isGif
                        ? Icons.gif_box_rounded
                        : file.isImage
                        ? Icons.image_rounded
                        : type.icon,
                    size: 16,
                    color: type.color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    [
                      kind,
                      file.humanSize,
                      if (when.isNotEmpty) when,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AttachmentBubble(
                file: file,
                headers: service.authHeaders(),
                resolveUrl: (f) => service.fileContentUrl(f.id),
                fetchBytes: (f) => service.downloadFile(f.id),
                maxWidth: math.min(box.maxWidth, 520),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One search result as a compact row: its icon, name and a line about it.
class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.section,
    required this.title,
    this.subtitle,
    this.feed = false,
    required this.index,
    this.onOpen,
    this.spaceId = '',
    this.avatar = '',
    this.dependencies,
  });
  final String section, title;

  /// The picture of what was found, shown over its icon ("" if none).
  final String avatar;

  /// What the result says about itself (the generic blurb otherwise).
  final String? subtitle;

  /// A feed search result: [onOpen] opens it.
  final bool feed;
  final VoidCallback? onOpen;
  final int index;
  final String spaceId;
  final AppDependencies? dependencies;

  VoidCallback? _open(BuildContext context) => feed
      ? onOpen
      : _hasProfile
      ? () => _openEntityProfile(context, section, title, dependencies, spaceId)
      : null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ThemeRoles.identity(context, '$section::$title');
    final open = _open(context);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              section == 'Agents' || section == 'Apps'
                  ? BotAvatar.fromFields(
                      id: title,
                      name: title,
                      kind: section == 'Apps' ? 'tool' : 'agent',
                      avatar: avatar,
                      radius: 18,
                      userId: dependencies
                              ?.sessionController.session?.accountId ??
                          '',
                    )
                  : Builder(builder: (context) {
                      const radius = 18.0;
                      final size = radius * 2;
                      final corners = context.avatarBorderRadius(size);
                      final picture = Avatars.of(avatar);
                      return HaloRing(
                        accent: color,
                        borderRadius: corners,
                        child: AvatarFace(
                          size: size,
                          borderRadius: corners,
                          backgroundColor: color.withValues(alpha: .18),
                          foregroundImage: picture,
                          onImageError:
                              picture == null ? null : (_, __) {},
                          child: Icon(
                            _sectionIcon(section),
                            color: color,
                            size: 18,
                          ),
                        ),
                      );
                    }),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? _description(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (open != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _description() => switch (section) {
    'Users' => 'Person on Aseman',
    'Agents' => 'Agent',
    'Apps' => 'App',
    'Rooms' => 'Room',
    'Workspaces' || 'Spaces' => 'Space',
    'Documents' => 'Document',
    'Messages' => 'Message',
    'Links' => 'Link',
    'Media' => 'Media',
    'GIFs' => 'GIF',
    'Posts' => 'Post',
    _ => 'Result',
  };
  bool get _hasProfile => const [
    'Users',
    'Agents',
    'Apps',
    'Workspaces',
    'Spaces',
    'Rooms',
  ].contains(section);
}

/// A post found by the feed's search, rendered in full.
class _PostPreview extends StatelessWidget {
  const _PostPreview({required this.post, this.dependencies});
  final SocialPost post;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 8, 4),
          child: Row(
            children: [
              Icon(Icons.article_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Post',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 15, height: 1.45),
              child: RichPostContent(
                post.body,
                headers: dependencies?.service.authHeaders() ?? const {},
                resolveUrl: dependencies?.service.resolveContentUrl,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Opens the profile of the account [accountId] (known as [handle]): who
/// they are, their posts, and following them.
void showAccountProfile(
  BuildContext context,
  AppDependencies dependencies, {
  required String accountId,
  String handle = '',
}) => _openEntityProfile(context, 'Users', handle, dependencies, '', accountId);

void _openEntityProfile(
  BuildContext context,
  String section,
  String title, [
  AppDependencies? dependencies,
  String spaceId = '',
  String entityId = '',
]) {
  final profile = _EntityProfileScreen(
    section: section == 'Spaces' ? 'Workspaces' : section,
    title: title,
    dependencies: dependencies,
    spaceId: spaceId,
    entityId: entityId,
  );
  showFloatingPanel(
    context,
    profile,
    maxWidth: 700,
    maxHeight: 760,
    barrierLabel: 'Close profile',
  );
}

class _EntityProfileScreen extends StatefulWidget {
  const _EntityProfileScreen({
    required this.section,
    required this.title,
    this.dependencies,
    this.spaceId = '',
    this.entityId = '',
  });
  final String section, title;
  final AppDependencies? dependencies;

  /// The entity's id when a search result knows it (a bot, an account or a
  /// space): the profile loads it directly instead of matching [title].
  final String entityId;

  /// The workspace the profile was opened from (used to install agents/tools).
  final String spaceId;
  @override
  State<_EntityProfileScreen> createState() => _EntityProfileScreenState();
}

class _EntityProfileScreenState extends State<_EntityProfileScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Resolved entity profiles (real backend data).
  BotProfile? _bot;
  UserProfile? _user;
  SpaceProfile? _space;
  RoomProfile? _room;
  List<SocialPost> _posts = const [];
  bool _inSpace =
      false; // agent/tool already installed in the current workspace

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = deps.service;
      switch (widget.section) {
        case 'Agents':
        case 'Apps':
          if (widget.entityId.isNotEmpty) {
            final prof = await service.fetchBotProfile(widget.entityId);
            if (mounted) {
              setState(() {
                _bot = prof;
                _loading = false;
              });
            }
            return;
          }
          var bots = await service.fetchBots();
          var bot = bots
              .where(
                (b) => widget.section == 'Agents'
                    ? b.isAgent
                    : (b.isTool && !b.isSandbox),
              )
              .where((b) => b.name == widget.title)
              .firstOrNull;
          // Agents/tools opened from a workspace tab are space bots; resolve
          // them from the workspace too when the global list has no match.
          if (bot == null && widget.spaceId.isNotEmpty) {
            try {
              final sb = await service.fetchSpaceBots(widget.spaceId);
              bot = sb
                  .where(
                    (b) => widget.section == 'Agents'
                        ? b.isAgent
                        : (b.isTool && !b.isSandbox),
                  )
                  .where((b) => b.name == widget.title)
                  .firstOrNull;
            } catch (_) {}
          }
          if (bot != null) {
            final resolved = bot;
            final prof = await service.fetchBotProfile(resolved.id);
            var inSpace = false;
            if (widget.spaceId.isNotEmpty) {
              try {
                final sb = await service.fetchSpaceBots(widget.spaceId);
                inSpace = sb.any(
                  (b) =>
                      b.id == resolved.id || b.accountId == resolved.accountId,
                );
              } catch (_) {}
            }
            if (mounted) {
              setState(() {
                _bot = prof;
                _inSpace = inSpace;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Users':
          final String? accountId;
          if (widget.entityId.isNotEmpty) {
            accountId = widget.entityId;
          } else {
            final users = await service.searchUsers(widget.title, limit: 10);
            accountId = users
                .where(
                  (u) =>
                      u.handle == widget.title ||
                      u.handle.contains(widget.title),
                )
                .firstOrNull
                ?.id;
          }
          if (accountId != null) {
            final prof = await service.fetchUserProfile(accountId);
            final posts = await service.fetchUserPosts(accountId);
            if (mounted) {
              setState(() {
                _user = prof;
                _posts = posts;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Workspaces':
          final String? spaceId;
          if (widget.entityId.isNotEmpty) {
            spaceId = widget.entityId;
          } else {
            final spaces = await service.fetchSpaces();
            spaceId = spaces
                .where(
                  (s) =>
                      s.name == widget.title || s.name.contains(widget.title),
                )
                .firstOrNull
                ?.id;
          }
          if (spaceId != null) {
            final prof = await service.fetchSpaceProfile(spaceId);
            if (mounted) {
              setState(() {
                _space = prof;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Rooms':
          if (widget.entityId.isNotEmpty) {
            final prof = await service.fetchRoomProfile(widget.entityId);
            if (mounted) {
              setState(() {
                _room = prof;
                _loading = false;
              });
            }
            return;
          }
          // Look in the workspace the room was opened from before the rest.
          final spaceIds = [
            if (widget.spaceId.isNotEmpty) widget.spaceId,
            for (final sp in await service.fetchSpaces())
              if (sp.id != widget.spaceId) sp.id,
          ];
          for (final spaceId in spaceIds) {
            final rooms = await service.fetchRoomsForSpace(spaceId);
            final room = rooms
                .where(
                  (r) =>
                      r.name == widget.title || r.name.contains(widget.title),
                )
                .firstOrNull;
            if (room != null) {
              final prof = await service.fetchRoomProfile(room.id);
              if (mounted) {
                setState(() {
                  _room = prof;
                  _loading = false;
                });
              }
              return;
            }
          }
          if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        default:
          if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _performAction() async {
    final deps = widget.dependencies;
    if (deps == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (widget.section == 'Users') {
        final u = _user;
        if (u == null) return;
        if (u.amFollowing) {
          await deps.service.unfollowUser(u.id);
          _snack('Unfollowed @${u.handle}');
        } else {
          await deps.service.followUser(u.id);
          _snack('Following @${u.handle}');
        }
        final updated = await deps.service.fetchUserProfile(u.id);
        if (mounted) setState(() => _user = updated);
        return;
      }
      if (widget.section == 'Agents' || widget.section == 'Apps') {
        final b = _bot;
        if (b == null) return;
        if (_inSpace) {
          _snack('${b.name} is already in this workspace');
          return;
        }
        if (widget.spaceId.isNotEmpty) {
          await deps.service.addBotToSpace(widget.spaceId, b.id);
          if (mounted) setState(() => _inSpace = true);
          _snack('Added ${b.name} to this workspace');
          if (b.kind == 'tool' && mounted) {
            await connectMcpToolIfNeeded(
              context,
              deps.service,
              botId: b.id,
              spaceId: widget.spaceId,
              name: b.name,
            );
          }
        } else if (b.listing.isNotEmpty) {
          await deps.service.installListing(
            b.listing['listing_id'] as String? ?? '',
          );
          if (mounted) setState(() => _inSpace = true);
          _snack('Installed ${b.name}');
        } else {
          _snack('Open a workspace to install ${b.name}');
        }
        return;
      }
      if (widget.section == 'Workspaces') {
        final s = _space;
        if (s == null) return;
        if (s.amMember) {
          _snack('You are already a member of ${s.name}');
          return;
        }
        await deps.service.joinSpace(s.id);
        if (mounted) {
          setState(
            () => _space = SpaceProfile(
              id: s.id,
              name: s.name,
              description: s.description,
              public: s.public,
              home: s.home,
              ownerId: s.ownerId,
              ownerHandle: s.ownerHandle,
              memberCount: s.memberCount + 1,
              agentCount: s.agentCount,
              roomCount: s.roomCount,
              rooms: s.rooms,
              postCount: s.postCount,
              fileCount: s.fileCount,
              amMember: true,
              metadata: s.metadata,
              avatar: s.avatar,
            ),
          );
        }
        _snack('Joined ${s.name}');
        return;
      }
      if (widget.section == 'Rooms') {
        final r = _room;
        if (r == null) return;
        if (r.amMember) {
          _snack('You are already a member of ${r.name}');
          return;
        }
        if (r.spaceId.isNotEmpty) {
          await deps.service.joinSpace(r.spaceId);
          if (mounted) {
            setState(
              () => _room = RoomProfile(
                id: r.id,
                name: r.name,
                topic: r.topic,
                spaceId: r.spaceId,
                spaceName: r.spaceName,
                memberCount: r.memberCount + 1,
                agentCount: r.agentCount,
                messageCount: r.messageCount,
                fileCount: r.fileCount,
                amMember: true,
                recentMessages: r.recentMessages,
              ),
            );
          }
          _snack('Joined ${r.spaceName}');
        }
        return;
      }
    } catch (e) {
      _snack('Action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get singular => switch (widget.section) {
    'Users' => 'Person',
    'Agents' => 'Agent',
    'Apps' => 'App',
    'Workspaces' => 'Workspace',
    'Rooms' => 'Room',
    _ => 'Profile',
  };

  /// The picture of the person, agent, app or workspace shown.
  String get _avatar => _user?.avatar ?? _bot?.avatar ?? _space?.avatar ?? '';

  bool get _loaded =>
      _user != null || _bot != null || _space != null || _room != null;

  /// The loaded entity's name, or the title it was opened with until then.
  String get _name {
    final name = _user?.name ?? _bot?.name ?? _space?.name ?? _room?.name ?? '';
    return name.isEmpty ? widget.title : name;
  }

  /// The line under the name: who the entity is, from its loaded profile.
  String get _subtitle {
    final u = _user;
    if (u != null) {
      return [
        '@${u.handle}',
        if (u.kind != 'user') u.kind,
        if (u.status != 'active') u.status,
      ].join(' · ');
    }
    final b = _bot;
    if (b != null) {
      return [
        if (b.vmType.isNotEmpty) b.vmType.toUpperCase(),
        if (b.ownerHandle.isNotEmpty) 'by @${b.ownerHandle}',
      ].join(' · ');
    }
    final s = _space;
    if (s != null) {
      return [
        s.public ? 'Public' : 'Private',
        if (s.ownerHandle.isNotEmpty) 'by @${s.ownerHandle}',
      ].join(' · ');
    }
    final r = _room;
    if (r != null && r.spaceName.isNotEmpty) return 'in ${r.spaceName}';
    return '';
  }

  /// The entity's own words about itself: a bio, description or topic.
  String get _about =>
      _user?.bio ??
      _bot?.description ??
      _space?.description ??
      _room?.topic ??
      '';

  IconData get icon => switch (widget.section) {
    'Users' => Icons.person_rounded,
    'Agents' => Icons.smart_toy_rounded,
    'Apps' => Icons.extension_rounded,
    'Workspaces' => Icons.hub_rounded,
    'Rooms' => Icons.forum_rounded,
    _ => Icons.category_rounded,
  };

  /// The primary action's label and whether it is already done.
  (String, bool)? get _action {
    final u = _user;
    if (u != null)
      return u.amFollowing ? ('Following', true) : ('Follow', false);
    final b = _bot;
    if (b != null)
      return _inSpace ? ('Added', true) : ('Add to workspace', false);
    final s = _space;
    if (s != null)
      return s.amMember ? ('Joined', true) : ('Join workspace', false);
    final r = _room;
    if (r != null) return r.amMember ? ('Joined', true) : ('Join room', false);
    return null;
  }

  List<(String, String, VoidCallback?)> get stats {
    final u = _user;
    final deps = widget.dependencies;
    if (u != null) {
      return [
        (
          '${u.followers}',
          'Followers',
          deps == null
              ? null
              : () => _showAccountList(context, deps, u.id, false),
        ),
        (
          '${u.following}',
          'Following',
          deps == null
              ? null
              : () => _showAccountList(context, deps, u.id, true),
        ),
        ('${_posts.length}', 'Posts', null),
      ];
    }
    final b = _bot;
    if (b != null) {
      return [
        (b.status.isEmpty ? '—' : b.status, 'Status', null),
        ('${b.installs}', 'Installs', null),
        (_fmtDuration(b.uptimeSec), 'Uptime', null),
      ];
    }
    final s = _space;
    if (s != null) {
      return [
        ('${s.memberCount}', 'Members', null),
        ('${s.roomCount}', 'Rooms', null),
        ('${s.postCount}', 'Posts', null),
      ];
    }
    final r = _room;
    if (r != null) {
      return [
        ('${r.memberCount}', 'Members', null),
        ('${r.agentCount}', 'Agents', null),
        ('${r.messageCount}', 'Messages', null),
      ];
    }
    return const [];
  }

  /// Shares the entity through the platform's share sheet, copying the
  /// text instead where there is none.
  Future<void> _share(BuildContext buttonContext) async {
    final u = _user;
    final text = u != null
        ? '$_name (@${u.handle}) on Aseman'
        : '$singular "$_name" on Aseman';
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _about.isEmpty ? text : '$text\n\n$_about',
          subject: text,
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      _snack('Sharing is not available here; the profile was copied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final action = _action;
    final subtitle = _subtitle;
    final about = _about;
    final stats = this.stats;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        Row(
          children: [
            MiniTag(singular.toUpperCase(), scheme.primary),
            const Spacer(),
            if (_loaded)
              Builder(
                builder: (buttonContext) => IconButton(
                  tooltip: 'Share profile',
                  onPressed: () => _share(buttonContext),
                  icon: const Icon(Icons.ios_share_rounded, size: 19),
                ),
              ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ThemeChrome.cardFillColor(context),
            borderRadius: ThemeChrome.softCardCorners(context, AppShape.card),
          ),
          child: Column(
            children: [
              Container(
                height: 104,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primary, scheme.tertiary],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -16,
                      top: -36,
                      child: Icon(
                        icon,
                        size: 160,
                        color: Colors.white.withValues(alpha: .15),
                      ),
                    ),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -31),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _bot != null
                              ? BotAvatar(
                                  bot: Bot(
                                    id: _bot!.id,
                                    ownerId: _bot!.ownerId,
                                    accountId: '',
                                    name: _bot!.name,
                                    kind: _bot!.kind.isEmpty
                                        ? (widget.section == 'Apps'
                                            ? 'tool'
                                            : 'agent')
                                        : _bot!.kind,
                                    vmType: _bot!.vmType,
                                    status: _bot!.status,
                                    avatar: _bot!.avatar,
                                  ),
                                  radius: 31,
                                  userId: widget.dependencies
                                          ?.sessionController
                                          .session
                                          ?.accountId ??
                                      '',
                                )
                              : Builder(builder: (context) {
                                  const size = 62.0;
                                  final corners =
                                      context.avatarBorderRadius(size);
                                  return HaloRing(
                                    pad: 3,
                                    borderRadius: corners,
                                    child: AvatarFace(
                                      size: size,
                                      borderRadius: corners,
                                      backgroundColor:
                                          scheme.surfaceContainerHighest,
                                      child: AvatarPicture(
                                        avatar: _avatar,
                                        size: size,
                                        borderRadius: corners,
                                        fallback: Center(
                                            child: Icon(icon,
                                                size: 31,
                                                color: scheme.primary)),
                                      ),
                                    ),
                                  );
                                }),
                          const Spacer(),
                          if (action != null)
                            FilledButton.icon(
                              onPressed: _busy ? null : _performAction,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      action.$2
                                          ? Icons.check_rounded
                                          : Icons.add_rounded,
                                      size: 17,
                                    ),
                              label: Text(action.$1),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (_loading) ...[
                        const SizedBox(height: 6),
                        const SkeletonParagraph(lines: 2, lineHeight: 10),
                      ] else ...[
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (about.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            about,
                            style: const TextStyle(height: 1.4, fontSize: 12),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: AppColors.dangerOf(context), fontSize: 12),
            ),
          ),
        if (_loading)
          const SkeletonBox(height: 58, radius: 15)
        else if (stats.isNotEmpty)
          Row(
            children: [
              for (final (i, stat) in stats.indexed)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: i == stats.length - 1 ? 0 : 7,
                    ),
                    child: ProfileStat(stat.$1, stat.$2, onTap: stat.$3),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 18),
        if (_user case final u?)
          _PersonProfileDetail(
            user: u,
            posts: _posts,
            dependencies: widget.dependencies,
          )
        else if (_bot case final b?)
          _BotProfileDetail(bot: b, dependencies: widget.dependencies)
        else if (_space case final s?)
          _WorkspaceProfileDetail(space: s, dependencies: widget.dependencies)
        else if (_room case final r?)
          _RoomProfileDetail(room: r, dependencies: widget.dependencies),
      ],
    );
  }

  static void _showAccountList(
    BuildContext context,
    AppDependencies deps,
    String userId,
    bool following,
  ) {
    final title = following ? 'Following' : 'Followers';
    showAppDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 360,
          height: 420,
          child: FutureBuilder<List<AccountSummary>>(
            future: following
                ? deps.service.fetchFollowing(accountId: userId)
                : deps.service.fetchFollowers(accountId: userId),
            builder: (ctx, snap) {
              final list = snap.data ?? const <AccountSummary>[];
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      snap.connectionState == ConnectionState.done
                          ? '$title · ${list.length}'
                          : title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: snap.connectionState != ConnectionState.done
                        ? const Center(child: CircularProgressIndicator())
                        : list.isEmpty
                        ? Center(
                            child: Text(
                              'None yet',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              onTap: () {
                                Navigator.pop(ctx);
                                showAccountProfile(
                                  context,
                                  deps,
                                  accountId: list[i].id,
                                  handle: list[i].handle,
                                );
                              },
                              leading: Builder(builder: (context) {
                                const radius = 16.0;
                                final size = radius * 2;
                                final corners =
                                    context.avatarBorderRadius(size);
                                final picture = Avatars.of(list[i].avatar);
                                return HaloRing(
                                  identity: HaloRingCache.person(list[i].id),
                                  borderRadius: corners,
                                  child: AvatarFace(
                                    size: size,
                                    borderRadius: corners,
                                    foregroundImage: picture,
                                    onImageError: picture == null
                                        ? null
                                        : (_, __) {},
                                    backgroundColor:
                                        ThemeRoles.wellFill(context),
                                    child: Text(
                                      list[i].handle.isEmpty
                                          ? '?'
                                          : list[i].handle[0].toUpperCase(),
                                      style: TextStyle(
                                        color: ThemeRoles.wellInk(context),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                              title: Text(
                                '@${list[i].handle}',
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                list[i].kind,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ProfileDetailCard extends StatelessWidget {
  const _ProfileDetailCard(this.title, this.icon, this.child);
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: GlassSurface(
      borderRadius: ThemeChrome.softCardCorners(context, AppShape.inner),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    ),
  );
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _PersonProfileDetail extends StatelessWidget {
  const _PersonProfileDetail({
    required this.user,
    required this.posts,
    this.dependencies,
  });
  final UserProfile user;
  final List<SocialPost> posts;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) => _ProfileDetailCard(
    'Recent posts',
    Icons.dynamic_feed_rounded,
    posts.isEmpty
        ? const _EmptyNote('No posts yet.')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in posts.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 12, height: 1.45),
                        child: RichPostContent(
                          p.body,
                          headers:
                              dependencies?.service.authHeaders() ?? const {},
                          resolveUrl: dependencies?.service.resolveContentUrl,
                        ),
                      ),
                      Text(
                        _timeAgo(p.createdAt),
                        style: TextStyle(
                          fontSize: 8,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
  );
}

/// The detail of an agent or an app (tool): both are bots on a VM.
class _BotProfileDetail extends StatelessWidget {
  const _BotProfileDetail({required this.bot, this.dependencies});
  final BotProfile bot;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    final cpu = bot.resources['cpu'] as num?;
    final ram = bot.resources['memory_mb'] as num?;
    final disk = bot.resources['disk_mb'] as num?;
    final costPerMinute = bot.cost['per_minute'] as num?;
    final category = bot.listing['category'] as String? ?? '';
    return Column(
      children: [
        _ProfileDetailCard(
          'Runtime',
          Icons.monitor_heart_rounded,
          Row(
            children: [
              _ResourceCell(
                'VM',
                bot.vmType.isEmpty ? '—' : bot.vmType.toUpperCase(),
              ),
              _ResourceCell('Frontend', bot.hasFrontend ? 'Elpian' : 'None'),
              _ResourceCell('Image', bot.imageRef.isEmpty ? '—' : bot.imageRef),
            ],
          ),
        ),
        if (cpu != null || ram != null || disk != null)
          _ProfileDetailCard(
            'Resources',
            Icons.memory_rounded,
            Row(
              children: [
                if (cpu != null) _ResourceCell('CPU', '$cpu vCPU'),
                if (ram != null) _ResourceCell('RAM', '$ram MB'),
                if (disk != null) _ResourceCell('Disk', '$disk MB'),
              ],
            ),
          ),
        _ProfileDetailCard(
          'Usage',
          Icons.analytics_rounded,
          Row(
            children: [
              _ResourceCell('Tokens', '${bot.tokens}'),
              if (costPerMinute != null)
                _ResourceCell('Cost/min', '$costPerMinute'),
            ],
          ),
        ),
        if (bot.listing.isNotEmpty)
          _ProfileDetailCard(
            'Marketplace',
            Icons.storefront_rounded,
            Row(
              children: [
                _ResourceCell(
                  'Price',
                  bot.price == 0 ? 'Free' : '${bot.price}',
                ),
                if (category.isNotEmpty) _ResourceCell('Category', category),
              ],
            ),
          ),
        if (bot.entities.isNotEmpty)
          _ProfileDetailCard(
            'Entities',
            Icons.folder_copy_rounded,
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final key in bot.entities) Chip(label: Text(key)),
              ],
            ),
          ),
        if (bot.ownerHandle.isNotEmpty)
          _ProfileDetailCard(
            'Owner',
            Icons.person_outline_rounded,
            InkWell(
              onTap: deps == null || bot.ownerId.isEmpty
                  ? null
                  : () => showAccountProfile(
                      context,
                      deps,
                      accountId: bot.ownerId,
                      handle: bot.ownerHandle,
                    ),
              child: Text(
                '@${bot.ownerHandle}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspaceProfileDetail extends StatelessWidget {
  const _WorkspaceProfileDetail({required this.space, this.dependencies});
  final SpaceProfile space;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    return Column(
      children: [
        _ProfileDetailCard(
          'Rooms',
          Icons.grid_view_rounded,
          space.rooms.isEmpty
              ? const _EmptyNote('No rooms yet.')
              : LayoutBuilder(
                  builder: (context, box) {
                    final columns = box.maxWidth < 420 ? 2 : 3;
                    return GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: columns,
                      mainAxisSpacing: 7,
                      crossAxisSpacing: 7,
                      childAspectRatio: 1.8,
                      children: [
                        for (final r in space.rooms)
                          _WorkspaceRoomPreview(
                            r,
                            Icons.forum_outlined,
                            onTap: () => _openEntityProfile(
                              context,
                              'Rooms',
                              r,
                              deps,
                              space.id,
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
        _ProfileDetailCard(
          'Community',
          Icons.groups_rounded,
          Row(
            children: [
              _ResourceCell('Agents', '${space.agentCount}'),
              _ResourceCell('Files', '${space.fileCount}'),
              if (space.home) const _ResourceCell('Home', 'Yes'),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkspaceRoomPreview extends StatelessWidget {
  const _WorkspaceRoomPreview(this.label, this.icon, {this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final corners = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      borderRadius: corners,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
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

class _RoomProfileDetail extends StatelessWidget {
  const _RoomProfileDetail({required this.room, this.dependencies});
  final RoomProfile room;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    return Column(
      children: [
        _ProfileDetailCard(
          'Workspace',
          Icons.hub_rounded,
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: room.spaceId.isEmpty
                      ? null
                      : () => _openEntityProfile(
                          context,
                          'Workspaces',
                          room.spaceName,
                          deps,
                          '',
                          room.spaceId,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.spaceName.isEmpty ? '—' : room.spaceName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text('Workspace', style: TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              ),
              _ResourceCell('Files', '${room.fileCount}'),
            ],
          ),
        ),
        _ProfileDetailCard(
          'Recent room activity',
          Icons.forum_outlined,
          room.recentMessages.isEmpty
              ? const _EmptyNote('No messages yet.')
              : Column(
                  children: [
                    for (final m in room.recentMessages)
                      _RoomActivityRow(
                        Icons.chat_bubble_outline_rounded,
                        '${_sender(m)}: ${m['body'] as String? ?? ''}',
                        _timeAgo(
                          DateTime.tryParse(m['created_at'] as String? ?? '') ??
                              DateTime.now(),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  static String _sender(Map<String, dynamic> m) {
    final handle = m['sender_handle'] as String? ?? '';
    return handle.isNotEmpty
        ? '@$handle'
        : _short(m['sender_id'] as String? ?? '?', 8);
  }
}

class _ResourceCell extends StatelessWidget {
  const _ResourceCell(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 9)),
      ],
    ),
  );
}

class _RoomActivityRow extends StatelessWidget {
  const _RoomActivityRow(this.icon, this.label, this.time);
  final IconData icon;
  final String label, time;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 10))),
        Text(time, style: const TextStyle(fontSize: 8)),
      ],
    ),
  );
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
