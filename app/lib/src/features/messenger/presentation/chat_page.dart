import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/theme/app_shape.dart';
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
import '../../calls/call_page.dart' deferred as call_page;
import '../../desk/data/desk_api.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../gadgets/presentation/gadgets_overlay.dart';
import '../../home/presentation/workspace_screen.dart';
import '../../rooms/presentation/widgets/room_chat.dart';
import '../../tools/connect/add_app.dart';
import '../../tools/connect/mcp_connect_dialog.dart';
import '../../voice/live/live_voice_backend.dart';
import '../../voice/live/live_voice_controller.dart';
import '../../voice/live/live_voice_model.dart';
import 'dm_desk_panel.dart' deferred as dm_desk;
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
/// full-height sheet stuck to the trailing edge; project rooms and compact
/// widths keep a full-page push
/// on the root navigator (so an embedded chats tab never hosts the chat).
Future<void> showChat(
  BuildContext context,
  AppDependencies dependencies,
  ChatSummary chat,
) {
  final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
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
/// their own desk. Every direct gets a collapsible avatar header above the
/// tabs — agents use the configurable humanoid; person↔person uses that
/// peer's picture. AI / Aseman directs also get a voice-call FAB.
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

  /// A refresh was asked for while one was running: the running one may have
  /// read the chat before what just changed (a message sent, an answer
  /// started), so it runs again as soon as that one ends.
  bool _reloadAfter = false;

  /// Polling ticks every second; an idle chat loads on every third tick.
  int _tick = 0;

  /// After sending, the chat is polled every second until then, so an answer
  /// that starts (the "thinking" bubble) and ends quickly is still seen.
  DateTime _fastUntil = DateTime.fromMillisecondsSinceEpoch(0);

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
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Library rail selection. Agents, matching the first direct-chat tab.
  int _libraryTab = 1;
  List<Bot> _allBots = const [];
  Map<String, ({String auth, bool connected, String name})> _connections =
      const {};

  /// Desktop: the desk is a pane beside the chat, so the Desk/Chat tabs hide.
  bool _deskBeside = false;

  /// The desktop library card is open over the chat.
  bool _libraryOpen = false;

  /// Work and Routines for the collapsing header, filled by [RoomChat].
  final _roomChrome = RoomChatChrome();

  /// Collapse progress for the AI avatar header (0 expanded → 1 collapsed).
  double _avatarCollapse = 0;

  BrainAvatarPrefs _avatarPrefs = const BrainAvatarPrefs();
  LiveVoiceController? _voice;

  ChatSummary get chat => _chat;

  /// Where the open conversation's messages live: the thread, else the room.
  String get _roomId => _thread?.id ?? chat.roomId;
  AsemanService get _service => widget.dependencies.service;
  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  bool get _isAiChat =>
      chat.isAseman || (chat.direct && (chat.peer?.isAgent ?? false));

  /// Phones keep Desk and Chat as tabs. A wide window puts the desk beside
  /// the chat, the way a workspace room does.
  bool get _showDualTabs => chat.direct && !_deskBeside;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) {
      _tick++;
      final fast = _page.working.isNotEmpty || DateTime.now().isBefore(_fastUntil);
      if (fast || _tick % 3 == 0) _load();
    });
    unawaited(_boot());
  }

  /// Bind Direct space (desk / mentionable agents), then load messages + agents.
  Future<void> _boot() async {
    if (chat.direct) {
      try {
        final enriched = await _service.ensureDirectSpace(chat);
        if (!mounted) return;
        if (enriched.spaceId != chat.spaceId ||
            enriched.roomId != chat.roomId ||
            enriched.peer?.botId != chat.peer?.botId ||
            enriched.peer?.kind != chat.peer?.kind) {
          setState(() => _chat = enriched);
        }
      } catch (_) {}
    }
    if (!mounted) return;
    // Wide windows show the desk beside the chat; phones show it as a tab.
    // Both read the same desk, so bind it whenever this direct chat has one.
    _bindDesk();
    if (_isAiChat) {
      _voice = LiveVoiceController(
        backend: ServiceLiveVoiceBackend(_service, peer: _peerId),
      )..addListener(_onVoice);
      unawaited(_bootAvatar());
    }
    await Future.wait([_load(), _loadAgents()]);
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
    _desk.dispose();
    _voice?.removeListener(_onVoice);
    _voice?.dispose();
    super.dispose();
  }

  String get _peerId => chat.peer?.id ?? chat.roomId;

  Future<void> _load() async {
    if (_loading) {
      _reloadAfter = true;
      return;
    }
    _loading = true;
    var switched = false;
    try {
      final thread = _roomId;
      final res = chat.direct
          ? await _service.fetchDirectChat(_peerId)
          : await _service.fetchRoomChat(chat.spaceId, thread);
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
      final again = _reloadAfter;
      _reloadAfter = false;
      if ((switched || again) && mounted) unawaited(_load());
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_page.hasMore || _page.messages.isEmpty) return;
    _loadingOlder = true;
    setState(() {});
    try {
      final oldest = _page.messages.first;
      final thread = _roomId;
      final res = chat.direct
          ? await _service.fetchDirectChat(_peerId, before: oldest.createdAt)
          : await _service.fetchRoomChat(chat.spaceId, thread,
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
    if (chat.direct) {
      unawaited(_service.markDirectRead(_peerId).catchError((_) {}));
    } else {
      unawaited(_service.markSeen(chat.spaceId, newest).catchError((_) {}));
    }
  }

  Future<void> _loadAgents() async {
    try {
      if (chat.direct) {
        // @decillion from users.dm_assistant; person↔agent Directs also list
        // the participant and any other agents on that conversation's space.
        final agents = <Bot>[];
        final apps = <Bot>[];
        var all = const <Bot>[];
        var connections =
            const <String, ({String auth, bool connected, String name})>{};
        if (!chat.saved) {
          final assistant = await _service.fetchDmAssistant();
          if (assistant != null) agents.add(assistant);
        }
        if (chat.spaceId.isNotEmpty) {
          final bots = await _service.fetchSpaceBots(chat.spaceId);
          try {
            all = await _service.fetchBots();
          } catch (_) {}
          try {
            connections = await _service.toolConnections(chat.spaceId);
          } catch (_) {}
          for (final b in bots) {
            if (b.isAgent) {
              if (!agents.any((a) => a.id == b.id || a.accountId == b.accountId)) {
                agents.add(b);
              }
            } else if (b.isTool && !b.isSandbox) {
              apps.add(b);
            }
          }
        }
        // Ensure the Direct's founding peer agent is known (bot id for asks).
        final peer = chat.peer;
        if (peer != null && peer.isAgent) {
          final known = agents.any((b) =>
              b.id == peer.botId ||
              b.accountId == peer.id ||
              b.id == peer.id);
          if (!known) {
            try {
              final id = peer.botId.isNotEmpty ? peer.botId : peer.id;
              final bot = await _service.fetchBot(id);
              if (bot.id.isNotEmpty &&
                  !agents.any((a) => a.id == bot.id)) {
                agents.add(bot);
              }
            } catch (_) {}
          }
        }
        if (mounted) {
          setState(() {
            _agents = agents;
            _apps = apps;
            _allBots = all;
            _connections = connections;
          });
        }
        return;
      }
      if (chat.spaceId.isEmpty) return;
      final bots = await _service.fetchSpaceBots(chat.spaceId);
      if (mounted) {
        setState(() {
          _agents = bots.where((b) => b.isAgent).toList();
          _apps = bots.where((b) => b.isTool && !b.isSandbox).toList();
        });
      }
    } catch (_) {}
  }

  /// Ids that identify the Direct chat's founding peer agent (account and bot).
  Set<String> get _participantIds {
    final peer = chat.peer;
    if (peer == null) return {};
    final ids = <String>{
      if (peer.id.isNotEmpty) peer.id,
      if (peer.botId.isNotEmpty) peer.botId,
    };
    for (final b in _agents) {
      if (b.accountId == peer.id ||
          b.id == peer.id ||
          (peer.botId.isNotEmpty &&
              (b.id == peer.botId || b.accountId == peer.botId))) {
        if (b.id.isNotEmpty) ids.add(b.id);
        if (b.accountId.isNotEmpty) ids.add(b.accountId);
      }
    }
    return ids;
  }

  /// Bot record id of the Direct's participant agent (any agent, not only
  /// Decillion) — what `spaces.ask` / turn seeds address.
  String get _participantBotId {
    final peer = chat.peer;
    if (peer == null || !peer.isAgent) return '';
    if (peer.botId.isNotEmpty) return peer.botId;
    for (final b in _agents) {
      if (b.isBuiltin) continue;
      if (b.accountId == peer.id || b.id == peer.id) return b.id;
    }
    return '';
  }

  bool _isParticipantAgent(Bot b) {
    final ids = _participantIds;
    return ids.contains(b.id) || ids.contains(b.accountId);
  }

  /// Whether [body] / [mentions] address the built-in @decillion assistant.
  bool _mentionsAssistant(String body, List<String> mentions) {
    if (RegExp(r'(^|[^a-z0-9-])@decillion\b', caseSensitive: false)
        .hasMatch(body)) {
      return true;
    }
    for (final a in _agents) {
      if (!a.isBuiltin) continue;
      if (_isParticipantAgent(a)) continue;
      if (mentions.contains(a.id) ||
          (a.accountId.isNotEmpty && mentions.contains(a.accountId))) {
        return true;
      }
      final handle = a.name.trim().toLowerCase().replaceFirst('@', '');
      if (handle.isNotEmpty &&
          RegExp('(^|[^a-z0-9-])@${RegExp.escape(handle)}\\b',
                  caseSensitive: false)
              .hasMatch(body)) {
        return true;
      }
    }
    return false;
  }

  /// Bot ids of agents the sender @mentioned that are not the DM participant.
  /// Includes market agents installed on the Direct; @decillion is separate.
  List<String> _otherMentionedAgentIds(List<String> mentions, String body) {
    final peerIds = _participantIds;
    final out = <String>{};
    for (final id in mentions) {
      if (id.isEmpty || peerIds.contains(id)) continue;
      final hit = _agents.where(
          (b) => b.id == id || b.accountId == id || b.name == id);
      if (hit.isEmpty) continue;
      final b = hit.first;
      if (b.isBuiltin || _isParticipantAgent(b)) continue;
      out.add(b.id);
    }
    for (final b in _agents) {
      if (b.isBuiltin || _isParticipantAgent(b)) continue;
      final handle = b.name.trim().toLowerCase().replaceFirst('@', '');
      if (handle.isEmpty) continue;
      if (RegExp('(^|[^a-z0-9-])@${RegExp.escape(handle)}\\b',
              caseSensitive: false)
          .hasMatch(body)) {
        out.add(b.id);
      }
    }
    return out.toList();
  }

  String get _assistantBotId {
    for (final b in _agents) {
      if (b.isBuiltin && b.id.isNotEmpty) return b.id;
    }
    return '';
  }

  Future<void> _send(
      String body, List<String> mentions, List<String> attachments,
      {String replyTo = ''}) async {
    try {
      if (chat.direct) {
        final others = _otherMentionedAgentIds(mentions, body);
        final assistant = _mentionsAssistant(body, mentions);
        final peer = chat.peer;
        final agentPeer = peer != null && peer.isAgent && !chat.saved;

        if (agentPeer && chat.spaceId.isNotEmpty) {
          // Person↔agent Direct on its space room. Backend directMentions:
          //   • no other agents named → founding peer agent runs
          //   • other agents @mentioned → those run (peer need not be named)
          // Replies are stored as users.directs (visible in dm_list).
          final List<String> address;
          if (others.isEmpty && !assistant) {
            address = const []; // bare → peer
          } else if (others.isNotEmpty) {
            address = others;
          } else {
            // Only @decillion: do not auto-run the peer.
            final aid = _assistantBotId;
            address = aid.isEmpty ? const [] : [aid];
          }
          final sent = await _service.sendRoomMessage(
            chat.spaceId,
            chat.roomId,
            body,
            mentions: address,
            attachments: attachments,
            replyTo: replyTo,
          );
          // Person↔person assistant path; also fine after a Direct store.
          if (assistant &&
              others.isEmpty &&
              sent.id.isNotEmpty &&
              address.isEmpty) {
            unawaited(_service.dmAgentAsk(sent.id).catchError((_) {}));
          }
        } else {
          // Person↔person, or agent DM before Direct space is bound.
          // users.dm_send asks the peer agent when `to` is an agent account.
          final sent = await _service.sendDirectMessage(_peerId, body,
              attachments: attachments, replyTo: replyTo);
          if (!chat.saved && assistant && sent.id.isNotEmpty) {
            unawaited(_service.dmAgentAsk(sent.id).catchError((_) {}));
          }
        }
      } else {
        // Project rooms: mentioned agents only; empty mentions → none.
        await _service.sendRoomMessage(chat.spaceId, _roomId, body,
            mentions: mentions, attachments: attachments, replyTo: replyTo);
      }
      _fastUntil = DateTime.now().add(const Duration(seconds: 30));
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
      await _service.pinChat(_peerId, pin);
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
      await _service.clearChat(_peerId);
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
      await _service.blockDirect(_peerId, block);
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
                  spaceId: chat.spaceId,
                  roomId: chat.roomId,
                  peer: chat.direct ? _peerId : ''));
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

  /// Work and routines stay on the direct-chat bar. The room list header
  /// that usually holds them is hidden under the collapsing avatar.
  List<Widget> _directHeaderActions() => [
        IconButton(
          tooltip: 'Work',
          visualDensity: VisualDensity.compact,
          onPressed: () => _roomChrome.openWork?.call(),
          icon: const Icon(Icons.history_rounded),
        ),
        IconButton(
          tooltip: 'Routines',
          visualDensity: VisualDensity.compact,
          onPressed: () => _roomChrome.openRoutines?.call(),
          icon: const Icon(Icons.schedule_rounded),
        ),
        ..._callActions(),
      ];

  List<Widget> _callActions() {
    if (!_canCall) return const [];
    final peer = chat.peer!;
    return [
      IconButton(
        tooltip: 'Voice call',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.call_outlined, size: 20),
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
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.videocam_outlined, size: 20),
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

  /// Loads this direct chat's desk. Safe to call again: the same room is a no-op.
  void _bindDesk() {
    if (!chat.direct || chat.spaceId.isEmpty) return;
    _desk.attach(chat.spaceId, chat.roomId);
  }

  void _selectSurface(int value) {
    if (_surface == value) return;
    setState(() => _surface = value);
  }

  void _openLibrary() {
    if (_deskBeside) {
      setState(() => _libraryOpen = !_libraryOpen);
      return;
    }
    _scaffoldKey.currentState?.openDrawer();
  }

  bool _isPeerAgent(Bot bot) {
    final peer = chat.peer;
    if (peer == null || !peer.isAgent) return false;
    return bot.id == peer.botId ||
        bot.accountId == peer.id ||
        bot.id == peer.id ||
        (peer.botId.isNotEmpty && bot.accountId == peer.botId);
  }

  Future<void> _addLibraryBot(Bot bot) async {
    if (chat.spaceId.isEmpty) return;
    try {
      await _service.addBotToSpace(chat.spaceId, bot.id);
      if (bot.kind == 'tool' && mounted) {
        await connectMcpToolIfNeeded(
          context,
          _service,
          botId: bot.id,
          spaceId: chat.spaceId,
          name: bot.name,
        );
      }
      await _loadAgents();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add: $e')),
      );
    }
  }

  Future<void> _removeLibraryBot(Bot bot) async {
    if (_isPeerAgent(bot)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The other participant cannot be removed from this chat.',
          ),
        ),
      );
      return;
    }
    if (chat.spaceId.isEmpty) return;
    try {
      await _service.removeBotFromSpace(chat.spaceId, bot.id);
      await _loadAgents();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove: $e')),
      );
    }
  }

  Future<void> _addLibraryApp() async {
    if (chat.spaceId.isEmpty) return;
    final added = await showAddApp(
      context,
      _service,
      spaceId: chat.spaceId,
    );
    if (added) await _loadAgents();
  }

  Future<void> _connectLibraryApp(Bot bot, bool reconnect) async {
    if (chat.spaceId.isEmpty) return;
    final connected = await connectMcpTool(
      context,
      _service,
      botId: bot.id,
      spaceId: chat.spaceId,
      name: bot.name,
      reconnect: reconnect,
    );
    if (connected && mounted) await _loadAgents();
  }

  void _openLibraryApp(Bot bot) {
    if (chat.spaceId.isEmpty) return;
    if (bot.isUnifiedTool) {
      _desk.open(bot.id, title: bot.name);
      if (_libraryOpen) setState(() => _libraryOpen = false);
      if (_showDualTabs) _selectSurface(0);
      return;
    }
  }

  Widget _library({bool card = false}) => DirectChatLibrary(
    title: chat.title,
    tab: _libraryTab,
    onTab: (tab) {
      setState(() => _libraryTab = tab);
      if (_showDualTabs) _scaffoldKey.currentState?.closeDrawer();
    },
    dependencies: widget.dependencies,
    spaceId: chat.spaceId,
    roomId: chat.roomId,
    agents: _agents,
    apps: _apps,
    allBots: _allBots,
    onAddBot: _addLibraryBot,
    onRemoveBot: _removeLibraryBot,
    onAddApp: _addLibraryApp,
    onOpenApp: _openLibraryApp,
    appConnections: _connections,
    onConnectApp: _connectLibraryApp,
    card: card,
  );

  /// Talks with this chat's Aseman or agent aloud: listening starts as the
  /// sheet opens, and closing it ends the call.
  Future<void> _openVoiceSheet() async {
    final voice = _voice;
    if (voice == null) return;
    unawaited(voice.start());
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
    await voice.end();
  }

  bool _onScroll(ScrollNotification n) {
    if (!chat.direct) return false;
    // The desk tab has no collapsing bar. Beside the desk, the chat scrolls.
    if (_showDualTabs && _surface != 1) return false;
    if (n.metrics.axis != Axis.vertical) return false;
    final next = (n.metrics.pixels / 120).clamp(0.0, 1.0);
    if ((next - _avatarCollapse).abs() > 0.02) {
      setState(() => _avatarCollapse = next);
    }
    return false;
  }

  static const _tabsBarHeight = 62.0;

  /// Matches [RoomChat] flat `bottomPad` (composer band) + a FAB gap.
  static const _voiceFabBottom = 72.0 + 12.0;

  double get _avatarExpanded => 132.0;

  double get _avatarCollapsed => 56.0;

  double get _avatarHeaderHeight {
    if (!chat.direct) return 0;
    return _avatarExpanded +
        (_avatarCollapsed - _avatarExpanded) * _avatarCollapse;
  }

  /// Collapsing avatar + Desk/Chat tabs; rides up as the avatar collapses.
  double get _chromeHeight {
    if (!chat.direct) return 0;
    return _avatarHeaderHeight + (_showDualTabs ? _tabsBarHeight : 0);
  }

  String get _headerSubtitle {
    if (chat.isAseman) return 'Your personal Aseman';
    final peer = chat.peer;
    if (peer?.isAgent ?? false) return 'AI agent';
    if (peer == null) return 'Direct chat';
    final handle = peer.handle.isNotEmpty ? '@${peer.handle}' : '';
    if (handle.isEmpty) return 'Direct chat';
    return '$handle · Direct chat';
  }

  /// Avatar in the collapsing DM header: configurable humanoid for AI,
  /// the other person's picture for person↔person.
  Widget _headerAvatar(double size) {
    if (_isAiChat) {
      return AgentHumanoidAvatar(
        agentId: _avatarPrefs.agentId,
        picture: chat.peer?.avatar ?? '',
        userId: _me,
        platform: chat.peer?.humanoid,
        prefs: _avatarPrefs,
        radius: size / 2,
        listening: _voice?.state == LiveState.listening,
      );
    }
    return ChatAvatar(chat: chat, radius: size / 2, userId: _me);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The library needs its icon rail plus a readable list, and the chat
        // needs a composer. Below that, phones and narrow columns keep the
        // drawer and the Desk/Chat tabs.
        final beside = chat.direct &&
            box.maxWidth >= 900 &&
            !AppHeightClass.fromHeight(box.maxHeight).isCompact;
        _deskBeside = beside;
        if (beside &&
            chat.spaceId.isNotEmpty &&
            (_desk.spaceId != chat.spaceId || _desk.room != chat.roomId)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _bindDesk();
          });
        }
        return _buildChat(context, box);
      },
    );
  }

  Widget _buildChat(BuildContext context, BoxConstraints box) {
    final peer = chat.peer;
    final canPop = Navigator.of(context).canPop();
    final modal = widget.asModal;
    final embedded = widget.embedded;
    final receipts = chat.direct && !chat.saved && !(peer?.isAgent ?? false);
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomInset = widget.bottomInset;
    final chrome = _chromeHeight;
    // Every direct chat keeps the collapsing avatar. Phones add Desk/Chat
    // tabs; a wide window puts the desk in a pane instead.
    final useOuterAvatar = chat.direct;

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
        // Threads are a spaces.room concept — not used for Expo DMs.
        threadRoomId: chat.direct ? '' : chat.roomId,
        threadTitle: chat.direct ? '' : (_thread?.title ?? ''),
        onThread: chat.direct ? null : _switchThread,
        canModerate: chat.canModerate,
        loading: _initialLoading,
        mentionable: _agents,
        direct: chat.direct,
        saved: chat.saved,
        peerId: _peerId,
        onSend: _send,
        onEdit: (m, body) => _change(() => chat.direct
            ? _service.editDirectMessage(m.id, body)
            : _service.editRoomMessage(m.id, body)),
        onDelete: (m) => _change(() => chat.direct
            ? _service.deleteDirectMessage(m.id)
            : _service.deleteRoomMessage(chat.spaceId, m.id)),
        onReport: (m) => reportToAdmins(context, _service,
            spaceId: chat.spaceId,
            roomId: _roomId,
            peer: chat.direct ? _peerId : '',
            messageId: m.id),
        onTyping: chat.saved
            ? null
            : (chat.direct
                ? () => unawaited(
                    _service.directTyping(_peerId).catchError((_) {}))
                : _typing),
        typing: _page.typing,
        receipts: receipts,
        peerSeenAt: _page.peerSeenAt,
        composerNotice: chat.canSend
            ? null
            : chat.blocked
                ? 'You blocked this chat. Unblock it from the menu to write.'
                : 'You can\'t reply to this chat.',
        chrome: useOuterAvatar ? _roomChrome : null,
        headerActions: useOuterAvatar
            ? const []
            : [
                if (_showDualTabs)
                  IconButton(
                    tooltip: 'Library',
                    icon: const Icon(Icons.menu_rounded),
                    onPressed: _openLibrary,
                  ),
                ..._callActions(),
                const SizedBox(width: 2),
                _menu(),
              ],
        bare: true,
        flat: embedded || chat.direct,
        showListHeader: !useOuterAvatar,
        topContentInset: chat.direct ? topPad + chrome : 0,
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
    if (_deskBeside) {
      final deskWidth = AppLayout.roomDeskPaneWidth(
        innerWidth: box.maxWidth,
        libraryWidth: 0,
      );
      body = Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AppPane(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Column(
                          children: [
                            if (chat.isAseman)
                              BrainProposalsBar(
                                dependencies: widget.dependencies,
                              ),
                            Expanded(child: chatBody),
                          ],
                        ),
                      ),
                      Positioned(
                        top: topPad,
                        left: 0,
                        right: 0,
                        child: _CollapsingDmHeader(
                          height: _avatarHeaderHeight,
                          collapse: _avatarCollapse,
                          title: chat.title,
                          subtitle: _headerSubtitle,
                          avatarBuilder: _headerAvatar,
                          leading: embedded || !(modal || canPop)
                              ? null
                              : IconButton(
                                  tooltip: modal ? 'Close' : 'Back',
                                  onPressed: () =>
                                      Navigator.of(context).maybePop(),
                                  icon: Icon(
                                    modal
                                        ? Icons.close_rounded
                                        : Icons.arrow_back_rounded,
                                  ),
                                ),
                          onRoom: _openLibrary,
                          onCustomize: _isAiChat ? _editAvatar : null,
                          actions: _directHeaderActions(),
                          menu: _menu(),
                        ),
                      ),
                      if (_isAiChat)
                        Positioned(
                          right: 18,
                          bottom:
                              _voiceFabBottom + (embedded ? bottomInset : 0),
                          child: _VoiceFab(
                            active: _voice?.active ?? false,
                            onPressed: _openVoiceSheet,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const PaneDivider(),
              AppPane(
                width: deskWidth,
                child: _DeferredDmDeskPanel(
                  dependencies: widget.dependencies,
                  controller: _desk,
                  spaceId: chat.spaceId,
                  roomId: chat.roomId,
                  title: chat.title,
                  board: true,
                  topInset: 0,
                  bottomInset: embedded ? bottomInset : 0,
                ),
              ),
            ],
          ),
            SpaceLibraryFlyout(
              open: _libraryOpen,
              top: topPad + _avatarHeaderHeight,
              onDismiss: () => setState(() => _libraryOpen = false),
              builder: (_) => _library(card: true),
            ),
        ],
      );
    } else if (!_showDualTabs) {
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
            child: IndexedStack(
              index: _surface,
              sizing: StackFit.expand,
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
          // Avatar then Desk/Chat tabs — tabs sit under the avatar and ride
          // up as it collapses. Person DMs match agent chrome; only the
          // avatar widget differs (peer picture vs configurable humanoid).
          Positioned(
            top: topPad,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CollapsingDmHeader(
                  height: _avatarHeaderHeight,
                  collapse: _avatarCollapse,
                  title: chat.title,
                  subtitle: _headerSubtitle,
                  avatarBuilder: _headerAvatar,
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
                  onCustomize: _isAiChat ? _editAvatar : null,
                  actions: _directHeaderActions(),
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
          // Below the app bar, same glass control as a workspace room.
          Positioned(
            top: topPad + _avatarHeaderHeight + 12,
            left: 12,
            child: GlassSurface(
              alpha: AppSurfaces.overlayAlphaOf(context),
              blur: AppSurfaces.blurSigmaOf(context),
              borderRadius: AppShape.borderRadius(context, 24),
              child: IconButton(
                tooltip: 'Library',
                onPressed: _openLibrary,
                icon: const Icon(Icons.menu_rounded),
              ),
            ),
          ),
          if (_isAiChat)
            Positioned(
              right: 18,
              // RoomChat's flat composer sits in a ~72px bottom band; clear
              // that band (+ gap) so the FAB floats above the message bar.
              bottom: _voiceFabBottom + (embedded ? bottomInset : 0),
              child: _VoiceFab(
                active: _voice?.active ?? false,
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
      key: _scaffoldKey,
      backgroundColor: background,
      drawer: chat.direct && !_deskBeside
          ? Drawer(
              backgroundColor: Colors.transparent,
              width: math.min(340, MediaQuery.sizeOf(context).width * .88),
              child: GlassDrawerSurface(
                child: SafeArea(child: _library()),
              ),
            )
          : null,
      body: SafeArea(
        top: false,
        bottom: !embedded,
        child: body,
      ),
    );
  }
}

/// Collapsing app bar shared by agent and person direct chats. [avatarBuilder]
/// supplies the face (configurable humanoid vs the peer's picture).
class _CollapsingDmHeader extends StatelessWidget {
  const _CollapsingDmHeader({
    required this.height,
    required this.collapse,
    required this.title,
    required this.subtitle,
    required this.avatarBuilder,
    this.leading,
    this.onCustomize,
    this.onRoom,
    this.actions = const [],
    this.menu,
  });

  final double height;
  final double collapse;
  final String title;
  final String subtitle;
  final Widget Function(double size) avatarBuilder;
  final Widget? leading;
  final VoidCallback? onCustomize;
  final VoidCallback? onRoom;
  final List<Widget> actions;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.maxWidth < 420;
        final size = tight
            ? 36.0
            : 92.0 + (36.0 - 92.0) * collapse;
        final subtitleOpacity = tight
            ? 0.0
            : (1 - collapse * 1.35).clamp(0.0, 1.0);
        final titleSize = tight ? 15.0 : 17.0 - 2.5 * collapse;
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
                    if (onRoom != null)
                      IconButton(
                        tooltip: 'Library',
                        visualDensity: VisualDensity.compact,
                        onPressed: onRoom,
                        icon: const Icon(Icons.menu_rounded, size: 20),
                      ),
                    if (leading != null) leading!,
                    avatarBuilder(size),
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
                                subtitle,
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
                    if (onCustomize != null)
                      IconButton(
                        tooltip: 'Customize avatar',
                        visualDensity: VisualDensity.compact,
                        onPressed: onCustomize,
                        icon: const Icon(
                          Icons.face_retouching_natural_outlined,
                          size: 20,
                        ),
                      ),
                    for (final action in actions)
                      IconButtonTheme(
                        data: const IconButtonThemeData(
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        child: action,
                      ),
                    if (menu != null) menu!,
                  ],
                ),
              ),
            ),
          ),
        );
      },
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
  final LiveVoiceController voice;
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
        final state = voice.state;
        final proposal = voice.proposal;
        final failed = state == LiveState.error || voice.setupNeeded;
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
                    listening: state == LiveState.listening,
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
                    liveCaptions[state] ?? '',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  if (voice.notice.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      voice.notice,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: failed ? scheme.error : scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (voice.heard.isNotEmpty)
                            Text('You: ${voice.heard}',
                                style: const TextStyle(fontSize: 14)),
                          if (voice.said.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text('$title: ${voice.said}',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                          ],
                          if (proposal != null) ...[
                            const SizedBox(height: 12),
                            _VoiceProposal(
                              title: title,
                              proposal: proposal,
                              busy: voice.confirming,
                              onConfirm: (approve) =>
                                  voice.confirm(approve: approve),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed:
                            state == LiveState.starting ? null : voice.tap,
                        icon: Icon(switch (state) {
                          LiveState.listening => Icons.check_rounded,
                          LiveState.thinking ||
                          LiveState.speaking =>
                            Icons.stop_rounded,
                          _ => Icons.graphic_eq_rounded,
                        }),
                        label: Text(switch (state) {
                          LiveState.listening => 'Done',
                          LiveState.thinking ||
                          LiveState.speaking =>
                            'Interrupt',
                          _ => 'Talk',
                        }),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(Icons.call_end_rounded),
                        label: const Text('End'),
                        style: FilledButton.styleFrom(
                          backgroundColor: scheme.error,
                          foregroundColor: scheme.onError,
                        ),
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

/// What the assistant proposed to do, waiting for a tap: a spoken "yes" never
/// confirms it.
class _VoiceProposal extends StatelessWidget {
  const _VoiceProposal({
    required this.title,
    required this.proposal,
    required this.busy,
    required this.onConfirm,
  });

  final String title;
  final LiveProposal proposal;
  final bool busy;
  final void Function(bool approve) onConfirm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$title proposes',
                style: const TextStyle(fontWeight: FontWeight.w800)),
            for (final step in proposal.steps)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('· $step',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant)),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => onConfirm(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: busy ? null : () => onConfirm(true),
                  child: const Text('Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
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
    this.agent,
  });

  final ChatSummary chat;
  final double radius;

  /// Account viewing the list — keys personal humanoid customization.
  final String userId;

  /// The agent's own record when the list has it. A thread peer only carries
  /// the account id, so without this the list seeds a different face from the
  /// one in the open chat.
  final Bot? agent;

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
        final person = peer!;
        final known = agent;
        final agentId = (known != null && known.id.isNotEmpty)
            ? known.id
            : (person.botId.isNotEmpty ? person.botId : person.id);
        final picture = (known != null && known.avatar.isNotEmpty)
            ? known.avatar
            : person.avatar;
        // BotAvatar already draws the bound sweep ring.
        return BotAvatar(
          bot: Bot(
            id: agentId,
            ownerId: known?.ownerId ?? '',
            accountId: known?.accountId.isNotEmpty == true
                ? known!.accountId
                : person.id,
            name: known?.name.isNotEmpty == true
                ? known!.name
                : person.displayName,
            kind: 'agent',
            vmType: known?.vmType ?? '',
            status: known?.status ?? '',
            avatar: picture,
            humanoid: known?.humanoid ?? person.humanoid,
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
            _avatarInitial(name),
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
      child: Text(_avatarInitial(label, fallback: '#'),
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

/// First grapheme for avatar initials; never throws on empty / odd unicode.
String _avatarInitial(String name, {String fallback = '?'}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return fallback;
  final chars = trimmed.characters;
  if (chars.isEmpty) return fallback;
  return chars.first.toUpperCase();
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
    this.board = false,
  });

  final AppDependencies dependencies;
  final DeskController controller;
  final String spaceId;
  final String roomId;
  final String title;
  final double topInset;
  final double bottomInset;
  final bool board;

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
      board: widget.board,
    );
  }
}
