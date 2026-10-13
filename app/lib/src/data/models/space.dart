/// A workspace (space) as returned by the Tradera spaces namespace.
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

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        id: json['id'] as String? ?? '',
        ownerId: json['owner_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        public: json['public'] as bool? ?? false,
        home: json['home'] as bool? ?? false,
        role: json['role'] as String? ?? '',
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
  });

  final String id;
  final String spaceId;
  final String roomId;
  final String senderId;
  final String body;
  final DateTime createdAt;

  /// "message" (normal conversation) or "log" (agentic-flow content rendered as
  /// a collapsible section, e.g. tradera's plans/dispatches/tool outputs).
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

  /// Message pages can rotate at the same length or enrich an existing
  /// attachment. Compare visible content rather than only the oldest ID.
  bool hasSameContentAs(RoomMessage other) =>
      id == other.id &&
      senderId == other.senderId &&
      body == other.body &&
      kind == other.kind &&
      createdAt == other.createdAt &&
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
  });

  final String spaceId;
  final String roomId;
  final bool direct;
  final String spaceName;
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

  bool get canManage => role == 'owner' || role == 'admin';
  String get key => '$spaceId/$roomId';
  String get title => direct ? (peer?.displayName ?? 'Direct chat') : roomName;

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
    );
  }
}
