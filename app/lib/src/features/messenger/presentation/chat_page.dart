import 'dart:async';
import '../../../core/theme/app_shape.dart';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/theme_chrome.dart';
import '../../../core/theme/theme_roles.dart';
import '../../../core/theme/halo_ring_cache.dart';
import '../../../data/models/agent_humanoid.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/sky_ui.dart';
import '../../brain/brain_avatar.dart';
import '../../brain/brain_voice.dart';
import '../../calls/call_page.dart' deferred as call_page;
import '../../desk/data/desk_api.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../gadgets/presentation/gadgets_overlay.dart';
import '../../rooms/presentation/widgets/room_chat.dart';
import 'dm_desk_panel.dart' deferred as dm_desk;
import 'dm_facility_sheet.dart';
import 'report_dialog.dart';
import 'widgets/brain_proposals.dart';
import '../../../core/deferred/deferred_loader.dart';

/// The call screen and a direct chat's desk, each loaded on first use.
final _callPage = DeferredLoader(() => call_page.loadLibrary());
final _dmDesk = DeferredLoader(() => dm_desk.loadLibrary());

/// Loads what a direct chat opens (calls, its desk).
Future<void> loadChatScreens() async {
  await _callPage.ensure();
  await _dmDesk.ensure();
}

/// Opens [chat]: on a wide screen a direct chat (or personal Aseman) is a
/// floating modal; project rooms and compact widths keep a full-page push
/// on the root navigator (so an embedded chats tab never hosts the chat).
Future<void> showChat(
  BuildContext context,
  AppDependencies dependencies,
  ChatSummary chat,
) {
  final wide = MediaQuery.sizeOf(context).width >= 820;
  if (wide && chat.direct) {
    return showFloatingPanel(
      context,
      ChatPage(dependencies: dependencies, chat: chat, asModal: true),
      maxWidth: 720,
      maxHeight: 860,
      barrierLabel: 'Close chat',
    );
  }
  return Navigator.of(context, rootNavigator: true).push<void>(
      MaterialPageRoute<void>(
          builder: (_) =>
              ChatPage(dependencies: dependencies, chat: chat)));
}

/// One conversation of the messenger, direct or a project room. Direct chats
/// use a Chat/Desk dual-tab shell (like a space room); each participant has
/// their own desk. AI / Aseman directs also get a collapsible avatar and a
/// voice-call FAB.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.dependencies,
    required this.chat,
    this.asModal = false,
    this.embedded = false,
    this.bottomInset = 0,
  });

  final AppDependencies dependencies;
  final ChatSummary chat;

  /// Shown as a floating desktop panel: close control instead of back-to-list.
  final bool asModal;

  /// Hosted inside the home Aseman tab (no back/close; respects [bottomInset]).
  final bool embedded;

  /// Extra bottom padding when embedded under the home tab pill.
  final double bottomInset;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  RoomChatPage _page = const RoomChatPage();
  List<Bot> _agents = const [];
  List<Bot> _apps = const [];
  Timer? _poll;
  bool _loading = false;

  /// True until the first fetch of this chat finishes (success or failure).
  bool _initialLoading = true;
  bool _loadingOlder = false;
  DateTime? _seen;
  late ChatSummary _chat = widget.chat;

  /// The open thread of the chat's room; null for its main thread.
  RoomThread? _thread;

  late final DeskController _desk = DeskController(
    DeskApi.of(widget.dependencies.service),
  );

  /// 0 = Desk, 1 = Chat (same order as space mobile tabs).
  int _surface = 1;
  final _pages = PageController(initialPage: 1);

  /// Collapse progress for the AI avatar header (0 expanded → 1 collapsed).
  double _avatarCollapse = 0;

  BrainAvatarPrefs _avatarPrefs = const BrainAvatarPrefs();
  BrainVoiceClient? _voice;

  ChatSummary get chat => _chat;

  /// Where the open conversation's messages live: the thread, else the room.
  String get _roomId => _thread?.id ?? chat.roomId;
  AsemanService get _service => widget.dependencies.service;
  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  bool get _isAiChat =>
      chat.isAseman || (chat.direct && (chat.peer?.isAgent ?? false));

  bool get _showDualTabs => chat.direct;

  @override
  void initState() {
    super.initState();
    _load();
    _loadAgents();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
    if (_showDualTabs) {
      _desk.attach(chat.spaceId, chat.roomId);
    }
    if (_isAiChat) {
      _voice = BrainVoiceClient(_service)..addListener(_onVoice);
      unawaited(_bootAvatar());
    }
  }

  String get _avatarAgentId {
    if (chat.saved) return '';
    final peer = chat.peer;
    if (peer == null) return '';
    return peer.botId.isNotEmpty ? peer.botId : peer.id;
  }

  Future<void> _bootAvatar() async {
    final prefs = await BrainAvatarPrefs.load(
      agentId: _avatarAgentId,
      userId: _me,
      platform: chat.peer?.humanoid,
    );
    if (!mounted) return;
    setState(() => _avatarPrefs = prefs);
    await _voice?.loadConfig();
  }

  void _onVoice() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _poll?.cancel();
    _pages.dispose();
    _desk.dispose();
    _voice?.removeListener(_onVoice);
    _voice?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    var switched = false;
    try {
      final thread = _roomId;
      final res = await _service.fetchRoomChat(chat.spaceId, thread);
      if (!mounted) return;
      if (thread != _roomId) {
        switched = true;
        return;
      }
      final old = _page;
      final msgs = mergeNewestRoomMessages(old.messages, res.messages);
      final holdsOlder = msgs.length > res.messages.length;
      final hasMore = holdsOlder ? old.hasMore : res.hasMore;
      final changed = msgs.length != old.messages.length ||
          List.generate(msgs.length, (i) => i).any((i) =>
              i >= old.messages.length ||
              !old.messages[i].hasSameContentAs(msgs[i])) ||
          res.working != old.working ||
          res.workingDetail != old.workingDetail ||
          res.typing.join('\n') != old.typing.join('\n') ||
          res.peerSeenAt != old.peerSeenAt ||
          res.blocked != old.blocked ||
          res.canSend != old.canSend ||
          hasMore != old.hasMore;
      if (changed || _initialLoading) {
        setState(() {
          _page = res.copyWith(messages: msgs, hasMore: hasMore);
          _chat = _chat.copyWith(blocked: res.blocked, canSend: res.canSend);
          _initialLoading = false;
        });
      }
      _markSeen(msgs);
    } catch (_) {
      if (_initialLoading && mounted) {
        setState(() => _initialLoading = false);
      }
    } finally {
      _loading = false;
      if (switched) unawaited(_load());
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_page.hasMore || _page.messages.isEmpty) return;
    _loadingOlder = true;
    setState(() {});
    try {
      final oldest = _page.messages.first;
      final thread = _roomId;
      final res = await _service.fetchRoomChat(chat.spaceId, thread,
          before: oldest.createdAt);
      if (!mounted || thread != _roomId) return;
      setState(() {
        _page = _page.copyWith(
          messages: mergeOlderRoomMessages(_page.messages, res.messages),
          hasMore: res.hasMore,
        );
      });
    } catch (_) {
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }

  void _markSeen(List<RoomMessage> msgs) {
    if (msgs.isEmpty) return;
    final newest =
        msgs.map((m) => m.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
    if (_seen != null && !newest.isAfter(_seen!)) return;
    _seen = newest;
    unawaited(_service.markSeen(chat.spaceId, newest).catchError((_) {}));
  }

  Future<void> _loadAgents() async {
    try {
      final bots = await _service.fetchSpaceBots(chat.spaceId);
      if (mounted) {
        setState(() {
          _agents = bots.where((b) => b.isAgent).toList();
          _apps = bots.where((b) => b.isTool && !b.isSandbox).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _send(
      String body, List<String> mentions, List<String> attachments,
      {String replyTo = ''}) async {
    var to = mentions;
    final peer = chat.peer;
    if (to.isEmpty &&
        chat.direct &&
        !chat.saved &&
        peer != null &&
        peer.isAgent) {
      final agent = _agents.where((b) =>
          b.id == peer.botId || b.accountId == peer.id || b.id == peer.id);
      to = [agent.isNotEmpty ? agent.first.id : peer.botId];
      to.removeWhere((id) => id.isEmpty);
    }
    try {
      await _service.sendRoomMessage(chat.spaceId, _roomId, body,
          mentions: to, attachments: attachments, replyTo: replyTo);
      await _load();
    } catch (e) {
      _say('Send failed: $e');
      rethrow;
    }
  }

  void _say(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
      await _load();
    } catch (e) {
      _say('Could not change it: $e');
      rethrow;
    }
  }

  void _typing() => unawaited(
      _service.setTyping(chat.spaceId, _roomId, true).catchError((_) {}));

  void _switchThread(RoomThread thread) {
    final next = thread.isMain || thread.id == chat.roomId ? null : thread;
    if (next?.id == _thread?.id) return;
    setState(() {
      _thread = next;
      _page = const RoomChatPage();
      _initialLoading = true;
    });
    unawaited(_load());
  }

  Future<void> _togglePin() async {
    final pin = !chat.pinned;
    try {
      await _service.pinChat(chat.spaceId, chat.roomId, pin);
      if (!mounted) return;
      setState(() => _chat = pin
          ? _chat.copyWith(pinnedAt: DateTime.now())
          : _chat.copyWith(clearPin: true));
      _say(pin ? 'Pinned to the top of your chats' : 'Unpinned');
    } catch (e) {
      _say('Could not pin: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_sweep_outlined),
        title: const Text('Delete this chat?'),
        content: Text(chat.saved
            ? 'Your Aseman notes are removed for you.'
            : 'It is deleted for you only; ${chat.title} keeps their copy. '
                'It comes back if a new message arrives.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.clearChat(chat.spaceId);
      if (mounted && !widget.embedded) {
        await Navigator.of(context).maybePop();
      }
    } catch (e) {
      _say('Could not delete the chat: $e');
    }
  }

  Future<void> _toggleBlock() async {
    final block = !chat.blocked;
    if (block) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.block_rounded),
          title: Text('Block ${chat.title}?'),
          content: const Text(
              'Neither of you can write in this chat until you unblock it.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Block')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await _service.blockDirect(chat.spaceId, block);
      if (!mounted) return;
      setState(() => _chat = _chat.copyWith(blocked: block));
      await _load();
    } catch (e) {
      _say('Could not ${block ? 'block' : 'unblock'}: $e');
    }
  }

  Widget _menu() => AppPopupMenuButton<String>(
        tooltip: 'Chat options',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: (value) {
          switch (value) {
            case 'pin':
              unawaited(_togglePin());
            case 'clear':
              unawaited(_clear());
            case 'block':
              unawaited(_toggleBlock());
            case 'report':
              unawaited(reportToAdmins(context, _service,
                  spaceId: chat.spaceId, roomId: chat.roomId));
            case 'avatar':
              unawaited(_editAvatar());
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
              value: 'pin',
              child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(chat.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined),
                  title: Text(chat.pinned ? 'Unpin chat' : 'Pin chat'))),
          if (_isAiChat)
            const PopupMenuItem(
                value: 'avatar',
                child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.face_retouching_natural_outlined),
                    title: Text('Customize avatar'))),
          if (chat.direct)
            const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_sweep_outlined),
                    title: Text('Delete chat for me'))),
          if (chat.direct && !chat.saved)
            PopupMenuItem(
                value: 'block',
                child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.block_rounded),
                    title: Text(chat.blocked ? 'Unblock' : 'Block'))),
          if (!chat.saved)
            const PopupMenuItem(
                value: 'report',
                child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.flag_outlined),
                    title: Text('Report chat'))),
        ],
      );

  Future<void> _editAvatar() async {
    final next = await showBrainAvatarSettings(
      context,
      prefs: _avatarPrefs.copyWith(agentId: _avatarAgentId, userId: _me),
      appAccent: AppSettingsScope.maybeOf(context)?.accent ??
          Theme.of(context).colorScheme.primary,
    );
    if (next != null && mounted) setState(() => _avatarPrefs = next);
  }

  bool get _canCall =>
      chat.direct &&
      !chat.saved &&
      !chat.blocked &&
      !(chat.peer?.isAgent ?? false) &&
      (chat.peer?.id.isNotEmpty ?? false);

  List<Widget> _callActions() {
    if (!_canCall) return const [];
    final peer = chat.peer!;
    return [
      IconButton(
        tooltip: 'Voice call',
        icon: const Icon(Icons.call_outlined),
        onPressed: () async {
          await _callPage.ensure();
          if (!mounted) return;
          await call_page.startDirectCall(
            context,
            widget.dependencies,
            peerId: peer.id,
            peerLabel: chat.title,
          );
        },
      ),
      IconButton(
        tooltip: 'Video call',
        icon: const Icon(Icons.videocam_outlined),
        onPressed: () async {
          await _callPage.ensure();
          if (!mounted) return;
          await call_page.startDirectCall(
            context,
            widget.dependencies,
            peerId: peer.id,
            peerLabel: chat.title,
            video: true,
          );
        },
      ),
    ];
  }

  void _selectSurface(int value) {
    if (_surface == value) return;
    setState(() => _surface = value);
    _pages.animateToPage(
      value,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _openFacility() {
    unawaited(showDmFacilitySheet(
      context,
      dependencies: widget.dependencies,
      spaceId: chat.spaceId,
      roomId: chat.roomId,
      title: chat.title,
      agents: _agents,
      apps: _apps,
      peer: chat.peer,
      onChanged: _loadAgents,
    ));
  }

  Future<void> _openVoiceSheet() async {
    final voice = _voice;
    if (voice == null) return;
    await showFloatingPanel(
      context,
      _AgentVoiceSheet(
        title: chat.title,
        voice: voice,
        avatarPrefs: _avatarPrefs,
        picture: chat.peer?.avatar ?? '',
        platform: chat.peer?.humanoid,
        userId: _me,
        onCustomize: _editAvatar,
      ),
      maxWidth: 420,
      maxHeight: 640,
      barrierLabel: 'Close voice call',
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (!_isAiChat || _surface != 1) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final next = (n.metrics.pixels / 120).clamp(0.0, 1.0);
    if ((next - _avatarCollapse).abs() > 0.02) {
      setState(() => _avatarCollapse = next);
    }
    return false;
  }

  static const _tabsBarHeight = 62.0;

  /// Matches [RoomChat] flat `bottomPad` (composer band) + a FAB gap.
  static const _voiceFabBottom = 94.0 + 12.0;

  double get _avatarExpanded => 132.0;

  double get _avatarCollapsed => 56.0;

  double get _avatarHeaderHeight {
    if (!_isAiChat) return 0;
    return _avatarExpanded +
        (_avatarCollapsed - _avatarExpanded) * _avatarCollapse;
  }

  /// Avatar (when AI) + Desk/Chat tabs; rides up as the avatar collapses.
  double get _chromeHeight {
    if (!_showDualTabs) return 0;
    return (_isAiChat ? _avatarHeaderHeight : 0) + _tabsBarHeight;
  }

  @override
  Widget build(BuildContext context) {
    final peer = chat.peer;
    final canPop = Navigator.of(context).canPop();
    final modal = widget.asModal;
    final embedded = widget.embedded;
    final receipts = chat.direct && !chat.saved && !(peer?.isAgent ?? false);
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomInset = widget.bottomInset;
    final chrome = _chromeHeight;
    final useOuterAvatar = _isAiChat && _showDualTabs;

    Widget chatBody = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: RoomChat(
        room: chat.title,
        messages: _page.messages,
        working: chat.saved && _page.working.isEmpty ? '' : _page.working,
        workingDetail: _page.workingDetail,
        me: _me,
        dependencies: widget.dependencies,
        spaceId: chat.spaceId,
        roomId: _roomId,
        threadRoomId: chat.roomId,
        threadTitle: _thread?.title ?? '',
        onThread: _switchThread,
        canModerate: chat.canModerate,
        loading: _initialLoading,
        mentionable: _agents,
        direct: chat.direct,
        saved: chat.saved,
        onSend: _send,
        onEdit: (m, body) =>
            _change(() => _service.editRoomMessage(m.id, body)),
        onDelete: (m) =>
            _change(() => _service.deleteRoomMessage(chat.spaceId, m.id)),
        onReport: (m) => reportToAdmins(context, _service,
            spaceId: chat.spaceId, roomId: _roomId, messageId: m.id),
        onTyping: chat.saved ? null : _typing,
        typing: _page.typing,
        receipts: receipts,
        peerSeenAt: _page.peerSeenAt,
        composerNotice: chat.canSend
            ? null
            : chat.blocked
                ? 'You blocked this chat. Unblock it from the menu to write.'
                : 'You can\'t reply to this chat.',
        headerActions: useOuterAvatar
            ? const []
            : [
                if (_showDualTabs)
                  IconButton(
                    tooltip: 'Room',
                    icon: const Icon(Icons.dashboard_customize_outlined),
                    onPressed: _openFacility,
                  ),
                ..._callActions(),
                const SizedBox(width: 2),
                _menu(),
              ],
        bare: true,
        flat: embedded || _showDualTabs,
        showListHeader: !useOuterAvatar,
        topContentInset: _showDualTabs ? topPad + chrome : 0,
        bottomContentInset: embedded ? bottomInset : 0,
        hint: chat.isAseman ? 'Message Aseman…' : 'Message ${chat.title}…',
        subtitle: chat.isAseman
            ? 'Your personal Aseman'
            : chat.direct
                ? (peer == null
                    ? 'Direct chat'
                    : [
                        if (peer.handle.isNotEmpty) '@${peer.handle}',
                        peer.isAgent ? 'Agent' : 'Direct chat',
                      ].join(' · '))
                : chat.spaceName,
        memberNames: {
          if (peer != null && peer.id.isNotEmpty) peer.id: peer.displayName,
        },
        leading: embedded || useOuterAvatar
            ? null
            : (modal || canPop
                ? IconButton(
                    tooltip: modal ? 'Close' : 'Back to chats',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(modal
                        ? Icons.close_rounded
                        : Icons.arrow_back_rounded))
                : null),
        avatar: useOuterAvatar
            ? null
            : ChatAvatar(chat: chat, radius: 21, userId: _me),
        hasMore: _page.hasMore,
        loadingOlder: _loadingOlder,
        onLoadOlder: _loadOlder,
      ),
    );

    // Outside the workspace shell (home chats), space gadgets still float
    // over this page; Aseman's own stay universal on the app overlay.
    if (!chat.isAseman && chat.spaceId.isNotEmpty) {
      chatBody = Stack(
        fit: StackFit.expand,
        children: [
          chatBody,
          WorkspaceGadgets(
            dependencies: widget.dependencies,
            spaceId: chat.spaceId,
            roomId: _roomId,
            compact: true,
          ),
        ],
      );
    }

    Widget body;
    if (!_showDualTabs) {
      body = Column(
        children: [
          if (chat.isAseman)
            BrainProposalsBar(dependencies: widget.dependencies),
          Expanded(child: chatBody),
        ],
      );
    } else {
      body = Stack(
        children: [
          Positioned.fill(
            child: PageView(
              controller: _pages,
              onPageChanged: (v) => setState(() => _surface = v),
              children: [
                _DeferredDmDeskPanel(
                  dependencies: widget.dependencies,
                  controller: _desk,
                  spaceId: chat.spaceId,
                  roomId: chat.roomId,
                  title: chat.title,
                  topInset: topPad + chrome,
                  bottomInset: embedded ? bottomInset : 0,
                ),
                Column(
                  children: [
                    if (chat.isAseman)
                      BrainProposalsBar(dependencies: widget.dependencies),
                    Expanded(child: chatBody),
                  ],
                ),
              ],
            ),
          ),
          // Avatar (AI) then Desk/Chat tabs — tabs sit under the avatar and
          // ride up as it collapses.
          Positioned(
            top: topPad,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isAiChat)
                  _CollapsingAgentHeader(
                    height: _avatarHeaderHeight,
                    collapse: _avatarCollapse,
                    title: chat.title,
                    prefs: _avatarPrefs,
                    picture: chat.peer?.avatar ?? '',
                    platform: chat.peer?.humanoid,
                    userId: _me,
                    listening:
                        _voice?.state.status == BrainVoiceStatus.listening,
                    leading: embedded || !(modal || canPop)
                        ? null
                        : IconButton(
                            tooltip: modal ? 'Close' : 'Back',
                            onPressed: () =>
                                Navigator.of(context).maybePop(),
                            icon: Icon(modal
                                ? Icons.close_rounded
                                : Icons.arrow_back_rounded),
                          ),
                    onCustomize: _editAvatar,
                    onRoom: _openFacility,
                    menu: _menu(),
                  ),
                SizedBox(
                  height: _tabsBarHeight,
                  child: Center(
                    child: SegmentedTabBar(
                      selectedIndex: _surface,
                      onTap: _selectSurface,
                      labels: const ['Desk', 'Chat'],
                      icons: const [
                        Icons.dashboard_customize_outlined,
                        Icons.forum_outlined,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_isAiChat)
            Positioned(
              right: 18,
              // RoomChat's flat composer sits in a ~94px bottom band; clear
              // that band (+ gap) so the FAB floats above the message bar.
              bottom: _voiceFabBottom + (embedded ? bottomInset : 0),
              child: _VoiceFab(
                active: (_voice?.state.status ?? BrainVoiceStatus.idle) !=
                    BrainVoiceStatus.idle,
                onPressed: _openVoiceSheet,
              ),
            ),
        ],
      );
    }

    // The home Aseman tab hosts this inside glass — stay clear so the frost
    // shows. Full-page pushes and floating panels need an opaque theme fill
    // or dark mode falls through to a white route backdrop.
    final background = embedded
        ? Colors.transparent
        : Theme.of(context).scaffoldBackgroundColor;
    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        top: false,
        bottom: !embedded,
        child: body,
      ),
    );
  }
}

class _CollapsingAgentHeader extends StatelessWidget {
  const _CollapsingAgentHeader({
    required this.height,
    required this.collapse,
    required this.title,
    required this.prefs,
    required this.listening,
    this.picture = '',
    this.platform,
    this.userId = '',
    this.leading,
    this.onCustomize,
    this.onRoom,
    this.menu,
  });

  final double height;
  final double collapse;
  final String title;
  final BrainAvatarPrefs prefs;
  final bool listening;
  final String picture;
  final AgentHumanoid? platform;
  final String userId;
  final Widget? leading;
  final VoidCallback? onCustomize;
  final VoidCallback? onRoom;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Keep a usable avatar size when collapsed so actions stay aligned.
    final size = 92.0 + (36.0 - 92.0) * collapse;
    final subtitleOpacity = (1 - collapse * 1.35).clamp(0.0, 1.0);
    final personal = prefs.agentId.isEmpty;
    final titleSize = 17.0 - 2.5 * collapse;
    return SizedBox(
      height: height,
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 4 + 2 * (1 - collapse), 8, 4),
        child: GlassSurface(
          alpha: AppSurfaces.cardAlphaOf(context) * (0.5 + 0.45 * collapse),
          blur: AppSurfaces.blurSigmaOf(context),
          borderRadius: AppShape.borderRadius(context, 20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                if (leading != null) leading!,
                AgentHumanoidAvatar(
                  agentId: prefs.agentId,
                  picture: picture,
                  userId: userId,
                  platform: platform,
                  prefs: prefs,
                  radius: size / 2,
                  listening: listening,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.2,
                        ),
                      ),
                      if (subtitleOpacity > 0.05)
                        Opacity(
                          opacity: subtitleOpacity,
                          child: Text(
                            personal ? 'Your personal Aseman' : 'AI agent',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.15,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (onRoom != null)
                  IconButton(
                    tooltip: 'Room',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRoom,
                    icon: const Icon(Icons.dashboard_customize_outlined,
                        size: 20),
                  ),
                if (onCustomize != null)
                  IconButton(
                    tooltip: 'Customize avatar',
                    visualDensity: VisualDensity.compact,
                    onPressed: onCustomize,
                    icon: const Icon(Icons.face_retouching_natural_outlined,
                        size: 20),
                  ),
                if (menu != null) menu!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VoiceFab extends StatelessWidget {
  const _VoiceFab({required this.active, required this.onPressed});

  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SkyFab(
        heroTag: 'agent-voice-fab',
        tooltip: active ? 'End voice call' : 'Voice call',
        onPressed: onPressed,
        danger: active,
        icon: active ? Icons.call_end_rounded : Icons.graphic_eq_rounded,
      );
}

class _AgentVoiceSheet extends StatelessWidget {
  const _AgentVoiceSheet({
    required this.title,
    required this.voice,
    required this.avatarPrefs,
    this.picture = '',
    this.platform,
    this.userId = '',
    this.onCustomize,
  });

  final String title;
  final BrainVoiceClient voice;
  final BrainAvatarPrefs avatarPrefs;
  final String picture;
  final AgentHumanoid? platform;
  final String userId;
  final VoidCallback? onCustomize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: voice,
      builder: (context, _) {
        final st = voice.state;
        final inCall = st.status != BrainVoiceStatus.idle;
        final label = switch (st.status) {
          BrainVoiceStatus.listening => 'Listening',
          BrainVoiceStatus.thinking => 'Thinking',
          BrainVoiceStatus.speaking => 'Speaking',
          BrainVoiceStatus.idle => 'Idle',
        };
        return Material(
          type: MaterialType.transparency,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Spacer(),
                      if (onCustomize != null)
                        IconButton(
                          tooltip: 'Customize avatar',
                          onPressed: onCustomize,
                          icon: const Icon(Icons.settings_outlined, size: 20),
                        ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ],
                  ),
                  AgentHumanoidAvatar(
                    agentId: avatarPrefs.agentId,
                    picture: picture,
                    userId: userId,
                    platform: platform,
                    prefs: avatarPrefs,
                    radius: 54,
                    listening: st.status == BrainVoiceStatus.listening,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (st.error.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(st.error,
                        style: TextStyle(color: scheme.error, fontSize: 13)),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (st.heard.isNotEmpty)
                            Text('You: ${st.heard}',
                                style: const TextStyle(fontSize: 14)),
                          if (st.reply.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text('$title: ${st.reply}',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (inCall)
                        IconButton.filledTonal(
                          tooltip: 'Interrupt',
                          onPressed: voice.interrupt,
                          icon: const Icon(Icons.stop_rounded),
                        ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () async {
                          if (inCall) {
                            await voice.stop();
                          } else {
                            await voice.startCall();
                          }
                        },
                        icon: Icon(inCall
                            ? Icons.call_end_rounded
                            : Icons.graphic_eq_rounded),
                        label: Text(inCall ? 'End' : 'Talk'),
                        style: inCall
                            ? FilledButton.styleFrom(
                                backgroundColor: scheme.error,
                                foregroundColor: scheme.onError,
                              )
                            : null,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A chat's picture: the person or agent of a direct chat, or the room's
/// initial for a project room.
///
/// Agent directs use [BotAvatar] (soft 3D humanoid + picture badge).
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({
    super.key,
    required this.chat,
    this.radius = 24,
    this.userId = '',
  });

  final ChatSummary chat;
  final double radius;

  /// Account viewing the list — keys personal humanoid customization.
  final String userId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = chat.peer;
    final size = radius * 2;
    final corners = context.avatarBorderRadius(size);
    if (chat.isAseman) {
      return HaloRing(
        identity: HaloRingCache.agent('aseman'),
        accent: scheme.primary,
        borderRadius: corners,
        child: AvatarFace(
          size: size,
          borderRadius: corners,
          backgroundColor: scheme.primary,
          child: Icon(Icons.auto_awesome_rounded,
              size: radius, color: scheme.onPrimary),
        ),
      );
    }
    if (chat.direct) {
      if (peer?.isAgent ?? false) {
        final agentId =
            peer!.botId.isNotEmpty ? peer.botId : peer.id;
        // BotAvatar already draws the bound sweep ring.
        return BotAvatar(
          bot: Bot(
            id: agentId,
            ownerId: '',
            accountId: peer.id,
            name: peer.displayName,
            kind: 'agent',
            vmType: '',
            status: '',
            avatar: peer.avatar,
            humanoid: peer.humanoid,
          ),
          radius: radius,
          userId: BrainAvatarPrefs.resolveUserId(userId),
        );
      }
      final name = peer?.displayName.replaceFirst('@', '') ?? '';
      final picture = Avatars.of(peer?.avatar);
      return HaloRing(
        identity: HaloRingCache.person(peer?.id ?? ''),
        accent: scheme.secondary,
        borderRadius: corners,
        child: AvatarFace(
          size: size,
          borderRadius: corners,
          foregroundImage: picture,
          onImageError: picture == null ? null : (_, __) {},
          backgroundColor: ThemeRoles.wellFill(context),
          child: Text(
            name.isEmpty ? '?' : name.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: radius * .8,
              fontWeight: FontWeight.w800,
              color: ThemeRoles.wellInk(context),
            ),
          ),
        ),
      );
    }
    final label = chat.roomName.isEmpty ? '#' : chat.roomName;
    final room = AvatarFace(
      size: size,
      borderRadius: corners,
      backgroundColor: ThemeRoles.wellFill(context),
      child: Text(label.characters.first.toUpperCase(),
          style: TextStyle(
              fontSize: radius * .8,
              fontWeight: FontWeight.w800,
              color: ThemeRoles.wellInk(context))),
    );
    return HaloRing(
      accent: scheme.primary,
      borderRadius: corners,
      child: AvatarPicture(
        avatar: chat.spaceAvatar,
        size: size,
        borderRadius: corners,
        fallback: room,
      ),
    );
  }
}

/// Loads the DM desk (tools / Elpian / computer) only when the Desk tab is
/// painted — keeps that stack out of the Pulse/chats entry chunk.
class _DeferredDmDeskPanel extends StatefulWidget {
  const _DeferredDmDeskPanel({
    required this.dependencies,
    required this.controller,
    required this.spaceId,
    required this.roomId,
    required this.title,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final AppDependencies dependencies;
  final DeskController controller;
  final String spaceId;
  final String roomId;
  final String title;
  final double topInset;
  final double bottomInset;

  @override
  State<_DeferredDmDeskPanel> createState() => _DeferredDmDeskPanelState();
}

class _DeferredDmDeskPanelState extends State<_DeferredDmDeskPanel> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ready = _dmDesk.isLoaded;
    if (!_ready) {
      _dmDesk.ensure()?.then((_) {
        if (mounted) setState(() => _ready = true);
      }).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return dm_desk.DmDeskPanel(
      dependencies: widget.dependencies,
      controller: widget.controller,
      spaceId: widget.spaceId,
      roomId: widget.roomId,
      title: widget.title,
      topInset: widget.topInset,
      bottomInset: widget.bottomInset,
    );
  }
}
