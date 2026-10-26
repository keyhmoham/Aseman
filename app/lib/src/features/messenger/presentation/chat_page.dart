import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/aseman_service.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../rooms/presentation/widgets/room_chat.dart';
import 'report_dialog.dart';

/// Opens [chat]: on a wide screen a direct chat (or Saved Messages) is a
/// floating modal; project rooms and compact widths keep a full-page push.
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
      maxWidth: 560,
      maxHeight: 780,
      barrierLabel: 'Close chat',
    );
  }
  return Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => ChatPage(dependencies: dependencies, chat: chat)));
}

/// One conversation of the messenger, direct or a project room. Both are rooms
/// of a space (a direct chat is a one-room space shared by two accounts), so
/// the page is the project room chat itself: files, voice, agent mentions,
/// the message designer, agent work and routines all work the same.
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.dependencies,
    required this.chat,
    this.asModal = false,
  });

  final AppDependencies dependencies;
  final ChatSummary chat;

  /// Shown as a floating desktop panel: close control instead of back-to-list.
  final bool asModal;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  RoomChatPage _page = const RoomChatPage();
  List<Bot> _agents = const [];
  Timer? _poll;
  bool _loading = false;

  /// True until the first fetch of this chat finishes (success or failure).
  bool _initialLoading = true;
  bool _loadingOlder = false;
  DateTime? _seen;
  late ChatSummary _chat = widget.chat;

  /// The open thread of the chat's room; null for its main thread.
  RoomThread? _thread;

  ChatSummary get chat => _chat;

  /// Where the open conversation's messages live: the thread, else the room.
  String get _roomId => _thread?.id ?? chat.roomId;
  AsemanService get _service => widget.dependencies.service;
  String get _me =>
      widget.dependencies.sessionController.session?.accountId ?? '';

  @override
  void initState() {
    super.initState();
    _load();
    _loadAgents();
    // Replies (agents answering, the other person writing) arrive on their own
    // time, so the open chat is polled like a project room.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
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
      // The thread was switched while this was loading: load the new one.
      if (thread != _roomId) {
        switched = true;
        return;
      }
      final old = _page;
      final msgs = mergeNewestRoomMessages(old.messages, res.messages);
      final holdsOlder = msgs.length > res.messages.length;
      final hasMore =
          holdsOlder ? old.hasMore : res.hasMore;
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
      // The next poll can recover without clearing the conversation.
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
      // Leave hasMore as-is so the user can try again.
    } finally {
      _loadingOlder = false;
      if (mounted) setState(() {});
    }
  }

  // Reading the chat moves the read cursor to its newest message.
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
        setState(() => _agents = bots.where((b) => b.isAgent).toList());
      }
    } catch (_) {}
  }

  Future<void> _send(
      String body, List<String> mentions, List<String> attachments,
      {String replyTo = ''}) async {
    // Writing to an agent in its direct chat is addressed to it, so it runs a
    // turn exactly as when it is mentioned in a project room.
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

  /// Switches to another thread of the room: its own history, loaded fresh.
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
            ? 'Your saved messages are removed for you.'
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
      if (mounted) await Navigator.of(context).maybePop();
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

  Widget _menu() => PopupMenuButton<String>(
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = chat.peer;
    final canPop = Navigator.of(context).canPop();
    final modal = widget.asModal;
    final receipts = chat.direct && !chat.saved && !(peer?.isAgent ?? false);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        top: false,
        child: RoomChat(
          room: chat.title,
          messages: _page.messages,
          working: _page.working,
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
          headerActions: [const SizedBox(width: 2), _menu()],
          bare: true,
          hint: chat.saved ? 'Write a note…' : 'Message ${chat.title}…',
          subtitle: chat.saved
              ? 'Notes, links and files for yourself'
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
          leading: modal || canPop
              ? IconButton(
                  tooltip: modal ? 'Close' : 'Back to chats',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(modal
                      ? Icons.close_rounded
                      : Icons.arrow_back_rounded))
              : null,
          avatar: ChatAvatar(chat: chat, radius: 21),
          hasMore: _page.hasMore,
          loadingOlder: _loadingOlder,
          onLoadOlder: _loadOlder,
        ),
      ),
    );
  }
}

/// A chat's picture: the person or agent of a direct chat, or the room's
/// initial for a project room.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.chat, this.radius = 24});

  final ChatSummary chat;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = chat.peer;
    if (chat.saved) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        child: Icon(Icons.bookmark_rounded, size: radius),
      );
    }
    if (chat.direct) {
      final agent = peer?.isAgent ?? false;
      final name = peer?.displayName.replaceFirst('@', '') ?? '';
      final picture = Avatars.of(peer?.avatar);
      return CircleAvatar(
        radius: radius,
        foregroundImage: picture,
        onForegroundImageError: picture == null ? null : (_, __) {},
        backgroundColor:
            agent ? scheme.tertiaryContainer : scheme.secondaryContainer,
        foregroundColor:
            agent ? scheme.onTertiaryContainer : scheme.onSecondaryContainer,
        child: agent
            ? Icon(Icons.smart_toy_rounded, size: radius)
            : Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: TextStyle(
                    fontSize: radius * .8, fontWeight: FontWeight.w800)),
      );
    }
    final label = chat.roomName.isEmpty ? '#' : chat.roomName;
    final room = Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
          color: scheme.primaryContainer,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radius * .6))),
      child: Text(label.characters.first.toUpperCase(),
          style: TextStyle(
              fontSize: radius * .8,
              fontWeight: FontWeight.w800,
              color: scheme.onPrimaryContainer)),
    );
    // A project room shows its project's picture.
    return AvatarPicture(
        avatar: chat.spaceAvatar,
        size: radius * 2,
        radius: radius * .6,
        fallback: room);
  }
}
