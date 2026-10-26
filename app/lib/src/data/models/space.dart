/// A workspace (space) as returned by the Aseman spaces namespace.
import 'dart:convert';

import 'uploaded_file.dart';

class Workspace {
  const Workspace({
    required this.id,
    required this.ownerId,
    required this.name,
    this.description = '',
    this.public = false,
    this.home = false,
    this.role = '',
    this.avatar = '',
  });

  final String id;
  final String ownerId;
  final String name;
  final String description;
  final bool public;
  final bool home;

  /// Caller's role in this space ("owner", "admin", "member", "guest") as
  /// returned by `spaces.space_list`. Empty when unknown.
  final String role;

  bool get isOwner => role == 'owner';

  /// Its owner and admins may change it (its name, its avatar, ...).
  bool get canManage => role == 'owner' || role == 'admin';

  /// The workspace's picture: a stored file's id, "" when it has none.
  final String avatar;

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        id: json['id'] as String? ?? '',
        ownerId: json['owner_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        public: json['public'] as bool? ?? false,
        home: json['home'] as bool? ?? false,
        role: json['role'] as String? ?? '',
        avatar: '${json['avatar'] ?? (json['profile'] is Map ? json['profile']['avatar'] : null) ?? ''}',
      );

  /// The same workspace with another avatar.
  Workspace withAvatar(String avatar) => Workspace(
        id: id,
        ownerId: ownerId,
        name: name,
        description: description,
        public: public,
        home: home,
        role: role,
        avatar: avatar,
      );

  String get initials {
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
    if (parts.isEmpty) return 'W';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }
}

/// A room inside a workspace.
class WorkspaceRoom {
  const WorkspaceRoom({
    required this.id,
    required this.spaceId,
    required this.name,
    this.topic = '',
  });

  final String id;
  final String spaceId;
  final String name;
  final String topic;

  factory WorkspaceRoom.fromJson(Map<String, dynamic> json) => WorkspaceRoom(
        id: json['id'] as String? ?? '',
        spaceId: json['space_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        topic: json['topic'] as String? ?? '',
      );
}

/// A conversation thread of a room (`spaces.thread_list`): its own message
/// history and its own context for the room's agents. The room itself is its
/// main thread ([isMain]); threads are addressed like rooms by their [id].
class RoomThread {
  const RoomThread({
    required this.id,
    required this.title,
    this.roomId = '',
    this.isMain = false,
    this.updatedAt,
    this.lastBody = '',
    this.lastAt,
  });

  final String id;
  final String title;

  /// The room the thread belongs to.
  final String roomId;
  final bool isMain;
  final DateTime? updatedAt;

  /// The newest message, for the thread list.
  final String lastBody;
  final DateTime? lastAt;

  /// When something last happened in it.
  DateTime? get activeAt => lastAt ?? updatedAt;

  factory RoomThread.fromJson(Map<String, dynamic> json,
      {bool isMain = false}) {
    final last = json['last'] is Map
        ? (json['last'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return RoomThread(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? (isMain ? 'Main' : 'Thread'),
      roomId: json['room_id'] as String? ?? '',
      isMain: isMain,
      updatedAt:
          DateTime.tryParse('${json['updated_at'] ?? ''}')?.toLocal(),
      lastBody: last['body'] as String? ?? '',
      lastAt: DateTime.tryParse('${last['created_at'] ?? ''}')?.toLocal(),
    );
  }
}

/// A room message as returned by spaces.message_list.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.spaceId,
    required this.roomId,
    required this.senderId,
    required this.body,
    required this.createdAt,
    this.kind = 'message',
    this.mentions = const [],
    this.attachments = const [],
    this.senderName = '',
    this.senderIsAgent = false,
    this.senderAvatar = '',
    this.replyTo = '',
    this.editedAt,
  });

  final String id;
  final String spaceId;
  final String roomId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// "message" (normal conversation) or "log" (agentic-flow content rendered as
  /// a collapsible section, e.g. aseman's plans/dispatches/tool outputs).
  final String kind;

  /// Explicitly mentioned member ids (users and agents) attached to the
  /// message; mentioned agents are triggered to respond.
  final List<String> mentions;

  /// Files attached to this message (photos, gifs, audio, voice, video,
  /// documents). Each entry carries its own metadata + streaming content url.
  final List<UploadedFile> attachments;

  /// The sender's display name and whether it is a bot, as the node resolved
  /// them when listing the room (empty when it did not).
  final String senderName;
  final bool senderIsAgent;

  /// The sender's picture (a stored file's id), "" when it has none.
  final String senderAvatar;

  /// The message of the room this one answers (empty when none).
  final String replyTo;

  /// When its sender last changed it (null when never).
  final DateTime? editedAt;

  bool get edited => editedAt != null;

  /// Message pages can rotate at the same length or enrich an existing
  /// attachment. Compare visible content rather than only the oldest ID.
  bool hasSameContentAs(RoomMessage other) =>
      id == other.id &&
      senderId == other.senderId &&
      body == other.body &&
      kind == other.kind &&
      createdAt == other.createdAt &&
      replyTo == other.replyTo &&
      editedAt == other.editedAt &&
      _sameList(mentions, other.mentions, (a, b) => a == b) &&
      _sameList(
          attachments,
          other.attachments,
          (a, b) =>
              a.id == b.id &&
              a.name == b.name &&
              a.mime == b.mime &&
              a.size == b.size &&
              a.contentUrl == b.contentUrl);

  static bool _sameList<T>(
      List<T> left, List<T> right, bool Function(T, T) equal) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!equal(left[i], right[i])) return false;
    }
    return true;
  }

  factory RoomMessage.fromJson(Map<String, dynamic> json) => RoomMessage(
        id: json['id'] as String? ?? '',
        spaceId: json['space_id'] as String? ?? '',
        roomId: json['room_id'] as String? ?? '',
        senderId: json['sender_id'] as String? ?? '',
        body: json['body'] as String? ?? '',
        kind: json['kind'] as String? ?? 'message',
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
            DateTime.now(),
        mentions: _strings(json['mentions']),
        attachments: _attachments(json['attachments']),
        senderName: _senderName(json['sender']),
        senderIsAgent: json['sender'] is Map && json['sender']['kind'] == 'bot',
        senderAvatar:
            json['sender'] is Map ? '${json['sender']['avatar'] ?? ''}' : '',
        replyTo: json['reply_to'] as String? ?? '',
        editedAt: DateTime.tryParse(json['edited_at'] as String? ?? ''),
      );

  static String _senderName(dynamic sender) {
    if (sender is! Map) return '';
    final name = '${sender['display_name'] ?? ''}'.trim();
    if (name.isNotEmpty) return name;
    final handle = '${sender['handle'] ?? ''}'.trim();
    return handle.isEmpty ? '' : '@$handle';
  }

  static List<String> _strings(dynamic raw) {
    if (raw is List) return raw.map((e) => e.toString()).toList();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return const [];
  }

  static List<UploadedFile> _attachments(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map<String, dynamic>>()
          .map(UploadedFile.fromJson)
          .toList();
    }
    return const [];
  }
}

/// A direct/packet message from the message namespace.
class Packet {
  const Packet({
    required this.id,
    required this.fromId,
    required this.toId,
    required this.kind,
    required this.status,
    this.body = '',
    this.payload = '',
    this.correlationId = '',
    this.repliedAt,
  });

  final String id;
  final String fromId;
  final String toId;
  final String kind; // message | ask | response
  final String status; // sent | requested | answered | failed
  final String body;
  final String payload;
  final String correlationId;
  final DateTime? repliedAt;

  bool get isAsk => kind == 'ask';
  bool get isAnswered => status == 'answered';
  bool get isRequested => status == 'requested';

  factory Packet.fromJson(Map<String, dynamic> json) => Packet(
        id: json['id'] as String? ?? '',
        fromId: json['from_id'] as String? ?? '',
        toId: json['to_id'] as String? ?? '',
        kind: json['kind'] as String? ?? 'message',
        status: json['status'] as String? ?? 'sent',
        body: json['body'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
        correlationId: json['correlation_id'] as String? ?? '',
        repliedAt: DateTime.tryParse(json['replied_at'] as String? ?? ''),
      );
}

/// The other side of a direct chat: a person or an agent.
class ChatPeer {
  const ChatPeer({
    required this.id,
    this.handle = '',
    this.name = '',
    this.kind = 'user',
    this.botId = '',
    this.avatar = '',
  });

  final String id;
  final String handle;
  final String name;

  /// "user" or "bot".
  final String kind;

  /// The bot record id when the peer is an agent (what mentions address).
  final String botId;
  final String avatar;

  bool get isAgent => kind == 'bot';
  String get displayName => name.isNotEmpty
      ? name
      : handle.isNotEmpty
          ? '@$handle'
          : 'Conversation';

  factory ChatPeer.fromJson(Map<String, dynamic> json) => ChatPeer(
        id: '${json['id'] ?? ''}',
        handle: '${json['handle'] ?? ''}',
        name: '${json['display_name'] ?? ''}',
        kind: '${json['kind'] ?? 'user'}',
        botId: '${json['bot_id'] ?? ''}',
        avatar: '${json['avatar'] ?? ''}',
      );
}

/// One conversation of the messenger (`spaces.chat_list`): a direct chat (a
/// one-room space shared by two accounts) or a room of one of the caller's
/// projects, with its latest message.
class ChatSummary {
  const ChatSummary({
    required this.spaceId,
    required this.roomId,
    this.direct = false,
    this.spaceName = '',
    this.spaceAvatar = '',
    this.roomName = '',
    this.peer,
    this.lastBody = '',
    this.lastSenderId = '',
    this.lastSenderName = '',
    this.lastAttachments = 0,
    this.updatedAt,
    this.unread = 0,
    this.working = false,
    this.role = '',
    this.pinnedAt,
    this.saved = false,
    this.blocked = false,
    this.canSend = true,
    this.typing = false,
  });

  final String spaceId;
  final String roomId;
  final bool direct;
  final String spaceName;

  /// The project's picture (a stored file's id), "" when it has none.
  final String spaceAvatar;
  final String roomName;
  final ChatPeer? peer;
  final String lastBody;
  final String lastSenderId;
  final String lastSenderName;
  final int lastAttachments;
  final DateTime? updatedAt;
  final int unread;
  final bool working;

  /// The caller's role in the chat's space ("owner", "admin", "member", ...).
  final String role;

  /// When the caller pinned the chat to the top of their list (null: not pinned).
  final DateTime? pinnedAt;

  /// The caller's Saved Messages: the direct chat with themselves.
  final bool saved;

  /// Whether the caller blocked the other side of a direct chat, and whether
  /// anyone can write in it (false when either side blocked the other).
  final bool blocked;
  final bool canSend;

  /// Whether someone else is typing in it right now.
  final bool typing;

  bool get pinned => pinnedAt != null;
  bool get canManage => role == 'owner' || role == 'admin';

  /// Whether the caller may delete other people's messages: a project's
  /// managers may; in a direct chat nobody moderates the other side.
  bool get canModerate => !direct && canManage;
  String get key => '$spaceId/$roomId';
  String get title => saved
      ? 'Saved Messages'
      : direct
          ? (peer?.displayName ?? 'Direct chat')
          : roomName;

  ChatSummary copyWith(
          {DateTime? pinnedAt,
          bool clearPin = false,
          bool? blocked,
          bool? canSend}) =>
      ChatSummary(
        spaceId: spaceId,
        roomId: roomId,
        direct: direct,
        spaceName: spaceName,
        spaceAvatar: spaceAvatar,
        roomName: roomName,
        peer: peer,
        lastBody: lastBody,
        lastSenderId: lastSenderId,
        lastSenderName: lastSenderName,
        lastAttachments: lastAttachments,
        updatedAt: updatedAt,
        unread: unread,
        working: working,
        role: role,
        pinnedAt: clearPin ? null : pinnedAt ?? this.pinnedAt,
        saved: saved,
        blocked: blocked ?? this.blocked,
        canSend: canSend ?? this.canSend,
        typing: typing,
      );

  factory ChatSummary.fromJson(Map<String, dynamic> json) {
    final last = json['last'] is Map
        ? (json['last'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final sender = last['sender'] is Map
        ? (last['sender'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final peer = json['peer'] is Map
        ? ChatPeer.fromJson((json['peer'] as Map).cast<String, dynamic>())
        : null;
    return ChatSummary(
      spaceId: '${json['space_id'] ?? ''}',
      roomId: '${json['room_id'] ?? ''}',
      direct: json['kind'] == 'direct',
      spaceName: '${json['space_name'] ?? ''}',
      spaceAvatar: '${json['space_avatar'] ?? ''}',
      roomName: '${json['room_name'] ?? ''}',
      peer: peer,
      lastBody: '${last['body'] ?? ''}',
      lastSenderId: '${sender['id'] ?? ''}',
      lastSenderName: ChatPeer.fromJson(sender).displayName,
      lastAttachments: (last['attachments'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}')?.toLocal(),
      unread: (json['unread'] as num?)?.toInt() ?? 0,
      working: json['working'] == true,
      role: '${json['role'] ?? ''}',
      pinnedAt: DateTime.tryParse('${json['pinned_at'] ?? ''}')?.toLocal(),
      saved: json['saved'] == true,
      blocked: json['blocked'] == true,
      canSend: json['can_send'] != false,
      typing: json['typing'] == true,
    );
  }
}

/// One superseded wording of a room message (`spaces.message_edits`).
class MessageEditVersion {
  const MessageEditVersion({required this.body, required this.at, this.id = ''});

  final String id;
  final String body;

  /// When this body was current until (replaced_at), or when the current
  /// body was last set (edited_at / created_at).
  final DateTime at;

  factory MessageEditVersion.fromJson(Map<String, dynamic> json) =>
      MessageEditVersion(
        id: '${json['id'] ?? ''}',
        body: json['body'] as String? ?? '',
        at: DateTime.tryParse(
                '${json['replaced_at'] ?? json['edited_at'] ?? json['created_at'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// Current body plus earlier wording of an edited room message.
class MessageEditHistory {
  const MessageEditHistory({
    required this.messageId,
    required this.current,
    this.previous = const [],
  });

  final String messageId;
  final MessageEditVersion current;

  /// Earlier bodies, newest superseded first.
  final List<MessageEditVersion> previous;

  factory MessageEditHistory.fromJson(Map<String, dynamic> json) {
    final currentRaw = json['current'];
    final currentMap = currentRaw is Map
        ? Map<String, dynamic>.from(currentRaw)
        : <String, dynamic>{};
    return MessageEditHistory(
      messageId: json['message_id'] as String? ?? '',
      current: MessageEditVersion.fromJson(currentMap),
      previous: [
        for (final row in json['previous'] as List? ?? const [])
          if (row is Map)
            MessageEditVersion.fromJson(Map<String, dynamic>.from(row))
      ],
    );
  }
}

/// A room's conversation as `spaces.message_list` reads it for a chat: its
/// messages, the agent working in it, who is typing and, for a direct chat,
/// how far the other side has read and whether anyone can write.
class RoomChatPage {
  const RoomChatPage({
    this.messages = const [],
    this.working = '',
    this.workingDetail = '',
    this.typing = const [],
    this.peerSeenAt,
    this.blocked = false,
    this.canSend = true,
    this.saved = false,
    this.hasMore = false,
  });

  final List<RoomMessage> messages;
  final String working;
  final String workingDetail;

  /// Display names of the others typing in the room now.
  final List<String> typing;
  final DateTime? peerSeenAt;
  final bool blocked;
  final bool canSend;
  final bool saved;

  /// True when older messages than [messages] still exist on the node.
  final bool hasMore;

  RoomChatPage copyWith({
    List<RoomMessage>? messages,
    String? working,
    String? workingDetail,
    List<String>? typing,
    DateTime? peerSeenAt,
    bool? blocked,
    bool? canSend,
    bool? saved,
    bool? hasMore,
  }) =>
      RoomChatPage(
        messages: messages ?? this.messages,
        working: working ?? this.working,
        workingDetail: workingDetail ?? this.workingDetail,
        typing: typing ?? this.typing,
        peerSeenAt: peerSeenAt ?? this.peerSeenAt,
        blocked: blocked ?? this.blocked,
        canSend: canSend ?? this.canSend,
        saved: saved ?? this.saved,
        hasMore: hasMore ?? this.hasMore,
      );

  factory RoomChatPage.fromJson(Map<String, dynamic> json) => RoomChatPage(
        messages: (json['messages'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            // Widgets agents once posted into the chat (kind "ui"): tools'
            // interfaces now open on the room's desk instead.
            .where((m) => m['kind'] != 'ui')
            .map(RoomMessage.fromJson)
            .toList(),
        working: json['working'] as String? ?? '',
        workingDetail: json['working_detail'] as String? ?? '',
        typing: [
          for (final t in json['typing'] as List? ?? const [])
            if (t is Map)
              ChatPeer.fromJson(t.cast<String, dynamic>()).displayName
        ],
        peerSeenAt: DateTime.tryParse('${json['peer_seen_at'] ?? ''}'),
        blocked: json['blocked'] == true,
        canSend: json['can_send'] != false,
        saved: json['saved'] == true,
        hasMore: json['has_more'] == true,
      );
}

/// Sorts room messages oldest→newest (id as tiebreaker), matching the chat UI.
List<RoomMessage> sortRoomMessages(List<RoomMessage> messages) {
  final out = [...messages];
  out.sort((a, b) {
    final c = a.createdAt.compareTo(b.createdAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return out;
}

/// Merges a newest [page] from `message_list` into [existing], keeping any
/// older messages already loaded and replacing the overlapping window so
/// edits and deletes in that window apply.
List<RoomMessage> mergeNewestRoomMessages(
    List<RoomMessage> existing, List<RoomMessage> page) {
  if (page.isEmpty) return existing;
  if (existing.isEmpty) return sortRoomMessages(page);
  var oldestInPage = page.first.createdAt;
  for (final m in page) {
    if (m.createdAt.isBefore(oldestInPage)) oldestInPage = m.createdAt;
  }
  // Strictly older than the page's oldest: history already scrolled into.
  // Everything from that instant onward is the page (rotations and deletes).
  final older = [
    for (final m in existing)
      if (m.createdAt.isBefore(oldestInPage)) m
  ];
  return sortRoomMessages([...older, ...page]);
}

/// Prepends an older [page] (messages before what the client already holds).
List<RoomMessage> mergeOlderRoomMessages(
    List<RoomMessage> existing, List<RoomMessage> page) {
  if (page.isEmpty) return existing;
  final ids = {for (final m in existing) m.id};
  return sortRoomMessages([
    ...existing,
    for (final m in page)
      if (!ids.contains(m.id)) m
  ]);
}
