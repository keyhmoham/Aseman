import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../rooms/presentation/widgets/room_chat.dart';

/// One conversation of the messenger, direct or a project room. Both are rooms
/// of a space (a direct chat is a one-room space shared by two accounts), so
/// the page is the project room chat itself: files, voice, agent mentions,
/// the message designer, agent tasks and routines all work the same.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.dependencies, required this.chat});

  final AppDependencies dependencies;
  final ChatSummary chat;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  List<RoomMessage> _messages = const [];
  String _working = '';
  String _workingDetail = '';
  List<Bot> _agents = const [];
  Timer? _poll;
  bool _loading = false;
  DateTime? _seen;

  ChatSummary get chat => widget.chat;
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
    try {
      final res = await widget.dependencies.service
          .fetchRoomMessages(chat.spaceId, chat.roomId);
      if (!mounted) return;
      final msgs = res.messages;
      final changed = msgs.length != _messages.length ||
          List.generate(msgs.length, (i) => i)
              .any((i) => !_messages[i].hasSameContentAs(msgs[i])) ||
          res.working != _working ||
          res.workingDetail != _workingDetail;
      if (changed) {
        setState(() {
          _messages = List.unmodifiable(msgs);
          _working = res.working;
          _workingDetail = res.workingDetail;
        });
      }
      _markSeen(msgs);
    } catch (_) {
      // The next poll can recover without clearing the conversation.
    } finally {
      _loading = false;
    }
  }

  // Reading the chat moves the read cursor to its newest message.
  void _markSeen(List<RoomMessage> msgs) {
    if (msgs.isEmpty) return;
    final newest =
        msgs.map((m) => m.createdAt).reduce((a, b) => a.isAfter(b) ? a : b);
    if (_seen != null && !newest.isAfter(_seen!)) return;
    _seen = newest;
    unawaited(widget.dependencies.service
        .markSeen(chat.spaceId, newest)
        .catchError((_) {}));
  }

  Future<void> _loadAgents() async {
    try {
      final bots =
          await widget.dependencies.service.fetchSpaceBots(chat.spaceId);
      if (mounted) {
        setState(() => _agents = bots.where((b) => b.isAgent).toList());
      }
    } catch (_) {}
  }

  Future<void> _send(
      String body, List<String> mentions, List<String> attachments) async {
    // Writing to an agent in its direct chat is addressed to it, so it runs a
    // turn exactly as when it is mentioned in a project room.
    var to = mentions;
    final peer = chat.peer;
    if (to.isEmpty && chat.direct && peer != null && peer.isAgent) {
      final agent = _agents.where((b) =>
          b.id == peer.botId || b.accountId == peer.id || b.id == peer.id);
      to = [agent.isNotEmpty ? agent.first.id : peer.botId];
      to.removeWhere((id) => id.isEmpty);
    }
    try {
      await widget.dependencies.service.sendRoomMessage(
          chat.spaceId, chat.roomId, body,
          mentions: to, attachments: attachments);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = chat.peer;
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        top: false,
        child: RoomChat(
          room: chat.title,
          messages: _messages,
          working: _working,
          workingDetail: _workingDetail,
          me: _me,
          dependencies: widget.dependencies,
          spaceId: chat.spaceId,
          roomId: chat.roomId,
          canManageTasks: chat.canManage,
          mentionable: _agents,
          onSend: _send,
          bare: true,
          hint: 'Message ${chat.title}…',
          subtitle: chat.direct
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
          leading: canPop
              ? IconButton(
                  tooltip: 'Back to chats',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded))
              : null,
          avatar: ChatAvatar(chat: chat, radius: 21),
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
    if (chat.direct) {
      final agent = peer?.isAgent ?? false;
      final name = peer?.displayName.replaceFirst('@', '') ?? '';
      return CircleAvatar(
        radius: radius,
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
    return Container(
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
  }
}
