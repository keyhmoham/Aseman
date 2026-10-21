import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import 'chat_page.dart';
import 'requests_panel.dart';

/// Opens the messenger: a bottom sheet on phones, a floating window on wider
/// screens.
Future<void> showMessenger(
        BuildContext context, AppDependencies dependencies) =>
    showFloatingPanel(context, MessengerPanel(dependencies: dependencies),
        maxWidth: 760, barrierLabel: 'Close messages');

/// Every conversation of the account in one place, like a messenger: direct
/// chats with people and agents and the rooms of the account's projects, each
/// opening the same full room chat.
class MessengerPanel extends StatefulWidget {
  const MessengerPanel({super.key, required this.dependencies});

  final AppDependencies dependencies;

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
    // closes the panel as usual.
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
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => _ChatList(
              dependencies: widget.dependencies,
              onClose: () => Navigator.of(context).pop(),
            ),
          ),
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
  const _ChatList({required this.dependencies, required this.onClose});

  final AppDependencies dependencies;
  final VoidCallback onClose;

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
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) =>
            ChatPage(dependencies: widget.dependencies, chat: chat)));
    if (mounted) unawaited(_load());
  }

  Future<void> _openSaved() async {
    try {
      final chat = await _service.openSaved();
      if (!mounted) return;
      await _open(chat);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open Saved Messages: $e')));
    }
  }

  // Long-pressing a chat pins or unpins it (and deletes a direct chat for
  // the caller).
  Future<void> _chatMenu(ChatSummary chat) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: Icon(chat.pinned
                  ? Icons.push_pin_rounded
                  : Icons.push_pin_outlined),
              title: Text(chat.pinned ? 'Unpin' : 'Pin to top'),
              onTap: () => Navigator.pop(context, 'pin')),
          if (chat.direct)
            ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Delete chat for me'),
                onTap: () => Navigator.pop(context, 'clear')),
          const SizedBox(height: 8),
        ]),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not change it: $e')));
    }
  }

  Future<void> _newChat() async {
    final peer = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
            builder: (_) => _NewChatPage(dependencies: widget.dependencies)));
    if (peer == null || !mounted) return;
    try {
      final chat = await _service.openDirect(peer);
      if (!mounted) return;
      await _open(chat);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not start chat: $e')));
    }
  }

  List<ChatSummary> get _shown {
    final q = _search.text.trim().toLowerCase();
    return _chats.where((c) {
      if (_filter == _Filter.direct && !c.direct) return false;
      if (_filter == _Filter.spaces && c.direct) return false;
      if (q.isEmpty) return true;
      return '${c.title} ${c.spaceName} ${c.peer?.handle ?? ''} ${c.lastBody}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  int _unread(bool? direct) => _chats
      .where((c) => direct == null || c.direct == direct)
      .fold(0, (sum, c) => sum + c.unread);

  String _label(String name, int unread) =>
      unread > 0 ? '$name · $unread' : name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final gutter = compact ? 16.0 : 26.0;
    final shown = _shown;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 16 : 22, gutter, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PanelHeader(
            icon: Icons.forum_outlined,
            title: 'Messages',
            subtitle: 'Direct chats and your project rooms',
            onClose: widget.onClose,
            actions: [
              IconButton(
                  tooltip: 'Refresh',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded)),
              IconButton(
                  tooltip: 'Saved Messages',
                  onPressed: _openSaved,
                  icon: const Icon(Icons.bookmark_outline_rounded)),
              FilledButton.icon(
                  onPressed: _newChat,
                  icon: const Icon(Icons.edit_square, size: 18),
                  label: const Text('New chat')),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search chats',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded)),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedTabBar(
            alignment: Alignment.centerLeft,
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
                }),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _Empty(
                        icon: Icons.cloud_off_rounded,
                        title: 'Could not load chats',
                        body: _error!)
                    : shown.isEmpty
                        ? _Empty(
                            icon: Icons.forum_outlined,
                            title: _search.text.isNotEmpty
                                ? 'No matching chats'
                                : _filter == _Filter.spaces
                                    ? 'No project rooms yet'
                                    : 'No chats yet',
                            body: _filter == _Filter.spaces
                                ? 'Rooms of the projects you belong to show up here.'
                                : 'Start one with a person or an agent.')
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              padding: const EdgeInsets.only(bottom: 24),
                              itemCount: shown.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 2),
                              itemBuilder: (context, i) => _ChatTile(
                                chat: shown[i],
                                me: _me,
                                onTap: () => _open(shown[i]),
                                onMenu: () => _chatMenu(shown[i]),
                              ),
                            ),
                          ),
          ),
        ]),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile(
      {required this.chat,
      required this.me,
      required this.onTap,
      required this.onMenu});

  final ChatSummary chat;
  final String me;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  String get _preview {
    final body = chat.lastBody.replaceAll(RegExp(r'\s+'), ' ').trim();
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = chat.unread > 0;
    return Material(
      color: unread
          ? scheme.primaryContainer.withValues(alpha: .35)
          : Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu,
        onSecondaryTap: onMenu,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              ChatAvatar(chat: chat, radius: 24),
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
                        border: Border.all(color: scheme.surface, width: 2)),
                  ),
                ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: unread
                                    ? FontWeight.w800
                                    : FontWeight.w700)),
                      ),
                      if (chat.blocked) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.block_rounded,
                            size: 14,
                            semanticLabel: 'Blocked',
                            color: scheme.onSurfaceVariant),
                      ],
                      if (chat.direct &&
                          !chat.saved &&
                          (chat.peer?.isAgent ?? false)) ...[
                        const SizedBox(width: 6),
                        _Tag('AI', scheme.tertiary),
                      ],
                      if (!chat.direct) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(chat.spaceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ),
                      ],
                    ]),
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
                                    : scheme.onSurfaceVariant)),
                  ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (chat.pinned) ...[
                  Icon(Icons.push_pin_rounded,
                      size: 13,
                      semanticLabel: 'Pinned',
                      color: scheme.onSurfaceVariant),
                  const SizedBox(width: 3),
                ],
                Text(_when(chat.updatedAt),
                    style: TextStyle(
                        fontSize: 11,
                        color:
                            unread ? scheme.primary : scheme.onSurfaceVariant,
                        fontWeight:
                            unread ? FontWeight.w700 : FontWeight.w400)),
              ]),
              const SizedBox(height: 6),
              if (unread)
                Badge(
                    label: Text(chat.unread > 99 ? '99+' : '${chat.unread}'),
                    backgroundColor: scheme.primary,
                    textColor: scheme.onPrimary)
              else
                const SizedBox(height: 16),
            ]),
          ]),
        ),
      ),
    );
  }

  static String _when(DateTime? t) {
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
      return const [
        'Mon',
        'Tue',
        'Wed',
        'Thu',
        'Fri',
        'Sat',
        'Sun'
      ][t.weekday - 1];
    }
    return '${t.day}/${t.month}/${t.year % 100}';
  }
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
            borderRadius: BorderRadius.circular(999)),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w800, color: color)),
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
          borderRadius: BorderRadius.circular(AppShape.inner)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(children: [
            const Icon(Icons.help_outline_rounded, color: AppColors.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                  count == 1
                      ? '1 question is waiting for your answer'
                      : '$count questions are waiting for your answer',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
                color: scheme.secondaryContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24))),
            child: Icon(icon, size: 34, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
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
    widget.dependencies.service.fetchBots().then((bots) {
      if (mounted)
        setState(() => _agents = bots.where((b) => b.isAgent).toList());
    }).catchError((_) {});
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
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final gutter = compact ? 16.0 : 26.0;
    final raw = _query.text.trim();
    final pastedId = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(raw);
    final agents = raw.isEmpty
        ? _agents
        : _agents
            .where((b) => b.name.toLowerCase().contains(raw.toLowerCase()))
            .toList();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: Padding(
        padding: EdgeInsets.fromLTRB(gutter, compact ? 12 : 18, gutter, 0),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            IconButton(
                tooltip: 'Back to chats',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back_rounded)),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('New chat',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            ),
          ]),
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
                          child: CircularProgressIndicator(strokeWidth: 2)))
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child:
                ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              if (pastedId)
                _PickTile(
                    icon: Icons.tag_rounded,
                    title: 'Account $raw',
                    subtitle: 'Start a chat with this account id',
                    onTap: () => Navigator.of(context).pop(raw)),
              for (final r in _results)
                _PickTile(
                    icon: Icons.person_outline_rounded,
                    title: '@${r.handle}',
                    avatar: r.avatar,
                    subtitle: 'Person',
                    onTap: () => Navigator.of(context).pop(r.id)),
              for (final b in _foundAgents)
                _PickTile(
                    icon: Icons.smart_toy_outlined,
                    title: b.name,
                    avatar: b.avatar,
                    subtitle: 'Agent',
                    onTap: () => Navigator.of(context)
                        .pop(b.accountId.isNotEmpty ? b.accountId : b.id)),
              if (agents.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
                  child: Text('YOUR AGENTS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: .8,
                          color: scheme.onSurfaceVariant)),
                ),
                for (final b in agents)
                  _PickTile(
                      icon: Icons.smart_toy_outlined,
                      title: b.name,
                      avatar: b.avatar,
                      subtitle: 'Agent',
                      onTap: () => Navigator.of(context)
                          .pop(b.accountId.isNotEmpty ? b.accountId : b.id)),
              ],
              if (raw.isNotEmpty &&
                  !_searching &&
                  _results.isEmpty &&
                  _foundAgents.isEmpty &&
                  !pastedId)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Nobody found for "$raw".',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ]),
          ),
        ]),
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
            borderRadius: BorderRadius.circular(AppShape.control)),
        leading: CircleAvatar(
            foregroundImage: Avatars.of(avatar),
            onForegroundImageError: avatar.isEmpty ? null : (_, __) {},
            child: Icon(icon)),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        onTap: onTap,
      );
}
