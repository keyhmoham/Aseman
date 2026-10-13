import 'dart:async';
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../app_dependencies.dart';
import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/post.dart';
import '../../../data/models/profile.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/glow_painter.dart';
import '../../../shared/widgets/mini_tag.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/profile_menu.dart';
import '../../../shared/widgets/user_profile_sheet.dart';
import '../../../shared/widgets/workspace_header.dart';
import '../../admin/presentation/admin_screen.dart';
import '../../miniapps/domain/sandbox_explorer_frontend.dart';
import '../../miniapps/domain/widget_dsl.dart';
import '../../miniapps/presentation/miniapp_sandbox_screen.dart';
import '../../miniapps/presentation/widget_dsl_renderer.dart';
import '../../rooms/presentation/widgets/attachment_bubble.dart';
import '../../rooms/presentation/widgets/workspace_links.dart';
import '../../search_feed/presentation/post_editor.dart';
import '../../search_feed/presentation/rich_post_content.dart';
import '../../workflows/presentation/workflow_panel.dart';
import 'space_settings_panel.dart';
import 'widgets/routines_panel.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({
    super.key,
    required this.dependencies,
    this.initialWorkspace = 'Home',
    this.onBackToFeed,
    this.onWorkspaceChanged,
  });
  final AppDependencies dependencies;
  final String initialWorkspace;
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
  final command = TextEditingController();
  final drafts = <String, String>{};
  String workspace = 'Home';
  String? room;
  int libraryTab = 0;
  int mobilePage = 0;
  Offset pointer = Offset.zero;
  final desks = <String, List<_MosaicItem>>{};
  List<Bot> bots = [];
  final Map<String, List<Bot>> _spaceBots = {};
  List<Workspace> spaces = [];
  List<WorkspaceRoom> currentRooms = [];
  final Map<String, List<RoomMessage>> roomMessages = {};
  final Map<String, List<DeskWidgetDsl>> roomWidgets = {};
  _DeskData desk = const _DeskData();
  Timer? _deskTimer;
  Timer? _roomTimer;
  String? _commandAgent;
  String? _commandReply;
  bool _commandReplying = false;
  int _fileRevision = 0;
  String _workingAgent = '';
  String _workingDetail = '';
  final Set<String> _messageLoads = {};
  late final AnimationController workspaceMotion = AnimationController(
      vsync: this,
      value: 1,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 260));

  @override
  void initState() {
    super.initState();
    workspace = widget.initialWorkspace;
    _loadWorkspaces();
    _loadBots();
    _loadDesk();
    _loadSpaceBots();
    _deskTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _loadDesk();
      _loadRoomWidgets();
    });
    // Async messaging: agent replies (and tradera's message/log flow) arrive
    // after a message is sent, so the open room is polled frequently and new
    // content shows up live without needing another message to trigger it.
    _roomTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (room != null) _loadRoomMessages(room!);
    });
  }

  @override
  void dispose() {
    _deskTimer?.cancel();
    _roomTimer?.cancel();
    command.dispose();
    mobilePages.dispose();
    workspaceMotion.dispose();
    super.dispose();
  }

  Future<void> _loadDesk() async {
    final requestedWorkspace = workspace;
    final deps = widget.dependencies;
    final sp = _spaceFor(workspace);
    final spaceId = sp?.id ?? '';
    try {
      final results = await Future.wait<Object>([
        deps.service.fetchWallet(),
        deps.service.fetchBots(),
        deps.service.fetchMarket(limit: 8),
        deps.service.fetchLedger(limit: 12),
        spaceId.isEmpty
            ? Future.value(const <SocialPost>[])
            : deps.service.fetchFeed(spaceId: spaceId, limit: 12),
      ]);
      if (!mounted || workspace != requestedWorkspace) return;
      final wallet = results[0] as Wallet;
      final bots = results[1] as List<Bot>;
      final market = results[2] as List<MarketListing>;
      final ledger = results[3] as List<Map<String, dynamic>>;
      final feed = results[4] as List<SocialPost>;
      setState(() {
        desk = _DeskData(
            wallet: wallet,
            bots: bots,
            market: market,
            ledger: ledger,
            feed: feed);
      });
    } catch (_) {}
  }

  Future<void> _loadRoomWidgets() async {
    final sp = _spaceFor(workspace);
    final r = room == null
        ? null
        : currentRooms.where((x) => x.name == room).toList();
    if (sp == null || r == null || r.isEmpty) return;
    final requestedScope = scopeKey;
    try {
      final widgets =
          await widget.dependencies.service.fetchRoomWidgets(sp.id, r.first.id);
      if (!mounted ||
          requestedScope != scopeKey ||
          _currentRoomId != r.first.id) return;
      setState(() {
        roomWidgets[requestedScope] = widgets;
        _syncDeskWdigets();
      });
    } catch (_) {}
  }

  /// Reconciles the desk mosaic with the miniapps currently installed in the
  /// room: removes tiles whose miniapp was removed and appends new ones.
  void _syncDeskWdigets() {
    final key = scopeKey;
    final current = desks[key] ?? [];
    final botsInDesk =
        current.where((m) => m.isMiniapp).map((m) => m.botId).toSet();
    final widgets = roomWidgets[scopeKey] ?? const <DeskWidgetDsl>[];
    final widgetBotIds = widgets.map((w) => w.botId).toSet();
    var changed = false;
    final kept = current.where((m) {
      if (!m.isMiniapp) return true;
      if (!widgetBotIds.contains(m.botId)) {
        changed = true;
        return false;
      }
      return true;
    }).toList();
    for (final w in widgets) {
      if (botsInDesk.contains(w.botId)) continue;
      kept.add(_MosaicItem(w.name, 2, 2, _WidgetKind.miniapp, w.botId));
      changed = true;
    }
    if (changed) desks[key] = kept;
    if (changed) _saveDeskLayout();
  }

  /// Loads the saved desk layout (widgets + order/positions) for the current
  /// room from the space's metadata tree (`desk/{roomKey}`). Falls back to the
  /// seed layout when nothing is stored yet.
  Future<void> _loadDeskLayout() async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    final key = scopeKey;
    final roomKey = room ?? 'home';
    try {
      final tree = await widget.dependencies.service.fetchSpaceMetadata(sp.id);
      final deskNode = tree['desk'];
      final raw = deskNode is Map<dynamic, dynamic> ? deskNode[roomKey] : null;
      if (!mounted || key != scopeKey || _spaceFor(workspace)?.id != sp.id)
        return;
      if (raw is List) {
        final items = raw
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => _MosaicItem.fromJson(e.cast<String, dynamic>()))
            .toList();
        setState(() {
          desks[key] = items.isEmpty ? _seedDesk(key) : items;
        });
        if (items.isEmpty) unawaited(_saveDeskLayout());
      } else {
        setState(() => desks.putIfAbsent(key, () => _seedDesk(key)));
        unawaited(_saveDeskLayout());
      }
      _syncDeskWdigets();
    } catch (_) {
      if (!mounted) return;
      setState(() => desks.putIfAbsent(key, () => _seedDesk(key)));
    }
  }

  /// Persists the current desk layout for the room into the space metadata.
  Future<void> _saveDeskLayout() async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    final items = desks[scopeKey];
    if (items == null) return;
    final path =
        'desk/${(room ?? 'home').replaceAll('~', '~0').replaceAll('/', '~1')}';
    try {
      await widget.dependencies.service.patchSpaceMetadata(sp.id, [
        {
          'op': 'set',
          'path': path,
          'value': [for (final m in items) m.toJson()],
        },
      ]);
    } catch (_) {}
  }

  Map<String, DeskWidgetDsl> get _roomWidgetDsl {
    if (room == null) return const {};
    final list = roomWidgets[scopeKey] ?? const [];
    return {for (final w in list) w.botId: w};
  }

  Future<String> _runWidgetAction(
      String botId, DslAction action, Map<String, dynamic> inline) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return '';
    final resolved = action.withInlineArgs(inline);
    return widget.dependencies.service
        .widgetAction(sp.id, botId, resolved.op, resolved.args);
  }

  void _addDeskWdiget() {
    final kinds = [
      ('Market pulse', _WidgetKind.market, Icons.candlestick_chart),
      ('Portfolio', _WidgetKind.portfolio, Icons.donut_large),
      ('Agent activity', _WidgetKind.agents, Icons.smart_toy_outlined),
      ('Watchlist', _WidgetKind.watchlist, Icons.star_outline),
      ('Recent activity', _WidgetKind.activity, Icons.query_stats),
      ('Room feed', _WidgetKind.feed, Icons.dynamic_feed_outlined),
    ];
    showMenu<String>(
      context: context,
      position: const RelativeRect.fromLTRB(200, 120, 40, 0),
      items: [
        for (final kind in kinds)
          PopupMenuItem(
              value: kind.$1,
              child: Row(children: [
                Icon(kind.$3,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                Text(kind.$1, style: const TextStyle(fontSize: 12)),
              ])),
      ],
    ).then((value) {
      if (value == null) return;
      final kind = kinds.firstWhere((k) => k.$1 == value);
      final key = scopeKey;
      final list = desks.putIfAbsent(key, () => _seedDesk(key));
      if (list.any((m) => m.kind == kind.$2)) return;
      setState(() => list.add(_MosaicItem(value, 1, 1, kind.$2)));
      _saveDeskLayout();
    });
  }

  Future<void> _loadBots() async {
    try {
      final loaded = await widget.dependencies.service.fetchBots();
      if (mounted) setState(() => bots = loaded);
    } catch (_) {}
  }

  /// Bots explicitly installed in the current workspace. Agents/miniapps/tools
  /// are only shown (and usable) here once added via [addBotToSpace].
  List<Bot> get spaceBots => _spaceBots[workspace] ?? const [];

  Future<void> _loadSpaceBots() async {
    final requestedWorkspace = workspace;
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      final list = await widget.dependencies.service.fetchSpaceBots(sp.id);
      if (mounted) setState(() => _spaceBots[requestedWorkspace] = list);
    } catch (_) {}
  }

  Future<void> _addBotToWorkspace(Bot bot) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.addBotToSpace(sp.id, bot.id);
      await _loadSpaceBots();
      await _loadDesk();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Add failed: $e')));
    }
  }

  Future<void> _removeBotFromWorkspace(Bot bot) async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.removeBotFromSpace(sp.id, bot.id);
      await _loadSpaceBots();
      await _loadDesk();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Remove failed: $e')));
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
      await _loadDeskLayout();
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
      setState(() {
        currentRooms = rooms;
        roomMessages.removeWhere((key, _) => key.startsWith('$workspace/'));
      });
      await _loadDeskLayout();
    } catch (_) {}
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
    final requestKey = '${sp.id}/${r.first.id}';
    if (!_messageLoads.add(requestKey)) return;
    try {
      final res = await widget.dependencies.service
          .fetchRoomMessages(sp.id, r.first.id);
      if (!mounted ||
          workspace != requestedWorkspace ||
          room != roomName ||
          _currentRoomId != r.first.id) return;
      // Only rebuild when the conversation or the working-agent indicator
      // actually changed, to avoid 3s rebuild churn.
      final prev = roomMessages[requestedScope] ?? const <RoomMessage>[];
      final msgs = res.messages;
      final changed = prev.length != msgs.length ||
          List.generate(msgs.length, (index) => index)
              .any((index) => !prev[index].hasSameContentAs(msgs[index])) ||
          _workingAgent != res.working ||
          _workingDetail != res.workingDetail;
      if (changed) {
        setState(() {
          final oldFiles = {
            for (final message in prev)
              ...message.attachments.map((file) => file.id)
          };
          final newFiles = {
            for (final message in msgs)
              ...message.attachments.map((file) => file.id)
          };
          if (!setEquals(oldFiles, newFiles)) _fileRevision++;
          roomMessages[requestedScope] = List.unmodifiable(msgs);
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

  Future<void> _sendRoomMessage(
      String body, List<String> mentions, List<String> attachments) async {
    final sp = _spaceFor(workspace);
    final r = room == null
        ? null
        : currentRooms.where((x) => x.name == room).toList();
    if (sp == null || r == null || r.isEmpty) return;
    try {
      await widget.dependencies.service.sendRoomMessage(sp.id, r.first.id, body,
          mentions: mentions, attachments: attachments);
      if (!mounted) return;
      // Bump so the left-panel file library (Docs/GIFs/Media/Audio) reloads and
      // shows the newly attached files.
      if (attachments.isNotEmpty) _fileRevision++;
      await _loadRoomMessages(r.first.name);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
      rethrow;
    }
  }

  Future<void> _createRoom() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _RoomNameDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      await widget.dependencies.service.createRoom(sp.id, name.trim(), '');
      await _loadRooms();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Create room failed: $e')));
    }
  }

  Future<void> _askCommand(String text) async {
    if (text.trim().isEmpty) return;
    final agent = bots.where((b) => b.isAgent).toList();
    if (agent.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No agents yet — create one in My bots.')));
      }
      return;
    }
    command.clear();
    setState(() {
      _commandAgent = agent.first.name;
      _commandReply = null;
      _commandReplying = true;
    });
    try {
      final spaceId = _spaceFor(workspace)?.id;
      final reply = spaceId == null || spaceId.isEmpty
          ? await widget.dependencies.service
              .askBot(agent.first.id, text.trim())
          : await widget.dependencies.service
              .askBotInSpace(spaceId, agent.first.id, text.trim());
      if (!mounted) return;
      setState(() {
        _commandReply = reply.trim().isEmpty ? 'No reply.' : reply;
        _commandReplying = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _commandReply = 'Agent error: $e';
        _commandReplying = false;
      });
    }
  }

  void openMiniapp(Bot bot) {
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => MiniappSandboxScreen(
            dependencies: widget.dependencies,
            bot: bot,
            spaceId: _spaceFor(workspace)?.id ?? '')));
  }

  /// Opens the shared per-space sandbox as a full file-explorer miniapp. The
  /// explorer frontend is installed on the sandbox bot (idempotent) so the
  /// sandbox tool appears in the workspace Tools library with its UI.
  Future<void> _openSandboxExplorer() async {
    final sp = _spaceFor(workspace);
    if (sp == null) return;
    try {
      final status = await widget.dependencies.service.sandboxStatus(sp.id);
      final botId = status['bot_id'] as String? ?? '';
      if (botId.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Could not provision the sandbox.')));
        }
        return;
      }
      await widget.dependencies.service
          .setBotFrontend(botId, SandboxExplorerFrontend.bundle());
      final bot = await widget.dependencies.service.fetchBot(botId);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => MiniappSandboxScreen(
              dependencies: widget.dependencies, bot: bot, spaceId: sp.id)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Sandbox explorer failed: $e')));
    }
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

  List<_MosaicItem> get widgets =>
      desks.putIfAbsent(scopeKey, () => _seedDesk(scopeKey));
  List<RoomMessage> get chatMessages => roomMessages[scopeKey] ?? const [];

  String get _currentRoomId {
    if (room == null) return '';
    final matches = currentRooms.where((r) => r.name == room).toList();
    return matches.isEmpty ? '' : matches.first.id;
  }

  void openRoom(String value) {
    if (value == hallRoom) {
      goHome();
      return;
    }
    drafts[scopeKey] = command.text;
    setState(() {
      room = value;
      _workingAgent = '';
      _workingDetail = '';
      command.text = drafts[scopeKey] ?? '';
    });
    _loadRoomMessages(value);
    _loadRoomWidgets();
    _loadDeskLayout();
  }

  void goHome() {
    drafts[scopeKey] = command.text;
    setState(() {
      room = null;
      _workingAgent = '';
      _workingDetail = '';
      command.text = drafts[scopeKey] ?? '';
    });
    _loadDeskLayout();
  }

  Future<void> switchWorkspace(String value) async {
    if (value == workspace || workspaceMotion.isAnimating) return;
    drafts[scopeKey] = command.text;
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
      command.text = drafts['$value/home'] ?? '';
    });
    widget.onWorkspaceChanged?.call(value);
    await _loadRooms();
    await _loadDesk();
    await _loadSpaceBots();
    await _loadRoomWidgets();
    await _loadDeskLayout();
    await workspaceMotion.forward();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 820;
    return MouseRegion(
      onHover: (e) => setState(() => pointer = e.position),
      child: Scaffold(
          key: scaffoldKey,
          drawer: compact
              ? Drawer(
                  width: math.min(340, MediaQuery.sizeOf(context).width * .88),
                  child: SafeArea(
                      child: _LibraryPanel(
                          room: room,
                          workspace: workspace,
                          rooms: rooms,
                          bots: bots,
                          spaceBots: spaceBots,
                          allBots: bots,
                          tab: libraryTab,
                          flat: true,
                          dependencies: widget.dependencies,
                          spaceId: _spaceFor(workspace)?.id ?? '',
                          roomId: _currentRoomId,
                          fileRevision: _fileRevision,
                          onTab: (v) => setState(() => libraryTab = v),
                          onOpenMiniapp: openMiniapp,
                          onOpenSandbox: _openSandboxExplorer,
                          onCreateRoom: _createRoom,
                          onSearch: () => _search(context),
                          onAddBot: _addBotToWorkspace,
                          onRemoveBot: _removeBotFromWorkspace,
                          openRoom: (value) {
                            Navigator.pop(context);
                            openRoom(value);
                          })))
              : null,
          body: Stack(children: [
            Positioned.fill(
                child: CustomPaint(
                    painter: GlowPainter(colors.primary, colors.tertiary))),
            SafeArea(
                child: Column(children: [
              WorkspaceHeader(
                  workspace: workspace,
                  room: room,
                  compact: compact,
                  handle:
                      widget.dependencies.sessionController.session?.handle ??
                          '',
                  onOpenNavigation: () =>
                      scaffoldKey.currentState?.openDrawer(),
                  onOpenWorkspaces: () => _workspacePicker(context),
                  onGoHome: goHome,
                  onOpenAdmin: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AdminScreen(dependencies: widget.dependencies),
                        ),
                      ),
                  onOpenSpaceSettings: () => _openSpaceSettings(),
                  onOpenProfile: () =>
                      showProfileMenu(context, widget.dependencies),
                  onOpenSearchFeed: widget.onBackToFeed),
              Expanded(child: LayoutBuilder(builder: (context, box) {
                if (box.maxWidth < 820) {
                  return _WorkspacePanelMotion(
                      animation: workspaceMotion,
                      hiddenOffset: const Offset(0, .06),
                      scaleFrom: .98,
                      child: _mobile());
                }
                return Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _WorkspacePanelMotion(
                              animation: workspaceMotion,
                              hiddenOffset: const Offset(-.24, 0),
                              child: SizedBox(
                                  width: math.min(286, box.maxWidth * .22),
                                  height: box.maxHeight * .82,
                                  child: _LibraryPanel(
                                      room: room,
                                      workspace: workspace,
                                      rooms: rooms,
                                      bots: bots,
                                      spaceBots: spaceBots,
                                      allBots: bots,
                                      tab: libraryTab,
                                      dependencies: widget.dependencies,
                                      spaceId: _spaceFor(workspace)?.id ?? '',
                                      roomId: _currentRoomId,
                                      fileRevision: _fileRevision,
                                      onTab: (v) =>
                                          setState(() => libraryTab = v),
                                      onOpenMiniapp: openMiniapp,
                                      onOpenSandbox: _openSandboxExplorer,
                                      onCreateRoom: _createRoom,
                                      onSearch: () => _search(context),
                                      onAddBot: _addBotToWorkspace,
                                      onRemoveBot: _removeBotFromWorkspace,
                                      openRoom: openRoom))),
                          const SizedBox(width: 16),
                          Expanded(
                              child: _WorkspacePanelMotion(
                                  animation: workspaceMotion,
                                  scaleFrom: .94,
                                  child: _CenterDesk(
                                      workspace: workspace,
                                      room: room,
                                      widgets: widgets,
                                      command: command,
                                      pointer: pointer,
                                      desk: desk,
                                      widgetDslByBot: _roomWidgetDsl,
                                      onWidgetAction: _runWidgetAction,
                                      openSearch: () => _search(context),
                                      onSubmit: _askCommand,
                                      remove: (v) {
                                        setState(() => widgets.remove(v));
                                        _saveDeskLayout();
                                      },
                                      reorder: (a, b) {
                                        setState(() {
                                          final x = widgets.removeAt(a);
                                          widgets.insert(b, x);
                                        });
                                        _saveDeskLayout();
                                      },
                                      add: () => _addDeskWdiget()))),
                          const SizedBox(width: 16),
                          _WorkspacePanelMotion(
                              animation: workspaceMotion,
                              hiddenOffset: const Offset(.24, 0),
                              child: SizedBox(
                                  width: math.min(330, box.maxWidth * .25),
                                  height: box.maxHeight * .88,
                                  child: room == null
                                      ? _SocialFeed(
                                          workspace: workspace,
                                          dependencies: widget.dependencies,
                                          spaceId:
                                              _spaceFor(workspace)?.id ?? '')
                                      : _RoomChat(
                                          key: ValueKey(
                                              '${_spaceFor(workspace)?.id}/$_currentRoomId'),
                                          room: room!,
                                          messages: chatMessages,
                                          working: _workingAgent,
                                          workingDetail: _workingDetail,
                                          me: widget
                                                  .dependencies
                                                  .sessionController
                                                  .session
                                                  ?.accountId ??
                                              '',
                                          dependencies: widget.dependencies,
                                          spaceId:
                                              _spaceFor(workspace)?.id ?? '',
                                          roomId: _currentRoomId,
                                          canManageTasks: _canManageTasks,
                                          mentionable: spaceBots
                                              .where((b) => b.isAgent)
                                              .toList(),
                                          onSend: _sendRoomMessage))),
                        ]));
              }))
            ])),
            if (_commandReplying || _commandReply != null)
              Positioned(
                  top: compact ? 66 : 60,
                  left: 16,
                  right: 16,
                  child: Align(
                      alignment: Alignment.topCenter,
                      child: _CommandReplyBubble(
                          agent: _commandAgent,
                          replying: _commandReplying,
                          reply: _commandReply,
                          onClose: () =>
                              setState(() => _commandReply = null)))),
          ])),
    );
  }

  Widget _mobile() => Stack(children: [
        Positioned.fill(
            child: PageView(
                controller: mobilePages,
                onPageChanged: (value) => setState(() => mobilePage = value),
                children: [
              _CenterDesk(
                  workspace: workspace,
                  room: room,
                  widgets: widgets,
                  command: command,
                  pointer: pointer,
                  desk: desk,
                  widgetDslByBot: _roomWidgetDsl,
                  onWidgetAction: _runWidgetAction,
                  topContentInset: 62,
                  openSearch: () => _search(context),
                  onSubmit: _askCommand,
                  remove: (v) {
                    setState(() => widgets.remove(v));
                    _saveDeskLayout();
                  },
                  reorder: (a, b) {
                    setState(() {
                      final x = widgets.removeAt(a);
                      widgets.insert(b, x);
                    });
                    _saveDeskLayout();
                  },
                  add: () => _addDeskWdiget()),
              room == null
                  ? _SocialFeed(
                      workspace: workspace,
                      flat: true,
                      topContentInset: 62,
                      dependencies: widget.dependencies,
                      spaceId: _spaceFor(workspace)?.id ?? '')
                  : _RoomChat(
                      key: ValueKey(
                          '${_spaceFor(workspace)?.id}/$_currentRoomId'),
                      room: room!,
                      messages: chatMessages,
                      working: _workingAgent,
                      workingDetail: _workingDetail,
                      me: widget.dependencies.sessionController.session
                              ?.accountId ??
                          '',
                      dependencies: widget.dependencies,
                      spaceId: _spaceFor(workspace)?.id ?? '',
                      roomId: _currentRoomId,
                      canManageTasks: _canManageTasks,
                      mentionable: spaceBots.where((b) => b.isAgent).toList(),
                      onSend: _sendRoomMessage,
                      flat: true,
                      topContentInset: 62),
            ])),
        Positioned(
            top: 5,
            left: 0,
            right: 0,
            child: Center(
                child: _MobileTabs(
                    selected: mobilePage,
                    room: room,
                    onSelect: (value) {
                      setState(() => mobilePage = value);
                      mobilePages.animateToPage(value,
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic);
                    }))),
      ]);
  void _search(BuildContext context) => _sheet(
      context,
      _SearchPanel(
          workspace: workspace,
          spaceId: _spaceFor(workspace)?.id ?? '',
          dependencies: widget.dependencies),
      maxWidth: 920);
  void _sheet(BuildContext context, Widget child, {double maxWidth = 1180}) =>
      showFloatingPanel(context, child, maxWidth: maxWidth);

  void _workspacePicker(BuildContext context) {
    final picker = WorkspacePicker(
        current: workspace,
        dependencies: widget.dependencies,
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
                      _loadDesk();
                    }),
                maxWidth: 720);
          });
        },
        onPick: (value) async {
          Navigator.pop(context);
          await Future<void>.delayed(const Duration(milliseconds: 320));
          if (mounted) await switchWorkspace(value);
        });
    if (MediaQuery.sizeOf(context).width < 820) {
      showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
          builder: (_) =>
              FractionallySizedBox(heightFactor: .82, child: picker));
      return;
    }
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Workspaces',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (_, __, ___) => picker,
      transitionBuilder: (routeContext, animation, __, child) =>
          desktopFloatingPanelTransition(routeContext, animation, child),
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
              _loadDesk();
            }),
        maxWidth: 720);
  }
}

List<_MosaicItem> _seedDesk(String key) => [
      const _MosaicItem('Market pulse', 2, 2, _WidgetKind.market),
      const _MosaicItem('Portfolio', 2, 1, _WidgetKind.portfolio),
      const _MosaicItem('Agent activity', 1, 1, _WidgetKind.agents),
      const _MosaicItem('Watchlist', 1, 2, _WidgetKind.watchlist),
      const _MosaicItem('Recent activity', 2, 1, _WidgetKind.activity),
      const _MosaicItem('Room feed', 3, 1, _WidgetKind.feed),
    ];

enum _WidgetKind {
  miniapp,
  market,
  portfolio,
  agents,
  watchlist,
  activity,
  feed,
}

class _MosaicItem {
  const _MosaicItem(this.title, this.columns, this.rows,
      [this.kind = _WidgetKind.feed, this.botId]);
  final String title;
  final int columns, rows;
  final _WidgetKind kind;
  final String? botId; // miniapp widget bot id

  bool get isMiniapp => kind == _WidgetKind.miniapp;

  Map<String, dynamic> toJson() => {
        'title': title,
        'columns': columns,
        'rows': rows,
        'kind': kind.name,
        if (botId != null) 'bot_id': botId,
      };

  factory _MosaicItem.fromJson(Map<String, dynamic> json) => _MosaicItem(
        json['title'] as String? ?? 'Widget',
        (json['columns'] as num?)?.toInt() ?? 1,
        (json['rows'] as num?)?.toInt() ?? 1,
        _kindFromName(json['kind'] as String?),
        json['bot_id'] as String?,
      );

  static _WidgetKind _kindFromName(String? name) => _WidgetKind.values
      .firstWhere((k) => k.name == name, orElse: () => _WidgetKind.feed);
}

class _WorkspacePanelMotion extends StatelessWidget {
  const _WorkspacePanelMotion({
    required this.animation,
    required this.child,
    this.hiddenOffset = Offset.zero,
    this.scaleFrom = 1,
  });
  final Animation<double> animation;
  final Widget child;
  final Offset hiddenOffset;
  final double scaleFrom;
  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(begin: hiddenOffset, end: Offset.zero)
            .animate(curved),
        child: ScaleTransition(
            scale: Tween<double>(begin: scaleFrom, end: 1).animate(curved),
            child: child),
      ),
    );
  }
}

class _MobileTabs extends StatelessWidget {
  const _MobileTabs(
      {required this.selected, required this.room, required this.onSelect});
  final int selected;
  final String? room;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => Container(
        width: 246,
        height: 44,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: .1),
                  blurRadius: 18,
                  offset: const Offset(0, 7))
            ]),
        child: Stack(children: [
          AnimatedAlign(
              duration: const Duration(milliseconds: 330),
              curve: Curves.easeOutCubic,
              alignment:
                  selected == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: Container(
                  width: 119,
                  height: 36,
                  decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: .12),
                            blurRadius: 10)
                      ]))),
          Row(children: [
            Expanded(
                child: _MobileTab(
                    label: 'Desk',
                    icon: Icons.dashboard_customize_outlined,
                    selected: selected == 0,
                    onTap: () => onSelect(0))),
            Expanded(
                child: _MobileTab(
                    label: room == null ? 'Feed' : 'Chat',
                    icon: room == null
                        ? Icons.dynamic_feed_outlined
                        : Icons.forum_outlined,
                    selected: selected == 1,
                    onTap: () => onSelect(1))),
          ]),
        ]),
      );
}

class _MobileTab extends StatelessWidget {
  const _MobileTab(
      {required this.label,
      required this.icon,
      required this.selected,
      required this.onTap});
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
        AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(icon,
                key: ValueKey('$icon-$selected'),
                size: 17,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant)),
        const SizedBox(width: 7),
        AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 220),
            style: TextStyle(
                fontSize: 12,
                color: selected
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500),
            child: Text(label))
      ])));
}

class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel(
      {required this.room,
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
      this.onOpenMiniapp,
      this.onOpenSandbox,
      this.onCreateRoom,
      this.onSearch,
      this.onAddBot,
      this.onRemoveBot,
      required this.openRoom});
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
  final ValueChanged<Bot>? onOpenMiniapp;
  final VoidCallback? onOpenSandbox;
  final VoidCallback? onCreateRoom;
  final VoidCallback? onSearch;
  final ValueChanged<Bot>? onAddBot;
  final ValueChanged<Bot>? onRemoveBot;
  static const icons = [
    Icons.forum_outlined,
    Icons.smart_toy_outlined,
    Icons.extension_outlined,
    Icons.description_outlined,
    Icons.link,
    Icons.gif_box_outlined,
    Icons.perm_media_outlined,
    Icons.graphic_eq_rounded
  ];
  static const labels = [
    'Rooms',
    'Agents',
    'Tools',
    'Docs',
    'Links',
    'GIFs',
    'Media',
    'Audio'
  ];
  @override
  Widget build(BuildContext context) => _Panel(
      flat: flat,
      child: Row(children: [
        Container(
            width: 58,
            margin: const EdgeInsets.fromLTRB(8, 10, 6, 10),
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .58),
                borderRadius: BorderRadius.circular(24)),
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(
                    icons.length,
                    (i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Tooltip(
                            message: labels[i],
                            child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                    onTap: () => onTab(i),
                                    borderRadius: BorderRadius.circular(16),
                                    child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 240),
                                        curve: Curves.easeOutCubic,
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                            color: i == tab
                                                ? Theme.of(context)
                                                    .colorScheme
                                                    .primaryContainer
                                                : Colors.transparent,
                                            borderRadius:
                                                BorderRadius.circular(16)),
                                        child: Icon(icons[i],
                                            size: 20,
                                            color: i == tab
                                                ? Theme.of(context).colorScheme.onPrimaryContainer
                                                : Theme.of(context).colorScheme.onSurfaceVariant))))))))),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 16, 14, 14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Text(labels[tab],
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900)),
                              const SizedBox(height: 2),
                              Text(room ?? workspace,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant))
                            ])),
                        IconButton.filledTonal(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Find ${labels[tab].toLowerCase()}',
                            onPressed: onSearch,
                            icon: const Icon(Icons.search_rounded, size: 18)),
                        const SizedBox(width: 3),
                        IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: tab == 0 ? 'New room' : 'Add',
                            onPressed: tab == 0 ? onCreateRoom : null,
                            icon: const Icon(Icons.add_rounded, size: 19))
                      ]),
                      const SizedBox(height: 12),
                      Expanded(
                          child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 220),
                              child: KeyedSubtree(
                                  key: ValueKey('$workspace-$room-$tab'),
                                  child: _libraryContent(context))))
                    ]))),
      ]));
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
                onTap: () => openRoom(name));
          });
    }
    if (tab >= 3) {
      // Docs / Links / GIFs / Media / Audio are backed by the space's file
      // library (spaces.file_list), filtered by mime type.
      return _LibraryFilesList(
          spaceId: spaceId,
          roomId: roomId,
          kind: tab,
          fileRevision: fileRevision,
          dependencies: dependencies);
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
                  onAdd: (b) => onAddBot?.call(b));
            }
            final bot = agents[index];
            return _LibraryBotCard(
                bot: bot,
                dependencies: dependencies,
                spaceId: spaceId,
                onRemove: onRemoveBot == null ? null : () => onRemoveBot!(bot));
          });
    }
    if (tab == 2) {
      // Only miniapps/tools explicitly added to this workspace are shown.
      final tools = spaceBots.where((b) => b.isMiniapp || b.isTool).toList();
      final candidates = allBots
          .where((b) =>
              (b.isMiniapp || b.isTool) && !spaceBots.any((s) => s.id == b.id))
          .toList();
      // The shared sandbox is surfaced as a first-class tool: its frontend is
      // the file-explorer miniapp (Sandbox Explorer).
      final sandboxTile = onOpenSandbox == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SandboxExplorerTile(onTap: onOpenSandbox!),
            );
      if (tools.isEmpty && candidates.isEmpty && sandboxTile == null) {
        return const _LibraryEmpty(
            icon: Icons.widgets_outlined,
            message:
                'No tools in this workspace yet — add a miniapp from the market.');
      }
      return LayoutBuilder(builder: (context, box) {
        final columns = math.max(1, (box.maxWidth / 124).floor());
        return GridView.builder(
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 7,
                mainAxisSpacing: 7,
                childAspectRatio: 1.12),
            itemCount: tools.length +
                (sandboxTile == null ? 0 : 1) +
                (candidates.isEmpty ? 0 : 1),
            itemBuilder: (_, index) {
              if (sandboxTile != null) {
                if (index == 0) return sandboxTile;
                index--;
              }
              if (index == tools.length) {
                return _AddBotTile(
                    label: 'Add tool',
                    icon: Icons.widgets_outlined,
                    candidates: candidates,
                    onAdd: (b) => onAddBot?.call(b));
              }
              final bot = tools[index];
              return Stack(children: [
                _LibraryToolCard(
                    label: bot.name,
                    icon: Icons.widgets_outlined,
                    dependencies: dependencies,
                    spaceId: spaceId,
                    onTap: () => onOpenMiniapp?.call(bot)),
                Positioned(
                    top: 2,
                    right: 2,
                    child: onRemoveBot == null
                        ? const SizedBox.shrink()
                        : IconButton(
                            tooltip: 'Remove from workspace',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => onRemoveBot!(bot),
                            icon: const Icon(Icons.close_rounded, size: 14))),
              ]);
            });
      });
    }
    return const _LibraryEmpty(
        icon: Icons.folder_outlined,
        message: 'Nothing here yet. Upload files to your workspace.');
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Center(
      child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 30,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ])));
}

/// File-backed library content for the Docs/Links/GIFs/Media/Audio tabs.
class _LibraryFilesList extends StatefulWidget {
  const _LibraryFilesList(
      {required this.spaceId,
      required this.roomId,
      required this.kind,
      this.fileRevision = 0,
      this.dependencies});
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
      final all = await deps.service.fetchFiles(widget.spaceId,
          roomId: widget.roomId, limit: _pageSize, offset: offset);
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_files.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                  'No files in this workspace yet. Upload one to see it here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).colorScheme.onSurfaceVariant))));
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
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.5))),
                );
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
                  dependencies: widget.dependencies);
            }));
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
  const _LibraryRoomCard(
      {required this.name,
      required this.index,
      required this.selected,
      required this.onTap,
      this.dependencies,
      this.spaceId = ''});
  final String name;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) {
    final hall = name == _WorkspaceScreenState.hallRoom;
    return Material(
        color: selected
            ? Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: .7)
            : Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(17),
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Theme.of(context).colorScheme.primary,
                            Theme.of(context).colorScheme.tertiary
                          ]),
                          borderRadius: BorderRadius.circular(12)),
                      child: Center(
                          child: hall
                              ? const Icon(Icons.dynamic_feed_rounded,
                                  color: Colors.white, size: 19)
                              : Text(name.characters.first.toUpperCase(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900)))),
                  const SizedBox(width: 9),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Row(children: [
                          Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                  color: Colors.greenAccent,
                                  shape: BoxShape.circle)),
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
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)))
                        ])
                      ])),
                  IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Room profile',
                      onPressed: () => _openEntityProfile(
                          context, 'Rooms', name, dependencies, spaceId),
                      icon: const Icon(Icons.info_outline_rounded, size: 17))
                ]))));
  }
}

class _LibraryListCard extends StatelessWidget {
  const _LibraryListCard(
      {required this.label,
      required this.icon,
      required this.kind,
      required this.index,
      this.subtitle,
      this.dependencies});
  final String label;
  final IconData icon;
  final int kind, index;
  final String? subtitle;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
          onTap: kind == 1 || kind == 2
              ? () => _openEntityProfile(
                  context, kind == 1 ? 'Agents' : 'Tools', label, dependencies)
              : null,
          borderRadius: BorderRadius.circular(15),
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(children: [
                Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(11)),
                    child: Icon(icon, size: 17)),
                const SizedBox(width: 9),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w700)),
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
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant))
                    ])),
                IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () {},
                    icon: const Icon(Icons.more_horiz_rounded, size: 17))
              ]))));
}

class _LibraryBotCard extends StatelessWidget {
  const _LibraryBotCard(
      {required this.bot, this.dependencies, this.spaceId = '', this.onRemove});
  final Bot bot;
  final AppDependencies? dependencies;
  final String spaceId;
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) {
    final color = bot.status == 'running' ? AppColors.success : AppColors.muted;
    return Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
            onTap: () => _openEntityProfile(
                context, 'Agents', bot.name, dependencies, spaceId),
            borderRadius: BorderRadius.circular(17),
            child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(children: [
                  Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          color: color.withValues(alpha: .18),
                          borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.smart_toy_outlined,
                          size: 19, color: AppColors.primary)),
                  const SizedBox(width: 9),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(bot.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text('${bot.kind} · ${bot.vmType} · ${bot.status}',
                            style: TextStyle(
                                fontSize: 9,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant))
                      ])),
                  if (onRemove != null)
                    IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Remove from workspace',
                        onPressed: onRemove,
                        icon: const Icon(Icons.close_rounded, size: 17))
                ]))));
  }
}

/// A tile that opens a picker of candidate bots (not yet in the workspace) and
/// adds the selected one.
class _SandboxExplorerTile extends StatelessWidget {
  const _SandboxExplorerTile({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: .10),
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.folder_open_rounded,
                        size: 19, color: AppColors.primary)),
                const SizedBox(width: 9),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Sandbox Explorer',
                          style: TextStyle(
                              fontSize: 12, fontWeight: FontWeight.w800)),
                      Text('Shared workspace file manager',
                          style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant))
                    ])),
                const Icon(Icons.arrow_forward_ios_rounded,
                    size: 13, color: AppColors.muted),
              ]))));
}

class _AddBotTile extends StatelessWidget {
  const _AddBotTile({
    required this.label,
    required this.icon,
    required this.candidates,
    required this.onAdd,
  });
  final String label;
  final IconData icon;
  final List<Bot> candidates;
  final ValueChanged<Bot> onAdd;

  void _pick(BuildContext context) {
    if (candidates.isEmpty) {
      showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('Nothing to add'),
                content: const Text(
                    'No bots of this type are available yet. Create one in My bots or install from the market.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('OK')),
                ],
              ));
      return;
    }
    showModalBottomSheet<Bot>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (context) => SafeArea(
                child: SizedBox(
              height: 420,
              child: Column(children: [
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Add $label',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w900))),
                Expanded(
                    child: ListView.separated(
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final b = candidates[i];
                          return ListTile(
                              leading: const Icon(Icons.smart_toy_outlined),
                              title: Text(b.name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text('${b.kind} · ${b.vmType}',
                                  style: const TextStyle(fontSize: 10)),
                              trailing: const Icon(Icons.add_rounded),
                              onTap: () => Navigator.pop(context, b));
                        })),
              ]),
            ))).then((b) {
      if (b != null) onAdd(b);
    });
  }

  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
          onTap: () => _pick(context),
          borderRadius: BorderRadius.circular(17),
          child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(children: [
                Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: .14),
                        borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, size: 19, color: AppColors.primary)),
                const SizedBox(width: 9),
                Expanded(
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w800))),
                const Icon(Icons.add_rounded, size: 18),
              ]))));
}

class _LibraryToolCard extends StatelessWidget {
  const _LibraryToolCard(
      {required this.label,
      required this.icon,
      this.onTap,
      this.dependencies,
      this.spaceId = ''});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
          onTap: onTap ??
              () => _openEntityProfile(
                  context, 'Tools', label, dependencies, spaceId),
          borderRadius: BorderRadius.circular(17),
          child: Padding(
              padding: const EdgeInsets.all(11),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(icon,
                          size: 21,
                          color: Theme.of(context).colorScheme.primary),
                      const Spacer(),
                      Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                              color: Colors.greenAccent,
                              shape: BoxShape.circle))
                    ]),
                    const Spacer(),
                    Text(label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    const Text('Connected', style: TextStyle(fontSize: 9))
                  ]))));
}

class _CommandReplyBubble extends StatelessWidget {
  const _CommandReplyBubble({
    this.agent,
    required this.replying,
    this.reply,
    required this.onClose,
  });

  final String? agent;
  final bool replying;
  final String? reply;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = agent == null ? 'Agent' : agent!;
    return Material(
        color: Colors.transparent,
        child: Container(
            constraints: const BoxConstraints(maxWidth: 620),
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh.withValues(alpha: .98),
                borderRadius: BorderRadius.circular(18),
                border:
                    Border.all(color: scheme.primary.withValues(alpha: .45)),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: .22),
                      blurRadius: 26,
                      offset: const Offset(0, 10))
                ]),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.smart_toy_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                  child: replying
                      ? const Row(children: [
                          SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          SizedBox(width: 10),
                          Flexible(
                              child: Text('Thinking…',
                                  style: TextStyle(fontSize: 12)))
                        ])
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              Text(title,
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                      color: scheme.primary)),
                              const SizedBox(height: 4),
                              ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxHeight: 220),
                                  child: SingleChildScrollView(
                                      child: SelectableText(reply ?? '',
                                          style: const TextStyle(
                                              fontSize: 12, height: 1.45)))),
                            ])),
              IconButton(
                  tooltip: 'Dismiss',
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_rounded, size: 18)),
            ])));
  }
}

class _CenterDesk extends StatelessWidget {
  const _CenterDesk(
      {required this.workspace,
      required this.room,
      required this.widgets,
      required this.command,
      required this.pointer,
      this.desk = const _DeskData(),
      this.widgetDslByBot = const {},
      this.onWidgetAction,
      this.topContentInset = 0,
      required this.openSearch,
      this.onSubmit,
      required this.remove,
      required this.reorder,
      required this.add});
  final String workspace;
  final String? room;
  final List<_MosaicItem> widgets;
  final TextEditingController command;
  final Offset pointer;
  final _DeskData desk;
  final Map<String, DeskWidgetDsl> widgetDslByBot;
  final Future<String> Function(
          String botId, DslAction action, Map<String, dynamic> inline)?
      onWidgetAction;
  final double topContentInset;
  final VoidCallback openSearch, add;
  final ValueChanged<String>? onSubmit;
  final ValueChanged<_MosaicItem> remove;
  final ReorderCallback reorder;
  @override
  Widget build(BuildContext context) => Material(
        type: MaterialType.transparency,
        child: Stack(children: [
          Positioned.fill(
              child: IgnorePointer(
                  child: CustomPaint(
                      painter: _WorkspacePatternPainter(workspace)))),
          Positioned.fill(
              child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(18, topContentInset, 18, 104),
                  child: Column(children: [
                    SizedBox(
                        height: 150, child: _MachineFace(pointer: pointer)),
                    Row(children: [
                      Expanded(
                          child: Text(
                              room == null ? 'My trading desk' : '$room desk',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w900))),
                      IconButton(
                          onPressed: add, icon: const Icon(Icons.add_rounded)),
                      IconButton(
                          onPressed: openSearch,
                          tooltip: 'Discover widgets & tools',
                          icon: const Icon(Icons.tune_rounded)),
                    ]),
                    _MosaicGrid(
                        items: widgets,
                        onMove: reorder,
                        onDelete: remove,
                        desk: desk,
                        widgetDslByBot: widgetDslByBot,
                        onWidgetAction: onWidgetAction),
                  ]))),
          Positioned(
              left: 18,
              right: 18,
              bottom: 18,
              child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                      widthFactor:
                          MediaQuery.sizeOf(context).width < 820 ? 1 : .82,
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: _CommandBar(
                            controller: command,
                            room: room,
                            openSearch: openSearch,
                            onSubmit: onSubmit,
                          ))))),
        ]),
      );
}

class _MosaicGrid extends StatelessWidget {
  const _MosaicGrid(
      {required this.items,
      required this.onMove,
      required this.onDelete,
      this.desk = const _DeskData(),
      this.widgetDslByBot = const {},
      this.onWidgetAction});
  final List<_MosaicItem> items;
  final ReorderCallback onMove;
  final ValueChanged<_MosaicItem> onDelete;
  final _DeskData desk;
  final Map<String, DeskWidgetDsl> widgetDslByBot;
  final Future<String> Function(
          String botId, DslAction action, Map<String, dynamic> inline)?
      onWidgetAction;
  static const gap = 7.0;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final columns = math.max(
            2, math.min(6, ((box.maxWidth + gap) / (118 + gap)).floor()));
        final unit = (box.maxWidth - gap * (columns - 1)) / columns;
        final cells = <List<bool>>[];
        final positions = <({int column, int row})>[];
        for (final item in items) {
          final columnSpan = math.min(item.columns, columns);
          var row = 0;
          while (true) {
            while (cells.length < row + item.rows) {
              cells.add(List.filled(columns, false));
            }
            var placed = false;
            for (var column = 0; column <= columns - columnSpan; column++) {
              var free = true;
              for (var y = row; y < row + item.rows; y++)
                for (var x = column; x < column + columnSpan; x++) {
                  if (cells[y][x]) free = false;
                }
              if (!free) continue;
              for (var y = row; y < row + item.rows; y++)
                for (var x = column; x < column + columnSpan; x++) {
                  cells[y][x] = true;
                }
              positions.add((column: column, row: row));
              placed = true;
              break;
            }
            if (placed) break;
            row++;
          }
        }
        final height =
            cells.length * unit + math.max(0, cells.length - 1) * gap;
        return SizedBox(
            height: height,
            child: Stack(children: [
              for (var i = 0; i < items.length; i++)
                Positioned(
                  left: positions[i].column * (unit + gap),
                  top: positions[i].row * (unit + gap),
                  width: math.min(items[i].columns, columns) * unit +
                      (math.min(items[i].columns, columns) - 1) * gap,
                  height: items[i].rows * unit + (items[i].rows - 1) * gap,
                  child: DragTarget<int>(
                    onWillAcceptWithDetails: (d) => d.data != i,
                    onAcceptWithDetails: (d) => onMove(d.data, i),
                    builder: (context, candidates, _) => AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        transform: Matrix4.diagonal3Values(
                            candidates.isEmpty ? 1 : .96,
                            candidates.isEmpty ? 1 : .96,
                            1),
                        child: LongPressDraggable<int>(
                          data: i,
                          feedback: Material(
                              color: Colors.transparent,
                              child: SizedBox(
                                  width: math.min(items[i].columns, columns) *
                                      unit,
                                  height: items[i].rows * unit,
                                  child: Opacity(
                                      opacity: .86,
                                      child: _DeskWidget(
                                          item: items[i],
                                          index: i,
                                          desk: desk,
                                          widgetDslByBot: widgetDslByBot,
                                          onWidgetAction: onWidgetAction,
                                          onDelete: () {})))),
                          childWhenDragging: Opacity(
                              opacity: .18,
                              child: _DeskWidget(
                                  item: items[i],
                                  index: i,
                                  desk: desk,
                                  widgetDslByBot: widgetDslByBot,
                                  onWidgetAction: onWidgetAction,
                                  onDelete: () {})),
                          child: _DeskWidget(
                              item: items[i],
                              index: i,
                              desk: desk,
                              widgetDslByBot: widgetDslByBot,
                              onWidgetAction: onWidgetAction,
                              onDelete: () => onDelete(items[i])),
                        )),
                  ),
                ),
            ]));
      });
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
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, boxShadow: [
                      BoxShadow(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: .28),
                          blurRadius: 48)
                    ]),
                    child: Image.asset('assets/images/only_orb.png')))));
  }
}

class _CommandBar extends StatelessWidget {
  const _CommandBar(
      {required this.controller,
      required this.room,
      required this.openSearch,
      this.onSubmit});
  final TextEditingController controller;
  final String? room;
  final VoidCallback openSearch;
  final ValueChanged<String>? onSubmit;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: .2), blurRadius: 30)
          ],
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: .35))),
      child: Row(children: [
        IconButton(
            onPressed: openSearch,
            icon: const Icon(Icons.travel_explore_rounded)),
        Expanded(
            child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                    fillColor: Colors.transparent,
                    filled: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    hintMaxLines: 1,
                    hintStyle: TextStyle(
                        overflow: TextOverflow.ellipsis,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    hintText: room == null
                        ? 'Ask ONLY to research, trade, or build a strategy…'
                        : 'Command agents or message $room…'))),
        IconButton(
            onPressed: openSearch,
            tooltip: 'Voice search',
            icon: const Icon(Icons.mic_none_rounded)),
        IconButton(
            onPressed: openSearch,
            tooltip: 'Talk to agents',
            icon: const Icon(Icons.headset_mic_outlined)),
        IconButton(
            onPressed:
                onSubmit == null ? null : () => onSubmit!(controller.text),
            icon: const Icon(Icons.arrow_upward_rounded))
      ]));
}

class _DeskData {
  const _DeskData({
    this.wallet,
    this.bots = const [],
    this.market = const [],
    this.ledger = const [],
    this.feed = const [],
  });
  final Wallet? wallet;
  final List<Bot> bots;
  final List<MarketListing> market;
  final List<Map<String, dynamic>> ledger;
  final List<SocialPost> feed;
}

class _DeskWidget extends StatefulWidget {
  const _DeskWidget(
      {required this.item,
      required this.index,
      required this.onDelete,
      this.desk = const _DeskData(),
      this.widgetDslByBot = const {},
      this.onWidgetAction});
  final _MosaicItem item;
  final int index;
  final VoidCallback onDelete;
  final _DeskData desk;
  final Map<String, DeskWidgetDsl> widgetDslByBot;
  final Future<String> Function(
          String botId, DslAction action, Map<String, dynamic> inline)?
      onWidgetAction;
  @override
  State<_DeskWidget> createState() => _DeskWidgetState();
}

class _DeskWidgetState extends State<_DeskWidget> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final index = widget.index;
    final accent = [
      Colors.purpleAccent,
      Colors.cyanAccent,
      Colors.greenAccent,
      Colors.orangeAccent
    ][index % 4];
    final large = item.columns > 1 || item.rows > 1;
    final icon = _kindIcon(item.kind);
    return Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
            gradient: index % 3 == 0
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                        accent.withValues(alpha: .22),
                        Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: .5)
                      ])
                : null,
            color: index % 3 == 0
                ? null
                : Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .55),
            borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: accent, size: large ? 21 : 17),
            const Spacer(),
            PopupMenuButton<void>(
                itemBuilder: (_) => [
                      PopupMenuItem<void>(
                          onTap: widget.onDelete, child: const Text('Remove'))
                    ],
                iconSize: 17)
          ]),
          Text(item.isMiniapp ? _widgetDsl()?.title ?? item.title : item.title,
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Expanded(child: _body(context, accent, large)),
        ]));
  }

  DeskWidgetDsl? _widgetDsl() {
    final botId = widget.item.botId;
    if (botId == null) return null;
    return widget.widgetDslByBot[botId];
  }

  static IconData _kindIcon(_WidgetKind kind) => switch (kind) {
        _WidgetKind.miniapp => Icons.extension_rounded,
        _WidgetKind.market => Icons.candlestick_chart,
        _WidgetKind.portfolio => Icons.donut_large,
        _WidgetKind.agents => Icons.smart_toy_outlined,
        _WidgetKind.watchlist => Icons.star_outline,
        _WidgetKind.activity => Icons.query_stats,
        _WidgetKind.feed => Icons.dynamic_feed_outlined,
      };

  Widget _body(BuildContext context, Color accent, bool large) {
    final kind = widget.item.kind;
    if (kind == _WidgetKind.miniapp) {
      final dsl = _widgetDsl();
      if (dsl == null) {
        return const Center(
            child: Text('Waiting for widget…', style: TextStyle(fontSize: 9)));
      }
      return SingleChildScrollView(
          child: WidgetDslRenderer(
        dsl: dsl,
        accent: accent,
        dense: !large,
        onAction: (action, inline) {
          final fn = widget.onWidgetAction;
          if (fn == null) return Future.value('');
          return fn(dsl.botId, action, inline);
        },
      ));
    }
    switch (kind) {
      case _WidgetKind.market:
        final listings = widget.desk.market;
        if (listings.isEmpty) {
          return const Center(
              child: Text('No market listings yet',
                  style: TextStyle(fontSize: 9)));
        }
        return Column(children: [
          for (final l in listings.take(4))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(l.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9))),
                  Text('${l.installs}',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: accent)),
                ])),
        ]);
      case _WidgetKind.portfolio:
        final wallet = widget.desk.wallet;
        if (wallet == null) {
          return const Center(
              child: Text('No wallet', style: TextStyle(fontSize: 9)));
        }
        return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('AVAILABLE',
                  style: TextStyle(
                      fontSize: 8, letterSpacing: .6, color: AppColors.muted)),
              Text(formatLedgerCredits(wallet.available),
                  style: TextStyle(
                      fontSize: large ? 20 : 15,
                      fontWeight: FontWeight.w900,
                      color: AppColors.success)),
              const SizedBox(height: 3),
              Text('${formatLedgerCredits(wallet.locked)} locked',
                  style: const TextStyle(fontSize: 8, color: AppColors.muted)),
            ]);
      case _WidgetKind.agents:
        final bots = widget.desk.bots.where((b) => b.isAgent).toList();
        if (bots.isEmpty) {
          return const Center(
              child: Text('No agents yet', style: TextStyle(fontSize: 9)));
        }
        return Column(children: [
          for (final b in bots.take(4))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.smart_toy_outlined,
                      size: 13,
                      color: b.status == 'running'
                          ? AppColors.success
                          : AppColors.muted),
                  const SizedBox(width: 5),
                  Expanded(
                      child: Text(b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9))),
                  Text(b.status,
                      style: TextStyle(
                          fontSize: 8,
                          color: b.status == 'running'
                              ? AppColors.success
                              : AppColors.muted)),
                ])),
        ]);
      case _WidgetKind.watchlist:
        final listings = widget.desk.market.take(4).toList();
        if (listings.isEmpty) {
          return const Center(
              child: Text('Watchlist empty', style: TextStyle(fontSize: 9)));
        }
        return Column(children: [
          for (final l in listings)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(l.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9))),
                  Text('${l.price}',
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: accent)),
                ])),
        ]);
      case _WidgetKind.activity:
        final ledger = widget.desk.ledger;
        if (ledger.isEmpty) {
          return const Center(
              child: Text('No activity yet', style: TextStyle(fontSize: 9)));
        }
        return Column(children: [
          for (final entry in ledger.take(5))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Expanded(
                      child: Text(
                          (entry['description'] as String?) ??
                              entry['type'] as String? ??
                              '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9))),
                  Text(_amount(entry),
                      style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: _amountSign(entry) == '-'
                              ? AppColors.danger
                              : AppColors.success)),
                ])),
        ]);
      case _WidgetKind.feed:
        final feed = widget.desk.feed;
        if (feed.isEmpty) {
          return const Center(
              child: Text('No posts yet', style: TextStyle(fontSize: 9)));
        }
        return Column(children: [
          for (final p in feed.take(3))
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(p.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, height: 1.3))),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  static String _amount(Map<String, dynamic> entry) {
    final amount = (entry['amount'] as num?)?.toInt() ?? 0;
    return '${amount >= 0 ? '+' : '-'}${amount.abs()}';
  }

  static String _amountSign(Map<String, dynamic> entry) =>
      ((entry['amount'] as num?)?.toInt() ?? 0) >= 0 ? '+' : '-';
}

class _SocialFeed extends StatefulWidget {
  const _SocialFeed({
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
  final Map<String, String> _handles = {};
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = true;
  int _offset = 0;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _load();
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
      _load();
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
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Posted to this workspace')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Post failed: $e')));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _openComposer() async {
    final md =
        await showPostEditor(context, hint: 'Write to ${widget.workspace}…');
    if (md == null || md.trim().isEmpty) return;
    await _publish(md);
  }

  Future<void> _load({bool more = false}) async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => loading = false);
      return;
    }
    if (more) {
      if (loadingMore || !hasMore || loading) return;
      setState(() => loadingMore = true);
    } else {
      setState(() => loading = true);
    }
    try {
      final spaceFilter = widget.spaceId.isEmpty ? null : widget.spaceId;
      final offset = more ? _offset : 0;
      final results = await Future.wait([
        deps.service
            .fetchFeed(spaceId: spaceFilter, limit: _pageSize, offset: offset),
        if (!more) deps.service.fetchLeaderboard(limit: 100),
      ]);
      final feed = results[0] as List<SocialPost>;
      if (!more) {
        final leaderboard = (results[1] as List).cast<Map<String, dynamic>>();
        final me = deps.sessionController.session?.accountId ?? '';
        final handles = <String, String>{
          for (final entry in leaderboard)
            if ((entry['author_id'] as String?) != null)
              entry['author_id'] as String:
                  (entry['handle'] as String?) ?? 'user',
          if (me.isNotEmpty) me: deps.sessionController.session?.handle ?? 'me',
        };
        _handles.clear();
        _handles.addAll(handles);
      }
      if (!mounted) return;
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
      if (!mounted) return;
      setState(() {
        loading = false;
        loadingMore = false;
      });
    }
  }

  Future<void> _toggleLike(SocialPost post) async {
    final deps = widget.dependencies;
    if (deps == null || post.id.isEmpty) return;
    final index = posts.indexWhere((p) => p.id == post.id);
    if (index < 0) return;
    final liked = !post.likedByMe;
    setState(() {
      posts[index] = SocialPost(
        id: post.id,
        authorId: post.authorId,
        body: post.body,
        createdAt: post.createdAt,
        spaceId: post.spaceId,
        parentId: post.parentId,
        tags: post.tags,
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
        child: Row(children: [
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(workspace == 'Home' ? 'Universal feed' : '$workspace feed',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w900)),
                Text(
                    workspace == 'Home'
                        ? 'Public platform posts'
                        : 'Posts from this workspace',
                    style: const TextStyle(fontSize: 9))
              ])),
          const Icon(Icons.tune, size: 18)
        ]));
    final postWidgets = [
      if (widget.spaceId.isNotEmpty) _composer(context),
    ];
    if (loading) {
      postWidgets.add(const Padding(
        padding: EdgeInsets.all(28),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (posts.isEmpty) {
      postWidgets.add(Padding(
        padding: const EdgeInsets.all(28),
        child: Center(
          child: Text('No posts in this workspace yet.',
              style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      ));
    } else {
      postWidgets.addAll(posts.map((p) => _Post(
            p,
            author: _authorOf(p.authorId),
            time: _timeAgo(p.createdAt),
            onLike: () => _toggleLike(p),
          )));
    }
    if (loadingMore) {
      postWidgets.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
            child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5))),
      ));
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
                padding:
                    EdgeInsets.fromLTRB(12, widget.topContentInset, 12, 24),
                children: [header, ...postWidgets])
            : ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: postWidgets));
    if (widget.flat) return _Panel(flat: true, child: body);
    return _Panel(
        flat: widget.flat,
        child: Column(children: [
          header,
          Expanded(child: body),
        ]));
  }

  Widget _composer(BuildContext context) => Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withValues(alpha: .5))),
      child: InkWell(
        onTap: _publishing ? null : _openComposer,
        borderRadius: BorderRadius.circular(12),
        child: Row(children: [
          const Icon(Icons.edit_note_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text(
            _publishing ? 'Publishing…' : 'Write a post for this workspace…',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          )),
          IconButton(
            onPressed: _publishing ? null : _openComposer,
            icon: _publishing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.add_rounded, size: 20),
          ),
        ]),
      ));

  String _authorOf(String authorId) {
    final handle = _handles[authorId];
    if (handle != null && handle.isNotEmpty) return '@$handle';
    if (authorId.length < 8) return 'user';
    return 'u_${authorId.substring(authorId.length - 6)}';
  }

  static String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }
}

class _Post extends StatelessWidget {
  const _Post(this.post,
      {required this.author, required this.time, this.onLike});
  final SocialPost post;
  final String author;
  final String time;
  final VoidCallback? onLike;
  @override
  Widget build(BuildContext context) {
    final initials =
        author.length >= 3 ? author.substring(1, 3).toUpperCase() : 'OC';
    return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: .45),
            borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(
                radius: 17,
                child: Text(initials, style: const TextStyle(fontSize: 10))),
            const SizedBox(width: 9),
            Expanded(
                child: Text(author,
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 12))),
            Text(time, style: const TextStyle(fontSize: 10))
          ]),
          const SizedBox(height: 11),
          RichPostContent(post.body),
          const SizedBox(height: 12),
          Row(children: [
            Chip(
                label: Text(
                    post.tags.isEmpty ? 'POST' : post.tags.first.toUpperCase(),
                    style: const TextStyle(fontSize: 9))),
            const Spacer(),
            InkWell(
                onTap: onLike,
                borderRadius: BorderRadius.circular(12),
                child: Row(children: [
                  Icon(
                      post.likedByMe
                          ? Icons.favorite_rounded
                          : Icons.favorite_border,
                      size: 15,
                      color: post.likedByMe
                          ? AppColors.danger
                          : Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text('${post.likes}', style: const TextStyle(fontSize: 10)),
                ])),
            const SizedBox(width: 14),
            const Icon(Icons.chat_bubble_outline, size: 15),
          ])
        ]));
  }
}

class _RoomChat extends StatefulWidget {
  const _RoomChat({
    super.key,
    required this.room,
    required this.messages,
    this.working = '',
    this.workingDetail = '',
    this.me = '',
    this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.canManageTasks = false,
    this.mentionable = const [],
    this.onSend,
    this.flat = false,
    this.topContentInset = 0,
  });
  final String room;
  final List<RoomMessage> messages;
  final String working;
  final String workingDetail;
  final String me;
  final AppDependencies? dependencies;
  final String spaceId;
  final String roomId;
  final bool canManageTasks;
  final List<Bot> mentionable;
  final Future<void> Function(
      String body, List<String> mentions, List<String> attachments)? onSend;
  final bool flat;
  final double topContentInset;
  @override
  State<_RoomChat> createState() => _RoomChatState();
}

class _RoomChatState extends State<_RoomChat> {
  final input = TextEditingController();
  final Set<String> _mentions = {};
  final Map<String, String> _mentionNames = {};
  final List<_DraftAttachment> _drafts = [];
  final ScrollController _chatScroll = ScrollController();
  final Set<String> _expandedLogs = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(covariant _RoomChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New messages arrived (async agent replies / logs): follow the bottom when
    // the user was already near it, so tradera's flow appears live.
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      final pos = _chatScroll.position;
      if (pos.maxScrollExtent - pos.pixels < 160) {
        _chatScroll.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  void _toggleLog(String id) {
    setState(() {
      if (!_expandedLogs.remove(id)) _expandedLogs.add(id);
    });
  }

  @override
  void dispose() {
    input.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _pickMention() {
    final agents = widget.mentionable;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No agents in this workspace to mention.')));
      return;
    }
    showModalBottomSheet<Bot>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (context) => SafeArea(
                child: SizedBox(
              height: 360,
              child: Column(children: [
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Mention an agent',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w900))),
                Expanded(
                    child: ListView.separated(
                        itemCount: agents.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final b = agents[i];
                          final already = _mentions.contains(b.id);
                          return ListTile(
                              leading: const Icon(Icons.smart_toy_outlined,
                                  size: 20),
                              title: Text(b.name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(b.kind,
                                  style: const TextStyle(fontSize: 10)),
                              trailing: Icon(already
                                  ? Icons.check_circle_rounded
                                  : Icons.add_circle_outline_rounded),
                              onTap: () => Navigator.pop(context, b));
                        })),
              ]),
            ))).then((b) {
      if (b == null || !mounted) return;
      setState(() {
        _mentions.add(b.id);
        _mentionNames[b.id] = b.name;
        if (!input.text.endsWith(' ')) input.text += ' ';
        input.text += '@${b.name} ';
      });
    });
  }

  void _removeMention(String id) {
    setState(() => _mentions.remove(id));
  }

  // Opens the markup message designer (like the post designer) so the user can
  // author a rich message and send it to the room chat.
  Future<void> _openDesigner() async {
    final initial = input.text.trim().isEmpty ? null : input.text.trim();
    final md = await showMessageDesigner(context, initial: initial);
    if (md == null || md.trim().isEmpty || !mounted) return;
    final attachments = _drafts
        .where((d) => d.uploaded && d.fileId.isNotEmpty)
        .map((d) => d.fileId)
        .toList();
    input.text = md;
    try {
      await widget.onSend?.call(md, _mentions.toList(), attachments);
    } catch (_) {
      // The parent reports the error. Keep the designed message and files.
      return;
    }
    if (!mounted) return;
    input.clear();
    setState(() {
      _mentions.clear();
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
    });
  }

  Future<void> _submit(String value) async {
    final drafts =
        _drafts.where((d) => d.uploaded && d.fileId.isNotEmpty).toList();
    final attachments = drafts.map((d) => d.fileId).toList();
    if (value.trim().isEmpty && attachments.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend?.call(value.trim(), _mentions.toList(), attachments);
      if (!mounted) return;
      // Success: drop the sent attachments and clear the composer.
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
      input.clear();
      setState(() => _mentions.clear());
    } catch (_) {
      // Keep the composer + drafts so the user can retry.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── file attachments ────────────────────────────────────────────────────

  void _showAttachSheet() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
        context: context,
        backgroundColor: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
        builder: (context) => SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Attach to message',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        _attachOption(Icons.photo_rounded, 'Photo / GIF', () {
                          Navigator.pop(context);
                          _pickFile(_imageTypes);
                        }),
                        _attachOption(Icons.videocam_rounded, 'Video', () {
                          Navigator.pop(context);
                          _pickFile(_videoTypes);
                        }),
                        _attachOption(Icons.mic_rounded, 'Voice / Audio', () {
                          Navigator.pop(context);
                          _pickFile(_audioTypes);
                        }),
                        _attachOption(
                            Icons.insert_drive_file_rounded, 'Document', () {
                          Navigator.pop(context);
                          _pickFile(_documentTypes);
                        }),
                      ]),
                    ]))));
  }

  Widget _attachOption(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
            width: 96,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Icon(icon, color: AppColors.primary, size: 26),
              const SizedBox(height: 6),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700)),
            ])));
  }

  static const _imageTypes = [
    XTypeGroup(
      label: 'Images',
      mimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'],
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    ),
  ];
  static const _videoTypes = [
    XTypeGroup(
      label: 'Videos',
      mimeTypes: [
        'video/mp4',
        'video/quicktime',
        'video/webm',
        'video/ogg',
        'video/x-msvideo',
      ],
      extensions: ['mp4', 'mov', 'webm', 'ogv', 'avi', 'mkv'],
    ),
  ];
  static const _audioTypes = [
    XTypeGroup(
      label: 'Audio',
      mimeTypes: [
        'audio/mpeg',
        'audio/mp4',
        'audio/wav',
        'audio/x-wav',
        'audio/ogg',
        'audio/webm',
        'audio/aac',
        'audio/x-m4a',
        'audio/opus',
        'audio/amr',
      ],
      extensions: [
        'mp3',
        'm4a',
        'wav',
        'ogg',
        'oga',
        'opus',
        'webm',
        'aac',
        'amr'
      ],
    ),
  ];
  static const _documentTypes = [
    XTypeGroup(
      label: 'Documents',
      mimeTypes: [
        'application/pdf',
        'text/plain',
        'text/csv',
        'text/markdown',
        'application/json',
        'application/zip',
        'application/msword',
        'text/html',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ],
      extensions: [
        'pdf',
        'txt',
        'md',
        'csv',
        'json',
        'log',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'zip',
        'rar',
        '7z',
        'tar',
        'gz',
        'yaml',
        'yml',
        'html',
        'htm',
      ],
    ),
  ];

  Future<void> _pickFile(List<XTypeGroup> types) async {
    final deps = widget.dependencies;
    if (deps == null || widget.spaceId.isEmpty) return;
    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: types);
    } catch (_) {
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return;
      final draft = _DraftAttachment(
          name: picked.name, mime: _mimeFromName(picked.name), bytes: bytes);
      setState(() => _drafts.add(draft));
      await _uploadDraft(draft);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Read failed: $e')));
    }
  }

  Future<void> _uploadDraft(_DraftAttachment draft) async {
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => draft.uploading = true);
    try {
      final uploaded = await deps.service.uploadFile(
        widget.spaceId,
        roomId: widget.roomId,
        name: draft.name,
        mime: draft.mime,
        bytes: draft.bytes,
      );
      draft.fileId = uploaded.id;
      draft.uploaded = true;
    } catch (e) {
      draft.error = e.toString();
    } finally {
      // The upload finished (success or failure) — stop the spinner.
      draft.uploading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeDraft(_DraftAttachment draft) async {
    // Best-effort cleanup of the uploaded file so cancelled drafts don't leak
    // into the workspace file library.
    if (draft.uploaded && draft.fileId.isNotEmpty) {
      try {
        await widget.dependencies?.service.deleteFile(draft.fileId);
      } catch (_) {}
    }
    if (mounted) setState(() => _drafts.remove(draft));
  }

  Widget _draftChip(_DraftAttachment d) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          if (d.bytes.isNotEmpty && d.mime.startsWith('image/'))
            ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(d.bytes,
                    width: 30, height: 30, fit: BoxFit.cover))
          else
            Icon(
                d.mime.startsWith('audio/')
                    ? Icons.mic_rounded
                    : d.mime.startsWith('video/')
                        ? Icons.videocam_rounded
                        : Icons.insert_drive_file_rounded,
                size: 22,
                color: AppColors.primary),
          const SizedBox(width: 7),
          Expanded(
              child: d.uploading
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : d.error != null
                      ? const Icon(Icons.error_outline_rounded,
                          color: AppColors.danger, size: 16)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              Text(d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)),
                              const Text('ready to send',
                                  style: TextStyle(
                                      fontSize: 8, color: AppColors.success)),
                            ])),
          const SizedBox(width: 3),
          IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              onPressed: () => _removeDraft(d),
              icon: const Icon(Icons.close_rounded)),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    // Show the conversation chronologically (oldest→newest). message_list
    // returns newest-first, so sort by createdAt with the id as a tiebreaker.
    final messages = [...widget.messages]..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    if (widget.flat) {
      return _Panel(
          flat: true,
          child: Stack(children: [
            Positioned.fill(
                child: CustomPaint(
              painter: _ChatPatternPainter(
                  Theme.of(context).colorScheme.primary, widget.room),
              child: ListView(
                  controller: _chatScroll,
                  padding:
                      EdgeInsets.fromLTRB(12, widget.topContentInset, 12, 94),
                  children: [
                    _chatHeader(),
                    const SizedBox(height: 10),
                    if (messages.isEmpty)
                      const _NoMessages()
                    else ...[
                      ...List.generate(messages.length,
                          (i) => _chatBubble(context, messages[i])),
                      if (widget.working.isNotEmpty)
                        _WorkingIndicator(
                            agent: widget.working,
                            detail: widget.workingDetail),
                    ]
                  ]),
            )),
            Positioned(left: 10, right: 10, bottom: 10, child: _composer()),
          ]));
    }
    return _Panel(
      flat: widget.flat,
      child: Column(children: [
        _chatHeader(),
        Expanded(
            child: CustomPaint(
          painter: _ChatPatternPainter(
              Theme.of(context).colorScheme.primary, widget.room),
          child: messages.isEmpty
              ? const _NoMessages()
              : ListView(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  children: List.generate(messages.length,
                          (i) => _chatBubble(context, messages[i])) +
                      [
                        if (widget.working.isNotEmpty)
                          _WorkingIndicator(
                              agent: widget.working,
                              detail: widget.workingDetail),
                      ]),
        )),
        Padding(padding: const EdgeInsets.all(10), child: _composer()),
      ]),
    );
  }

  Widget _chatHeader() => Container(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        CircleAvatar(child: Text(widget.room.isEmpty ? 'R' : widget.room[0])),
        const SizedBox(width: 10),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.room,
              style: const TextStyle(fontWeight: FontWeight.w900)),
          Text(
              widget.messages.isEmpty
                  ? 'Live room'
                  : '${widget.messages.length} messages',
              style: const TextStyle(fontSize: 10))
        ])),
        IconButton(
            tooltip: 'Agent tasks',
            onPressed: widget.dependencies == null ||
                    widget.spaceId.isEmpty ||
                    widget.roomId.isEmpty
                ? null
                : () => showWorkflowPanel(context, widget.dependencies!.service,
                    widget.spaceId, widget.roomId, widget.room,
                    canManage: widget.canManageTasks),
            icon: const Icon(Icons.account_tree_outlined, size: 18)),
        IconButton(
            tooltip: 'Routines',
            onPressed: widget.dependencies == null
                ? null
                : () => showRoutinesSheet(context, widget.dependencies!,
                    widget.spaceId, widget.roomId, widget.room),
            icon: const Icon(Icons.schedule_rounded, size: 18)),
        const Icon(Icons.more_vert)
      ]));
  Widget _composer() => Container(
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: Theme.of(context)
                  .colorScheme
                  .outlineVariant
                  .withValues(alpha: .5))),
      child: Column(children: [
        if (_drafts.isNotEmpty)
          Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: SizedBox(
                  height: 42,
                  child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _drafts.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 6),
                      itemBuilder: (context, index) =>
                          _draftChip(_drafts[index])))),
        if (_mentions.isNotEmpty)
          Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final id in _mentions)
                      InputChip(
                          visualDensity: VisualDensity.compact,
                          label: Text('@${_mentionNames[id] ?? id}',
                              style: const TextStyle(fontSize: 10)),
                          onDeleted: () => _removeMention(id)),
                  ]))),
        Row(children: [
          IconButton(
              tooltip: 'Attach file',
              onPressed: _sending ? null : _showAttachSheet,
              icon: const Icon(Icons.add_circle_outline_rounded, size: 18)),
          IconButton(
              tooltip: 'Mention an agent',
              onPressed: _pickMention,
              icon: const Icon(Icons.alternate_email_rounded, size: 18)),
          IconButton(
              tooltip: 'Design a message',
              onPressed: _sending ? null : _openDesigner,
              icon: const Icon(Icons.auto_awesome_rounded, size: 18)),
          Expanded(
              child: TextField(
                  controller: input,
                  enabled: !_sending,
                  onSubmitted: _submit,
                  decoration: const InputDecoration(
                      hintText: 'Message room…', border: InputBorder.none))),
          IconButton(
              onPressed: _sending ? null : () => _submit(input.text),
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded, size: 18)),
        ]),
      ]));
  Widget _chatBubble(BuildContext context, RoomMessage m) {
    // Agentic-flow content (tradera's plans, dispatches, tool/sandbox outputs)
    // renders as a collapsible log section rather than a chat bubble.
    if (m.kind == 'log') {
      return _LogSection(
        title: _logTitle(m.body),
        body: m.body,
        expanded: _expandedLogs.contains(m.id),
        onToggle: () => _toggleLog(m.id),
        dependencies: widget.dependencies,
      );
    }
    final mine = m.senderId == widget.me;
    final time = _msgTime(m.createdAt);
    final deps = widget.dependencies;
    return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(11),
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: BoxDecoration(
                color: mine
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(18)),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (m.attachments.isNotEmpty)
                ...m.attachments.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: AttachmentBubble(
                        file: f,
                        headers: deps?.service.authHeaders() ?? const {},
                        resolveUrl: deps == null
                            ? null
                            : (file) => deps.service.fileContentUrl(file.id),
                        fetchBytes: (file) =>
                            deps?.service.downloadFile(file.id) ??
                            Future.value(Uint8List(0)),
                        mine: mine,
                      ),
                    )),
              if (m.body.trim().isNotEmpty)
                RichPostContent(m.body,
                    headers: deps?.service.authHeaders() ?? const {},
                    onLinkTap: deps == null
                        ? null
                        : (link) =>
                            openWorkspaceLink(context, deps.service, link)),
              // A gateway proxy message gets an "open in webview" button so the
              // room's users can view the page served from the sandbox behind it.
              if (deps != null &&
                  m.kind != 'log' &&
                  _proxyPathIn(m.body) != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _ProxyOpenButton(
                        title: _proxyTitle(m.body) ?? 'Sandbox service',
                        url:
                            deps.service.proxyUrl(_proxyPathIn(m.body) ?? ''))),
              const SizedBox(height: 4),
              Text(
                  mine
                      ? 'You · $time'
                      : '@${m.senderId.isEmpty ? '?' : m.senderId.substring(0, 8)} · $time',
                  style: const TextStyle(fontSize: 8))
            ])));
  }

  static String _msgTime(DateTime t) =>
      '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

/// A file picked for an in-flight room message. It is uploaded to the space's
/// room as soon as it is picked so the message only references the file id.
class _DraftAttachment {
  _DraftAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
  });

  final String name;
  final String mime;
  final Uint8List bytes;
  bool uploading = false;
  bool uploaded = false;
  String fileId = '';
  String? error;
}

/// Guess a MIME type from a file name extension (mirrors the server-side sniff).
String _mimeFromName(String name) {
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mov':
      return 'video/quicktime';
    case 'ogg':
      return 'audio/ogg';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'wav':
      return 'audio/wav';
    case 'opus':
      return 'audio/opus';
    case 'pdf':
      return 'application/pdf';
    case 'json':
      return 'application/json';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'md':
      return 'text/markdown';
    case 'txt':
    case 'log':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'zip':
      return 'application/zip';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    default:
      return 'application/octet-stream';
  }
}

// _proxyPathIn extracts a gateway proxy path (/v1/proxy/{id}/) from a message
// body, if any.
String? _proxyPathIn(String body) {
  final m = RegExp(r'/v1/proxy/[0-9a-fA-F]{32}/').firstMatch(body);
  return m?.group(0);
}

// _proxyTitle pulls a short title out of a proxy message (the "🔗 **Title**"
// lead), falling back to null.
String? _proxyTitle(String body) {
  final m = RegExp(r'\*\*(.+?)\*\*').firstMatch(body);
  return m?.group(1)?.trim();
}

// _ProxyOpenButton opens the proxied sandbox page. On web the page is opened in
// a new browser tab (reliable); on native platforms it opens the in-app webview.
class _ProxyOpenButton extends StatelessWidget {
  const _ProxyOpenButton({required this.title, required this.url});

  final String title;
  final String url;

  Future<void> _open(BuildContext context) async {
    try {
      await openWorkspacePreview(context, url, title: title);
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not open preview. Try again or download the delivered files.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  kIsWeb
                      ? Icons.open_in_new_rounded
                      : Icons.open_in_browser_rounded,
                  size: 16,
                  color: scheme.onPrimary),
              const SizedBox(width: 6),
              Text(
                  workspacePreviewUsesWebView ? 'Open in webview' : 'Open page',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimary)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NoMessages extends StatelessWidget {
  const _NoMessages();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'No messages yet. Say hello!',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}

// _WorkingIndicator shows, below the last message, which agent is currently
// working and a live sentence describing what it is doing right now
// ("running in the sandbox…", "generating an image…", "thinking…", …) with a
// minimal pulsing-dots animation.
class _WorkingIndicator extends StatefulWidget {
  const _WorkingIndicator({required this.agent, this.detail = ''});
  final String agent;
  final String detail;

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1300))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail =
        widget.detail.trim().isEmpty ? 'agent is working' : widget.detail;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: .75),
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.agent,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary)),
          const SizedBox(width: 4),
          Text(detail,
              style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(width: 8),
          _WorkingDots(controller: _controller, color: scheme.primary),
        ]),
      ),
    );
  }
}

// _WorkingDots is the minimal animated part: three dots pulsing in sequence.
class _WorkingDots extends StatelessWidget {
  const _WorkingDots({required this.controller, required this.color});
  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SizedBox(
        width: 22,
        height: 12,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(3, (i) {
            // Staggered phase so the dots pulse left-to-right.
            final t = (controller.value * 3 + (2 - i)) % 1.0;
            final opacity = 0.2 + 0.8 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
            return Opacity(
              opacity: opacity.clamp(0.2, 1.0),
              child: Container(
                  width: 5,
                  height: 5,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
            );
          }),
        ),
      ),
    );
  }
}

// _logTitle derives a short label for an agentic-flow log message so it can be
// rendered as a collapsible section header.
String _logTitle(String body) {
  final first = body.trim().split('\n').first.trim();
  final lower = first.toLowerCase();
  if (first.startsWith('📋')) return 'Dispatching';
  if (lower.contains('execution plan') || lower.startsWith('1.')) return 'Plan';
  if (first.startsWith('###')) {
    final t = first.replaceAll('#', '').trim();
    return t.isEmpty ? 'Agent contribution' : t;
  }
  if (first.startsWith('exit=') || lower.contains('error'))
    return 'Sandbox output';
  return first.length > 48 ? first.substring(0, 48) + '…' : first;
}

// _LogSection renders an agentic-flow log as a collapsible/expandable section
// between conversation messages.
class _LogSection extends StatelessWidget {
  const _LogSection({
    required this.title,
    required this.body,
    required this.expanded,
    required this.onToggle,
    this.dependencies,
  });

  final String title;
  final String body;
  final bool expanded;
  final VoidCallback onToggle;
  final AppDependencies? dependencies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(children: [
              Icon(Icons.terminal_rounded,
                  size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
        if (expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: body.trim().isEmpty
                ? Text('(no output)',
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
                : RichPostContent(body,
                    headers: dependencies?.service.authHeaders() ?? const {}),
          ),
      ]),
    );
  }
}

class _SearchPanel extends StatefulWidget {
  const _SearchPanel(
      {required this.workspace, this.spaceId = '', this.dependencies});
  final String workspace;
  final String spaceId;
  final AppDependencies? dependencies;
  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  int localSection = 0;
  int globalSection = 0;
  int filter = 0;
  String query = '';
  static const local = [
    'Users',
    'Agents',
    'Tools',
    'Media',
    'Documents',
    'Links',
    'GIFs',
    'Messages'
  ];
  static const global = ['Users', 'Agents', 'Tools', 'Posts', 'Workspaces'];
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
    tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final sections = tabs.index == 0 ? local : global;
    final selected = tabs.index == 0 ? localSection : globalSection;
    return Padding(
        padding:
            EdgeInsets.fromLTRB(compact ? 14 : 24, 18, compact ? 14 : 24, 12),
        child: Column(children: [
          Row(children: [
            const Icon(Icons.travel_explore_rounded, size: 30),
            const SizedBox(width: 12),
            Expanded(
                child: Text(compact ? 'Discover' : 'Search & discover',
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w900))),
            IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close))
          ]),
          const SizedBox(height: 18),
          TextField(
              autofocus: true,
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: const Icon(Icons.tune_rounded),
                  hintText: tabs.index == 0
                      ? 'Search ${widget.workspace}…'
                      : 'Search all of Tradera…')),
          const SizedBox(height: 9),
          SizedBox(
              height: 34,
              child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: 4,
                  separatorBuilder: (_, __) => const SizedBox(width: 7),
                  itemBuilder: (context, index) {
                    final labels = [
                      'Relevant',
                      'Trending',
                      'Verified',
                      'Recent'
                    ];
                    return FilterChip(
                        selected: filter == index,
                        onSelected: (_) => setState(() => filter = index),
                        label: Text(labels[index],
                            style: const TextStyle(fontSize: 10)),
                        visualDensity: VisualDensity.compact);
                  })),
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .55),
                borderRadius: BorderRadius.circular(24)),
            child: TabBar(
                controller: tabs,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(20)),
                tabs: [
                  Tab(text: 'In ${widget.workspace}'),
                  const Tab(text: 'Explore Tradera')
                ]),
          ),
          Expanded(
              child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  child: _SearchResults(
                      key: ValueKey('${tabs.index}-$selected-$query'),
                      section: sections[selected],
                      global: tabs.index == 1,
                      workspace: widget.workspace,
                      spaceId: widget.spaceId,
                      query: query,
                      filter: filter,
                      dependencies: widget.dependencies))),
          _SearchSectionNav(
              sections: sections,
              selected: selected,
              onSelect: (value) => setState(() {
                    if (tabs.index == 0) {
                      localSection = value;
                    } else {
                      globalSection = value;
                    }
                  })),
        ]));
  }
}

class _SearchSectionNav extends StatelessWidget {
  const _SearchSectionNav(
      {required this.sections, required this.selected, required this.onSelect});
  final List<String> sections;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final tabWidths = [
          for (final section in sections) _searchTabWidth(context, section)
        ];
        final contentWidth =
            8 + tabWidths.fold<double>(0, (width, tab) => width + tab);
        final width = math.min(box.maxWidth, contentWidth);
        return Center(
            child: SizedBox(
                width: width,
                height: 56,
                child: Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: .12),
                              blurRadius: 18,
                              offset: const Offset(0, 7))
                        ]),
                    child: DefaultTabController(
                        key: ValueKey(sections.join('-')),
                        length: sections.length,
                        initialIndex: selected,
                        child: TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            dividerColor: Colors.transparent,
                            indicatorSize: TabBarIndicatorSize.tab,
                            indicator: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                borderRadius: BorderRadius.circular(22),
                                boxShadow: [
                                  BoxShadow(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: .12),
                                      blurRadius: 10)
                                ]),
                            labelColor: Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer,
                            unselectedLabelColor:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                            labelStyle: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w800),
                            unselectedLabelStyle: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w500),
                            labelPadding: EdgeInsets.zero,
                            onTap: onSelect,
                            tabs: [
                              for (var index = 0;
                                  index < sections.length;
                                  index++)
                                Tab(
                                    height: 42,
                                    child: SizedBox(
                                        width: tabWidths[index],
                                        child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(
                                                  _sectionIcon(sections[index]),
                                                  size: 17),
                                              const SizedBox(width: 6),
                                              Text(sections[index])
                                            ])))
                            ])))));
      });
}

double _searchTabWidth(BuildContext context, String section) {
  final painter = TextPainter(
      text: TextSpan(
          text: section,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1)
    ..layout();
  return painter.width + 39;
}

IconData _sectionIcon(String section) => switch (section) {
      'Users' => Icons.people_outline,
      'Agents' => Icons.smart_toy_outlined,
      'Tools' => Icons.extension_outlined,
      'Media' => Icons.perm_media_outlined,
      'Documents' => Icons.description_outlined,
      'Links' => Icons.link_rounded,
      'GIFs' => Icons.gif_box_outlined,
      'Messages' => Icons.chat_bubble_outline_rounded,
      'Posts' => Icons.dynamic_feed_outlined,
      'Rooms' => Icons.forum_outlined,
      'Workspaces' => Icons.hub_outlined,
      _ => Icons.search_rounded
    };

class _SearchResults extends StatefulWidget {
  const _SearchResults(
      {super.key,
      required this.section,
      required this.global,
      required this.workspace,
      required this.spaceId,
      required this.query,
      required this.filter,
      this.dependencies});
  final String section;
  final bool global;
  final String workspace;
  final String spaceId;
  final String query;
  final int filter;
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
  List<String> _items = const [];
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
  Future<List<String>> _fetchPage(AppDependencies deps, int offset) async {
    final q = widget.query.trim().toLowerCase();
    final space = widget.spaceId;
    switch (widget.section) {
      case 'Users':
        if (widget.global) {
          final users = await deps.service
              .searchUsers(q, limit: _pageSize, offset: offset);
          return users.map((u) => u.handle).toList();
        }
        if (space.isEmpty) return const [];
        final mems = await deps.service
            .fetchSpaceMembers(space, limit: _pageSize, offset: offset);
        return mems
            .where((m) => m['kind'] != 'bot')
            .map((m) =>
                (m['handle'] as String?) ?? (m['member_id'] as String? ?? ''))
            .where((n) => n.isNotEmpty && n.toLowerCase().contains(q))
            .toList();
      case 'Agents':
      case 'Tools':
        final isTool = widget.section == 'Tools';
        if (widget.global) {
          final kinds = isTool ? 'miniapp,tool' : 'agent';
          final bots = await deps.service
              .searchBots(q, kind: kinds, limit: _pageSize, offset: offset);
          return bots
              .map((b) => b['name'] as String? ?? '')
              .where((n) => n.isNotEmpty && n.toLowerCase().contains(q))
              .toList();
        }
        if (space.isEmpty) return const [];
        final sb = await deps.service.fetchSpaceBots(space);
        return sb
            .where((b) => isTool ? (b.isMiniapp || b.isTool) : b.isAgent)
            .map((b) => b.name)
            .where((n) => n.toLowerCase().contains(q))
            .skip(offset)
            .take(_pageSize)
            .toList();
      case 'Workspaces':
        if (!widget.global) return const [];
        final spaces = await deps.service
            .searchSpaces(q, limit: _pageSize, offset: offset);
        return spaces.map((s) => s['name'] as String? ?? '').toList();
      case 'Posts':
        if (!widget.global) return const [];
        final posts =
            await deps.service.searchPosts(q, limit: _pageSize, offset: offset);
        return posts.map((p) => p.body).toList();
      case 'Messages':
        if (space.isEmpty) return const [];
        final msgs = await deps.service.searchSpaceMessages(space,
            query: q, limit: _pageSize, offset: offset);
        return msgs
            .map((m) => m['body'] as String? ?? '')
            .where((n) => n.isNotEmpty)
            .toList();
      case 'Media':
      case 'Documents':
      case 'Links':
      case 'GIFs':
        if (space.isEmpty) return const [];
        final files = await deps.service
            .fetchFiles(space, limit: _pageSize, offset: offset);
        return files
            .where((f) => _fileMatchesSection(f, widget.section))
            .map((f) => f['name'] as String? ?? 'file')
            .where((n) => n.toLowerCase().contains(q))
            .toList();
      default:
        return const [];
    }
  }

  static bool _fileMatchesSection(Map<String, dynamic> file, String section) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (section) {
      case 'Media':
        return mime.startsWith('image/') || mime.startsWith('video/');
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
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
          child: Row(children: [
            Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13)),
                child: Icon(_sectionIcon(section), size: 19)),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(section,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w900)),
                  Text(
                      widget.global
                          ? 'Discover across the platform'
                          : 'Results from ${widget.workspace} workspace',
                      style: const TextStyle(fontSize: 10))
                ])),
            if (count != null)
              Chip(
                  avatar: const Icon(Icons.auto_awesome_rounded, size: 13),
                  label: Text('$count found',
                      style: const TextStyle(fontSize: 9))),
          ])),
      Expanded(child: LayoutBuilder(builder: (context, grid) {
        const gap = 12.0;
        final columns = math.max(
            1, math.min(4, ((grid.maxWidth + gap) / (250 + gap)).floor()));
        if (_loading) return const Center(child: CircularProgressIndicator());
        if (_items.isEmpty)
          return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.search_off_rounded, size: 42),
            SizedBox(height: 10),
            Text('No matching results',
                style: TextStyle(fontWeight: FontWeight.w800))
          ]));
        return GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: gap,
                mainAxisSpacing: gap,
                mainAxisExtent: 206),
            itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= _items.length) {
                return const Center(
                    child: Padding(
                  padding: EdgeInsets.all(18),
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5)),
                ));
              }
              return _SearchResultCard(
                  section: section,
                  title: _items[index],
                  global: widget.global,
                  spaceId: widget.spaceId,
                  index: index,
                  filter: widget.filter,
                  dependencies: widget.dependencies);
            });
      })),
    ]);
  }
}

class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard(
      {required this.section,
      required this.title,
      required this.global,
      required this.index,
      required this.filter,
      this.spaceId = '',
      this.dependencies});
  final String section, title;
  final bool global;
  final int index, filter;
  final String spaceId;
  final AppDependencies? dependencies;
  bool get visual => const ['Media', 'GIFs', 'Posts'].contains(section);
  @override
  Widget build(BuildContext context) {
    final color = [
      Colors.purpleAccent,
      Colors.cyan,
      Colors.green,
      Colors.orangeAccent
    ][index % 4];
    return Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: _hasProfile
                ? () => _openEntityProfile(
                    context, section, title, dependencies, spaceId)
                : null,
            child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (visual)
                        Container(
                            height: 58,
                            margin: const EdgeInsets.only(bottom: 9),
                            decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [
                                  color.withValues(alpha: .55),
                                  Theme.of(context).colorScheme.primaryContainer
                                ]),
                                borderRadius: BorderRadius.circular(14)),
                            child: Center(
                                child: Icon(
                                    section == 'Posts'
                                        ? Icons.article_outlined
                                        : Icons.play_circle_outline_rounded,
                                    color: Colors.white,
                                    size: 28)))
                      else
                        Row(children: [
                          CircleAvatar(
                              backgroundColor: color.withValues(alpha: .18),
                              child: Icon(_sectionIcon(section),
                                  color: color, size: 19)),
                          const Spacer(),
                          IconButton(
                              onPressed: () {},
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.more_horiz, size: 18))
                        ]),
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      Text(_description(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 10,
                              height: 1.35,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant)),
                      const Spacer(),
                      Row(children: [
                        MiniTag(global ? 'GLOBAL' : 'WORKSPACE', color),
                        const SizedBox(width: 6),
                        MiniTag(
                            [
                              'RELEVANT',
                              'TRENDING',
                              'VERIFIED',
                              'RECENT'
                            ][filter],
                            Theme.of(context).colorScheme.primary),
                        const Spacer(),
                        IconButton.filledTonal(
                            onPressed: _hasProfile
                                ? () => _openEntityProfile(
                                    context, section, title, dependencies)
                                : () {},
                            tooltip: _action(),
                            icon: Icon(_actionIcon(), size: 17))
                      ])
                    ]))));
  }

  String _description() => switch (section) {
        'Users' => 'Systematic trader · macro and digital assets',
        'Agents' =>
          'Autonomous market intelligence with configurable permissions',
        'Tools' => 'Connected trading utility · privacy reviewed',
        'Rooms' =>
          'Active discussion, agents, shared research and live widgets',
        'Workspaces' =>
          'Public trading workspace with rooms, research and shared agents',
        'Documents' => 'Research document · updated recently',
        'Messages' => 'Matched conversation with room context',
        'Links' => 'Saved research resource from this workspace',
        'Media' => 'Rich market analysis with charts and commentary',
        'GIFs' => 'Shared reaction from workspace media',
        'Posts' => 'Market insight with discussion and trade context',
        _ => 'Relevant result selected for your current search'
      };
  bool get _hasProfile => const [
        'Users',
        'Agents',
        'Tools',
        'Workspaces',
        'Rooms'
      ].contains(section);
  String _action() => _hasProfile ? 'View profile' : 'Open';
  IconData _actionIcon() =>
      _hasProfile ? Icons.arrow_outward_rounded : Icons.arrow_forward_rounded;
}

void _openEntityProfile(BuildContext context, String section, String title,
    [AppDependencies? dependencies, String spaceId = '']) {
  final profile = _EntityProfileScreen(
      section: section,
      title: title,
      dependencies: dependencies,
      spaceId: spaceId);
  if (MediaQuery.sizeOf(context).width < 820) {
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
        builder: (_) =>
            FractionallySizedBox(heightFactor: .94, child: profile));
    return;
  }
  showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close profile',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 420),
      pageBuilder: (routeContext, __, ___) {
        final size = MediaQuery.sizeOf(routeContext);
        return Material(
            color: Theme.of(routeContext).colorScheme.surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: BorderRadius.circular(30),
            child: SizedBox(
                width: math.min(700, size.width - 48),
                height: math.min(760, size.height - 48),
                child: profile));
      },
      transitionBuilder: (routeContext, animation, __, child) => Align(
          alignment: Alignment.center,
          child:
              desktopFloatingPanelTransition(routeContext, animation, child)));
}

class _EntityProfileScreen extends StatefulWidget {
  const _EntityProfileScreen(
      {required this.section,
      required this.title,
      this.dependencies,
      this.spaceId = ''});
  final String section, title;
  final AppDependencies? dependencies;

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
        case 'Tools':
          var bots = await service.fetchBots();
          var bot = bots
              .where((b) => widget.section == 'Agents'
                  ? b.isAgent
                  : (b.isMiniapp || b.isTool))
              .where((b) => b.name == widget.title)
              .firstOrNull;
          // Agents/tools opened from a workspace tab are space bots; resolve
          // them from the workspace too when the global list has no match.
          if (bot == null && widget.spaceId.isNotEmpty) {
            try {
              final sb = await service.fetchSpaceBots(widget.spaceId);
              bot = sb
                  .where((b) => widget.section == 'Agents'
                      ? b.isAgent
                      : (b.isMiniapp || b.isTool))
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
                inSpace = sb.any((b) =>
                    b.id == resolved.id || b.accountId == resolved.accountId);
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
          final users = await service.searchUsers(widget.title, limit: 10);
          final acc = users
              .where((u) =>
                  u.handle == widget.title || u.handle.contains(widget.title))
              .firstOrNull;
          if (acc != null) {
            final prof = await service.fetchUserProfile(acc.id);
            final posts = await service.fetchUserPosts(acc.id);
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
          final spaces = await service.fetchSpaces();
          final sp = spaces
              .where((s) =>
                  s.name == widget.title || s.name.contains(widget.title))
              .firstOrNull;
          if (sp != null) {
            final prof = await service.fetchSpaceProfile(sp.id);
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
          final spaces = await service.fetchSpaces();
          for (final sp in spaces) {
            final rooms = await service.fetchRoomsForSpace(sp.id);
            final room = rooms
                .where((r) =>
                    r.name == widget.title || r.name.contains(widget.title))
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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      if (widget.section == 'Agents' || widget.section == 'Tools') {
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
        } else if (b.listing.isNotEmpty) {
          await deps.service
              .installListing(b.listing['listing_id'] as String? ?? '');
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
          setState(() => _space = SpaceProfile(
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
              ));
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
            setState(() => _room = RoomProfile(
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
                ));
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
        'Users' => 'Trader',
        'Agents' => 'Agent',
        'Tools' => 'Tool',
        'Workspaces' => 'Workspace',
        'Rooms' => 'Room',
        _ => 'Profile'
      };
  IconData get icon => switch (widget.section) {
        'Users' => Icons.person_rounded,
        'Agents' => Icons.smart_toy_rounded,
        'Tools' => Icons.extension_rounded,
        'Workspaces' => Icons.hub_rounded,
        'Rooms' => Icons.forum_rounded,
        _ => Icons.category_rounded
      };
  String get action {
    final u = _user;
    if (u != null) return u.amFollowing ? 'Following' : 'Follow';
    final b = _bot;
    if (b != null) return _inSpace ? 'Added' : 'Add to workspace';
    final s = _space;
    if (s != null) return s.amMember ? 'Joined' : 'Join workspace';
    final r = _room;
    if (r != null) return r.amMember ? 'Joined' : 'Join room';
    return 'Open';
  }

  List<(String, String)> get stats {
    final u = _user;
    if (u != null) {
      return [
        ('${u.followers}', 'Followers'),
        ('${u.following}', 'Following'),
        ('${_posts.length}', 'Posts'),
      ];
    }
    final b = _bot;
    if (b != null) {
      return [
        (b.status, 'Status'),
        (b.kind.toUpperCase(), 'Kind'),
        ('${b.installs}', 'Installs'),
      ];
    }
    final s = _space;
    if (s != null) {
      return [
        ('${s.memberCount}', 'Members'),
        ('${s.roomCount}', 'Rooms'),
        ('${s.postCount}', 'Posts'),
      ];
    }
    final r = _room;
    if (r != null) {
      return [
        ('${r.memberCount}', 'Members'),
        ('${r.agentCount}', 'Agents'),
        ('${r.messageCount}', 'Messages'),
      ];
    }
    return switch (widget.section) {
      'Users' => [('—', 'Followers'), ('—', 'Posts')],
      'Agents' => [('—', 'Status'), ('—', 'Installs')],
      'Tools' => [('—', 'Status'), ('—', 'Installs')],
      'Workspaces' => [('—', 'Members'), ('—', 'Rooms')],
      'Rooms' => [('—', 'Members'), ('—', 'Messages')],
      _ => [('—', 'Activity')]
    };
  }

  List<String> get features {
    final u = _user;
    if (u != null) {
      return [
        '@${u.handle}',
        u.kind,
        u.status,
        if (u.bio.isNotEmpty) u.bio,
      ];
    }
    final b = _bot;
    if (b != null) {
      return [
        b.vmType.toUpperCase(),
        b.hasFrontend ? 'Elpian frontend' : 'No frontend yet',
        '${b.entities.length} entities',
        if (b.description.isNotEmpty) b.description,
      ];
    }
    final s = _space;
    if (s != null) {
      return [
        s.public ? 'Public' : 'Private',
        '${s.agentCount} agents',
        '${s.fileCount} files',
        if (s.description.isNotEmpty) s.description,
      ];
    }
    final r = _room;
    if (r != null) {
      return [
        '${r.spaceName}',
        '${r.agentCount} agents',
        '${r.fileCount} files',
        if (r.topic.isNotEmpty) r.topic,
      ];
    }
    return switch (widget.section) {
      'Users' => ['Public profile'],
      'Agents' => ['Agent profile'],
      'Tools' => ['Tool profile'],
      'Workspaces' => ['Workspace profile'],
      'Rooms' => ['Room profile'],
      _ => ['Public profile']
    };
  }

  @override
  Widget build(BuildContext context) =>
      ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 28), children: [
        Row(children: [
          MiniTag(
              singular.toUpperCase(), Theme.of(context).colorScheme.primary),
          const Spacer(),
          IconButton(
              tooltip: 'Share profile',
              onPressed: () {},
              icon: const Icon(Icons.ios_share_rounded, size: 19)),
          IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded))
        ]),
        const SizedBox(height: 7),
        Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(26)),
            child: Column(children: [
              Container(
                  height: 104,
                  decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.tertiary
                  ])),
                  child: Stack(children: [
                    Positioned(
                        right: -16,
                        top: -36,
                        child: Icon(icon,
                            size: 160,
                            color: Colors.white.withValues(alpha: .15)))
                  ])),
              Transform.translate(
                  offset: const Offset(0, -31),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Container(
                                  width: 70,
                                  height: 70,
                                  decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primaryContainer,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .surface,
                                          width: 4)),
                                  child: Icon(icon, size: 31)),
                              const Spacer(),
                              FilledButton.icon(
                                  onPressed: _busy ? null : _performAction,
                                  icon: _busy
                                      ? const SizedBox(
                                          width: 15,
                                          height: 15,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : Icon(
                                          action == 'Follow' ||
                                                  action == 'Join workspace' ||
                                                  action == 'Join room' ||
                                                  action == 'Add to workspace'
                                              ? Icons.add_rounded
                                              : Icons.check_rounded,
                                          size: 17),
                                  label: Text(action))
                            ]),
                        const SizedBox(height: 10),
                        Row(children: [
                          Flexible(
                              child: Text(widget.title,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 23,
                                      fontWeight: FontWeight.w900))),
                          const SizedBox(width: 6),
                          const Icon(Icons.verified_rounded,
                              size: 18, color: Colors.blueAccent)
                        ]),
                        const SizedBox(height: 4),
                        Align(
                            alignment: Alignment.centerLeft,
                            child: _loading
                                ? const SizedBox(
                                    height: 12,
                                    width: 12,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : Text(_summary(),
                                    style: TextStyle(
                                        height: 1.4,
                                        fontSize: 11,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant)))
                      ])))
            ])),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!,
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 12))),
        Row(
            children: stats
                .map((stat) => Expanded(
                    child: Padding(
                        padding:
                            EdgeInsets.only(right: stat == stats.last ? 0 : 7),
                        child: ProfileStat(stat.$1, stat.$2))))
                .toList()),
        const SizedBox(height: 18),
        Text(_sectionTitle(),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
        const SizedBox(height: 9),
        Wrap(
            spacing: 7,
            runSpacing: 7,
            children: features
                .map((feature) =>
                    Chip(avatar: Icon(icon, size: 14), label: Text(feature)))
                .toList()),
        const SizedBox(height: 18),
        _EntityProfileDetail(section: widget.section, icon: icon),
      ]);

  String _summary() {
    final u = _user;
    if (u != null) {
      return u.bio.isNotEmpty
          ? u.bio
          : '@${u.handle} — ${u.kind} account, following ${u.following} with ${u.followers} followers.';
    }
    final b = _bot;
    if (b != null) {
      return b.description.isNotEmpty
          ? b.description
          : '${b.name} — a ${b.kind} running on the ${b.vmType} VM. Status: ${b.status}.';
    }
    final s = _space;
    if (s != null) {
      return s.description.isNotEmpty
          ? s.description
          : '${s.name} — ${s.memberCount} members, ${s.roomCount} rooms, ${s.postCount} posts.';
    }
    final r = _room;
    if (r != null) {
      return '${r.name} in ${r.spaceName} — ${r.memberCount} members, ${r.agentCount} agents, ${r.messageCount} messages.';
    }
    return switch (widget.section) {
      'Users' => 'Trader profile',
      'Agents' => 'Agent profile',
      'Tools' => 'Tool profile',
      'Workspaces' => 'Workspace profile',
      'Rooms' => 'Room profile',
      _ => 'Tradera profile'
    };
  }

  String _sectionTitle() => switch (widget.section) {
        'Users' => 'Profile',
        'Agents' => 'Runtime',
        'Tools' => 'Runtime',
        'Workspaces' => 'Overview',
        'Rooms' => 'Activity',
        _ => 'Highlights'
      };
}

class _EntityProfileDetail extends StatelessWidget {
  const _EntityProfileDetail({required this.section, required this.icon});
  final String section;
  final IconData icon;
  @override
  Widget build(BuildContext context) => switch (section) {
        'Users' => const _TraderProfileDetail(),
        'Agents' => const _AgentProfileDetail(),
        'Tools' => const _ToolProfileDetail(),
        'Workspaces' => const _WorkspaceProfileDetail(),
        'Rooms' => const _RoomProfileDetail(),
        _ => const SizedBox.shrink()
      };
}

class _ProfileDetailCard extends StatelessWidget {
  const _ProfileDetailCard(this.title, this.icon, this.child);
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(21)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(title,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
          const Spacer()
        ]),
        const SizedBox(height: 12),
        child
      ]));
}

class _TraderProfileDetail extends StatelessWidget {
  const _TraderProfileDetail();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_EntityProfileScreenState>();
    final user = state?._user;
    final posts = state?._posts ?? const <SocialPost>[];
    final deps = state?.widget.dependencies;
    return Column(children: [
      _ProfileDetailCard(
          'About',
          Icons.edit_note_rounded,
          Text(user?.bio.isNotEmpty == true ? user!.bio : 'No bio yet.',
              style: const TextStyle(fontSize: 11, height: 1.5))),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Connections',
          Icons.people_rounded,
          Row(children: [
            _ConnectorCount('Followers', user?.followers ?? 0,
                onTap: deps == null || user == null
                    ? null
                    : () => _showAccountList(context, deps, user.id, false)),
            const SizedBox(width: 16),
            _ConnectorCount('Following', user?.following ?? 0,
                onTap: deps == null || user == null
                    ? null
                    : () => _showAccountList(context, deps, user.id, true)),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Recent posts',
          Icons.dynamic_feed_rounded,
          posts.isEmpty
              ? const Text('No posts yet.',
                  style: TextStyle(fontSize: 11, color: AppColors.muted))
              : Column(children: [
                  for (final p in posts.take(5))
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.body,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 11)),
                              Text(_timeAgo(p.createdAt),
                                  style: const TextStyle(
                                      fontSize: 8, color: AppColors.muted))
                            ]))
                ])),
    ]);
  }

  static void _showAccountList(BuildContext context, AppDependencies deps,
      String userId, bool following) {
    final title = following ? 'Following' : 'Followers';
    showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
            backgroundColor: Theme.of(ctx).colorScheme.surfaceContainerLow,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            child: SizedBox(
                width: 360,
                height: 420,
                child: FutureBuilder<List<AccountSummary>>(
                    future: following
                        ? deps.service.fetchFollowing(accountId: userId)
                        : deps.service.fetchFollowers(accountId: userId),
                    builder: (ctx, snap) {
                      final list = snap.data ?? const <AccountSummary>[];
                      return Column(children: [
                        Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text('$title · ${list.length}',
                                style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900))),
                        const Divider(height: 1),
                        Expanded(
                          child: list.isEmpty
                              ? const Center(
                                  child: Text('None yet',
                                      style: TextStyle(color: AppColors.muted)))
                              : ListView.separated(
                                  itemCount: list.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (_, i) => ListTile(
                                      dense: true,
                                      leading: CircleAvatar(
                                          radius: 16,
                                          child: Text(list[i].handle.isEmpty
                                              ? '?'
                                              : list[i]
                                                  .handle[0]
                                                  .toUpperCase())),
                                      title: Text('@${list[i].handle}',
                                          style: const TextStyle(fontSize: 13)),
                                      subtitle: Text(list[i].kind,
                                          style:
                                              const TextStyle(fontSize: 10)))),
                        ),
                      ]);
                    }))));
  }
}

class _ConnectorCount extends StatelessWidget {
  const _ConnectorCount(this.label, this.count, {this.onTap});
  final String label;
  final int count;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12)),
          child: Column(children: [
            Text('$count',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            Text(label, style: const TextStyle(fontSize: 10))
          ])));
}

class _AgentProfileDetail extends StatelessWidget {
  const _AgentProfileDetail();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_EntityProfileScreenState>();
    final bot = state?._bot;
    if (bot == null) return const SizedBox.shrink();
    return Column(children: [
      _ProfileDetailCard(
          'Resources',
          Icons.memory_rounded,
          Row(children: [
            _ResourceCell('CPU', '${(bot.resources['cpu'] as num?) ?? 0} vCPU'),
            _ResourceCell(
                'RAM', '${(bot.resources['memory_mb'] as num?) ?? 0} MB'),
            _ResourceCell(
                'Disk', '${(bot.resources['disk_mb'] as num?) ?? 0} MB'),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Usage',
          Icons.analytics_rounded,
          Row(children: [
            _ResourceCell('Uptime', _fmtDuration(bot.uptimeSec)),
            _ResourceCell('Tokens', '${bot.tokens}'),
            _ResourceCell(
                'Cost/min', '${(bot.cost['per_minute'] as num?) ?? 0}'),
          ])),
      const SizedBox(height: 9),
      if (bot.listing.isNotEmpty)
        _ProfileDetailCard(
            'Marketplace',
            Icons.storefront_rounded,
            Row(children: [
              _ResourceCell('Installs', '${bot.installs}'),
              _ResourceCell('Price', '${bot.price}'),
              _ResourceCell(
                  'Category', bot.listing['category'] as String? ?? '—'),
            ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Entities',
          Icons.folder_copy_rounded,
          bot.entities.isEmpty
              ? const Text('No runtime entities yet.',
                  style: TextStyle(fontSize: 11, color: AppColors.muted))
              : Wrap(spacing: 7, runSpacing: 7, children: [
                  for (final key in bot.entities) Chip(label: Text(key)),
                ])),
      if (bot.ownerHandle.isNotEmpty) ...[
        const SizedBox(height: 9),
        _ProfileDetailCard(
            'Owner',
            Icons.person_outline_rounded,
            Text('@${bot.ownerHandle}',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700))),
      ],
    ]);
  }
}

class _ToolProfileDetail extends StatelessWidget {
  const _ToolProfileDetail();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_EntityProfileScreenState>();
    final bot = state?._bot;
    if (bot == null) return const SizedBox.shrink();
    return Column(children: [
      _ProfileDetailCard(
          'Resources',
          Icons.memory_rounded,
          Row(children: [
            _ResourceCell('CPU', '${(bot.resources['cpu'] as num?) ?? 0} vCPU'),
            _ResourceCell(
                'RAM', '${(bot.resources['memory_mb'] as num?) ?? 0} MB'),
            _ResourceCell(
                'Disk', '${(bot.resources['disk_mb'] as num?) ?? 0} MB'),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Status',
          Icons.monitor_heart_rounded,
          Row(children: [
            _ResourceCell('Runtime', bot.vmType.toUpperCase()),
            _ResourceCell('Status', bot.status),
            _ResourceCell('Image', bot.imageRef),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Usage',
          Icons.analytics_rounded,
          Row(children: [
            _ResourceCell('Uptime', _fmtDuration(bot.uptimeSec)),
            _ResourceCell('Tokens', '${bot.tokens}'),
            _ResourceCell(
                'Cost/min', '${(bot.cost['per_minute'] as num?) ?? 0}'),
          ])),
      const SizedBox(height: 9),
      if (bot.listing.isNotEmpty)
        _ProfileDetailCard(
            'Marketplace',
            Icons.storefront_rounded,
            Row(children: [
              _ResourceCell('Installs', '${bot.installs}'),
              _ResourceCell('Price', '${bot.price}'),
            ])),
    ]);
  }
}

class _WorkspaceProfileDetail extends StatelessWidget {
  const _WorkspaceProfileDetail();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_EntityProfileScreenState>();
    final space = state?._space;
    if (space == null) return const SizedBox.shrink();
    final rooms = space.rooms.isEmpty ? const ['Hall room'] : space.rooms;
    return Column(children: [
      _ProfileDetailCard('Rooms', Icons.grid_view_rounded,
          LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth < 420 ? 2 : 3;
        return GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: columns,
            mainAxisSpacing: 7,
            crossAxisSpacing: 7,
            childAspectRatio: 1.8,
            children: [
              for (final r in rooms.take(6))
                _WorkspaceRoomPreview(r, Icons.forum_outlined),
            ]);
      })),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Community',
          Icons.groups_rounded,
          Row(children: [
            _ResourceCell('Members', '${space.memberCount}'),
            _ResourceCell('Agents', '${space.agentCount}'),
            _ResourceCell('Files', '${space.fileCount}'),
            _ResourceCell('Posts', '${space.postCount}'),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Visibility',
          Icons.public_rounded,
          Row(children: [
            _ResourceCell('Access', space.public ? 'Public' : 'Private'),
            _ResourceCell('Owner',
                space.ownerHandle.isEmpty ? '—' : '@${space.ownerHandle}'),
            _ResourceCell('Home', space.home ? 'Yes' : 'No'),
          ])),
    ]);
  }
}

class _WorkspaceRoomPreview extends StatelessWidget {
  const _WorkspaceRoomPreview(this.label, this.icon);
  final String label;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(13)),
      child: Row(children: [
        Icon(icon, size: 15),
        const SizedBox(width: 6),
        Expanded(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 9, fontWeight: FontWeight.w700)))
      ]));
}

class _RoomProfileDetail extends StatelessWidget {
  const _RoomProfileDetail();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_EntityProfileScreenState>();
    final room = state?._room;
    if (room == null) return const SizedBox.shrink();
    return Column(children: [
      _ProfileDetailCard(
          'Stats',
          Icons.query_stats_rounded,
          Row(children: [
            _ResourceCell('Members', '${room.memberCount}'),
            _ResourceCell('Agents', '${room.agentCount}'),
            _ResourceCell('Messages', '${room.messageCount}'),
            _ResourceCell('Files', '${room.fileCount}'),
          ])),
      const SizedBox(height: 9),
      _ProfileDetailCard(
          'Recent room activity',
          Icons.forum_outlined,
          room.recentMessages.isEmpty
              ? const Text('No messages yet.',
                  style: TextStyle(fontSize: 11, color: AppColors.muted))
              : Column(children: [
                  for (final m in room.recentMessages)
                    _RoomActivityRow(
                        Icons.chat_bubble_outline_rounded,
                        _short(m['sender_id'] as String? ?? '?', 10) +
                            ': ' +
                            (m['body'] as String? ?? ''),
                        _timeAgo(DateTime.tryParse(
                                m['created_at'] as String? ?? '') ??
                            DateTime.now())),
                ])),
      if (room.topic.isNotEmpty) ...[
        const SizedBox(height: 9),
        _ProfileDetailCard('Topic', Icons.subject_rounded,
            Text(room.topic, style: const TextStyle(fontSize: 11))),
      ],
    ]);
  }
}

class _ResourceCell extends StatelessWidget {
  const _ResourceCell(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 9)),
      ]));
}

class _RoomActivityRow extends StatelessWidget {
  const _RoomActivityRow(this.icon, this.label, this.time);
  final IconData icon;
  final String label, time;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 10))),
        Text(time, style: const TextStyle(fontSize: 8))
      ]));
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
  Widget build(BuildContext context) => flat
      ? Material(color: Theme.of(context).colorScheme.surface, child: child)
      : Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: .92),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: .6)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .12),
                    blurRadius: 30,
                    offset: const Offset(0, 12))
              ]),
          child: Material(type: MaterialType.transparency, child: child));
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
      const Color(0xFF4997FF)
    ][workspace.length % 4];
    for (var i = 0; i < 4; i++) {
      final center = Offset(
          size.width * random.nextDouble(), size.height * random.nextDouble());
      final radius = size.shortestSide * (.22 + random.nextDouble() * .28);
      canvas.drawCircle(
          center,
          radius,
          Paint()
            ..shader = RadialGradient(colors: [
              primary.withValues(alpha: .065),
              primary.withValues(alpha: 0)
            ]).createShader(Rect.fromCircle(center: center, radius: radius)));
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
          y + random.nextDouble() * 100 - 50);
      canvas.drawPath(
          path,
          Paint()
            ..color = primary.withValues(alpha: .075 - i * .012)
            ..strokeWidth = 1.2 + i * .8
            ..style = PaintingStyle.stroke);
    }
    final nodes = <Offset>[];
    for (var i = 0;
        i < math.max(18, (size.width * size.height / 36000).round());
        i++) {
      final point = Offset(
          size.width * random.nextDouble(), size.height * random.nextDouble());
      nodes.add(point);
      final radius = 2 + random.nextDouble() * 5;
      canvas.drawCircle(
          point,
          radius,
          Paint()
            ..color =
                primary.withValues(alpha: .035 + random.nextDouble() * .07));
      if (i > 0 && random.nextDouble() > .38)
        canvas.drawLine(
            nodes[random.nextInt(i)],
            point,
            Paint()
              ..color = primary.withValues(alpha: .035)
              ..strokeWidth = .7);
    }
    for (var i = 0; i < 10; i++) {
      final center = Offset(
          size.width * random.nextDouble(), size.height * random.nextDouble());
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
            ..color =
                primary.withValues(alpha: .018 + random.nextDouble() * .025)
            ..style = PaintingStyle.fill);
      canvas.drawPath(
          path,
          Paint()
            ..color = primary.withValues(alpha: .055)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8);
    }
  }

  @override
  bool shouldRepaint(covariant _WorkspacePatternPainter old) =>
      old.workspace != workspace;
}

class _ChatPatternPainter extends CustomPainter {
  const _ChatPatternPainter(this.color, this.room);
  final Color color;
  final String room;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withValues(alpha: .075),
                Colors.transparent,
                color.withValues(alpha: .035)
              ]).createShader(Offset.zero & size));
    final seed = room.codeUnits.fold(29, (a, b) => a * 37 + b);
    final random = math.Random(seed);
    final count = math.max(18, (size.width * size.height / 12500).round());
    for (var i = 0; i < count; i++) {
      final center = Offset(
          size.width * random.nextDouble(), size.height * random.nextDouble());
      final scale = 7 + random.nextDouble() * 15;
      final paint = Paint()
        ..color = color.withValues(alpha: .035 + random.nextDouble() * .055)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7 + random.nextDouble();
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(random.nextDouble() * math.pi * 2);
      switch (i % 5) {
        case 0:
          canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: scale), 0,
              math.pi * 1.45, false, paint);
          canvas.drawCircle(Offset(scale * .8, scale * .5), 2, paint);
          break;
        case 1:
          canvas.drawLine(
              Offset(-scale, scale * .5), Offset(scale, -scale * .5), paint);
          for (var x = -1; x <= 1; x++)
            canvas.drawCircle(
                Offset(x * scale * .65, x.isEven ? -2 : 4), 2.2, paint);
          break;
        case 2:
          final path = Path()
            ..moveTo(0, -scale)
            ..lineTo(scale, 0)
            ..lineTo(0, scale)
            ..lineTo(-scale, 0)
            ..close();
          canvas.drawPath(path, paint);
          break;
        case 3:
          for (var bar = 0; bar < 3; bar++)
            canvas.drawRRect(
                RRect.fromRectAndRadius(
                    Rect.fromLTWH(
                        -scale + bar * scale * .7,
                        -scale * (.3 + random.nextDouble() * .5),
                        scale * .25,
                        scale * (1 + random.nextDouble())),
                    const Radius.circular(2)),
                paint);
          break;
        default:
          canvas.drawCircle(Offset.zero, scale, paint);
          canvas.drawCircle(Offset.zero, scale * .35, paint);
          break;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ChatPatternPainter old) =>
      old.color != color || old.room != room;
}

class _RoomNameDialog extends StatefulWidget {
  const _RoomNameDialog();
  @override
  State<_RoomNameDialog> createState() => _RoomNameDialogState();
}

class _RoomNameDialogState extends State<_RoomNameDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('New room'),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(context, v.trim());
          },
          decoration: const InputDecoration(labelText: 'Room name'),
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
