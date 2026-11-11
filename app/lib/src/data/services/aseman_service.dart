import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/network/api_client.dart';
import '../../core/network/session_store.dart';
import '../../core/platform/platform_mode.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/models/market_quote.dart';
import '../../domain/models/message.dart';
import '../../domain/models/room.dart';
import '../../features/rooms/domain/room_work.dart';
import '../../features/tools/domain/widget_dsl.dart';
import '../models/app_notification.dart';
import '../models/bot.dart';
import '../models/llm_provider.dart';
import '../models/post.dart';
import '../models/profile.dart';
import '../models/space.dart';
import '../models/theme_pack_remote.dart';
import '../models/uploaded_file.dart';
import 'backend_capabilities.dart';
import 'backend_service.dart';

export '../models/theme_pack_remote.dart';

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

/// The real, server-backed implementation of [AsemanService]. All calls go
/// through the signed Aseman gateway, so every action runs with the signed
/// in user's identity — including app backend asks.
class AsemanService implements BackendService {
  AsemanService(this.client);

  final AsemanApiClient client;

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
          'Action is not part of the Aseman client contract');
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

  /// [inviteCode]: needed while the node takes new people by invitation only
  /// (`auth.config` `signup: invite`).
  Future<Session> register({
    required String handle,
    required String email,
    required String password,
    String inviteCode = '',
  }) async {
    final resp = await client.call('auth', 'register', body: {
      'handle': handle,
      'email': email,
      'password': password,
      if (inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
      ...PlatformMode.authField,
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
      ...PlatformMode.authField,
    });
    return _adopt(_sessionFrom(resp.body as Map<String, dynamic>));
  }

  /// [inviteCode] lets a first Google or Apple sign-in make an account while
  /// the node is by invitation.
  Future<Session> oauth(String provider, String identityToken,
      {String inviteCode = ''}) async {
    if (provider != 'google' && provider != 'apple') {
      throw ArgumentError.value(provider, 'provider');
    }
    final response = await client.call('auth', 'oauth_$provider', body: {
      if (provider == 'google') 'id_token': identityToken,
      if (provider == 'apple') 'identity_token': identityToken,
      if (inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
      ...PlatformMode.authField,
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
      ...PlatformMode.authField,
    });
    final token = result['token'] as String? ?? '';
    if (token.isEmpty) return null;
    return _adopt(_sessionFrom(result));
  }

  /// Trades a single sign-on handoff for a session (once).
  Future<Session> ssoComplete(String handoff) async {
    final result =
        await actionMap('enterprise', 'sso_complete', body: {'handoff': handoff});
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

  /// The platform this client is for (see [PlatformMode]): its name and
  /// published frontend. Needs no sign-in.
  Future<PlatformInfo> platformInfo([String? slug]) async {
    final result = await actionMap('developer', 'platform_frontend',
        body: {'platform': slug ?? PlatformMode.slug});
    return PlatformInfo.fromJson(result);
  }

  /// Wakes the computer behind platform [slug]'s published frontend and
  /// reports `{state, ready, error, retry_after_ms}`, waiting up to [wait] for
  /// the wake to finish. Anyone may wake it, so it carries no session.
  Future<Map<String, dynamic>> platformWake(String slug,
      {Duration wait = const Duration(seconds: 15)}) async {
    final base = client.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final res = await http
        .post(Uri.parse(
            '$base/v1/platforms/$slug/app/_decillion/wake?wait=${wait.inSeconds}'))
        .timeout(wait + const Duration(seconds: 30));
    final decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    final map =
        decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (res.statusCode >= 400) {
      throw ApiException('${map['code'] ?? 'ERROR'}',
          '${map['error'] ?? 'The platform could not be woken'}',
          status: res.statusCode);
    }
    return map;
  }

  static Session _sessionFrom(Map<String, dynamic> json) => Session(
        platformId: json['platform_id'] as String? ?? '',
        accountId: json['account_id'] as String? ?? '',
        handle: json['handle'] as String? ?? '',
        token: json['token'] as String? ?? '',
        privateKey: json['private_key'] as String? ?? '',
        publicKey: json['public_key'] as String? ?? '',
        homeSpaceId: json['home_space_id'] as String? ?? '',
      );

  // ── spaces ────────────────────────────────────────────────────────────────

  /// The latest notifications of the signed-in user, newest first, and how
  /// many of them are unread.
  Future<({List<AppNotification> items, int unread})> fetchNotifications(
      {int limit = 30}) async {
    final resp = await client.call('users', 'notifications_list',
        body: {'limit': limit});
    final body = (resp.body as Map?) ?? const {};
    final list = body['notifications'] as List? ?? const [];
    return (
      items: list
          .whereType<Map<String, dynamic>>()
          .map(AppNotification.fromJson)
          .toList(),
      unread: (body['unread'] as num?)?.toInt() ?? 0,
    );
  }

  /// Marks every notification of the signed-in user read.
  Future<void> markNotificationsRead() async {
    await client.call('users', 'notifications_read');
  }

  Future<List<Workspace>> fetchSpaces({int limit = 100, int offset = 0}) async {
    final resp = await client.call('spaces', 'space_list', body: {
      'kind': 'workspace',
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
      avatar: m['avatar'] as String? ?? '',
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

  /// Create a room. One made for something ([purpose], with an [icon] and a
  /// [color]) is greeted by the lead with three things to start on.
  Future<WorkspaceRoom> createRoom(String spaceId, String name, String topic,
      {String purpose = '', String icon = '', String color = ''}) async {
    final resp = await client.call('spaces', 'room_create', body: {
      'space': spaceId,
      'name': name,
      'topic': topic,
      if (purpose.isNotEmpty) 'purpose': purpose,
      if (icon.isNotEmpty) 'icon': icon,
      if (color.isNotEmpty) 'color': color,
    });
    final m = resp.body as Map<String, dynamic>;
    return WorkspaceRoom(
      id: m['room_id'] as String? ?? '',
      spaceId: spaceId,
      name: name,
      topic: topic,
      purpose: purpose,
      icon: icon,
      color: color,
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
  /// rooms of their projects. [kind] narrows it to "direct" or "room";
  /// [query] keeps the chats whose other side (or room) is named like it.
  Future<List<ChatSummary>> fetchChats(
      {String kind = '', String query = ''}) async {
    final resp = await client.call('spaces', 'chat_list', body: {
      if (kind.isNotEmpty) 'kind': kind,
      if (query.isNotEmpty) 'query': query,
    });
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

  /// Opens the caller's personal Aseman chat — also their home workspace.
  Future<ChatSummary> openSaved() async {
    final resp = await client.call('spaces', 'direct_open',
        body: {'peer': session?.accountId ?? ''});
    final m = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return ChatSummary.fromJson(
        {...m, 'kind': 'direct', 'saved': true, 'home': true});
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

  // ── room threads ──────────────────────────────────────────────────────────

  /// A room's conversation threads: its main thread (the room itself) and
  /// the threads opened in it, most recently active first.
  Future<({RoomThread main, List<RoomThread> threads})> fetchRoomThreads(
      String spaceId, String roomId) async {
    final resp = await client.call('spaces', 'thread_list',
        body: {'space': spaceId, 'room': roomId});
    final body = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    final main = (body['main'] as Map?)?.cast<String, dynamic>() ??
        {'id': body['room'] ?? roomId, 'title': 'Main'};
    return (
      main: RoomThread.fromJson(main, isMain: true),
      threads: (body['threads'] as List? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .map((t) => RoomThread.fromJson(t.cast<String, dynamic>()))
          .toList(),
    );
  }

  /// Opens a new thread in a room; it is named after its first message
  /// unless [title] names it.
  Future<RoomThread> createRoomThread(String spaceId, String roomId,
      {String title = ''}) async {
    final resp = await client.call('spaces', 'thread_create', body: {
      'space': spaceId,
      'room': roomId,
      if (title.trim().isNotEmpty) 'title': title.trim(),
    });
    final body = (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
    return RoomThread.fromJson(
        (body['thread'] as Map?)?.cast<String, dynamic>() ?? const {});
  }

  Future<void> renameRoomThread(String threadId, String title) async {
    await client.call('spaces', 'thread_rename',
        body: {'thread': threadId, 'title': title});
  }

  /// Deletes a thread with its messages (and the agents' context of it).
  Future<void> deleteRoomThread(String threadId) async {
    await client.call('spaces', 'thread_delete', body: {'thread': threadId});
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

  // ── MCP tool connections ──────────────────────────────────────────────────

  /// Starts signing in to an MCP server (OAuth with PKCE). The node finds the
  /// server's sign-in and registers itself where it can; the app only opens
  /// the returned `authorization_url`. With [bot], the OAuth client a node
  /// admin saved for that server is used, and its URL when [url] is empty.
  /// `needs_client` means the provider wants a client someone creates.
  Future<Map<String, dynamic>> mcpOAuthPrepare(
      {String url = '',
      String bot = '',
      required String redirectUri,
      String clientId = '',
      String clientSecret = ''}) async {
    final resp = await client.call('tools', 'oauth_prepare', body: {
      if (url.isNotEmpty) 'url': url,
      if (bot.isNotEmpty) 'bot': bot,
      'redirect_uri': redirectUri,
      if (clientId.isNotEmpty) 'client_id': clientId,
      if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
    });
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Trades the code the provider sent back for tokens; the node keeps them
  /// with the sign-in ([state]) so a connection made from it renews itself.
  Future<Map<String, dynamic>> mcpOAuthExchange(
      String state, String code) async {
    final resp = await client
        .call('tools', 'oauth_exchange', body: {'state': state, 'code': code});
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Stores the caller's own connection to a per-person tool in a project:
  /// from a completed sign-in ([grant], its state) or a pasted [token].
  Future<bool> setToolConnection(String botId, String spaceId,
      {String token = '', String grant = ''}) async {
    final resp = await client.call('tools', 'connection_set', body: {
      'bot': botId,
      'space': spaceId,
      if (token.isNotEmpty) 'token': token,
      if (grant.isNotEmpty) 'grant': grant,
    });
    return (resp.body as Map?)?['connected'] == true;
  }

  /// Whether a tool needs each person's own account ("user") and whether the
  /// caller connected theirs in the project. A tool that is not an MCP
  /// server reads as shared and connected.
  Future<({String auth, bool connected, String name})> toolConnection(
      String botId, String spaceId) async {
    final resp = await client
        .call('tools', 'commands_list', body: {'bot': botId, 'space': spaceId});
    final m = (resp.body as Map?) ?? const {};
    return (
      auth: '${m['auth'] ?? ''}',
      connected: m['connected'] != false,
      name: '${m['name'] ?? ''}',
    );
  }

  /// How a person connects their own account to a connector app (Google, a
  /// broker like Composio): its `connect` description ({namespace, start,
  /// status, disconnect} or {url}), or null for any other app.
  Future<Map<String, dynamic>?> appAccount(String botId, String spaceId) async {
    final resp = await client
        .call('tools', 'commands_list', body: {'bot': botId, 'space': spaceId});
    final m = (resp.body as Map?) ?? const {};
    final connect = m['connect'];
    if (m['auth'] != 'account' || connect is! Map) return null;
    return connect.cast<String, dynamic>();
  }

  /// Every tool's connection state in a project, by bot id.
  Future<Map<String, ({String auth, bool connected, String name})>>
      toolConnections(String spaceId) async {
    final resp =
        await client.call('tools', 'commands_list', body: {'space': spaceId});
    final list = (resp.body as Map?)?['tools'] as List? ?? const [];
    return {
      for (final t in list)
        if (t is Map)
          '${t['bot_id']}': (
            auth: '${t['auth'] ?? ''}',
            connected: t['connected'] != false,
            name: '${t['name'] ?? ''}',
          ),
    };
  }

  /// The MCP apps the caller can add to a space: their own and those the
  /// node's admins listed for everyone (`tools.commands_list`).
  Future<List<({String id, String name, String auth, String avatar})>> mcpCatalog() async {
    final resp = await client.call('tools', 'commands_list');
    final list = (resp.body as Map?)?['tools'] as List? ?? const [];
    return [
      for (final t in list)
        if (t is Map)
          (
            id: '${t['bot_id']}',
            name: '${t['name'] ?? ''}',
            auth: '${t['auth'] ?? ''}',
            avatar: '${t['avatar'] ?? ''}'
          ),
    ];
  }

  /// Registers a remote MCP server as a tool the caller owns. With [auth]
  /// "user" each person connects their own account and the node does not
  /// call the server now; otherwise it checks that the server answers.
  /// Returns the new tool's bot id.
  Future<String> mcpRegister(
      {required String name,
      required String url,
      String auth = '',
      String token = '',
      Map<String, dynamic> descriptor = const {}}) async {
    final resp = await client.call('tools', 'mcp_register',
        body: {
          'name': name,
          'url': url,
          if (auth.isNotEmpty) 'auth': auth,
          if (token.isNotEmpty) 'token': token,
          if (descriptor.isNotEmpty) 'descriptor': descriptor,
        },
        requestTimeout: const Duration(minutes: 1));
    return '${(resp.body as Map?)?['bot_id'] ?? ''}';
  }

  // ── developer API console ─────────────────────────────────────────────────

  /// One action of the developer console (`developer.<action>`), signed in
  /// as the person; [body] usually names the organization ("org").
  Future<Map<String, dynamic>> developer(String action,
      [Map<String, dynamic> body = const {}]) async {
    final resp = await client.call('developer', action,
        body: body, requestTimeout: const Duration(minutes: 3));
    return (resp.body as Map?)?.cast<String, dynamic>() ?? const {};
  }

  // ── talent requests ───────────────────────────────────────────────────────

  /// The jobs the caller posted for talent, newest first.
  Future<List<Map<String, dynamic>>> fetchTalentRequests() async {
    final resp = await client.call('talent', 'request_list');
    final list = (resp.body as Map?)?['requests'] as List? ?? const [];
    return list.whereType<Map<String, dynamic>>().toList().reversed.toList();
  }

  /// Posts a request for talent (`talent.request_create`).
  Future<Map<String, dynamic>> createTalentRequest(
      Map<String, dynamic> input) async {
    final resp = await client.call('talent', 'request_create', body: input);
    return ((resp.body as Map?)?['request'] as Map?)?.cast<String, dynamic>() ??
        const {};
  }

  /// Closes ("closed") or reopens ("open") one of the caller's requests.
  Future<void> setTalentRequestStatus(String id, String status) async {
    await client
        .call('talent', 'request_status', body: {'id': id, 'status': status});
  }

  Future<void> deleteTalentRequest(String id) async {
    await client.call('talent', 'request_delete', body: {'id': id});
  }

  /// Records that the caller has read a space's conversation up to [at].
  Future<void> markSeen(String spaceId, DateTime at) async {
    await client.call('spaces', 'seen_set',
        body: {'space': spaceId, 'at': at.toUtc().toIso8601String()});
  }

  // ── room messages ─────────────────────────────────────────────────────────

  /// A room's newest messages, or the page older than [before] (a message's
  /// creation time). `spaces.message_list` pages with before/after cursors,
  /// not offsets; [hasMore] is true when older messages still exist.
  Future<
      ({
        List<RoomMessage> messages,
        String working,
        String workingDetail,
        bool hasMore
      })> fetchRoomMessages(String spaceId, String roomId,
      {int limit = 50, DateTime? before}) async {
    final resp = await client.call('spaces', 'message_list', body: {
      'space': spaceId,
      'room': roomId,
      'limit': limit,
      if (before != null) 'before': before.toUtc().toIso8601String(),
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
      hasMore: body['has_more'] == true,
    );
  }

  /// A room's conversation for a chat page: messages plus who is typing and,
  /// for a direct chat, the peer's read cursor and whether anyone can write.
  /// Pass [before] to page further back through history.
  Future<RoomChatPage> fetchRoomChat(String spaceId, String roomId,
      {int limit = 50, DateTime? before}) async {
    final resp = await client.call('spaces', 'message_list', body: {
      'space': spaceId,
      'room': roomId,
      'limit': limit,
      if (before != null) 'before': before.toUtc().toIso8601String(),
    });
    return RoomChatPage.fromJson(
        (resp.body as Map?)?.cast<String, dynamic>() ?? const {});
  }

  /// Changes the text of a message the caller sent.
  Future<void> editRoomMessage(String messageId, String body) async {
    body = await hostMarkupMedia(body);
    await client.call('spaces', 'message_edit',
        body: {'message': messageId, 'body': body});
  }

  /// Earlier wording of an edited message (plus the current body).
  Future<MessageEditHistory> fetchMessageEdits(String messageId) async {
    final resp = await client
        .call('spaces', 'message_edits', body: {'message': messageId});
    return MessageEditHistory.fromJson(
        (resp.body as Map?)?.cast<String, dynamic>() ?? const {});
  }

  /// Deletes a message for everyone: the caller's own, or anyone's for a
  /// project's manager.
  Future<void> deleteRoomMessage(String spaceId, String messageId) async {
    await client.call('spaces', 'message_delete',
        body: {'space': spaceId, 'message': messageId});
  }

  // ── room work: agent turns ───────────────────────────────────────────────

  /// The project's agent work (newest first): runs live and queued now, and
  /// each run's history. Every room's; callers keep their own.
  Future<({List<WorkRun> live, List<WorkRun> queued, List<WorkEntry> entries})>
      roomWork(String spaceId, {int limit = 40}) async {
    final resp = await client
        .call('spaces', 'turn_log', body: {'space': spaceId, 'limit': limit});
    final body = (resp.body as Map?) ?? const {};
    List<Map<String, dynamic>> rows(String key) => [
          for (final r in (body[key] as List? ?? const []))
            if (r is Map) Map<String, dynamic>.from(r)
        ];
    return (
      live: rows('live').map(WorkRun.fromJson).toList(),
      queued: rows('queued').map(WorkRun.fromJson).toList(),
      entries: rows('entries').map(WorkEntry.fromJson).toList(),
    );
  }

  /// What the room's agents are doing now and the answers they are writing.
  /// Pass the last [seq] to wait (up to about 20 s) for the next change.
  Future<({int seq, List<LiveActivity> activity})> roomLive(
      String spaceId, String roomId,
      {int seq = 0}) async {
    final resp = await client.call('spaces', 'live',
        body: {'space': spaceId, 'room': roomId, if (seq > 0) 'seq': seq},
        requestTimeout: const Duration(seconds: 40));
    final body = (resp.body as Map?) ?? const {};
    return (
      seq: (body['seq'] as num?)?.toInt() ?? 0,
      activity: [
        for (final a in (body['activity'] as List? ?? const []))
          if (a is Map) LiveActivity.fromJson(Map<String, dynamic>.from(a))
      ],
    );
  }

  /// Stops a queued or running turn.
  Future<void> cancelTurn(String turnId) async {
    await client.call('spaces', 'turn_cancel', body: {'turn': turnId});
  }

  /// Runs an interrupted turn again, as it was.
  Future<void> resumeTurn(String turnId) async {
    await client.call('spaces', 'turn_resume',
        body: {'turn': turnId, 'verdict': 'not_executed'});
  }

  /// The questions the project's agents are waiting on people for.
  Future<List<AgentQuestion>> agentQuestions(String spaceId) async {
    final resp = await client
        .call('spaces', 'agent_questions', body: {'space': spaceId});
    return [
      for (final q in ((resp.body as Map?)?['questions'] as List? ?? const []))
        if (q is Map) AgentQuestion.fromJson(Map<String, dynamic>.from(q))
    ];
  }

  /// Answers an agent's question; the agent carries on with it.
  Future<void> answerAgent(
      String spaceId, AgentQuestion question, String answer) async {
    await client.call('spaces', 'agent_answer',
        body: {
          'space': spaceId,
          'room': question.roomId,
          'bot': question.botId,
          'question_id': question.id,
          'answer': answer,
        },
        requestTimeout: const Duration(minutes: 10));
  }

  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) async {
    body = await hostMarkupMedia(body);
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

  /// Turns a media address from post/message markup into a URL [Image.network]
  /// (and video/audio players) can load: a stored file id or `/v1/files/…`
  /// path becomes [fileContentUrl], a root-relative path is joined to the
  /// gateway, and http(s)/data URLs are left as they are.
  String resolveContentUrl(String ref) {
    ref = ref.trim();
    if (ref.isEmpty) return ref;
    final lower = ref.toLowerCase();
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('data:')) {
      return ref;
    }
    final fileId = RegExp(
            r'^(?:(?:attachment|file):/?/?|/v1/files/)?([0-9a-fA-F]{32})(?:/content)?(?:\?.*)?$')
        .firstMatch(ref)
        ?.group(1);
    if (fileId != null && !RegExp(r'^0+$').hasMatch(fileId)) {
      return fileContentUrl(fileId);
    }
    if (ref.startsWith('/')) {
      final base = client.baseUrl.replaceFirst(RegExp(r'/$'), '');
      return '$base$ref';
    }
    return ref;
  }

  /// Build the absolute gateway URL for a sandbox proxy path (e.g.
  /// `/v1/proxy/{id}/`, or a platform's frontend `/v1/platforms/{slug}/app/`). The session token is appended as a query parameter so
  /// a webview (which cannot reliably set Authorization headers on every
  /// platform) can authenticate against the gateway.
  String proxyUrl(String proxyPath) {
    final p = proxyPath.startsWith('/') ? proxyPath : '/$proxyPath';
    final path = Uri.parse(p);
    if (path.hasScheme ||
        path.hasAuthority ||
        !RegExp(r'^/v1/(proxy/[0-9a-fA-F]{32}|platforms/[a-z][a-z0-9-]{1,47}/app)/')
            .hasMatch(path.path) ||
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

  // ── avatars ──────────────────────────────────────────────────────────────

  /// Stores a picture chosen as an avatar and returns its file id. It is
  /// stored public (`users.file_upload`): an avatar is shown to everyone who
  /// can see the account, workspace, agent or app it stands for.
  Future<String> uploadAvatar({
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final resp = await client.call('users', 'file_upload', body: {
      'name': name,
      'mime': mime,
      'data': base64Encode(bytes),
      'public': true,
    });
    final id = '${(resp.body as Map?)?['file_id'] ?? ''}';
    if (id.isEmpty) {
      throw const ApiException(
          'UPLOAD_FAILED', 'The picture could not be stored');
    }
    return id;
  }

  /// Sets (a stored picture's id) or clears ("") the signed-in account's
  /// avatar (`auth.profile_update`).
  Future<void> setMyAvatar(String fileId) async {
    await client.call('auth', 'profile_update', body: {
      'profile': {'avatar': fileId},
    });
  }

  /// Sets or clears a workspace's avatar; its owner and admins may
  /// (`spaces.space_update`).
  Future<void> setSpaceAvatar(String spaceId, String fileId) async {
    await client.call('spaces', 'space_update',
        body: {'space': spaceId, 'avatar': fileId});
  }

  /// Sets or clears an agent's or an app's avatar; its owner may
  /// (`bots.bot_edit`).
  Future<void> setBotAvatar(String botId, String fileId) async {
    await client
        .call('bots', 'bot_edit', body: {'bot': botId, 'avatar': fileId});
  }

  /// The signed-in account's avatar (a file id), "" when it has none.
  Future<String> fetchMyAvatar() async {
    final profile = (await fetchMyMetadata())['profile'];
    return profile is Map ? '${profile['avatar'] ?? ''}'.trim() : '';
  }

  /// The picture an avatar reference points at: a stored file (its id or its
  /// `/v1/files/{id}/content` path) or a web address. Null when there is none.
  ImageProvider? avatarImage(String ref) {
    ref = ref.trim();
    if (ref.isEmpty) return null;
    if (ref.startsWith('http://') || ref.startsWith('https://')) {
      return NetworkImage(ref);
    }
    final id = RegExp(r'^(?:/v1/files/)?([0-9a-fA-F]{32})(?:/content)?$')
        .firstMatch(ref)
        ?.group(1);
    // A zero id is how the node writes "none".
    if (id == null || RegExp(r'^0+$').hasMatch(id)) return null;
    return NetworkImage(fileContentUrl(id), headers: authHeaders());
  }

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
    final file = UploadedFile.fromJson(m);
    if (bytes == null) return file;
    return UploadedFile(
      id: file.id,
      name: file.name,
      mime: file.mime,
      size: file.size,
      ownerId: file.ownerId,
      spaceId: file.spaceId,
      roomId: file.roomId,
      public: file.public,
      contentUrl: file.contentUrl,
      createdAt: file.createdAt,
      bytes: bytes,
      detail: file.detail,
      voice: file.voice,
      durationMs: file.durationMs,
      waveform: file.waveform,
      kept: file.kept,
    );
  }

  Future<List<UploadedFile>> _resolveAttachments(List<String> ids) async {
    if (ids.isEmpty) return const [];
    // Attached project folders ("folder:<id>") are the sender's shared folders.
    Map<String, Map<String, dynamic>> folders = const {};
    if (ids.any((id) => id.startsWith('folder:'))) {
      try {
        final list = (await actionMap('hostaccess', 'folders'))['folders'];
        folders = {
          if (list is List)
            for (final f in list)
              if (f is Map) 'folder:${f['id']}': f.cast<String, dynamic>(),
        };
      } catch (_) {}
    }
    final out = <UploadedFile>[];
    for (final id in ids) {
      if (id.startsWith('folder:')) {
        final f = folders[id] ?? const {};
        out.add(UploadedFile.fromJson({
          'id': id,
          'kind': 'folder',
          'mime': 'inode/directory',
          'name': f['name'] ?? 'Folder',
          'path': f['path'] == null ? null : '/workspace/${f['path']}',
          'access': f['access'],
        }));
        continue;
      }
      try {
        out.add(await fetchFile(id));
      } catch (_) {}
    }
    return out;
  }

  // ── bots / agents / apps ──────────────────────────────────────────────

  Future<List<Bot>> fetchBots({int limit = 100, int offset = 0}) async {
    final resp = await client.call('bots', 'bot_list', body: {
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    // Sandboxes are computers, not apps — never surface them in bot lists.
    return list
        .whereType<Map<String, dynamic>>()
        .map(Bot.fromJson)
        .where((b) => !b.isSandbox)
        .toList();
  }

  /// List the bots (agents and apps) installed in a space. Bots are only
  /// present here when explicitly added through [addBotToSpace]. The space
  /// sandbox is omitted: it is a computer, not an app.
  Future<List<Bot>> fetchSpaceBots(String spaceId) async {
    final resp =
        await client.call('spaces', 'bots_list', body: {'space': spaceId});
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((j) => Bot.fromJson({
              'id': j['id'],
              'owner_id': j['owner_id'] ?? '',
              'account_id': j['account_id'],
              'name': j['name'],
              'kind': j['kind'],
              'vm_type': j['vm_type'],
              'status': j['status'],
              'image_ref': j['image_ref'] ?? '',
              'has_frontend': j['has_frontend'] ?? false,
              'avatar': j['avatar'] ?? '',
              'humanoid': j['humanoid'],
            }))
        .where((b) => !b.isSandbox)
        .toList();
  }

  /// Add a bot (agent or app) to a space so it becomes available there.
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

  /// Chat with an agent or ask an app backend; returns the reply string.
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

  /// List the apps available to agents in a space (sandbox is sandbox_exec).
  Future<List<Map<String, dynamic>>> fetchSpaceTools(String spaceId,
      {String? roomId}) async {
    final resp = await client.call('spaces', 'tools_list', body: {
      'space': spaceId,
      if (roomId != null && roomId.isNotEmpty) 'room': roomId,
    });
    final list = (resp.body as Map?)?['tools'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Search agents and apps across the whole platform (paged). Sandbox
  /// instances are never returned as apps.
  Future<List<Map<String, dynamic>>> searchBots(String query,
      {String kind = '', int limit = 20, int offset = 0}) async {
    final resp = await client.call('bots', 'bot_search', body: {
      if (query.isNotEmpty) 'query': query,
      if (kind.isNotEmpty) 'kind': kind,
      'limit': limit,
      if (offset > 0) 'offset': offset,
    });
    final list = (resp.body as Map?)?['bots'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .where((b) => !Bot.fromJson({
              'id': b['id'],
              'owner_id': b['owner_id'] ?? '',
              'account_id': b['account_id'] ?? '',
              'name': b['name'],
              'kind': b['kind'],
              'vm_type': b['vm_type'],
              'status': b['status'] ?? '',
            }).isSandbox)
        .toList();
  }

  /// Members of a space (enriched with handle/kind/role), paged. [kind]
  /// keeps only `user` (people) or `bot` (agents and apps) members; empty
  /// lists everyone.
  Future<List<Map<String, dynamic>>> fetchSpaceMembers(String spaceId,
      {String kind = '', int limit = 50, int offset = 0}) async {
    final resp = await client.call('spaces', 'members_list', body: {
      'space': spaceId,
      if (kind.isNotEmpty) 'kind': kind,
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

  /// Fetch the live desk-widget DSLs of every app installed in a room.
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

  /// Run a widget action against an app's backend VM. The action is sent as
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

  /// Store the default desk-widget DSL of an app (used as a fallback when
  /// its backend VM cannot answer a live widget ask).
  Future<void> setBotWidget(String botId, String dsl) async {
    await putBotEntity(botId, BotEntityKeys.widgetDsl, dsl);
  }

  /// Read the stored default desk-widget DSL of an app.
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
      final liked = p.likedByMe || _likedBy(j['liked_by']).contains(me);
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

  /// Downloads every remote image/video/audio in [body] into Aseman storage
  /// (reusing the URL cache) and returns markup that only references hosted
  /// files. Call before publishing a designed post or message so previews and
  /// readers never hit the original link.
  Future<String> hostMarkupMedia(String body) async {
    if (body.trim().isEmpty) return body;
    final resp =
        await client.call('users', 'host_markup', body: {'body': body});
    final hosted = (resp.body as Map?)?['body'];
    return hosted is String && hosted.isNotEmpty ? hosted : body;
  }

  Future<SocialPost> createPost(String body,
      {String? spaceId, List<String> tags = const []}) async {
    body = await hostMarkupMedia(body);
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

  /// Edits one of the signed-in user's posts.
  Future<void> updatePost(String postId, String body) async {
    body = await hostMarkupMedia(body);
    await client
        .call('posts', 'post_update', body: {'post': postId, 'body': body});
  }

  /// Deletes one of the signed-in user's posts.
  Future<void> deletePost(String postId) async {
    await client.call('posts', 'post_delete', body: {'post': postId});
  }

  /// Shares [postId] into the global feed or, with [spaceId], the feed of a
  /// space the user is a member of; the shared post names its original
  /// author. Returns the new post's id.
  Future<String> forwardPost(String postId, {String? spaceId}) async {
    final resp = await client.call('posts', 'post_create', body: {
      'forward': postId,
      if (spaceId != null && spaceId.isNotEmpty) 'space': spaceId,
    });
    return (resp.body as Map?)?['post_id'] as String? ?? '';
  }

  /// Reports a post to the node's admins. [reason] is spam, harassment,
  /// abuse, scam, inappropriate or other.
  Future<void> reportPost(String postId,
      {required String reason, String note = ''}) async {
    await client.call('posts', 'post_report', body: {
      'post': postId,
      'reason': reason,
      if (note.trim().isNotEmpty) 'note': note.trim(),
    });
  }

  Future<void> likePost(String postId) async {
    await client.call('posts', 'post_like', body: {'post': postId});
  }

  Future<void> unlikePost(String postId) async {
    await client.call('posts', 'post_unlike', body: {'post': postId});
  }

  Future<List<SocialPost>> fetchComments(String postId,
      {int limit = 200}) async {
    final resp = await client.call('posts', 'post_comments',
        body: {'post': postId, 'limit': limit});
    final list = (resp.body as Map?)?['comments'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(SocialPost.fromJson)
        .toList();
  }

  /// Comments [body] on a post; returns the new comment's id.
  Future<String> commentPost(String postId, String body) async {
    final resp = await client
        .call('posts', 'post_comment', body: {'post': postId, 'body': body});
    return '${(resp.body as Map?)?['comment_id'] ?? ''}';
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

  /// Install a theme listing (applies the pack to the signed-in account).
  Future<void> installThemeListing(String listingId) async {
    await client.call('market', 'install', body: {'listing': listingId});
  }

  // ── themes ────────────────────────────────────────────────────────────────

  Future<CreatedTheme> createTheme({
    required String name,
    String description = '',
    required String packJson,
    bool publish = false,
  }) async {
    final resp = await client.call('themes', 'create', body: {
      'name': name,
      'description': description,
      'pack': packJson,
      'publish': publish,
    });
    final body = resp.body as Map? ?? {};
    return CreatedTheme(
      themeId: '${body['theme_id'] ?? ''}',
      listingId: '${body['listing_id'] ?? ''}',
      status: '${body['status'] ?? ''}',
    );
  }

  Future<ActiveThemePack?> fetchActiveTheme() async {
    final resp = await client.call('themes', 'active');
    final body = resp.body as Map? ?? {};
    if (body['active'] != true) return null;
    final raw = '${body['pack_json'] ?? ''}';
    if (raw.isEmpty) return null;
    return ActiveThemePack(
      themeId: '${body['theme_id'] ?? ''}',
      listingId: '${body['listing_id'] ?? ''}',
      packJson: raw,
    );
  }

  Future<void> applyTheme({String? themeId, String? listingId}) async {
    await client.call('themes', 'apply', body: {
      if (themeId != null && themeId.isNotEmpty) 'theme': themeId,
      if (listingId != null && listingId.isNotEmpty) 'listing': listingId,
    });
  }

  Future<void> uninstallActiveTheme() async {
    await client.call('themes', 'uninstall');
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

  /// How the node takes new people and signs them in (`auth.config`).
  Future<AuthConfig> authConfig() async =>
      AuthConfig.fromJson(await actionMap('auth', 'config'));

  /// Emails a one-time code that verifies [email]; returns how the node
  /// delivers it (`email`, or `log` on a node without mail).
  Future<String> sendVerification(String email) async {
    final out = await actionMap('auth', 'send_verification',
        body: {'email': email, ...PlatformMode.authField});
    return '${out['delivery'] ?? ''}';
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

  /// Search people (never agents or apps) by handle/email.
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

  /// Rich agent or app profile (description, resources, usage, entities,
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
      {bool following = false, int limit = 20, int offset = 0}) async {
    final resp = await client.call('posts', 'post_search', body: {
      'query': query,
      if (following) 'scope': 'following',
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

  // ── privacy / notifications ──────────────────────────────────────────

  Future<Map<String, dynamic>> privacyGet() =>
      actionMap('users', 'privacy_get');

  Future<Map<String, dynamic>> privacySet(Map<String, dynamic> prefs) =>
      actionMap('users', 'privacy_set', body: prefs);

  Future<Map<String, dynamic>> notifyPrefs() =>
      actionMap('users', 'notify_prefs');

  Future<Map<String, dynamic>> notifySet(
          {required String category, required bool enabled}) =>
      actionMap('users', 'notify_set',
          body: {'category': category, 'enabled': enabled});

  Future<Map<String, dynamic>> notifyMute({
    String space = '',
    String peer = '',
    required bool muted,
  }) =>
      actionMap('users', 'notify_mute', body: {
        if (space.isNotEmpty) 'space': space,
        if (peer.isNotEmpty) 'peer': peer,
        'muted': muted,
      });

  // ── Room message react / hide / keep (works in project rooms and DMs) ─

  /// React to a room message; empty [emoji] removes yours.
  Future<Map<String, dynamic>> messageReact(
    String spaceId,
    String messageId, {
    String emoji = '',
  }) =>
      actionMap('spaces', 'message_react', body: {
        'space': spaceId,
        'message': messageId,
        'emoji': emoji,
      });

  /// Hide a room message for the caller only.
  Future<Map<String, dynamic>> messageHide(String spaceId, String messageId) =>
      actionMap('spaces', 'message_hide', body: {
        'space': spaceId,
        'message': messageId,
      });

  /// Keep files of a room message in the caller's storage.
  Future<Map<String, dynamic>> messageKeep(
    String spaceId,
    String messageId, {
    String file = '',
  }) =>
      actionMap('spaces', 'message_keep', body: {
        'space': spaceId,
        'message': messageId,
        if (file.isNotEmpty) 'file': file,
      });

  Future<Map<String, dynamic>> storageUsage() =>
      actionMap('users', 'storage_usage');

  // ── calls ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> callStart(String to, {bool video = false}) =>
      actionMap('users', 'call_start', body: {'to': to, 'video': video});

  Future<Map<String, dynamic>> callAccept(String id) =>
      actionMap('users', 'call_accept', body: {'id': id});

  Future<Map<String, dynamic>> callDecline(String id) =>
      actionMap('users', 'call_decline', body: {'id': id});

  Future<Map<String, dynamic>> callEnd(String id) =>
      actionMap('users', 'call_end', body: {'id': id});

  Future<Map<String, dynamic>> callIncoming() =>
      actionMap('users', 'call_incoming');

  Future<Map<String, dynamic>> callPoll(String id, {String after = ''}) =>
      actionMap('users', 'call_poll',
          body: {'id': id, if (after.isNotEmpty) 'after': after});

  Future<Map<String, dynamic>> callSignal(
    String id, {
    required String kind,
    required String payload,
  }) =>
      actionMap('users', 'call_signal',
          body: {'id': id, 'kind': kind, 'payload': payload});

  // ── brain (personal Aseman chat) ─────────────────────────────────────

  Future<Map<String, dynamic>> brainConfirm(String message,
          {required bool approve}) =>
      actionMap('users', 'brain_confirm',
          body: {'message': message, 'approve': approve});

  Future<Map<String, dynamic>> brainRetry(String message) =>
      actionMap('users', 'brain_retry', body: {'message': message});

  Future<Map<String, dynamic>> brainRooms() =>
      actionMap('users', 'brain_rooms');

  Future<Map<String, dynamic>> brainRoomSet(String room,
          {required bool allowed}) =>
      actionMap('users', 'brain_room_set',
          body: {'room': room, 'allowed': allowed});

  Future<Map<String, dynamic>> brainMemoryGet() =>
      actionMap('users', 'brain_memory_get');

  Future<Map<String, dynamic>> brainMemorySet(Map<String, dynamic> body) =>
      actionMap('users', 'brain_memory_set', body: body);

  /// Saved-messages / self DM thread (brain proposals + agents_working).
  Future<Map<String, dynamic>> dmListSelf({int limit = 40}) {
    final me = session?.accountId ?? '';
    return actionMap('users', 'dm_list',
        body: {'peer': me, 'limit': limit});
  }

  /// Which live-voice roles the node has on ({speech, transcription, live}).
  Future<Map<String, dynamic>> voiceConfig() =>
      actionMap('users', 'voice_config');

  /// One spoken turn: mic audio in, transcript + reply + TTS audio out.
  Future<Map<String, dynamic>> voiceTurn({
    required List<int> audio,
    required String mime,
  }) =>
      actionMap('users', 'voice_turn', body: {
        'audio': base64Encode(audio),
        'mime': mime,
      });

  // ── credits / admin misc ─────────────────────────────────────────────

  Future<Map<String, dynamic>> creditRequest({
    required String reason,
    double amountUsd = 0,
  }) =>
      actionMap('finance', 'credit_request', body: {
        'reason': reason,
        if (amountUsd > 0) 'amount_usd': amountUsd,
      });

  Future<Map<String, dynamic>> creditRequestsMine() =>
      actionMap('finance', 'credit_requests_mine');

  Future<Map<String, dynamic>> adminAILog(
          {Map<String, dynamic> body = const {}}) =>
      actionMap('users', 'admin_ai_log', body: body);

  Future<Map<String, dynamic>> emailTemplates() =>
      actionMap('settings', 'email_templates');

  Future<Map<String, dynamic>> emailPreview(String key) =>
      actionMap('settings', 'email_preview', body: {'key': key});

  // ── BackendService home/market helpers ───────────────────────────────

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

/// How a node takes new people and signs them in (`auth.config`).
class AuthConfig {
  const AuthConfig({
    this.signup = 'open',
    this.emailVerify = false,
    this.google = false,
    this.googleClientId = '',
    this.apple = false,
  });

  factory AuthConfig.fromJson(Map<String, dynamic> json) => AuthConfig(
        signup: switch ('${json['signup'] ?? ''}'.trim().toLowerCase()) {
          'invite' => 'invite',
          'closed' => 'closed',
          _ => 'open',
        },
        emailVerify: json['email_verify'] == true,
        google: json['google'] == true,
        googleClientId: '${json['google_client_id'] ?? ''}'.trim(),
        apple: json['apple'] == true,
      );

  /// `open` (anyone), `invite` (only with an invite code) or `closed`.
  final String signup;

  /// A new account signs in only after its email is verified.
  final bool emailVerify;
  final bool google;
  final String googleClientId;
  final bool apple;

  bool get inviteOnly => signup == 'invite';
  bool get signupClosed => signup == 'closed';
}
