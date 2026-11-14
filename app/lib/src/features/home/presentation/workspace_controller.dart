import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../desk/data/desk_api.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../desk/presentation/tool_avatar.dart';

/// Owns workspace session data and async loaders (spaces, rooms, bots,
/// messages). UI (animations, dialogs, BuildContext) stays on the screen.
class WorkspaceController extends ChangeNotifier {
  WorkspaceController({
    required this.dependencies,
    required String initialWorkspace,
    this.initialSpaceId,
    this.initialRoom,
    this.initialRoomId,
    this.onWorkspaceChanged,
    this.onAttachGadgets,
  }) : workspace = initialWorkspace,
       activeSpaceId = initialSpaceId ?? '',
       deskController = DeskController(
         DeskApi.of(dependencies.service),
       );

  static const hallRoom = 'Hall room';

  final AppDependencies dependencies;

  /// Preferred id when opening a space (chats list). Wins over name lookup.
  final String? initialSpaceId;
  final String? initialRoom;
  final String? initialRoomId;
  final ValueChanged<String>? onWorkspaceChanged;

  /// Called when the gadgets edge manager should point at this workspace.
  /// The screen supplies this so it can read [GadgetsScope] from context.
  final VoidCallback? onAttachGadgets;

  AsemanService get _service => dependencies.service;

  String workspace;

  /// Id of the space currently shown; used so rooms/messages never bind to
  /// another project that happens to share a name.
  String activeSpaceId;
  String? room;
  int libraryTab = 0;

  /// True after the room requested at open has been applied (or ruled out).
  bool appliedInitialRoom = false;

  /// The workspace file opened last, highlighted in the Files tab.
  String openFilePath = '';
  int mobilePage = 0;
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
  final Map<String, RoomThread> roomThreads = {};
  final Set<String> _loadingOlder = {};

  /// The desk of the room on screen: tools' card windows.
  final DeskController deskController;

  Timer? _roomTimer;
  int fileRevision = 0;
  String workingAgent = '';
  String workingDetail = '';
  final Set<String> _messageLoads = {};

  /// Whether each app of a workspace needs each person's own account, and
  /// whether the caller has connected theirs, by bot id.
  final Map<String, Map<String, ({String auth, bool connected, String name})>>
  appConnections = {};

  bool _disposed = false;

  /// Bots explicitly installed in the current workspace.
  List<Bot> get spaceBots => _spaceBots[workspace] ?? const [];

  Map<String, ({String auth, bool connected, String name})>
  get currentAppConnections => appConnections[workspace] ?? const {};

  String get scopeKey => '$workspace/${room ?? 'home'}';

  List<String> get rooms {
    if (currentRooms.isNotEmpty) {
      return [hallRoom, ...currentRooms.map((r) => r.name)];
    }
    return const [hallRoom];
  }

  List<RoomMessage> get chatMessages => roomMessages[scopeKey] ?? const [];
  bool get chatHasMore => roomHasMore[scopeKey] ?? false;
  bool get chatLoadingOlder =>
      currentRoomId.isNotEmpty &&
      _loadingOlder.contains(
        'older:${spaceFor(workspace)?.id ?? ''}/$chatRoomId',
      );

  String get currentRoomId {
    if (room == null) return '';
    final matches = currentRooms.where((r) => r.name == room).toList();
    return matches.isEmpty ? '' : matches.first.id;
  }

  /// Where a room's open conversation lives: its open thread, else the room.
  String messageRoom(String roomId) => roomThreads[roomId]?.id ?? roomId;

  /// The open room's conversation (its thread, else the room itself).
  String get chatRoomId =>
      currentRoomId.isEmpty ? '' : messageRoom(currentRoomId);

  bool get canManageTasks {
    final space = spaceFor(workspace);
    final account = dependencies.sessionController.session?.accountId;
    return space != null &&
        account != null &&
        (space.isOwner || space.role == 'admin' || space.ownerId == account);
  }

  Workspace? spaceFor(String name) {
    if (activeSpaceId.isNotEmpty) {
      for (final s in spaces) {
        if (s.id == activeSpaceId) return s;
      }
    }
    for (final s in spaces) {
      if (s.name == name) return s;
    }
    return null;
  }

  Workspace? spaceById(String id) {
    if (id.isEmpty) return null;
    for (final s in spaces) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Starts initial loads and the room-message poll timer.
  void start() {
    unawaited(loadWorkspaces());
    unawaited(loadBots());
    unawaited(loadSpaceBots());
    _roomTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (room != null) unawaited(loadRoomMessages(room!));
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _roomTimer?.cancel();
    deskController.dispose();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadBots() async {
    try {
      final loaded = await _service.fetchBots();
      if (_disposed) return;
      bots = loaded;
      _notify();
    } catch (_) {}
  }

  Future<void> loadSpaceBots() async {
    final requestedWorkspace = workspace;
    final sp = spaceFor(workspace);
    if (sp == null) return;
    try {
      final list = await _service.fetchSpaceBots(sp.id);
      ToolAvatar.remember({for (final b in list) b.id: b.avatar});
      if (_disposed) return;
      _spaceBots[requestedWorkspace] = list;
      _notify();
    } catch (_) {}
    try {
      final connections = await _service.toolConnections(sp.id);
      if (_disposed) return;
      appConnections[requestedWorkspace] = connections;
      _notify();
    } catch (_) {}
  }

  /// Adds a bot to the current workspace (no dialogs). Returns an error
  /// message on failure, or null on success.
  Future<String?> addBotToWorkspace(Bot bot) async {
    final sp = spaceFor(workspace);
    if (sp == null) return null;
    try {
      await _service.addBotToSpace(sp.id, bot.id);
      await loadSpaceBots();
      return null;
    } catch (e) {
      return 'Add failed: $e';
    }
  }

  /// Removes a bot from the current workspace. Returns an error message on
  /// failure, or null on success.
  Future<String?> removeBotFromWorkspace(Bot bot) async {
    final sp = spaceFor(workspace);
    if (sp == null) return null;
    try {
      await _service.removeBotFromSpace(sp.id, bot.id);
      await loadSpaceBots();
      return null;
    } catch (e) {
      return 'Remove failed: $e';
    }
  }

  Future<void> loadWorkspaces() async {
    try {
      final sp = await _service.fetchSpaces();
      if (_disposed) return;
      spaces = sp;
      await _resolveActiveSpace();
      if (_disposed) return;
      _notify();
      onAttachGadgets?.call();
      await loadRooms();
      attachDesk();
      await loadSpaceBots();
    } catch (_) {
      // Spaces failed to load; the workspace keeps its current name.
    }
  }

  /// Bind [workspace] / [activeSpaceId] to the requested project. Prefer id
  /// (from chats); only fall back to home when nothing was requested.
  Future<void> _resolveActiveSpace() async {
    final wantId = (activeSpaceId.isNotEmpty
            ? activeSpaceId
            : (initialSpaceId ?? ''))
        .trim();
    if (wantId.isNotEmpty) {
      var match = spaceById(wantId);
      if (match == null) {
        // Not in the list (stale cache / kind gap): fetch that project alone.
        try {
          match = await _service.fetchSpace(wantId);
          if (_disposed) return;
          spaces = [...spaces.where((s) => s.id != match!.id), match];
        } catch (_) {
          match = null;
        }
      }
      if (match != null) {
        activeSpaceId = match.id;
        workspace = match.name;
        return;
      }
    }
    final byName = spaces.where((s) => s.name == workspace).toList();
    if (byName.isNotEmpty) {
      activeSpaceId = byName.first.id;
      return;
    }
    // No target matched — only then land on home / first. Never rewrite a
    // successfully resolved id to another project.
    if (spaces.isEmpty) return;
    if (wantId.isNotEmpty) return;
    final home = spaces.firstWhere((s) => s.home, orElse: () => spaces.first);
    activeSpaceId = home.id;
    workspace = home.name;
  }

  /// Refreshes the spaces list without switching workspace.
  Future<void> refreshSpaces() async {
    try {
      final sp = await _service.fetchSpaces();
      if (_disposed) return;
      spaces = sp;
      _notify();
    } catch (_) {}
  }

  Future<void> loadRooms() async {
    final sp = spaceFor(workspace);
    if (sp == null) return;
    try {
      final rooms = await _service.fetchRoomsForSpace(sp.id);
      if (_disposed || spaceFor(workspace)?.id != sp.id) return;
      currentRooms = rooms;
      roomMessages.removeWhere((key, _) => key.startsWith('$workspace/'));
      roomHasMore.removeWhere((key, _) => key.startsWith('$workspace/'));
      final openedInitial = applyInitialRoom(rooms);
      _notify();
      attachDesk();
      if (openedInitial && room != null) unawaited(loadRoomMessages(room!));
    } catch (_) {}
  }

  /// Selects the room this workspace was opened with, once, after its rooms
  /// have loaded. The id matches across a rename; the name is the fallback.
  bool applyInitialRoom(List<WorkspaceRoom> rooms) {
    if (appliedInitialRoom) return false;
    appliedInitialRoom = true;
    final id = initialRoomId ?? '';
    final name = initialRoom ?? '';
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
    workingAgent = '';
    workingDetail = '';
    return true;
  }

  Future<void> loadRoomMessages(String roomName) async {
    final sp = spaceFor(workspace);
    if (sp == null) return;
    final r = currentRooms.where((x) => x.name == roomName).toList();
    if (r.isEmpty) return;
    final requestedWorkspace = workspace;
    final requestedScope = '$requestedWorkspace/$roomName';
    final thread = messageRoom(r.first.id);
    final requestKey = '${sp.id}/$thread';
    if (!_messageLoads.add(requestKey)) return;
    try {
      final res = await _service.fetchRoomMessages(sp.id, thread);
      if (_disposed ||
          workspace != requestedWorkspace ||
          room != roomName ||
          currentRoomId != r.first.id ||
          messageRoom(r.first.id) != thread) {
        return;
      }
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
          workingAgent != res.working ||
          workingDetail != res.workingDetail ||
          (roomHasMore[requestedScope] ?? false) != hasMore;
      if (changed) {
        final oldFiles = {
          for (final message in prev)
            ...message.attachments.map((file) => file.id),
        };
        final newFiles = {
          for (final message in msgs)
            ...message.attachments.map((file) => file.id),
        };
        if (!setEquals(oldFiles, newFiles)) fileRevision++;
        roomMessages[requestedScope] = List.unmodifiable(msgs);
        roomHasMore[requestedScope] = hasMore;
        workingAgent = res.working;
        workingDetail = res.workingDetail;
        _notify();
      }
    } catch (_) {
      // The next poll can recover without clearing the conversation.
    } finally {
      _messageLoads.remove(requestKey);
    }
  }

  /// Loads the next older page when the user scrolls to the top of the chat.
  Future<void> loadOlderRoomMessages() async {
    final roomName = room;
    final sp = spaceFor(workspace);
    if (roomName == null || sp == null) return;
    final r = currentRooms.where((x) => x.name == roomName).toList();
    if (r.isEmpty) return;
    final requestedWorkspace = workspace;
    final requestedScope = '$requestedWorkspace/$roomName';
    if (!(roomHasMore[requestedScope] ?? false)) return;
    final prev = roomMessages[requestedScope] ?? const <RoomMessage>[];
    if (prev.isEmpty) return;
    final thread = messageRoom(r.first.id);
    final requestKey = 'older:${sp.id}/$thread';
    if (!_loadingOlder.add(requestKey)) return;
    _notify();
    try {
      final oldest = prev.first;
      final res = await _service.fetchRoomMessages(
        sp.id,
        thread,
        before: oldest.createdAt,
      );
      if (_disposed ||
          workspace != requestedWorkspace ||
          room != roomName ||
          currentRoomId != r.first.id ||
          messageRoom(r.first.id) != thread) {
        return;
      }
      // Merge into whatever the poll may have refreshed while we waited.
      final current = roomMessages[requestedScope] ?? prev;
      final msgs = mergeOlderRoomMessages(current, res.messages);
      roomMessages[requestedScope] = List.unmodifiable(msgs);
      roomHasMore[requestedScope] = res.hasMore;
      _notify();
    } catch (_) {
      // Leave hasMore as-is so the user can try again.
    } finally {
      _loadingOlder.remove(requestKey);
      _notify();
    }
  }

  /// Sends a room message. Throws on failure so the screen can show a snackbar.
  Future<void> sendRoomMessage(
    String body,
    List<String> mentions,
    List<String> attachments, {
    String replyTo = '',
  }) async {
    final sp = spaceFor(workspace);
    final r = room == null
        ? null
        : currentRooms.where((x) => x.name == room).toList();
    if (sp == null || r == null || r.isEmpty) return;
    await _service.sendRoomMessage(
      sp.id,
      messageRoom(r.first.id),
      body,
      mentions: mentions,
      attachments: attachments,
      replyTo: replyTo,
    );
    if (_disposed) return;
    // Bump so the left-panel file library (Docs/GIFs/Media/Audio) reloads and
    // shows the newly attached files.
    if (attachments.isNotEmpty) {
      fileRevision++;
      _notify();
    }
    await loadRoomMessages(r.first.name);
  }

  Future<void> messageChange(Future<void> Function() change) async {
    await change();
    if (room != null) await loadRoomMessages(room!);
  }

  Future<void> editRoomMessage(RoomMessage m, String body) =>
      messageChange(() => _service.editRoomMessage(m.id, body));

  Future<void> deleteRoomMessage(RoomMessage m) =>
      messageChange(() => _service.deleteRoomMessage(m.spaceId, m.id));

  Future<void> createRoom({
    required String name,
    required String purpose,
    required String icon,
    required String color,
  }) async {
    final sp = spaceFor(workspace);
    if (sp == null) return;
    await _service.createRoom(
      sp.id,
      name,
      '',
      purpose: purpose,
      icon: icon,
      color: color,
    );
    await loadRooms();
  }

  /// Shows the desk of the room on screen (the space's own on the hall).
  void attachDesk() => deskController.attach(
    spaceFor(workspace)?.id ?? '',
    currentRoomId.isEmpty ? 'home' : currentRoomId,
  );

  /// Switches the open room's chat to another of its threads, loaded fresh.
  void switchThread(RoomThread thread) {
    final roomId = currentRoomId;
    final roomName = room;
    if (roomId.isEmpty || roomName == null) return;
    if (thread.isMain || thread.id == roomId) {
      roomThreads.remove(roomId);
    } else {
      roomThreads[roomId] = thread;
    }
    roomMessages.remove('$workspace/$roomName');
    roomHasMore.remove('$workspace/$roomName');
    workingAgent = '';
    workingDetail = '';
    _notify();
    unawaited(loadRoomMessages(roomName));
  }

  void openRoom(String value) {
    if (value == hallRoom) {
      goHome();
      return;
    }
    room = value;
    workingAgent = '';
    workingDetail = '';
    _notify();
    unawaited(loadRoomMessages(value));
    attachDesk();
  }

  void goHome() {
    room = null;
    workingAgent = '';
    workingDetail = '';
    _notify();
    attachDesk();
  }

  /// Applies a workspace switch after the screen has finished exit motion.
  void selectWorkspace(String value, {String spaceId = ''}) {
    workspace = value;
    if (spaceId.isNotEmpty) {
      activeSpaceId = spaceId;
    } else {
      activeSpaceId = '';
      for (final s in spaces) {
        if (s.name == value) {
          activeSpaceId = s.id;
          break;
        }
      }
    }
    room = null;
    currentRooms = [];
    roomThreads.clear();
    workingAgent = '';
    workingDetail = '';
    _notify();
    onWorkspaceChanged?.call(value);
  }

  void setLibraryTab(int value) {
    if (libraryTab == value) return;
    libraryTab = value;
    _notify();
  }

  void setMobilePage(int value) {
    if (mobilePage == value) return;
    mobilePage = value;
    _notify();
  }

  void setOpenFilePath(String path) {
    if (openFilePath == path) return;
    openFilePath = path;
    _notify();
  }
}
