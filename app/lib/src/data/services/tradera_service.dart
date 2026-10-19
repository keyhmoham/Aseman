import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/network/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/models/market_quote.dart';
import '../../domain/models/message.dart';
import '../../domain/models/room.dart';
import '../../features/miniapps/domain/widget_dsl.dart';
import '../models/bot.dart';
import '../models/llm_provider.dart';
import '../models/post.dart';
import '../models/profile.dart';
import '../models/space.dart';
import '../models/uploaded_file.dart';
import 'backend_capabilities.dart';
import 'backend_service.dart';

/// Contract keys for the per-bot entity store. These are set at runtime and
/// mirror the backend bot contract, so new entity types can be added without
/// client changes.
abstract final class BotEntityKeys {
  static const backend = 'backend';
  static const spec = 'spec';
  static const frontend = 'frontend';
  static const resources = 'resources';
  static const cost = 'cost';
  static const widgetDsl = 'widget_dsl';
  static const backendSecret = 'backend_secret';
  static const staticPrefix = 'static/';
  static const assetsPrefix = 'assets/';
}

/// The real, server-backed implementation of [TraderaService]. All calls go
/// through the signed Tradera gateway, so every action runs with the signed
/// in user's identity — including miniapp backend asks.
class TraderaService implements BackendService {
  TraderaService(this.client);

  final TraderaApiClient client;

  Session? get session => client.session;

  /// Invoke any action in the client contract. Feature-specific methods below
  /// provide convenient typed mappings; this entry point keeps administration
  /// and newly deployed additive actions available without a client release.
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    if (!BackendCapabilities.contains(namespace, action)) {
      throw ArgumentError.value('$namespace.$action', 'action',
          'Action is not part of the Tradera client contract');
    }
    final response = await client.call(
      namespace,
      action,
      body: body,
      requestTimeout: timeout,
    );
    return response.body;
  }

  Future<Map<String, dynamic>> actionMap(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    final value = await invokeAction(
      namespace,
      action,
      body: body,
      timeout: timeout,
    );
    return value is Map ? value.cast<String, dynamic>() : <String, dynamic>{};
  }

  // ── auth ──────────────────────────────────────────────────────────────────

  Future<Session> register({
    required String handle,
    required String email,
    required String password,
  }) async {
    final resp = await client.call('auth', 'register', body: {
      'handle': handle,
      'email': email,
      'password': password,
    });
    return _adopt(_sessionFrom(resp.body as Map<String, dynamic>));
  }

  Future<Session> login({
    required String account,
    required String password,
  }) async {
    final resp = await client.call('auth', 'login', body: {
      'account': account,
      'password': password,
    });
    return _adopt(_sessionFrom(resp.body as Map<String, dynamic>));
  }

  Future<Session> oauth(String provider, String identityToken) async {
    if (provider != 'google' && provider != 'apple') {
      throw ArgumentError.value(provider, 'provider');
    }
    final response = await client.call('auth', 'oauth_$provider', body: {
      if (provider == 'google') 'id_token': identityToken,
      if (provider == 'apple') 'identity_token': identityToken,
    });
    return _adopt(_sessionFrom((response.body as Map).cast<String, dynamic>()));
  }

  Future<Session?> verifyEmail({
    required String email,
    required String code,
    String password = '',
  }) async {
    final result = await actionMap('auth', 'verify_email', body: {
      'email': email,
      'code': code,
      if (password.isNotEmpty) 'password': password,
    });
    final token = result['token'] as String? ?? '';
    if (token.isEmpty) return null;
    return _adopt(_sessionFrom(result));
  }

  /// Makes a freshly obtained session the client's identity, so the following
  /// requests carry its bearer token and signature (without this, calls made
  /// right after logging in were unauthenticated until the app restarted).
  Session _adopt(Session s) {
    client.session = s;
    return s;
  }

  /// Whether the signed-in account may use the admin console (`auth.me`).
  Future<bool> fetchIsAdmin() async {
    final me = await actionMap('auth', 'me');
    return me['is_admin'] == true;
  }

  Future<void> logout() async {
    try {
      await client.call('auth', 'logout');
    } catch (_) {}
    await SessionStore.clear();
    client.session = null;
  }

  Future<void> restoreSession() async {
    final stored = await SessionStore.load();
    if (stored != null) client.session = stored;
  }

  static Session _sessionFrom(Map<String, dynamic> json) => Session(
        accountId: json['account_id'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        token: json['token'] as String? ?? '',
        privateKey: json['private_key'] as String? ?? '',
        publicKey: json['public_key'] as String? ?? '',
        homeSpaceId: json['home_space_id'] as String? ?? '',
      );

  // ── spaces ────────────────────────────────────────────────────────────────

  Future<List<Workspace>> fetchSpaces({int limit = 100, int offset = 0}) async {
    final resp = await client.call('spaces', 'space_list', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['spaces'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Workspace.fromJson)
        .toList();
  }

  Future<Workspace> createSpace(String name, String description) async {
    final resp = await client.call('spaces', 'space_create', body: {
      'name': name,
      'description': description,
    });
    final m = resp.body as Map<String, dynamic>;
    return Workspace(
      id: m['space_id'] as String? ?? '',
      ownerId: session?.accountId ?? '',
      name: name,
      description: description,
    );
  }

  /// Fetch a single space by id (`spaces.space_get`).
  Future<Workspace> fetchSpace(String spaceId) async {
    final resp =
        await client.call('spaces', 'space_get', body: {'space': spaceId});
    final m = resp.body as Map<String, dynamic>;
    return Workspace(
      id: m['id'] as String? ?? spaceId,
      ownerId: m['owner_id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      description: m['description'] as String? ?? '',
      public: m['public'] as bool? ?? false,
    );
  }

  /// Update a space's name / description / visibility (`spaces.space_update`).
  Future<void> updateSpace(String spaceId,
      {String? name, String? description, bool? public}) async {
    await client.call('spaces', 'space_update', body: {
      'space': spaceId,
      if (name != null && name.isNotEmpty) 'name': name,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (public != null) 'public': public,
    });
  }

  /// Delete a workspace forever (owner only, `spaces.space_delete`).
  Future<void> deleteSpace(String spaceId) async {
    await client.call('spaces', 'space_delete', body: {'space': spaceId});
  }

  /// Leave a workspace (removes the caller's memberships, `spaces.leave`).
  Future<void> leaveSpace(String spaceId) async {
    await client.call('spaces', 'leave', body: {'space': spaceId});
  }

  /// Invite an account to a space (`spaces.invite`); returns the invitation id.
  Future<String> inviteToSpace(String spaceId, String inviteeId,
      {String role = 'member'}) async {
    final resp = await client.call('spaces', 'invite', body: {
      'space': spaceId,
      'invitee': inviteeId,
      if (role.isNotEmpty) 'role': role,
    });
    return ((resp.body as Map?)?['invitation_id'] as String?) ?? '';
  }

  /// Remove a member from a space (`spaces.member_remove`).
  Future<void> removeSpaceMember(String spaceId, String memberId) async {
    await client.call('spaces', 'member_remove', body: {
      'space': spaceId,
      'member': memberId,
    });
  }

  /// Set a member's role in a space (`spaces.member_role`).
  Future<void> setMemberRole(
      String spaceId, String memberId, String role) async {
    await client.call('spaces', 'member_role', body: {
      'space': spaceId,
      'member': memberId,
      'role': role,
    });
  }

  Future<List<WorkspaceRoom>> fetchRoomsForSpace(String spaceId,
      {int limit = 100, int offset = 0}) async {
    final resp = await client.call('spaces', 'room_list', body: {
      'space': spaceId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['rooms'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(WorkspaceRoom.fromJson)
        .toList();
  }

  Future<WorkspaceRoom> createRoom(
      String spaceId, String name, String topic) async {
    final resp = await client.call('spaces', 'room_create', body: {
      'space': spaceId,
      'name': name,
      'topic': topic,
    });
    final m = resp.body as Map<String, dynamic>;
    return WorkspaceRoom(
      id: m['room_id'] as String? ?? '',
      spaceId: spaceId,
      name: name,
      topic: topic,
    );
  }

  /// Delete a room and its messages (`spaces.room_delete`).
  Future<void> deleteRoom(String roomId) async {
    await client.call('spaces', 'room_delete', body: {'room': roomId});
  }

  /// Load a space's metadata tree (desk layouts, room resources, etc.).
  Future<Map<String, dynamic>> fetchSpaceMetadata(String spaceId) async {
    final resp =
        await client.call('spaces', 'metadata_view', body: {'space': spaceId});
    final m = resp.body as Map<String, dynamic>;
    final tree = m['tree'];
    return tree is Map<String, dynamic> ? tree : const {};
  }

  /// Apply a JSON patch to a space's metadata tree.
  Future<void> patchSpaceMetadata(
      String spaceId, List<Map<String, dynamic>> patch) async {
    await client.call('spaces', 'metadata_patch',
        body: {'space': spaceId, 'patch': patch});
  }

  // ── messenger ─────────────────────────────────────────────────────────────

  /// Every conversation of the caller, newest first: direct chats and the
  /// rooms of their projects. [kind] narrows it to "direct" or "room".
  Future<List<ChatSummary>> fetchChats({String kind = ''}) async {
    final resp = await client
        .call('spaces', 'chat_list', body: {if (kind.isNotEmpty) 'kind': kind});
    final list = (resp.body as Map?)?['chats'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(ChatSummary.fromJson)
        .toList();
  }

  /// Opens the direct chat with a person or an agent ([peer] is an account or
  /// bot id), starting it on first use.
  Future<ChatSummary> openDirect(String peer) async {
    final resp =
        await client.call('spaces', 'direct_open', body: {'peer': peer});
    final m = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return ChatSummary.fromJson({...m, 'kind': 'direct'});
  }

  /// Opens the caller's Saved Messages: the direct chat with themselves.
  Future<ChatSummary> openSaved() async {
    final resp = await client.call('spaces', 'direct_open',
        body: {'peer': session?.accountId ?? ''});
    final m = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return ChatSummary.fromJson({...m, 'kind': 'direct', 'saved': true});
  }

  /// Pins a chat to the top of the caller's chats, or unpins it.
  Future<void> pinChat(String spaceId, String roomId, bool pinned) async {
    await client.call('spaces', 'chat_pin',
        body: {'space': spaceId, 'room': roomId, 'pinned': pinned});
  }

  /// Deletes a direct chat for the caller only: it returns with a newer message.
  Future<void> clearChat(String spaceId) async {
    await client.call('spaces', 'chat_clear', body: {'space': spaceId});
  }

  /// Blocks (or unblocks) the other side of a direct chat: neither can write.
  Future<void> blockDirect(String spaceId, bool blocked) async {
    await client.call('spaces', 'direct_block',
        body: {'space': spaceId, 'blocked': blocked});
  }

  /// Tells the room's others that the caller is typing (or stopped).
  Future<void> setTyping(String spaceId, String roomId, bool typing) async {
    await client.call('spaces', 'typing_set',
        body: {'space': spaceId, 'room': roomId, 'typing': typing});
  }

  /// Reports a message ([messageId]) or a whole chat to the node's admins.
  /// [reason] is spam, harassment, abuse, scam, inappropriate or other.
  Future<void> reportChat(String spaceId, String roomId,
      {String messageId = '', required String reason, String note = ''}) async {
    await client.call('spaces', 'message_report', body: {
      'space': spaceId,
      'room': roomId,
      if (messageId.isNotEmpty) 'message': messageId,
      'reason': reason,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    });
  }

  /// Admin: what people reported in chats. [status] is open, resolved,
  /// dismissed or all.
  Future<({List<Map<String, dynamic>> reports, int open})> adminChatReports(
      {String status = 'open'}) async {
    final resp = await client
        .call('spaces', 'admin_chat_reports', body: {'status': status});
    final m = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return (
      reports: (m['reports'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList(),
      open: (m['open'] as num?)?.toInt() ?? 0,
    );
  }

  /// Admin: resolve, dismiss or reopen ("open") a chat report.
  Future<void> adminResolveChatReport(String id, String status) async {
    await client.call('spaces', 'admin_chat_report_resolve',
        body: {'id': id, 'status': status});
  }

  /// Records that the caller has read a space's conversation up to [at].
  Future<void> markSeen(String spaceId, DateTime at) async {
    await client.call('spaces', 'seen_set',
        body: {'space': spaceId, 'at': at.toUtc().toIso8601String()});
  }

  // ── room messages ─────────────────────────────────────────────────────────

  Future<({List<RoomMessage> messages, String working, String workingDetail})>
      fetchRoomMessages(String spaceId, String roomId,
          {int limit = 50, int offset = 0}) async {
    final resp = await client.call('spaces', 'message_list', body: {
      'space': spaceId,
      'room': roomId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final body = resp.body as Map? ?? const {};
    final list = body['messages'] as List? ?? [];
    return (
      messages: list
          .whereType<Map<String, dynamic>>()
          // Widgets agents once posted into the chat (kind "ui"): tools'
          // interfaces now open on the room's desk instead.
          .where((m) => m['kind'] != 'ui')
          .map(RoomMessage.fromJson)
          .toList(),
      working: body['working'] as String? ?? '',
      workingDetail: body['working_detail'] as String? ?? '',
    );
  }

  /// A room's conversation for a chat page: messages plus who is typing and,
  /// for a direct chat, the peer's read cursor and whether anyone can write.
  Future<RoomChatPage> fetchRoomChat(String spaceId, String roomId,
      {int limit = 50}) async {
    final resp = await client.call('spaces', 'message_list',
        body: {'space': spaceId, 'room': roomId, 'limit': limit});
    return RoomChatPage.fromJson(
        (resp.body as Map?)?.cast<String, dynamic>() ?? const {});
  }

  /// Changes the text of a message the caller sent.
  Future<void> editRoomMessage(String messageId, String body) async {
    await client.call('spaces', 'message_edit',
        body: {'message': messageId, 'body': body});
  }

  /// Deletes a message for everyone: the caller's own, or anyone's for a
  /// project's manager.
  Future<void> deleteRoomMessage(String spaceId, String messageId) async {
    await client.call('spaces', 'message_delete',
        body: {'space': spaceId, 'message': messageId});
  }

  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) async {
    final resp = mentions.isNotEmpty
        ? await client.call('spaces', 'turn_submit', body: {
            'space': spaceId,
            'room': roomId,
            'submission_id':
                '${session?.accountId ?? 'client'}:${DateTime.now().microsecondsSinceEpoch}',
            'body': body,
            'prompt': body,
            'seeds': mentions,
            if (attachments.isNotEmpty) 'attachments': attachments,
            if (replyTo.isNotEmpty) 'reply_to': replyTo,
          })
        : await client.call('spaces', 'message_send', body: {
            'space': spaceId,
            'room': roomId,
            'body': body,
            if (attachments.isNotEmpty) 'attachments': attachments,
            if (replyTo.isNotEmpty) 'reply_to': replyTo,
          });
    final m = resp.body as Map<String, dynamic>;
    return RoomMessage(
      id: m['message_id'] as String? ?? m['id'] as String? ?? '',
      spaceId: spaceId,
      roomId: roomId,
      senderId: session?.accountId ?? '',
      body: body,
      createdAt: DateTime.now(),
      mentions: mentions,
      attachments: await _resolveAttachments(attachments),
      replyTo: replyTo,
    );
  }

  // ── files / media attachments ────────────────────────────────────────────

  /// Build the absolute URL that streams a file's raw bytes for direct media
  /// preview/playback. On web, media elements (<img>/<video>/<audio>) cannot
  /// reliably set the Authorization header, so the session token is appended as
  /// a query parameter; everywhere else auth flows through [authHeaders].
  String fileContentUrl(String fileId) {
    final base = '${client.baseUrl}/v1/files/$fileId/content';
    if (kIsWeb) {
      final token = session?.token ?? '';
      if (token.isNotEmpty) {
        return '$base?token=${Uri.encodeQueryComponent(token)}';
      }
    }
    return base;
  }

  /// Build the absolute gateway URL for a sandbox proxy path (e.g.
  /// `/v1/proxy/{id}/`). The session token is appended as a query parameter so
  /// a webview (which cannot reliably set Authorization headers on every
  /// platform) can authenticate against the gateway.
  String proxyUrl(String proxyPath) {
    final p = proxyPath.startsWith('/') ? proxyPath : '/$proxyPath';
    final path = Uri.parse(p);
    if (path.hasScheme ||
        path.hasAuthority ||
        !RegExp(r'^/v1/proxy/[0-9a-fA-F]{32}/').hasMatch(path.path) ||
        path.pathSegments.any((segment) => segment == '..' || segment == '.')) {
      throw const FormatException('Invalid gateway preview path');
    }
    final base =
        Uri.parse('${client.baseUrl.replaceFirst(RegExp(r'/$'), '')}$p');
    final token = session?.token ?? '';
    return base.replace(queryParameters: {
      for (final entry in base.queryParameters.entries)
        if (entry.key != 'token') entry.key: entry.value,
      if (token.isNotEmpty) 'token': token,
    }).toString();
  }

  /// Headers needed to fetch a raw content URL with the signed-in identity.
  Map<String, String> authHeaders() => {
        if (session?.token != null && session!.token.isNotEmpty)
          'Authorization': 'Bearer ${session!.token}',
      };

  /// Upload a file (photos, gifs, audio, voice, video, documents) to a
  /// space/room. [bytes] are sent base64-encoded in the action body.
  Future<UploadedFile> uploadFile(
    String spaceId, {
    String roomId = '',
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final resp = await client.call('spaces', 'file_upload', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      'name': name,
      'mime': mime,
      'data': base64Encode(bytes),
    });
    final m = resp.body as Map<String, dynamic>;
    return _fileFrom(m);
  }

  /// Fetch a single file's metadata, optionally including its decoded payload.
  Future<UploadedFile> fetchFile(String fileId, {bool withData = false}) async {
    final resp = await client.call('spaces', 'file_get', body: {
      'file': fileId,
      if (withData) 'with_data': true,
    });
    final m = resp.body as Map<String, dynamic>;
    return _fileFrom(m);
  }

  /// Download a file's full payload (base64-decoded) for saving to disk.
  Future<Uint8List> downloadFile(String fileId) async {
    final f = await fetchFile(fileId, withData: true);
    if (f.bytes != null) return f.bytes!;
    // Fallback: stream from the raw content endpoint.
    final resp = await http.get(
      Uri.parse(fileContentUrl(fileId)),
      headers: authHeaders(),
    );
    if (resp.statusCode != 200) {
      throw ApiException(
          'DOWNLOAD_FAILED', 'Download failed: ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  /// Delete a file from a space/room.
  Future<void> deleteFile(String fileId) async {
    await client.call('spaces', 'file_delete', body: {'file': fileId});
  }

  /// List the files uploaded to a space/room (metadata only).
  Future<List<UploadedFile>> fetchSpaceFiles(String spaceId,
      {String? roomId, int limit = 100, int offset = 0}) async {
    final resp = await client.call('spaces', 'file_list', body: {
      'space': spaceId,
      if (roomId != null && roomId.isNotEmpty) 'room': roomId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['files'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().map(_fileFrom).toList();
  }

  UploadedFile _fileFrom(Map<String, dynamic> m) {
    final raw = m['data'] as String? ?? '';
    Uint8List? bytes;
    if (raw.isNotEmpty) {
      try {
        bytes = base64Decode(raw);
      } catch (_) {}
    }
    return UploadedFile(
      id: m['file_id'] as String? ?? m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      mime: m['mime'] as String? ?? '',
      size: (m['size'] as num?)?.toInt() ?? 0,
      ownerId: m['owner_id'] as String? ?? '',
      spaceId: m['space_id'] as String? ?? '',
      roomId: m['room_id'] as String? ?? '',
      public: m['public'] as bool? ?? false,
      contentUrl: m['content_url'] as String? ?? '',
      createdAt: DateTime.tryParse(m['created_at'] as String? ?? ''),
      bytes: bytes,
    );
  }

  Future<List<UploadedFile>> _resolveAttachments(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final out = <UploadedFile>[];
    for (final id in ids) {
      try {
        out.add(await fetchFile(id));
      } catch (_) {}
    }
    return out;
  }

  // ── bots / agents / miniapps ──────────────────────────────────────────────

  Future<List<Bot>> fetchBots({int limit = 100, int offset = 0}) async {
    final resp = await client.call('bots', 'bot_list', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().map(Bot.fromJson).toList();
  }

  /// List the bots (agents/miniapps/tools) installed in a space. Bots are only
  /// present here when explicitly added through [addBotToSpace].
  Future<List<Bot>> fetchSpaceBots(String spaceId) async {
    final resp =
        await client.call('spaces', 'bots_list', body: {'space': spaceId});
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((j) => Bot.fromJson({
              'id': j['id'],
              'owner_id': '',
              'account_id': j['account_id'],
              'name': j['name'],
              'kind': j['kind'],
              'vm_type': j['vm_type'],
              'status': j['status'],
            }))
        .toList();
  }

  /// Add a bot (agent/miniapp/tool) to a space so it becomes available there.
  Future<void> addBotToSpace(String spaceId, String botId,
      {String roomId = ''}) async {
    await client.call('spaces', 'bot_add', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      'bot': botId,
    });
  }

  /// Remove a bot from a space.
  Future<void> removeBotFromSpace(String spaceId, String botId,
      {String roomId = ''}) async {
    await client.call('spaces', 'bot_remove', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      'bot': botId,
    });
  }

  Future<Bot> createBot({
    required String name,
    required String kind,
    required String vmType,
    String? description,
    String? imageRef,
    String? specYml,
    String? frontend,
    String? module,
    String? instructions,
    String? provider,
    String? model,
    int? maxTurns,
    int? maxTokens,
    List<Map<String, dynamic>>? skills,
    String? widgetDsl,
    int? cpu,
    int? memoryMb,
    int? diskMb,
    Map<String, String>? entities,
  }) async {
    final resp = await client.call('bots', 'bot_create', body: {
      'name': name,
      'kind': kind,
      'vm_type': vmType,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (imageRef != null && imageRef.isNotEmpty) 'image_ref': imageRef,
      if (specYml != null && specYml.isNotEmpty) 'spec_yml': specYml,
      if (frontend != null && frontend.isNotEmpty) 'frontend': frontend,
      if (module != null && module.isNotEmpty) 'module': module,
      if (instructions != null && instructions.isNotEmpty)
        'instructions': instructions,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      if (model != null && model.isNotEmpty) 'model': model,
      if (maxTurns != null && maxTurns > 0) 'max_turns': maxTurns,
      if (maxTokens != null && maxTokens > 0) 'max_tokens': maxTokens,
      if (skills != null && skills.isNotEmpty) 'skills': skills,
      if (widgetDsl != null && widgetDsl.isNotEmpty) 'widget_dsl': widgetDsl,
      if (cpu != null && cpu > 0)
        'resources': {
          'cpu': cpu,
          'memory': memoryMb ?? 512,
          'disk': diskMb ?? 512,
        },
      if (entities != null && entities.isNotEmpty) 'entities': entities,
    });
    final m = resp.body as Map<String, dynamic>;
    return Bot(
      id: m['bot_id'] as String? ?? '',
      ownerId: session?.accountId ?? '',
      accountId: '',
      name: name,
      kind: kind,
      vmType: vmType,
      status: m['status'] as String? ?? 'pending',
    );
  }

  Future<void> botLifecycle(String botId, String op) async {
    await client.call('bots', 'bot_lifecycle', body: {'bot': botId, 'op': op});
  }

  /// A bot's descriptor and, for its owner, its configuration (an agent's
  /// form fields under `agent`), as bots.bot_detail reports it.
  Future<Map<String, dynamic>> fetchBotDetail(String botId) async {
    final resp = await client.call('bots', 'bot_detail', body: {'bot': botId});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? {};
  }

  /// Changes an existing bot; only what is given changes. An agent whose
  /// configuration or computer changes is redeployed with it.
  Future<void> editBot(
    String botId, {
    String? name,
    String? description,
    String? instructions,
    String? provider,
    String? model,
    int? maxTurns,
    int? maxTokens,
    List<Map<String, dynamic>>? skills,
    int? cpu,
    int? memoryMb,
    int? diskMb,
  }) async {
    await client.call('bots', 'bot_edit', body: {
      'bot': botId,
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (instructions != null) 'instructions': instructions,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      if (model != null && model.isNotEmpty) 'model': model,
      if (maxTurns != null) 'max_turns': maxTurns,
      if (maxTokens != null) 'max_tokens': maxTokens,
      if (skills != null) 'skills': skills,
      if (cpu != null && cpu > 0)
        'resources': {
          'cpu': cpu,
          'memory': memoryMb ?? 512,
          'disk': diskMb ?? 512,
        },
    });
  }

  Future<Bot> fetchBot(String botId) async {
    final resp = await client.call('bots', 'bot_get', body: {'bot': botId});
    return Bot.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Chat with an agent or ask a miniapp backend; returns the reply string.
  /// [history] carries earlier turns of the conversation so conversational
  /// agents remember the context.
  Future<String> askBot(String botId, String message,
      {List<Map<String, String>> history = const []}) async {
    final resp = await client.call('message', 'ask', body: {
      'to': botId,
      'body': message,
      if (history.isNotEmpty) 'history': history,
    });
    final m = resp.body as Map<String, dynamic>;
    if (m['status'] == 'answered' && m['response'] != null) {
      return (m['response'] as String?) ?? '';
    }
    final correlation = m['correlation_id'] as String? ?? '';
    if (correlation.isEmpty) return '';
    // Poll once for the answer.
    final got =
        await client.call('message', 'get', body: {'message': correlation});
    final g = got.body as Map<String, dynamic>;
    return (g['response'] as String?) ?? '';
  }

  /// Ask a bot inside a space via spaces.ask — gives langchain agents access
  /// to the space's shared docker sandbox (sandbox_exec tool). [history]
  /// carries earlier turns so the agent remembers the conversation.
  Future<String> askBotInSpace(String spaceId, String botId, String message,
      {List<Map<String, String>> history = const []}) async {
    final resp = await client.call('spaces', 'ask', body: {
      'space': spaceId,
      'bot': botId,
      'body': message,
      if (history.isNotEmpty) 'history': history,
      'timeout_sec': 120,
    });
    final m = resp.body as Map<String, dynamic>;
    return (m['reply'] as String?) ?? '';
  }

  /// Run a shell command in a space's shared sandbox.
  Future<String> sandboxExec(String spaceId, String command) async {
    final resp = await client.call('spaces', 'sandbox_exec', body: {
      'space': spaceId,
      'command': command,
    });
    return ((resp.body as Map?)?['output'] as String?) ?? '';
  }

  /// Shared per-space sandbox status (ensures the sandbox bot exists).
  Future<Map<String, dynamic>> sandboxStatus(String spaceId) async {
    final resp =
        await client.call('spaces', 'sandbox_status', body: {'space': spaceId});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Start the shared per-space sandbox.
  Future<Map<String, dynamic>> sandboxStart(String spaceId) async {
    final resp =
        await client.call('spaces', 'sandbox_start', body: {'space': spaceId});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Stop the shared per-space sandbox (kept for reuse).
  Future<Map<String, dynamic>> sandboxStop(String spaceId) async {
    final resp =
        await client.call('spaces', 'sandbox_stop', body: {'space': spaceId});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Search public workspaces across the platform (paged).
  Future<List<Map<String, dynamic>>> searchSpaces(String query,
      {int limit = 20, int offset = 0}) async {
    final resp = await client.call('spaces', 'space_search', body: {
      if (query.isNotEmpty) 'query': query,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['spaces'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// List the tools (miniapps + sandbox) available to agents in a space.
  Future<List<Map<String, dynamic>>> fetchSpaceTools(String spaceId,
      {String? roomId}) async {
    final resp = await client.call('spaces', 'tools_list', body: {
      'space': spaceId,
      if (roomId != null && roomId.isNotEmpty) 'room': roomId,
    });
    final list = (resp.body as Map?)?['tools'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Search agents/miniapps/tools across the whole platform (paged).
  Future<List<Map<String, dynamic>>> searchBots(String query,
      {String kind = '', int limit = 20, int offset = 0}) async {
    final resp = await client.call('bots', 'bot_search', body: {
      if (query.isNotEmpty) 'query': query,
      if (kind.isNotEmpty) 'kind': kind,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Members of a space (enriched with handle/kind/role), paged.
  Future<List<Map<String, dynamic>>> fetchSpaceMembers(String spaceId,
      {int limit = 50, int offset = 0}) async {
    final resp = await client.call('spaces', 'members_list', body: {
      'space': spaceId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['members'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Search room messages across a whole space, newest first (paged).
  Future<List<Map<String, dynamic>>> searchSpaceMessages(String spaceId,
      {String query = '', int limit = 50, int offset = 0}) async {
    final resp = await client.call('spaces', 'message_search', body: {
      'space': spaceId,
      if (query.isNotEmpty) 'query': query,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['messages'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  // ── room desk widgets ────────────────────────────────────────────────────

  /// Fetch the live desk-widget DSLs of every miniapp installed in a room.
  Future<List<DeskWidgetDsl>> fetchRoomWidgets(
      String spaceId, String roomId) async {
    final resp = await client.call('spaces', 'widget_list', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
    });
    final list = (resp.body as Map?)?['widgets'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DeskWidgetDsl.fromWidgetListEntry)
        .toList();
  }

  /// Run a widget action against a miniapp's backend VM. The action is sent as
  /// a static ask request and the backend reply is returned.
  Future<String> widgetAction(String spaceId, String botId, String op,
      [Map<String, dynamic> args = const {}]) async {
    final resp = await client.call('spaces', 'widget_action', body: {
      'space': spaceId,
      'bot': botId,
      'op': op,
      if (args.isNotEmpty) 'args': args,
    });
    return ((resp.body as Map?)?['reply'] as String?) ?? '';
  }

  /// Store the default desk-widget DSL of a miniapp (used as a fallback when
  /// its backend VM cannot answer a live widget ask).
  Future<void> setBotWidget(String botId, String dsl) async {
    await putBotEntity(botId, BotEntityKeys.widgetDsl, dsl);
  }

  /// Read the stored default desk-widget DSL of a miniapp.
  Future<String> fetchBotWidget(String botId) async {
    return fetchBotEntity(botId, BotEntityKeys.widgetDsl);
  }

  /// Fire-and-forget packet to a user or bot.
  Future<String> sendPacket(String toId, String body,
      {String payload = ''}) async {
    final resp = await client.call('message', 'send', body: {
      'to': toId,
      'body': body,
      if (payload.isNotEmpty) 'payload': payload,
    });
    return ((resp.body as Map?)?['id'] as String?) ?? '';
  }

  Future<List<Packet>> fetchPackets(
      {String? peer, int limit = 50, int offset = 0}) async {
    final resp = await client.call('message', 'list', body: {
      if (peer != null && peer.isNotEmpty) 'peer': peer,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['messages'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().map(Packet.fromJson).toList();
  }

  Future<List<Packet>> fetchPendingRequests(
      {int limit = 50, int offset = 0}) async {
    final resp = await client.call('message', 'requests', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['requests'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().map(Packet.fromJson).toList();
  }

  Future<void> respondToAsk(String correlation, String body) async {
    await client.call('message', 'respond', body: {
      'correlation': correlation,
      'body': body,
    });
  }

  Future<String> fetchBotFrontend(String botId) async {
    // Canonical copy lives in the entity store under the frontend contract key.
    try {
      final e = await fetchBotEntity(botId, BotEntityKeys.frontend);
      if (e.isNotEmpty) return e;
    } catch (_) {}
    final resp =
        await client.call('bots', 'frontend_get', body: {'bot': botId});
    return ((resp.body as Map?)?['frontend'] as String?) ?? '';
  }

  Future<void> setBotFrontend(String botId, String frontend) async {
    await putBotEntity(botId, BotEntityKeys.frontend, frontend);
  }

  // ── bot entity storage (dynamic runtime artifacts) ───────────────────────

  /// Store a runtime entity (backend, spec, frontend, static file, ...) for a
  /// bot under a contract key. Keys are set at runtime — new entity types need
  /// no schema or code changes. Pass [base64] = true for binary content.
  Future<void> putBotEntity(String botId, String key, String value,
      {String mime = '', bool base64 = false}) async {
    await client.call('bots', 'entity_put', body: {
      'bot': botId,
      'key': key,
      'value': value,
      if (mime.isNotEmpty) 'mime': mime,
      if (base64) 'encoding': 'base64',
    });
  }

  /// Read a runtime entity of a bot. Text entities return the raw text;
  /// binary entities return base64 (check [fetchBotEntityInfo]).
  Future<String> fetchBotEntity(String botId, String key) async {
    final info = await fetchBotEntityInfo(botId, key);
    return info['value'] as String? ?? '';
  }

  /// Read a runtime entity with its metadata (value, mime, size, encoding).
  Future<Map<String, dynamic>> fetchBotEntityInfo(
      String botId, String key) async {
    final resp = await client.call('bots', 'entity_get', body: {
      'bot': botId,
      'key': key,
    });
    final m = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return {
      'value': m['value'] as String? ?? '',
      'mime': m['mime'] as String? ?? '',
      'size': (m['size'] as num?)?.toInt() ?? 0,
      'encoding': m['encoding'] as String? ?? 'text',
    };
  }

  /// List the runtime entity keys stored for a bot.
  Future<List<String>> listBotEntities(String botId) async {
    final resp = await client.call('bots', 'entity_list', body: {'bot': botId});
    final list = (resp.body as Map?)?['entities'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((e) => e['key'] as String? ?? '')
        .where((k) => k.isNotEmpty)
        .toList();
  }

  /// Delete a runtime entity of a bot.
  Future<void> deleteBotEntity(String botId, String key) async {
    await client
        .call('bots', 'entity_delete', body: {'bot': botId, 'key': key});
  }

  // ── posts / feed ──────────────────────────────────────────────────────────

  Future<List<SocialPost>> fetchFeed(
      {bool following = false,
      String? spaceId,
      int limit = 30,
      int offset = 0}) async {
    final resp = await client.call('posts', 'post_feed', body: {
      'following': following,
      if (spaceId != null && spaceId.isNotEmpty) 'space': spaceId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['posts'] as List? ?? [];
    final me = session?.accountId ?? '';
    return list.whereType<Map<String, dynamic>>().map((j) {
      final p = SocialPost.fromJson(j);
      final liked = _likedBy(j['liked_by']).contains(me);
      return p.withLike(likes: p.likes, likedByMe: liked);
    }).toList();
  }

  /// Decode the JSON-encoded `liked_by` column. The backend stores it as a
  /// JSON string (e.g. `"[\"id\"]"`), but some responses may carry a real
  /// list; both forms are accepted.
  static List<String> _likedBy(dynamic raw) {
    if (raw is List) return raw.whereType<String>().toList();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return const [];
  }

  Future<SocialPost> createPost(String body,
      {String? spaceId, List<String> tags = const []}) async {
    final resp = await client.call('posts', 'post_create', body: {
      'body': body,
      if (spaceId != null && spaceId.isNotEmpty) 'space': spaceId,
      if (tags.isNotEmpty) 'tags': tags,
    });
    final m = resp.body as Map<String, dynamic>;
    return SocialPost(
      id: m['post_id'] as String? ?? '',
      authorId: session?.accountId ?? '',
      body: body,
      createdAt: DateTime.now(),
      tags: tags,
    );
  }

  Future<void> likePost(String postId) async {
    await client.call('posts', 'post_like', body: {'post': postId});
  }

  Future<void> unlikePost(String postId) async {
    await client.call('posts', 'post_unlike', body: {'post': postId});
  }

  Future<List<SocialPost>> fetchComments(String postId) async {
    final resp =
        await client.call('posts', 'post_comments', body: {'post': postId});
    final list = (resp.body as Map?)?['comments'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SocialPost.fromJson)
        .toList();
  }

  Future<void> commentPost(String postId, String body) async {
    await client
        .call('posts', 'post_comment', body: {'post': postId, 'body': body});
  }

  Future<List<SocialPost>> fetchUserPosts(String userId,
      {int limit = 50, int offset = 0}) async {
    final resp = await client.call('posts', 'post_user_posts', body: {
      'user': userId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['posts'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SocialPost.fromJson)
        .toList();
  }

  /// Aggregate the private posts of every workspace the signed-in user is a
  /// member of (the "Spaces" feed).
  Future<List<SocialPost>> fetchSpacesFeed(
      {int limit = 30, int offset = 0}) async {
    final resp = await client.call('posts', 'spaces_feed', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['posts'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SocialPost.fromJson)
        .toList();
  }

  // ── market ────────────────────────────────────────────────────────────────

  Future<List<MarketListing>> fetchMarket(
      {String? type, String? query, int limit = 50, int offset = 0}) async {
    final resp = await client.call('market', 'list', body: {
      if (type != null && type.isNotEmpty) 'type': type,
      if (query != null && query.isNotEmpty) 'query': query,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['items'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MarketListing.fromJson)
        .toList();
  }

  Future<MarketListing> fetchMarketItem(String listingId) async {
    final resp =
        await client.call('market', 'get', body: {'listing': listingId});
    return MarketListing.fromJson(resp.body as Map<String, dynamic>);
  }

  Future<String> publishListing({
    required String botId,
    required String type,
    required String name,
    String description = '',
    int price = 0,
    String category = '',
  }) async {
    final resp = await client.call('market', 'publish', body: {
      'bot': botId,
      'type': type,
      'name': name,
      'description': description,
      'price': price,
      'category': category,
    });
    return ((resp.body as Map?)?['listing_id'] as String?) ?? '';
  }

  Future<void> unpublishListing(String listingId) async {
    await client.call('market', 'unpublish', body: {'listing': listingId});
  }

  Future<List<MarketListing>> fetchMyListings() async {
    final resp = await client.call('market', 'my_listings');
    final list = (resp.body as Map?)?['items'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(MarketListing.fromJson)
        .toList();
  }

  /// Install a listing into a workspace (adds the bot to the space).
  Future<String> installListing(String listingId, {String? spaceId}) async {
    final resp = await client.call('market', 'install', body: {
      'listing': listingId,
      if (spaceId != null && spaceId.isNotEmpty) 'space': spaceId,
    });
    return ((resp.body as Map?)?['bot_id'] as String?) ?? '';
  }

  // ── wallet ────────────────────────────────────────────────────────────────

  Future<Wallet> fetchWallet() async {
    final resp = await client.call('finance', 'wallet_get');
    return Wallet.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Claim demo credits from the rate-limited faucet.
  Future<int> claimFaucet() async {
    final resp = await client.call('finance', 'faucet');
    return ((resp.body as Map?)?['amount'] as num?)?.toInt() ?? 0;
  }

  /// Ledger entries (ordered newest first).
  Future<List<Map<String, dynamic>>> fetchLedger(
      {int limit = 50, int offset = 0}) async {
    final resp = await client.call('finance', 'ledger_list', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['entries'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Transfer credits to another account.
  Future<void> transferCredits(String toId, int amount) async {
    await client
        .call('finance', 'transfer', body: {'to': toId, 'amount': amount});
  }

  // ── accounts ──────────────────────────────────────────────────────────────

  Future<AccountSummary> fetchAccount(String id) async {
    final resp =
        await client.call('users', 'account_get', body: {'account': id});
    return AccountSummary.fromJson(resp.body as Map<String, dynamic>);
  }

  /// List files uploaded to a space/room.
  Future<List<Map<String, dynamic>>> fetchFiles(String spaceId,
      {String? roomId, int limit = 100, int offset = 0}) async {
    final resp = await client.call('spaces', 'file_list', body: {
      'space': spaceId,
      if (roomId != null && roomId.isNotEmpty) 'room': roomId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['files'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Search accounts by handle/email.
  Future<List<AccountSummary>> searchUsers(String query,
      {int limit = 20, int offset = 0}) async {
    final resp = await client.call('users', 'search', body: {
      'query': query,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['users'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AccountSummary.fromJson)
        .toList();
  }

  // ── entity profiles ────────────────────────────────────────────────────────

  /// Rich user/account profile (metadata, follow counts, relationship).
  Future<UserProfile> fetchUserProfile(String accountId) async {
    final resp =
        await client.call('users', 'account_get', body: {'account': accountId});
    return UserProfile.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Follow an account.
  Future<void> followUser(String accountId) async {
    await client.call('users', 'follow', body: {'account': accountId});
  }

  /// Unfollow an account.
  Future<void> unfollowUser(String accountId) async {
    await client.call('users', 'unfollow', body: {'account': accountId});
  }

  /// Accounts an account follows.
  Future<List<AccountSummary>> fetchFollowing(
      {String? accountId, int limit = 50, int offset = 0}) async {
    final resp = await client.call('users', 'following_list', body: {
      if (accountId != null && accountId.isNotEmpty) 'account': accountId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['users'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AccountSummary.fromJson)
        .toList();
  }

  /// Accounts following an account.
  Future<List<AccountSummary>> fetchFollowers(
      {String? accountId, int limit = 50, int offset = 0}) async {
    final resp = await client.call('users', 'followers_list', body: {
      if (accountId != null && accountId.isNotEmpty) 'account': accountId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['users'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(AccountSummary.fromJson)
        .toList();
  }

  /// Rich agent/miniapp/tool profile (description, resources, usage, entities,
  /// marketplace listing).
  Future<BotProfile> fetchBotProfile(String botId) async {
    final resp = await client.call('bots', 'bot_profile', body: {'bot': botId});
    return BotProfile.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Rich workspace profile (members, rooms, agents, posts, files).
  Future<SpaceProfile> fetchSpaceProfile(String spaceId) async {
    final resp =
        await client.call('spaces', 'space_profile', body: {'space': spaceId});
    return SpaceProfile.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Rolled-up LLM token usage of a space, grouped per room and per agent
  /// (`usage.summary`).
  Future<Map<String, dynamic>> fetchUsageSummary(String spaceId,
      {int limit = 200}) async {
    final resp = await client.call('usage', 'summary', body: {
      'space': spaceId,
      'limit': limit,
    });
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Raw LLM token usage events of a space, optionally filtered by room/bot
  /// (`usage.list`), newest first.
  Future<List<Map<String, dynamic>>> fetchUsageList(String spaceId,
      {String roomId = '',
      String botId = '',
      int limit = 50,
      int offset = 0}) async {
    final resp = await client.call('usage', 'list', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      if (botId.isNotEmpty) 'bot': botId,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['usages'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Rich room profile (members, agents, messages, files, recent activity).
  Future<RoomProfile> fetchRoomProfile(String roomId) async {
    final resp =
        await client.call('spaces', 'room_profile', body: {'room': roomId});
    return RoomProfile.fromJson(resp.body as Map<String, dynamic>);
  }

  /// Join a public workspace (or accept a pending invitation).
  Future<void> joinSpace(String spaceId) async {
    await client.call('spaces', 'join', body: {'space': spaceId});
  }

  // ── per-room routines (task timing) ───────────────────────────────────────

  /// Create a delayed or periodic routine in a room.
  Future<Map<String, dynamic>> createRoutine(
    String spaceId, {
    String roomId = '',
    String name = '',
    required String type, // delayed | periodic
    String target = '',
    required String task,
    int delaySec = 0,
    int intervalSec = 0,
  }) async {
    final resp = await client.call('routines', 'create', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
      if (name.isNotEmpty) 'name': name,
      'type': type,
      if (target.isNotEmpty) 'target': target,
      'task': task,
      if (delaySec > 0) 'delay_sec': delaySec,
      if (intervalSec > 0) 'interval_sec': intervalSec,
    });
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// List the routines of a room.
  Future<List<Map<String, dynamic>>> fetchRoutines(String spaceId,
      {String roomId = ''}) async {
    final resp = await client.call('routines', 'list', body: {
      'space': spaceId,
      if (roomId.isNotEmpty) 'room': roomId,
    });
    final list = (resp.body as Map?)?['routines'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Update a routine's task/timing.
  Future<Map<String, dynamic>> updateRoutine(
    String routineId, {
    String name = '',
    String target = '',
    String task = '',
    int delaySec = 0,
    int intervalSec = 0,
  }) async {
    final resp = await client.call('routines', 'update', body: {
      'routine': routineId,
      if (name.isNotEmpty) 'name': name,
      if (target.isNotEmpty) 'target': target,
      if (task.isNotEmpty) 'task': task,
      if (delaySec > 0) 'delay_sec': delaySec,
      if (intervalSec > 0) 'interval_sec': intervalSec,
    });
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Delete a routine.
  Future<void> deleteRoutine(String routineId) async {
    await client.call('routines', 'delete', body: {'routine': routineId});
  }

  /// Pause / resume a routine.
  Future<void> setRoutineStatus(String routineId, bool paused) async {
    await client.call('routines', paused ? 'pause' : 'resume',
        body: {'routine': routineId});
  }

  /// Search top-level posts by body text.
  Future<List<SocialPost>> searchPosts(String query,
      {int limit = 20, int offset = 0}) async {
    final resp = await client.call('posts', 'post_search', body: {
      'query': query,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['posts'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SocialPost.fromJson)
        .toList();
  }

  /// Top post authors by engagement.
  Future<List<Map<String, dynamic>>> fetchLeaderboard({int limit = 10}) async {
    final resp =
        await client.call('posts', 'leaderboard', body: {'limit': limit});
    final list = (resp.body as Map?)?['leaderboard'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// The traders leaderboard the admins space's evaluator tool keeps: traders
  /// ranked by the reliability scores it measured from their CoinMarketCap
  /// posts. [board] is overall, technical, fundamental, accuracy,
  /// consistency, risk or timing.
  Future<Map<String, dynamic>> fetchTraderLeaderboard(
      {String board = 'overall', int limit = 100}) async {
    final resp = await client.call('tools', 'traders_leaderboard',
        body: {'board': board, 'limit': limit});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// One trader's full reliability report from the evaluator.
  Future<Map<String, dynamic>> fetchTraderProfile(String handle) async {
    final resp =
        await client.call('tools', 'trader_profile', body: {'handle': handle});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Admin: runs one of the admins space evaluator's admin microtools
  /// (trader_credentials, trader_remove, …) in the admins space and returns
  /// its result. Throws the evaluator's message when it reports an error.
  Future<Map<String, dynamic>> evaluatorAdmin(
      String function, Map<String, dynamic> payload) async {
    final admins = (await client.call('spaces', 'admins_space_get')).body;
    final space = ((admins as Map?)?['space'] as Map?)?['id'] as String?;
    if (space == null || space.isEmpty) {
      throw const ApiException('NOT_FOUND', 'No admins space is chosen.',
          status: 404);
    }
    final bots =
        (await client.call('spaces', 'bots_list', body: {'space': space})).body;
    final evaluator = ((bots as Map?)?['bots'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .firstWhere(
            (b) =>
                '${b['name']}'.toLowerCase() == 'evaluator' &&
                b['kind'] == 'tool',
            orElse: () => const <String, dynamic>{});
    if (evaluator['id'] == null) {
      throw const ApiException(
          'NOT_FOUND', 'The admins space has no evaluator tool.',
          status: 404);
    }
    final resp = await client.call('tools', 'invoke',
        body: {
          'bot': evaluator['id'],
          'space': space,
          'function': function,
          'payload': payload,
        },
        requestTimeout: const Duration(minutes: 2));
    final result = ((resp.body as Map?)?['result'] as Map?) ?? const {};
    if (result['isError'] == true) {
      final text = (result['content'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((c) => '${c['text'] ?? ''}')
          .join(' ');
      throw ApiException(
          'TOOL_ERROR', text.isEmpty ? 'The evaluator failed.' : text,
          status: 400);
    }
    final value = result['structuredContent'] ?? result;
    return value is Map ? value.cast<String, dynamic>() : const {};
  }

  // ── metadata / preferences ───────────────────────────────────────────────

  /// Load the signed-in user's metadata tree (for preferences/profile edits).
  Future<Map<String, dynamic>> fetchMyMetadata() async {
    final me = session?.accountId ?? '';
    if (me.isEmpty) return const {};
    final resp =
        await client.call('users', 'metadata_view', body: {'account': me});
    final m = resp.body as Map<String, dynamic>;
    final tree = m['tree'];
    return tree is Map<String, dynamic> ? tree : const {};
  }

  /// Apply a JSON patch to the signed-in user's metadata.
  Future<void> updateMetadata(List<Map<String, dynamic>> patch) async {
    await client.call('users', 'metadata_patch', body: {'patch': patch});
  }

  // ── admin / telemetry ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> adminTelemetry() async {
    final resp = await client.call('admin', 'telemetry');
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<List<Map<String, dynamic>>> adminPlugins() async {
    final resp = await client.call('admin', 'plugins_list');
    final list = (resp.body as Map?)?['plugins'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  Future<Map<String, dynamic>> adminActions() async {
    final resp = await client.call('admin', 'actions_list');
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  // ── LLM providers ─────────────────────────────────────────────────────────

  /// LLM providers configured by the node admin (keys masked). Admin only.
  Future<List<LlmProvider>> adminLlmProviders() async {
    final resp = await client.call('llm', 'llm_providers_list');
    final list = (resp.body as Map?)?['providers'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(LlmProvider.fromJson)
        .toList();
  }

  /// Supported provider kinds with their default endpoints. Admin only.
  Future<List<LlmKind>> adminLlmKinds() async {
    final resp = await client.call('llm', 'llm_kinds');
    final list = (resp.body as Map?)?['kinds'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(LlmKind.fromJson)
        .toList();
  }

  /// Create or update an LLM provider. An empty [apiKey] on update keeps the
  /// stored key.
  Future<LlmProvider> adminSetLlmProvider({
    String? id,
    required String name,
    required String kind,
    String baseUrl = '',
    String apiKey = '',
    bool enabled = true,
    bool isDefault = false,
    required List<LlmModel> models,
    String imageModel = '',
    double imagePrice = 0,
  }) async {
    final resp = await client.call('llm', 'llm_provider_set', body: {
      if (id != null && id.isNotEmpty) 'id': id,
      'name': name,
      'kind': kind,
      if (baseUrl.isNotEmpty) 'base_url': baseUrl,
      if (apiKey.isNotEmpty) 'api_key': apiKey,
      'enabled': enabled,
      'is_default': isDefault,
      'models': [for (final m in models) m.toJson()],
      'image_model': imageModel,
      'image_price': imagePrice,
    });
    final m = (resp.body as Map?)?['provider'];
    return LlmProvider.fromJson((m as Map).cast<String, dynamic>());
  }

  Future<void> adminDeleteLlmProvider(String id) async {
    await client.call('llm', 'llm_provider_delete', body: {'id': id});
  }

  /// The LLM providers + models agents can use as their backbone, with token
  /// prices (credits per 1M tokens). Available to every user.
  Future<List<LlmProvider>> fetchLlmCatalog() async {
    final resp = await client.call('llm', 'llm_models');
    final list = (resp.body as Map?)?['providers'] as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(LlmProvider.fromJson)
        .toList();
  }

  // ── legacy TraderaService surface (kept for compatibility) ─────────────

  @override
  Future<List<MarketQuote>> fetchMarketQuotes() async {
    try {
      final listings = await fetchMarket(limit: 6);
      const colors = [
        AppColors.warning,
        AppColors.primary,
        AppColors.success,
        AppColors.danger,
        Color(0xFF8497FF),
        AppColors.cyan,
      ];
      return [
        for (var i = 0; i < listings.length; i++)
          MarketQuote(
            symbol: listings[i].name.length > 4
                ? listings[i].name.substring(0, 4).toUpperCase()
                : listings[i].name.toUpperCase(),
            price: '${listings[i].installs} installs',
            change: (listings[i].installs % 10) * 0.4,
            color: colors[i % colors.length],
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Room>> fetchRooms() async {
    try {
      final spaces = await fetchSpaces();
      final rooms = <Room>[];
      for (final sp in spaces.take(3)) {
        final list = await fetchRoomsForSpace(sp.id);
        for (final r in list.take(3)) {
          rooms.add(Room(
            name: r.name,
            members: '${sp.name}',
            status: 'online',
          ));
        }
      }
      return rooms;
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<Message>> fetchMessages(String roomId) async {
    try {
      final packets = await fetchPackets();
      return [
        for (final p in packets.take(40))
          if (p.body.trim().isNotEmpty)
            Message(
              author:
                  p.fromId.length > 6 ? '@${p.fromId.substring(0, 6)}' : 'user',
              body: p.body,
              sentAt: p.repliedAt?.toIso8601String() ?? 'now',
            ),
      ];
    } catch (_) {
      return const [];
    }
  }
}
