import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../search_feed/presentation/rich_post_parser.dart'
    show markupPreview;
import 'chat_page.dart';
import 'requests_panel.dart';

/// Opens the messenger: a bottom sheet on phones, a floating window on wider
/// screens.
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
    this.onOpenSpaceRoom,
  });

  final AppDependencies dependencies;

  /// Home-shell tab: no close button.
  final bool embedded;

  /// Narrow desktop rail sizing; leave false on the mobile chats tab.
  final bool dense;

  /// Opens a project's room on the workspace page (its desk, chat, and the
  /// rest). Set on the home chats list. When null, a room still opens as a
  /// chat — the floating messenger.
  final void Function(String spaceName, String roomName, String roomId)?
  onOpenSpaceRoom;

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
              onOpenSpaceRoom: widget.onOpenSpaceRoom,
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

enum _Filter { all, direct, spaces }

class _ChatList extends StatefulWidget {
  const _ChatList({
    required this.dependencies,
    this.onClose,
    this.embedded = false,
    this.dense = false,
    this.onOpenSpaceRoom,
  });

  final AppDependencies dependencies;

  /// Null when the list is an embedded home tab (no close control).
  final VoidCallback? onClose;
  final bool embedded;

  /// Compact chrome for a desktop side rail.
  final bool dense;

  /// See [MessengerPanel.onOpenSpaceRoom].
  final void Function(String spaceName, String roomName, String roomId)?
  onOpenSpaceRoom;

  @override
  State<_ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<_ChatList> {
  final _search = TextEditingController();
  List<ChatSummary> _chats = const [];
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
      final chats = await _service.fetchChats();
      if (!mounted) return;
      setState(() {
        _chats = chats;
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
    // A project's room, from the home chats list, opens that room in its
    // workspace. Direct chats, and rooms in the floating messenger, open here.
    final openRoom = widget.onOpenSpaceRoom;
    if (!chat.direct && openRoom != null && chat.spaceName.isNotEmpty) {
      openRoom(chat.spaceName, chat.roomName, chat.roomId);
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

  Future<void> _openSaved() async {
    try {
      final chat = await _service.openSaved();
      if (!mounted) return;
      await _open(chat);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open Saved Messages: $e')),
      );
    }
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
        await _service.pinChat(chat.spaceId, chat.roomId, !chat.pinned);
      } else {
        await _service.clearChat(chat.spaceId);
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
        builder: (_) => _NewChatPage(dependencies: widget.dependencies),
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

  /// Direct chats stay one row each. Every room of a project folds into a
  /// single space row, ordered like the chats they replace: pinned first,
  /// then most recently active.
  List<_ChatEntry> get _shown {
    final q = _search.text.trim().toLowerCase();
    final directs = <_DirectEntry>[];
    final bySpace = <String, _SpaceEntry>{};
    for (final chat in _chats) {
      if (_filter == _Filter.direct && !chat.direct) continue;
      if (_filter == _Filter.spaces && chat.direct) continue;
      if (chat.direct) {
        if (_chatMatches(chat, q)) directs.add(_DirectEntry(chat));
        continue;
      }
      bySpace
          .putIfAbsent(chat.spaceId, () => _SpaceEntry(chat.spaceId))
          .rooms
          .add(chat);
    }
    final spaces = <_SpaceEntry>[];
    for (final entry in bySpace.values) {
      final nameHit = q.isEmpty || entry.name.toLowerCase().contains(q);
      if (!nameHit) {
        entry.rooms.retainWhere((room) => _chatMatches(room, q));
      }
      if (entry.rooms.isNotEmpty) spaces.add(entry);
    }
    final entries = <_ChatEntry>[...directs, ...spaces];
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
          : _filter == _Filter.spaces
          ? 'No spaces yet'
          : 'No chats yet',
      body: _filter == _Filter.spaces
          ? 'Projects you belong to show up here.'
          : 'Start one with a person or an agent.',
      expand: expand,
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 560;
    final dense = widget.dense;
    final gutter = dense ? 12.0 : (compact || widget.embedded ? 16.0 : 26.0);
    final shown = _shown;
    // Phone chats tab: header, search, filters, and rows share one scroll.
    // The desktop rail and the floating messenger keep that chrome fixed and
    // scroll only the list.
    final pageScroll = widget.embedded && !dense;
    final top = dense || compact || widget.embedded ? 8.0 : 22.0;
    // On the phone chats tab, clear the floating tab pill.
    // The desktop rail has no bar under it.
    final listBottom = pageScroll
        ? 90 + MediaQuery.viewPaddingOf(context).bottom
        : 24.0;
    final waiting = _loading || _error != null || shown.isEmpty;
    final chrome = <Widget>[
      PanelHeader(
        icon: Icons.forum_outlined,
        title: widget.embedded ? 'Chats' : 'Messages',
        subtitle: 'Direct chats and your spaces',
        onClose: widget.onClose,
        actions: [
          IconButton(
            tooltip: 'Saved Messages',
            onPressed: _openSaved,
            icon: const Icon(Icons.bookmark_outline_rounded),
          ),
          if (dense)
            IconButton.filled(
              tooltip: 'New chat',
              onPressed: _newChat,
              icon: const Icon(Icons.edit_square, size: 18),
            )
          else
            FilledButton.icon(
              onPressed: _newChat,
              icon: const Icon(Icons.edit_square, size: 18),
              label: const Text('New chat'),
            ),
        ],
      ),
      SizedBox(height: dense ? 10 : 14),
      TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Search chats',
          isDense: dense,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  onPressed: () => setState(_search.clear),
                  icon: const Icon(Icons.close_rounded),
                ),
        ),
      ),
      SizedBox(height: dense ? 8 : 12),
      SegmentedTabBar(
        alignment: Alignment.center,
        compact: compact,
        selectedIndex: _filter.index,
        onTap: (i) => setState(() => _filter = _Filter.values[i]),
        labels: [
          _label('All', _unread(null)),
          _label('Direct', _unread(true)),
          _label('Spaces', _unread(false)),
        ],
        icons: const [
          Icons.all_inbox_rounded,
          Icons.person_outline_rounded,
          Icons.workspaces_outline,
        ],
      ),
      if (_requests > 0) ...[
        const SizedBox(height: 10),
        _RequestsBanner(
          count: _requests,
          onTap: () async {
            await showRequestsPanel(context, widget.dependencies);
            if (mounted) unawaited(_load());
          },
        ),
      ],
      const SizedBox(height: 8),
    ];
    final tiles = _chatTiles(shown, dense);

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
              ...chrome,
              if (waiting) _listPlaceholder(shown, expand: false) else ...tiles,
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
            ...chrome,
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

  List<Widget> _entryTiles(_ChatEntry entry, bool dense) {
    if (entry is _DirectEntry) {
      final chat = entry.chat;
      return [
        _ChatTile(
          chat: chat,
          me: _me,
          dense: dense,
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
          borderRadius: BorderRadius.circular(AppShape.inner),
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
                    ChatAvatar(chat: latest, radius: dense ? 18 : 24),
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
                          style: TextStyle(
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
  });

  final List<ChatSummary> rooms;
  final String me;
  final bool dense;
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
              color: scheme.primary.withValues(alpha: .4),
              width: 3,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Column(
            children: [
              for (final room in rooms)
                _ChatTile(
                  chat: room,
                  me: me,
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
    this.dense = false,
    this.topic = false,
  });

  final ChatSummary chat;
  final String me;
  final bool dense;

  /// A room shown under its space, rather than as its own chat.
  final bool topic;
  final VoidCallback onTap;
  final void Function(Offset at, BuildContext anchor) onMenu;

  String get _preview => _chatPreview(chat, me);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = chat.unread > 0;
    return Material(
      color: unread
          ? scheme.primaryContainer.withValues(alpha: .35)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: null,
        onSecondaryTap: null,
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
                    ),
                    if (chat.working)
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
                              !chat.saved &&
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
                          style: TextStyle(
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
  final body = markupPreview(chat.lastBody);
  final text = body.isNotEmpty
      ? body
      : chat.lastAttachments > 0
      ? (chat.lastAttachments == 1
            ? '📎 Attachment'
            : '📎 ${chat.lastAttachments} attachments')
      : '';
  if (text.isEmpty) {
    if (chat.saved) return 'Notes, links and files for yourself';
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

class _RequestsBanner extends StatelessWidget {
  const _RequestsBanner({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: AppColors.warning.withValues(alpha: .14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.inner),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const Icon(Icons.help_outline_rounded, color: AppColors.warning),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  count == 1
                      ? '1 question is waiting for your answer'
                      : '$count questions are waiting for your answer',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
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
    final scheme = Theme.of(context).colorScheme;
    final message = Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
              color: scheme.secondaryContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Icon(icon, size: 34, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
    if (!expand) return Align(alignment: Alignment.topCenter, child: message);
    return Center(child: SingleChildScrollView(child: message));
  }
}

/// Picks who to start a direct chat with: a person or agent found by @handle,
/// or one of the account's own agents. Pops with the chosen account id.
class _NewChatPage extends StatefulWidget {
  const _NewChatPage({required this.dependencies});
  final AppDependencies dependencies;

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
            setState(() => _agents = bots.where((b) => b.isAgent).toList());
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
                .where((b) => !mine.contains(b.id))
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
    final compact = MediaQuery.sizeOf(context).width < 560;
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
    return Scaffold(
      backgroundColor: background,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 12 : 18, gutter, 0),
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
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
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
                      avatar: b.avatar,
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
                        avatar: b.avatar,
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
  });
  final IconData icon;

  /// The picture shown over [icon], when there is one.
  final String avatar;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppShape.control),
    ),
    leading: CircleAvatar(
      foregroundImage: Avatars.of(avatar),
      onForegroundImageError: avatar.isEmpty ? null : (_, __) {},
      child: Icon(icon),
    ),
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
