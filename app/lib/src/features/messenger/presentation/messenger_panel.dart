import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../../shared/widgets/workspace_header.dart'
    show promptCreateWorkspace;
import '../../search_feed/presentation/rich_post_parser.dart'
    show markupPreview;
import 'chat_page.dart';
import 'requests_panel.dart';

/// Opens the messenger: a bottom sheet on phones, a full-height sheet stuck
/// to the trailing edge on wider screens.
Future<void> showMessenger(
  BuildContext context,
  AppDependencies dependencies,
) => showFloatingPanel(
  context,
  MessengerPanel(dependencies: dependencies),
  maxWidth: 760,
  barrierLabel: 'Close messages',
);

/// Every conversation of the account in one place, like a messenger: direct
/// chats with people and agents, and one row per project. A project's rooms
/// stay folded under that row until it is expanded. From the home chats list,
/// each room opens that room in its workspace. Elsewhere, a room still opens
/// as a chat.
///
/// With [embedded] the list is a home-shell tab (no close control); the
/// sheet/dialog form still uses [showMessenger]. The sheet owns the glass
/// ([AppSheetScope]); this panel's body stays transparent.
/// With [dense] chrome and rows shrink for a narrow desktop rail — not for
/// the full-width mobile chats tab.
class MessengerPanel extends StatefulWidget {
  const MessengerPanel({
    super.key,
    required this.dependencies,
    this.embedded = false,
    this.dense = false,
    this.topContentInset = 0,
    this.onOpenSpaceRoom,
    this.onOpenWorkspace,
    this.onSelect,
  });

  final AppDependencies dependencies;

  /// Home-shell tab: no close button.
  final bool embedded;

  /// Narrow desktop rail sizing; leave false on the mobile chats tab.
  final bool dense;

  /// Extra top padding inside the scroll (home floating app bar). Content
  /// starts clear of the bar and scrolls under it — same pattern as Explore.
  final double topContentInset;

  /// Opens a project's room on the workspace page (its desk, chat, and the
  /// rest). Set on the home chats list. When null, a room still opens as a
  /// chat — the floating messenger. [spaceId] is preferred for loading rooms.
  final void Function(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  )? onOpenSpaceRoom;

  /// Opens a newly created space on the workspace page (same as picking it
  /// in the workspace switcher). Set on the home chats list.
  final ValueChanged<String>? onOpenWorkspace;

  /// Desktop list-detail: selecting a chat fills the detail pane instead of
  /// pushing a route or opening the workspace.
  final ValueChanged<ChatSummary>? onSelect;

  @override
  State<MessengerPanel> createState() => _MessengerPanelState();
}

class _MessengerPanelState extends State<MessengerPanel> {
  final _navigator = GlobalKey<NavigatorState>();
  late final _depth = _DepthObserver(() {
    if (mounted) setState(() {});
  });

  @override
  Widget build(BuildContext context) {
    // The list and the chats share the panel: a chat slides in over the list
    // and back (or the system back gesture) returns to it. On the list, back
    // closes the panel as usual (unless this is an embedded home tab).
    final inChat = _depth.depth > 1;
    return PopScope(
      canPop: !inChat,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _navigator.currentState?.maybePop();
      },
      child: ScaffoldMessenger(
        child: Navigator(
          key: _navigator,
          observers: [_depth],
          onGenerateRoute: (_) {
            final list = _ChatList(
              dependencies: widget.dependencies,
              embedded: widget.embedded,
              dense: widget.dense,
              topContentInset: widget.topContentInset,
              onOpenSpaceRoom: widget.onOpenSpaceRoom,
              onOpenWorkspace: widget.onOpenWorkspace,
              onSelect: widget.onSelect,
              onClose: widget.embedded
                  ? null
                  : () => Navigator.of(context).pop(),
            );
            // Embedded home tab: transparent route so the page glow shows.
            if (widget.embedded) {
              return PageRouteBuilder<void>(
                opaque: false,
                pageBuilder: (_, __, ___) => list,
              );
            }
            return MaterialPageRoute<void>(builder: (_) => list);
          },
        ),
      ),
    );
  }
}

/// Counts the routes of the messenger's own navigator.
class _DepthObserver extends NavigatorObserver {
  _DepthObserver(this.onChange);
  final VoidCallback onChange;
  int depth = 0;

  void _set(int value) {
    depth = value;
    // Navigator callbacks can arrive mid-build; rebuild after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange());
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(depth + 1);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(depth - 1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _set(depth - 1);
}

/// Expo Home segments: All | Rooms | Personal (saved/Decillion excluded).
enum _Filter { all, personal, rooms }

class _ChatList extends StatefulWidget {
  const _ChatList({
    required this.dependencies,
    this.onClose,
    this.embedded = false,
    this.dense = false,
    this.topContentInset = 0,
    this.onOpenSpaceRoom,
    this.onOpenWorkspace,
    this.onSelect,
  });

  final AppDependencies dependencies;

  /// Null when the list is an embedded home tab (no close control).
  final VoidCallback? onClose;
  final bool embedded;

  /// Compact chrome for a desktop side rail.
  final bool dense;

  /// See [MessengerPanel.topContentInset].
  final double topContentInset;

  /// See [MessengerPanel.onOpenSpaceRoom].
  final void Function(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  )? onOpenSpaceRoom;

  /// See [MessengerPanel.onOpenWorkspace].
  final ValueChanged<String>? onOpenWorkspace;

  /// See [MessengerPanel.onSelect].
  final ValueChanged<ChatSummary>? onSelect;

  @override
  State<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<_ChatList> {
  final _search = TextEditingController();
  List<ChatSummary> _chats = const [];

  /// Owned agents keyed by bot id and account id, so a chat row uses the same
  /// face as the open conversation instead of a look seeded from the account.
  Map<String, Bot> _agents = const {};
  int _requests = 0;
  bool _loading = true;
  String? _error;
  _Filter _filter = _Filter.all;
  Timer? _poll;
  bool _refreshing = false;

  /// Spaces whose rooms are spread open inside the list.
  final _openSpaces = <String>{};

  AsemanService get _service => widget.dependencies.service;
  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  /// The agent record behind a direct chat, when this account owns it.
  Bot? _agentFor(ChatSummary chat) {
    final peer = chat.peer;
    if (peer == null || !peer.isAgent) return null;
    if (peer.botId.isNotEmpty) {
      final byBot = _agents[peer.botId];
      if (byBot != null) return byBot;
    }
    return _agents[peer.id];
  }

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      // Expo: Personal = users.dm_threads (minus saved); Rooms = spaces.space_list.
      final results = await Future.wait<Object>([
        _service.fetchChats(),
        _service.fetchProjectChats(),
        _service.fetchBots(limit: 200).catchError((_) => const <Bot>[]),
      ]);
      if (!mounted) return;
      final bots = results[2] as List<Bot>;
      final agents = <String, Bot>{};
      for (final bot in bots) {
        if (!bot.isAgent) continue;
        if (bot.id.isNotEmpty) agents[bot.id] = bot;
        if (bot.accountId.isNotEmpty) agents[bot.accountId] = bot;
      }
      setState(() {
        _chats = [
          ...(results[0] as List<ChatSummary>),
          ...(results[1] as List<ChatSummary>),
        ];
        _agents = agents;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // Keep showing what loaded before; only an empty list shows the error.
        if (_chats.isEmpty) _error = '$e';
      });
    } finally {
      _refreshing = false;
    }
    try {
      final requests = await _service.fetchPendingRequests();
      if (mounted && requests.length != _requests) {
        setState(() => _requests = requests.length);
      }
    } catch (_) {}
  }

  Future<void> _open(ChatSummary chat) async {
    final select = widget.onSelect;
    if (select != null) {
      select(chat);
      return;
    }
    // A project's room, from the home chats list, opens that room in its
    // workspace. Direct chats, and rooms in the floating messenger, open here.
    final openRoom = widget.onOpenSpaceRoom;
    if (!chat.direct &&
        openRoom != null &&
        (chat.spaceId.isNotEmpty || chat.spaceName.isNotEmpty)) {
      openRoom(chat.spaceId, chat.spaceName, chat.roomName, chat.roomId);
      return;
    }
    await showChat(context, widget.dependencies, chat);
    if (mounted) unawaited(_load());
  }

  void _toggleSpace(String spaceId) {
    setState(() {
      if (!_openSpaces.add(spaceId)) _openSpaces.remove(spaceId);
    });
  }

  // Long-pressing a chat pins or unpins it (and deletes a direct chat for
  // the caller).
  Future<void> _chatMenu(
    ChatSummary chat, {
    Offset? at,
    BuildContext? anchor,
  }) async {
    final picked = await showAppPicker<String>(
      context: context,
      anchor: anchor,
      anchorPoint: at,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                chat.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              ),
              title: Text(chat.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () => Navigator.pop(context, 'pin'),
            ),
            if (chat.direct)
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Delete chat for me'),
                onTap: () => Navigator.pop(context, 'clear'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      if (picked == 'pin') {
        if (chat.direct) {
          final peer = chat.peer?.id ?? chat.roomId;
          await _service.pinChat(peer, !chat.pinned);
        } else {
          await _service.pinProject(chat.spaceId, !chat.pinned);
        }
      } else {
        final peer = chat.peer?.id ?? chat.roomId;
        await _service.clearChat(peer);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not change it: $e')));
    }
  }

  Future<void> _newChat() async {
    final peer = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => _NewChatPage(
          dependencies: widget.dependencies,
          // Same floating-app-bar clearance as the chats list — without it
          // the back control sits under the home glass pill.
          topContentInset: widget.topContentInset,
        ),
      ),
    );
    if (peer == null || !mounted) return;
    try {
      final chat = await _service.openDirect(peer);
      if (!mounted) return;
      await _open(chat);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start chat: $e')));
    }
  }

  /// Same create flow as the workspace switcher's **New workspace** tile.
  Future<void> _newSpace() async {
    final created = await promptCreateWorkspace(context, widget.dependencies);
    if (created == null || !mounted) return;
    // Prefer id so the desk loads this project, not a name collision / home.
    final openRoom = widget.onOpenSpaceRoom;
    if (openRoom != null && created.id.isNotEmpty) {
      openRoom(created.id, created.name, '', '');
      return;
    }
    final open = widget.onOpenWorkspace;
    if (open != null) {
      open(created.name);
      return;
    }
    await _load();
  }

  Future<void> _composeMenu(BuildContext fabContext) async {
    final box = fabContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final overlay = Overlay.of(fabContext).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final bottomRight = box.localToGlobal(
      box.size.bottomRight(Offset.zero),
      ancestor: overlay,
    );
    final picked = await showAppMenu<String>(
      context: fabContext,
      position: RelativeRect.fromRect(
        Rect.fromPoints(topLeft, bottomRight),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'space',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.workspaces_outline),
            title: Text('New space'),
          ),
        ),
        PopupMenuItem(
          value: 'chat',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_square),
            title: Text('New chat'),
          ),
        ),
      ],
    );
    if (!mounted || picked == null) return;
    if (picked == 'space') {
      await _newSpace();
    } else if (picked == 'chat') {
      await _newChat();
    }
  }

  /// Expo Home: Personal DMs one row each; Rooms = one row per project
  /// (from space_list). Saved/Aseman is not in this list.
  List<_ChatEntry> get _shown {
    final q = _search.text.trim().toLowerCase();
    final directs = <_DirectEntry>[];
    final rooms = <_SpaceEntry>[];
    for (final chat in _chats) {
      if (chat.isAseman || chat.home) continue;
      if (_filter == _Filter.personal && !chat.direct) continue;
      if (_filter == _Filter.rooms && chat.direct) continue;
      if (chat.direct) {
        if (_chatMatches(chat, q)) directs.add(_DirectEntry(chat));
        continue;
      }
      if (!_chatMatches(chat, q) &&
          !(q.isEmpty || chat.spaceName.toLowerCase().contains(q))) {
        continue;
      }
      final existing = rooms.where((space) => space.spaceId == chat.spaceId);
      if (existing.isEmpty) {
        rooms.add(_SpaceEntry(chat.spaceId)..rooms.add(chat));
      } else {
        existing.first.rooms.add(chat);
      }
    }
    final entries = <_ChatEntry>[...directs, ...rooms];
    entries.sort(_newerFirst);
    return entries;
  }

  bool _chatMatches(ChatSummary chat, String q) {
    if (q.isEmpty) return true;
    return '${chat.title} ${chat.spaceName} ${chat.roomName} '
            '${chat.peer?.handle ?? ''} ${chat.lastBody}'
        .toLowerCase()
        .contains(q);
  }

  int _newerFirst(_ChatEntry a, _ChatEntry b) {
    final ap = a.pinnedAt;
    final bp = b.pinnedAt;
    if ((ap != null) != (bp != null)) return ap == null ? 1 : -1;
    if (ap != null && bp != null) {
      final byPin = bp.compareTo(ap);
      if (byPin != 0) return byPin;
    }
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final au = a.updatedAt ?? epoch;
    final bu = b.updatedAt ?? epoch;
    return bu.compareTo(au);
  }

  int _unread(bool? direct) => _chats
      .where((c) => direct == null || c.direct == direct)
      .fold(0, (sum, c) => sum + c.unread);

  String _label(String name, int unread) =>
      unread > 0 ? '$name · $unread' : name;

  /// How many list rows each filter shows (a project counts once).
  int _count(_Filter f) {
    final spaces = <String>{};
    var n = 0;
    for (final chat in _chats) {
      if (chat.isAseman || chat.home) continue;
      if (f == _Filter.personal && !chat.direct) continue;
      if (f == _Filter.rooms && chat.direct) continue;
      if (chat.direct) {
        n++;
      } else if (spaces.add(chat.spaceId)) {
        n++;
      }
    }
    return n;
  }

  /// Agents you talk to directly, with what each is doing right now.
  List<_AgentStatus> get _agentStatuses => [
    for (final chat in _chats)
      if (chat.direct && !chat.isAseman && (chat.peer?.isAgent ?? false))
        _AgentStatus(chat: chat, agent: _agentFor(chat)),
  ]..sort((a, b) => a.rank.compareTo(b.rank));

  /// Phone chats tab: pinned rows, then the rest, each set in one card with
  /// inset dividers.
  List<Widget> _groupedTiles(List<_ChatEntry> shown, bool dense) {
    final pinned = [for (final e in shown) if (e.pinnedAt != null) e];
    final recent = [for (final e in shown) if (e.pinnedAt == null) e];
    Widget group(String label, List<_ChatEntry> entries) => _ChatGroup(
      label: label,
      children: [
        for (final e in entries) ..._entryTiles(e, dense, grouped: true),
      ],
    );
    return [
      if (pinned.isNotEmpty) group('PINNED', pinned),
      if (recent.isNotEmpty) group('RECENT', recent),
    ];
  }

  List<Widget> _chatTiles(List<_ChatEntry> shown, bool dense) => [
    for (var i = 0; i < shown.length; i++) ...[
      if (i > 0) const SizedBox(height: 2),
      ..._entryTiles(shown[i], dense),
    ],
  ];

  /// Placeholder for a list that is loading, failed, or empty. [expand] fills
  /// the rail under a fixed header; otherwise the block sits in the page scroll.
  Widget _listPlaceholder(List<_ChatEntry> shown, {required bool expand}) {
    if (_loading) {
      if (expand) return const SkeletonList();
      return Column(
        children: [
          for (var i = 0; i < 6; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            const SkeletonListTile(),
          ],
        ],
      );
    }
    if (_error != null) {
      return _Empty(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load chats',
        body: _error!,
        expand: expand,
      );
    }
    return _Empty(
      icon: Icons.forum_outlined,
      title: _search.text.isNotEmpty
          ? 'No matching chats'
          : _filter == _Filter.rooms
          ? 'No rooms yet'
          : 'No chats yet',
      body: _filter == _Filter.rooms
          ? 'Projects you belong to show up here.'
          : 'Start one with a person or an agent.',
      expand: expand,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final dense = widget.dense;
    final gutter = dense ? 12.0 : (compact || widget.embedded ? 16.0 : 26.0);
    final shown = _shown;
    // Phone chats tab: header, search, filters, and rows share one scroll.
    // The desktop rail and the floating messenger keep that chrome fixed and
    // scroll only the list.
    final pageScroll = widget.embedded && !dense;
    final top = (dense || compact || widget.embedded ? 6.0 : 18.0) +
        widget.topContentInset;
    // Phone chats tab: clear the floating tab pill.
    final listBottom = pageScroll
        ? 90 + MediaQuery.viewPaddingOf(context).bottom
        : 24.0;
    final waiting = _loading || _error != null || shown.isEmpty;
    final unreadAll = _unread(null);
    final chrome = _MessengerChrome(
      title: widget.embedded ? 'Chats' : 'Messages',
      subtitle: unreadAll > 0
          ? (unreadAll == 1
              ? '1 unread across your chats'
              : '$unreadAll unread across your chats')
          : 'People, agents & your rooms',
      dense: dense,
      compact: compact,
      search: _search,
      onSearchChanged: () => setState(() {}),
      onClearSearch: () => setState(_search.clear),
      filterIndex: _filter.index,
      onFilter: (i) => setState(() => _filter = _Filter.values[i]),
      filterLabels: [
        _label('All', unreadAll),
        _label('Personal', _unread(true)),
        _label('Rooms', _unread(false)),
      ],
      filterNames: const ['All', 'Personal', 'Rooms'],
      filterCounts: [for (final f in _Filter.values) _count(f)],
      agents: pageScroll ? _agentStatuses : const [],
      onOpenAgent: _open,
      me: _me,
      composeInTitle: pageScroll,
      onCompose: _composeMenu,
      onClose: widget.onClose,
      requests: _requests,
      onRequests: _requests <= 0
          ? null
          : () async {
              await showRequestsPanel(context, widget.dependencies);
              if (mounted) unawaited(_load());
            },
    );
    final tiles = pageScroll
        ? _groupedTiles(shown, dense)
        : _chatTiles(shown, dense);

    if (pageScroll) {
      return Scaffold(
        // Host glass ([GlassSurface] / sheet / floating panel) paints the fill;
        // an opaque scaffold would hide the frost.
        backgroundColor: Colors.transparent,
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(gutter, top, gutter, listBottom),
            children: [
              chrome,
              if (waiting)
                _listPlaceholder(shown, expand: false)
              else
                ...tiles,
            ],
          ),
        ),
      );
    }

    return Scaffold(
      // Host glass ([GlassSurface] / sheet / floating panel) paints the fill;
      // an opaque scaffold would hide the frost.
      backgroundColor: Colors.transparent,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, top, gutter, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            chrome,
            Expanded(
              child: waiting
                  ? _listPlaceholder(shown, expand: true)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: EdgeInsets.only(bottom: listBottom),
                        children: tiles,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _entryTiles(
    _ChatEntry entry,
    bool dense, {
    bool grouped = false,
  }) {
    if (entry is _DirectEntry) {
      final chat = entry.chat;
      return [
        _ChatTile(
          chat: chat,
          me: _me,
          agent: _agentFor(chat),
          dense: dense,
          grouped: grouped,
          onTap: () => _open(chat),
          onMenu: (at, anchor) => _chatMenu(chat, at: at, anchor: anchor),
        ),
      ];
    }
    final space = entry as _SpaceEntry;
    final open = _openSpaces.contains(space.spaceId);
    final scheme = Theme.of(context).colorScheme;
    return [
      AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: open
              ? scheme.primary.withValues(alpha: .07)
              : Colors.transparent,
          borderRadius: grouped
              ? BorderRadius.zero
              : BorderRadius.circular(AppShape.innerOf(context)),
        ),
        child: Column(
          children: [
            _SpaceChatTile(
              space: space,
              me: _me,
              dense: dense,
              expanded: open,
              onToggle: () => _toggleSpace(space.spaceId),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: open
                  ? _SpaceRooms(
                      rooms: space.orderedRooms,
                      me: _me,
                      dense: dense,
                      onOpen: _open,
                      onMenu: (chat, at, anchor) =>
                          _chatMenu(chat, at: at, anchor: anchor),
                      agentOf: _agentFor,
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    ];
  }
}

/// A direct chat, or one project folded down to a single list row.
abstract class _ChatEntry {
  DateTime? get pinnedAt;
  DateTime? get updatedAt;
}

class _DirectEntry extends _ChatEntry {
  _DirectEntry(this.chat);
  final ChatSummary chat;

  @override
  DateTime? get pinnedAt => chat.pinnedAt;
  @override
  DateTime? get updatedAt => chat.updatedAt;
}

class _SpaceEntry extends _ChatEntry {
  _SpaceEntry(this.spaceId);
  final String spaceId;
  final List<ChatSummary> rooms = [];

  String get name {
    for (final room in rooms) {
      if (room.spaceName.isNotEmpty) return room.spaceName;
    }
    return 'Space';
  }

  int get unread => rooms.fold(0, (sum, room) => sum + room.unread);
  bool get working => rooms.any((room) => room.working);
  bool get typing => rooms.any((room) => room.typing);

  @override
  DateTime? get pinnedAt {
    DateTime? best;
    for (final room in rooms) {
      final pinned = room.pinnedAt;
      if (pinned != null && (best == null || pinned.isAfter(best))) {
        best = pinned;
      }
    }
    return best;
  }

  @override
  DateTime? get updatedAt {
    DateTime? best;
    for (final room in rooms) {
      final at = room.updatedAt;
      if (at != null && (best == null || at.isAfter(best))) best = at;
    }
    return best;
  }

  /// The room whose latest message represents the space while it is folded.
  ChatSummary get latest {
    var best = rooms.first;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    var bestAt = best.updatedAt ?? epoch;
    for (final room in rooms.skip(1)) {
      final at = room.updatedAt ?? epoch;
      if (at.isAfter(bestAt)) {
        best = room;
        bestAt = at;
      }
    }
    return best;
  }

  /// Pinned rooms first, then the ones that spoke most recently.
  List<ChatSummary> get orderedRooms {
    final copy = [...rooms];
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    copy.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return (b.updatedAt ?? epoch).compareTo(a.updatedAt ?? epoch);
    });
    return copy;
  }
}

/// One project in the chat list. Tap, long-press, or right-click spreads its
/// rooms underneath, the way a Telegram forum shows its topics in the list.
class _SpaceChatTile extends StatelessWidget {
  const _SpaceChatTile({
    required this.space,
    required this.me,
    required this.expanded,
    required this.onToggle,
    this.dense = false,
  });

  final _SpaceEntry space;
  final String me;
  final bool dense;
  final bool expanded;
  final VoidCallback onToggle;

  String get _status {
    if (space.working) return 'Agent is working…';
    if (space.typing) return 'typing…';
    final latest = space.latest;
    final room = latest.roomName.isEmpty ? 'Room' : latest.roomName;
    final preview = _chatPreview(latest, me);
    if (preview.isEmpty) {
      return space.rooms.length == 1 ? room : '${space.rooms.length} rooms';
    }
    return '$room · $preview';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = space.unread > 0;
    final latest = space.latest;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onToggle,
        onLongPress: null,
        onSecondaryTap: null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: (_) => onToggle(),
          onSecondaryTapDown: (_) => onToggle(),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 6 : 10,
              vertical: dense ? 7 : 10,
            ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ChatAvatar(
                      chat: latest,
                      radius: dense ? 18 : 24,
                      userId: me,
                    ),
                    if (space.working)
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              space.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                              ),
                            ),
                          ),
                          if (space.rooms.length > 1) ...[
                            const SizedBox(width: 6),
                            _Tag('${space.rooms.length}', scheme.primary),
                          ],
                          Icon(
                            expanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            size: dense ? 18 : 20,
                            color: scheme.onSurfaceVariant,
                            semanticLabel: expanded
                                ? 'Hide rooms'
                                : 'Show rooms',
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: space.working || space.typing
                              ? scheme.primary
                              : unread
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (space.pinnedAt != null) ...[
                          Icon(
                            Icons.push_pin_rounded,
                            size: 13,
                            semanticLabel: 'Pinned',
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          _chatWhen(space.updatedAt),
                          style: ThemeChrome.numeric(context).copyWith(
                            fontSize: 11,
                            color: unread
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (unread)
                      Badge(
                        label: Text(
                          space.unread > 99 ? '99+' : '${space.unread}',
                        ),
                        backgroundColor: scheme.primary,
                        textColor: scheme.onPrimary,
                      )
                    else
                      const SizedBox(height: 16),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The rooms of an expanded space, drawn under it like forum topics.
class _SpaceRooms extends StatelessWidget {
  const _SpaceRooms({
    required this.rooms,
    required this.me,
    required this.dense,
    required this.onOpen,
    required this.onMenu,
    this.agentOf,
  });

  final List<ChatSummary> rooms;
  final String me;
  final bool dense;
  final Bot? Function(ChatSummary chat)? agentOf;
  final ValueChanged<ChatSummary> onOpen;
  final void Function(ChatSummary chat, Offset at, BuildContext anchor) onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 28, bottom: 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: .55),
              width: 1,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Column(
            children: [
              for (final room in rooms)
                _ChatTile(
                  chat: room,
                  me: me,
                  agent: agentOf?.call(room),
                  dense: dense,
                  topic: true,
                  onTap: () => onOpen(room),
                  onMenu: (at, anchor) => onMenu(room, at, anchor),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.chat,
    required this.me,
    required this.onTap,
    required this.onMenu,
    this.agent,
    this.dense = false,
    this.topic = false,
    this.grouped = false,
  });

  final ChatSummary chat;
  final String me;
  final Bot? agent;
  final bool dense;

  /// Drawn inside a [_ChatGroup] card: no unread wash, the badge and time
  /// carry it.
  final bool grouped;

  /// A room shown under its space, rather than as its own chat.
  final bool topic;
  final VoidCallback onTap;
  final void Function(Offset at, BuildContext anchor) onMenu;

  String get _preview => _chatPreview(chat, me);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = chat.unread > 0;
    // Agent humanoid may wear a picture badge at BR; park the working
    // indicator at TR so they do not overlap.
    final agentRow =
        chat.direct && !chat.isAseman && (chat.peer?.isAgent ?? false);
    // Flat rows (not SoftCards): a light unread wash only.
    return Material(
      color: unread && !grouped
          ? ThemeRoles.selectedFill(context)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onLongPressStart: (d) => onMenu(d.globalPosition, context),
          onSecondaryTapDown: (d) => onMenu(d.globalPosition, context),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 6 : 10,
              vertical: topic ? (dense ? 4 : 6) : (dense ? 7 : 10),
            ),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ChatAvatar(
                      chat: chat,
                      radius: topic ? (dense ? 15 : 18) : (dense ? 18 : 24),
                      userId: me,
                      agent: agent,
                    ),
                    if (chat.working)
                      Positioned(
                        right: -1,
                        top: agentRow ? -1 : null,
                        bottom: agentRow ? null : -1,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              chat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w700,
                              ),
                            ),
                          ),
                          if (chat.blocked) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.block_rounded,
                              size: 14,
                              semanticLabel: 'Blocked',
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                          if (chat.direct &&
                              !chat.isAseman &&
                              (chat.peer?.isAgent ?? false)) ...[
                            const SizedBox(width: 6),
                            _Tag('AI', scheme.tertiary),
                          ],
                          if (!chat.direct && !topic) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                chat.spaceName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        chat.working
                            ? 'Agent is working…'
                            : chat.typing
                            ? 'typing…'
                            : _preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: chat.working || chat.typing
                              ? scheme.primary
                              : unread
                              ? scheme.onSurface
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (chat.pinned) ...[
                          Icon(
                            Icons.push_pin_rounded,
                            size: 13,
                            semanticLabel: 'Pinned',
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          _chatWhen(chat.updatedAt),
                          style: ThemeChrome.numeric(context).copyWith(
                            fontSize: 11,
                            color: unread
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                            fontWeight: unread
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (unread)
                      Badge(
                        label: Text(
                          chat.unread > 99 ? '99+' : '${chat.unread}',
                        ),
                        backgroundColor: scheme.primary,
                        textColor: scheme.onPrimary,
                      )
                    else
                      const SizedBox(height: 16),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _chatPreview(ChatSummary chat, String me) {
  // markupPreview is already fail-soft; keep a local catch so a future
  // regression cannot grey-box the whole chats list (ErrorWidget in a
  // ListView expands into the blank panel under the chrome).
  String body;
  try {
    body = markupPreview(chat.lastBody);
  } catch (_) {
    body = chat.lastBody.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.length > 160) body = '${body.substring(0, 160)}…';
  }
  final text = body.isNotEmpty
      ? body
      : chat.lastAttachments > 0
      ? (chat.lastAttachments == 1
            ? '📎 Attachment'
            : '📎 ${chat.lastAttachments} attachments')
      : '';
  if (text.isEmpty) {
    if (chat.isAseman) return 'Notes & voice';
    return chat.direct ? 'Say hello' : 'No messages yet';
  }
  if (chat.lastSenderId == me) return 'You: $text';
  if (!chat.direct && chat.lastSenderName.isNotEmpty) {
    return '${chat.lastSenderName}: $text';
  }
  return text;
}

String _chatWhen(DateTime? t) {
  if (t == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final days = today.difference(day).inDays;
  if (days <= 0) {
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
  if (days == 1) return 'Yesterday';
  if (days < 7) {
    return const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][t.weekday -
        1];
  }
  return '${t.day}/${t.month}/${t.year % 100}';
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: color),
    ),
  );
}

/// Chats header composition: editorial title, search + compose command bar,
/// and the All / Direct / Spaces filter. Personal Aseman is a normal list row.
class _MessengerChrome extends StatelessWidget {
  const _MessengerChrome({
    required this.title,
    required this.subtitle,
    required this.dense,
    required this.compact,
    required this.search,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.filterIndex,
    required this.onFilter,
    required this.filterLabels,
    required this.onCompose,
    this.filterNames = const [],
    this.filterCounts = const [],
    this.agents = const [],
    this.onOpenAgent,
    this.me = '',
    this.composeInTitle = false,
    this.onClose,
    this.requests = 0,
    this.onRequests,
  });

  /// Plain filter names with [filterCounts] (phone tab). Empty keeps the
  /// [filterLabels] tab bar.
  final List<String> filterNames;
  final List<int> filterCounts;

  /// Agents in the strip under the filters (phone tab only).
  final List<_AgentStatus> agents;
  final ValueChanged<ChatSummary>? onOpenAgent;
  final String me;

  /// The compose button sits in the title row instead of beside search.
  final bool composeInTitle;

  final String title;
  final String subtitle;
  final bool dense;
  final bool compact;
  final TextEditingController search;
  final VoidCallback onSearchChanged;
  final VoidCallback onClearSearch;
  final int filterIndex;
  final ValueChanged<int> onFilter;
  final List<String> filterLabels;
  final Future<void> Function(BuildContext fabContext) onCompose;
  final VoidCallback? onClose;
  final int requests;
  final VoidCallback? onRequests;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gap = dense ? 10.0 : 14.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titleRow(context, scheme),
        SizedBox(height: dense ? 4 : 6),
        Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: dense ? 11.5 : 13,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
        ),
        SizedBox(height: gap),
        _SearchComposeBar(
          dense: dense,
          search: search,
          onSearchChanged: onSearchChanged,
          onClearSearch: onClearSearch,
          onCompose: composeInTitle ? null : onCompose,
        ),
        SizedBox(height: dense ? 10 : 12),
        if (filterNames.isNotEmpty && filterCounts.length == filterNames.length)
          _FilterSegments(
            names: filterNames,
            counts: filterCounts,
            selected: filterIndex,
            onTap: onFilter,
          )
        else
          SegmentedTabBar(
            alignment: Alignment.center,
            compact: compact,
            selectedIndex: filterIndex,
            onTap: onFilter,
            labels: filterLabels,
            icons: const [
              Icons.all_inbox_rounded,
              Icons.person_outline_rounded,
              Icons.workspaces_outline,
            ],
          ),
        if (agents.isNotEmpty) ...[
          const SizedBox(height: 12),
          _AgentStrip(agents: agents, me: me, onOpen: onOpenAgent),
        ],
        if (requests > 0 && onRequests != null) ...[
          SizedBox(height: dense ? 8 : 10),
          _RequestsBanner(count: requests, onTap: onRequests!),
        ],
        SizedBox(height: dense ? 6 : 10),
      ],
    );
  }

  Widget _titleRow(BuildContext context, ColorScheme scheme) {
    final titleStyle = (dense
            ? Theme.of(context).textTheme.titleLarge
            : Theme.of(context).textTheme.headlineSmall)
        ?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: -0.7,
          height: 1.05,
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
              const SizedBox(height: 8),
              Container(
                width: dense ? 28 : 36,
                height: 3,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  // Flat packs: one solid accent rule, no gradient.
                  color: ThemeChrome.isFlat(context) ? scheme.primary : null,
                  gradient: ThemeChrome.isFlat(context)
                      ? null
                      : LinearGradient(
                          colors: [
                            scheme.primary,
                            AppColors.cyanOf(context).withValues(alpha: .85),
                            scheme.primary.withValues(alpha: .15),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        if (composeInTitle)
          Builder(
            builder: (fabContext) => SkyFab(
              mini: true,
              tooltip: 'New chat or space',
              icon: Icons.edit_square,
              onPressed: () => onCompose(fabContext),
            ),
          ),
        if (onClose != null)
          IconButton.filledTonal(
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
  }
}

/// Search field with the compose FAB docked on its trailing edge.
class _SearchComposeBar extends StatelessWidget {
  const _SearchComposeBar({
    required this.dense,
    required this.search,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onCompose,
  });

  final bool dense;
  final TextEditingController search;
  final VoidCallback onSearchChanged;
  final VoidCallback onClearSearch;

  /// Null when the compose button lives in the title row.
  final Future<void> Function(BuildContext fabContext)? onCompose;

  @override
  Widget build(BuildContext context) {
    final compose = onCompose;
    return Row(
      children: [
        Expanded(
          child: SoftSearchField(
            controller: search,
            dense: dense,
            hintText: 'Search chats',
            onChanged: (_) => onSearchChanged(),
            trailing: search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                    onPressed: onClearSearch,
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
          ),
        ),
        if (compose != null) ...[
          const SizedBox(width: 8),
          Builder(
            builder: (fabContext) => SkyFab(
              mini: true,
              tooltip: 'New',
              icon: Icons.add_rounded,
              onPressed: () => compose(fabContext),
            ),
          ),
        ],
      ],
    );
  }
}

class _RequestsBanner extends StatelessWidget {
  const _RequestsBanner({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DockedBanner(
      eyebrow: 'REQUESTS',
      accent: AppColors.warningOf(context),
      title: count == 1
          ? '1 question is waiting'
          : '$count questions are waiting',
      subtitle: 'Tap to answer',
      onTap: onTap,
      leading: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: AppColors.warningOf(context).withValues(alpha: .16),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Icon(Icons.help_outline_rounded,
            size: 18, color: AppColors.warningOf(context)),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.body,
    this.expand = true,
  });
  final IconData icon;
  final String title;
  final String body;

  /// Centers in the leftover rail. Off when the message sits in the page scroll.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final message = PanelEmpty(icon: icon, title: title, message: body);
    if (!expand) return Align(alignment: Alignment.topCenter, child: message);
    return Center(child: SingleChildScrollView(child: message));
  }
}

/// Picks who to start a direct chat with: a person or agent found by @handle,
/// or one of the account's own agents. Pops with the chosen account id.
class _NewChatPage extends StatefulWidget {
  const _NewChatPage({
    required this.dependencies,
    this.topContentInset = 0,
  });
  final AppDependencies dependencies;

  /// Clears the home floating app bar when this page is pushed from the
  /// embedded chats tab (see [MessengerPanel.topContentInset]).
  final double topContentInset;

  @override
  State<_NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends State<_NewChatPage> {
  final _query = TextEditingController();
  List<AccountSummary> _results = const [];
  List<Bot> _foundAgents = const [];
  List<Bot> _agents = const [];
  Timer? _debounce;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    widget.dependencies.service
        .fetchBots()
        .then((bots) {
          if (mounted)
            setState(() => _agents =
                bots.where((b) => b.isAgent && !b.isBuiltin).toList());
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = text.trim().replaceFirst(RegExp(r'^@+'), '');
      if (q.isEmpty) {
        if (mounted) {
          setState(() {
            _results = const [];
            _foundAgents = const [];
          });
        }
        return;
      }
      setState(() => _searching = true);
      try {
        // People and agents are searched apart: users.search only ever
        // returns people, and apps are not chat partners.
        final service = widget.dependencies.service;
        final found = await service.searchUsers(q, limit: 12);
        final bots = await service
            .searchBots(q, kind: 'agent', limit: 12)
            .catchError((_) => <Map<String, dynamic>>[]);
        final me = widget.dependencies.sessionController.session?.accountId;
        final mine = {for (final b in _agents) b.id};
        if (mounted) {
          setState(() {
            _results = found.where((a) => a.id != me).toList();
            _foundAgents = bots
                .map(Bot.fromJson)
                .where((b) => !b.isBuiltin && !mine.contains(b.id))
                .toList();
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _results = const [];
            _foundAgents = const [];
          });
        }
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final compact = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    final gutter = compact ? 16.0 : 26.0;
    final raw = _query.text.trim();
    final pastedId = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(raw);
    final agents = raw.isEmpty
        ? _agents
        : _agents
              .where((b) => b.name.toLowerCase().contains(raw.toLowerCase()))
              .toList();
    // The chat list stays transparent so the rail's glass shows through.
    // This page slides over that list, so its fill has to be opaque or the
    // chats stay visible until people and agents arrive.
    final background = Color.alphaBlend(
      AppSurfaces.tint(scheme).withValues(alpha: AppSurfaces.tintAlpha(scheme)),
      theme.scaffoldBackgroundColor,
    );
    final topPad = (compact ? 12.0 : 18.0) + widget.topContentInset;
    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        // Host SafeArea already cleared the status bar when embedded; keep
        // bottom safe for home-indicator clearance on the sheet form.
        top: widget.topContentInset <= 0,
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, topPad, gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Back to chats',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      'New chat',
                      style:
                          TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                autofocus: true,
                onChanged: (v) {
                  setState(() {});
                  _search(v);
                },
                decoration: InputDecoration(
                  hintText: 'Search people and agents by @handle',
                  prefixIcon: const Icon(Icons.person_search_rounded),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (pastedId)
                      _PickTile(
                        icon: Icons.tag_rounded,
                        title: 'Account $raw',
                        subtitle: 'Start a chat with this account id',
                        onTap: () => Navigator.of(context).pop(raw),
                      ),
                    for (final r in _results)
                      _PickTile(
                        icon: Icons.person_outline_rounded,
                        title: '@${r.handle}',
                        avatar: r.avatar,
                        subtitle: 'Person',
                        onTap: () => Navigator.of(context).pop(r.id),
                      ),
                    for (final b in _foundAgents)
                      _PickTile(
                        icon: Icons.smart_toy_outlined,
                        title: b.name,
                        bot: b,
                        userId: widget.dependencies.sessionController
                                .session?.accountId ??
                            '',
                        subtitle: 'Agent',
                        onTap: () => Navigator.of(
                          context,
                        ).pop(b.accountId.isNotEmpty ? b.accountId : b.id),
                      ),
                    if (agents.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                        child: Text(
                          'YOUR AGENTS',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .8,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      for (final b in agents)
                        _PickTile(
                          icon: Icons.smart_toy_outlined,
                          title: b.name,
                          bot: b,
                          userId: widget.dependencies.sessionController
                                  .session?.accountId ??
                              '',
                          subtitle: 'Agent',
                          onTap: () => Navigator.of(
                            context,
                          ).pop(b.accountId.isNotEmpty ? b.accountId : b.id),
                        ),
                    ],
                    if (raw.isNotEmpty &&
                        !_searching &&
                        _results.isEmpty &&
                        _foundAgents.isEmpty &&
                        !pastedId)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Nobody found for "$raw".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
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
  }
}

class _PickTile extends StatelessWidget {
  const _PickTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.avatar = '',
    this.bot,
    this.userId = '',
  });
  final IconData icon;

  /// The picture shown over [icon], when there is one.
  final String avatar;

  /// When set (an agent), shows the unified humanoid + picture badge.
  final Bot? bot;
  final String userId;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
    ),
    leading: bot != null
        ? BotAvatar(bot: bot!, radius: 20, userId: userId)
        : Builder(builder: (context) {
            const radius = 20.0;
            final size = radius * 2;
            final corners = context.avatarBorderRadius(size);
            final picture = Avatars.of(avatar);
            return HaloRing(
              borderRadius: corners,
              child: AvatarFace(
                size: size,
                borderRadius: corners,
                backgroundColor: ThemeRoles.wellFill(context),
                foregroundImage: picture,
                onImageError: picture == null ? null : (_, __) {},
                child: Icon(icon, color: ThemeRoles.wellInk(context)),
              ),
            );
          }),
    title: Text(
      title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w700),
    ),
    subtitle: Text(subtitle),
    onTap: onTap,
  );
}


/// One agent in the chats strip and what it is doing.
class _AgentStatus {
  _AgentStatus({required this.chat, this.agent});

  final ChatSummary chat;
  final Bot? agent;

  bool get working => chat.working;
  bool get waiting => !working && chat.unread > 0;

  /// Working first, then those with replies for you, then idle.
  int get rank => working ? 0 : (waiting ? 1 : 2);

  String get label => working
      ? 'working'
      : waiting
      ? (chat.unread == 1 ? '1 new reply' : '${chat.unread} new replies')
      : 'idle';
}

/// Horizontal strip of agent chips: avatar, name and a status dot (firoozeh
/// working, saffron waiting on you, grey idle). Tapping opens the chat.
class _AgentStrip extends StatelessWidget {
  const _AgentStrip({required this.agents, required this.me, this.onOpen});

  final List<_AgentStatus> agents;
  final String me;
  final ValueChanged<ChatSummary>? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: agents.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = agents[i];
          final dot = a.working
              ? AppColors.successOf(context)
              : a.waiting
              ? AppColors.warningOf(context)
              : scheme.onSurfaceVariant;
          return Semantics(
            button: true,
            label: '${a.chat.title}, ${a.label}',
            excludeSemantics: true,
            child: Material(
              color: scheme.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpen == null ? null : () => onOpen!(a.chat),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ChatAvatar(
                        chat: a.chat,
                        radius: 15,
                        userId: me,
                        agent: a.agent,
                      ),
                      const SizedBox(width: 8),
                      Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.chat.title,
                            maxLines: 1,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              height: 1.15,
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: dot,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                a.label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  height: 1.15,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Full-width filter: a sunken track with the selected segment raised on a
/// hairline, each name followed by its count.
class _FilterSegments extends StatelessWidget {
  const _FilterSegments({
    required this.names,
    required this.counts,
    required this.selected,
    required this.onTap,
  });

  final List<String> names;
  final List<int> counts;
  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final r = AppShape.controlOf(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(r),
      ),
      child: Row(
        children: [
          for (var i = 0; i < names.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                label: '${names[i]}, ${counts[i]}',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: i == selected ? scheme.surface : null,
                      borderRadius: BorderRadius.circular(
                        (r - 3).clamp(4.0, 99.0),
                      ),
                      border: i == selected
                          ? Border.all(color: scheme.outlineVariant)
                          : null,
                    ),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: names[i]),
                          TextSpan(
                            text: '  ${counts[i]}',
                            style: ThemeChrome.numeric(context).copyWith(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: i == selected
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: i == selected
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A labelled card of chat rows separated by inset hairlines.
class _ChatGroup extends StatelessWidget {
  const _ChatGroup({required this.label, required this.children});

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 4, 2, 6),
            child: Text(
              label,
              style: ThemeChrome.numeric(context).copyWith(
                fontSize: 11,
                letterSpacing: 1.3,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: 68,
                      color: scheme.outlineVariant.withValues(alpha: .7),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
