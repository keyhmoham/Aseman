import 'dart:typed_data';

import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/core/theme/app_colors.dart';
import 'package:tradera/src/data/models/bot.dart';
import 'package:tradera/src/data/models/post.dart';
import 'package:tradera/src/data/models/profile.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/data/models/uploaded_file.dart';
import 'package:tradera/src/data/services/tradera_service.dart';
import 'package:tradera/src/domain/models/market_quote.dart';
import 'package:tradera/src/domain/models/message.dart';
import 'package:tradera/src/domain/models/room.dart';
import 'package:tradera/src/features/rooms/domain/room_work.dart';
import 'package:tradera/src/features/tools/domain/widget_dsl.dart';

/// Deterministic in-memory `TraderaService` used by widget tests. It stands
/// in for the backend gateway so tests exercise the real UI with stable data,
/// with no network and no showcase fallbacks.
class FakeTraderaService extends TraderaService {
  FakeTraderaService({TraderaApiClient? client, this.admin = true})
      : super(client ?? TraderaApiClient(baseUrl: 'http://localhost:8080'));

  /// Whether `auth.me` reports the signed-in account as an admin.
  final bool admin;

  static const homeId = '00000000000000010000000000000002';
  static const atlasId = '00000000000000010000000000000003';
  static const sharedId = '00000000000000010000000000000005';

  final Map<String, dynamic> _spaceMeta = {};
  final Map<String, Map<String, String>> _botEntities = {};
  final Map<String, List<UploadedFile>> _files = {};
  final Set<String> _follows = {};
  int _fileSeq = 0;

  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
  }) async {
    if (namespace == 'auth' && action == 'me') {
      return {'id': 'me', 'handle': 'test', 'is_admin': admin};
    }
    if (namespace == 'auth' && action == 'config') {
      return const {
        'password': true,
        'google': false,
        'apple': false,
        'password_reset': true,
        'email_verify': true,
      };
    }
    return const <String, dynamic>{};
  }

  List<Workspace> _spaces = const [
    Workspace(id: homeId, ownerId: 'me', name: 'Home', home: true),
    Workspace(id: atlasId, ownerId: 'me', name: 'Atlas Capital'),
    Workspace(id: sharedId, ownerId: 'u1', name: 'Shared Desk'),
  ];

  @override
  Future<Workspace> createSpace(String name, String description) async {
    final id =
        '0000000000000001${DateTime.now().microsecondsSinceEpoch.toRadixString(16).padLeft(16, '0').substring(0, 16)}';
    final created = Workspace(id: id, ownerId: 'me', name: name, role: 'owner');
    _spaces = [..._spaces, created];
    return created;
  }

  @override
  Future<Workspace> fetchSpace(String spaceId) async =>
      _spaces.firstWhere((s) => s.id == spaceId, orElse: () => _spaces.first);

  @override
  Future<void> updateSpace(String spaceId,
      {String? name, String? description, bool? public}) async {
    _spaces = [
      for (final s in _spaces)
        if (s.id == spaceId)
          Workspace(
            id: s.id,
            ownerId: s.ownerId,
            name: name ?? s.name,
            description: description ?? s.description,
            public: public ?? s.public,
            home: s.home,
            role: s.role,
          )
        else
          s,
    ];
  }

  @override
  Future<void> deleteSpace(String spaceId) async {
    _spaces = _spaces.where((s) => s.id != spaceId).toList();
  }

  @override
  Future<void> leaveSpace(String spaceId) async {
    _spaces = _spaces.where((s) => s.id != spaceId).toList();
  }

  @override
  Future<String> inviteToSpace(String spaceId, String inviteeId,
          {String role = 'member'}) async =>
      'inv-1';

  @override
  Future<void> removeSpaceMember(String spaceId, String memberId) async {}

  @override
  Future<void> setMemberRole(
      String spaceId, String memberId, String role) async {}

  @override
  Future<void> deleteRoom(String roomId) async {}

  @override
  Future<void> putBotEntity(String botId, String key, String value,
      {String mime = '', bool base64 = false}) async {
    _botEntities.putIfAbsent(botId, () => <String, String>{})[key] = value;
  }

  @override
  Future<String> fetchBotEntity(String botId, String key) async =>
      _botEntities[botId]?[key] ?? '';

  @override
  Future<List<String>> listBotEntities(String botId) async =>
      (_botEntities[botId]?.keys ?? const <String>[]).toList();

  @override
  Future<void> deleteBotEntity(String botId, String key) async {
    _botEntities[botId]?.remove(key);
  }

  @override
  Future<Map<String, dynamic>> fetchSpaceMetadata(String spaceId) async =>
      Map<String, dynamic>.of(_spaceMeta);

  @override
  Future<void> patchSpaceMetadata(
      String spaceId, List<Map<String, dynamic>> patch) async {
    for (final op in patch) {
      if (op['op'] != 'set' || op['path'] is! String) continue;
      final segments =
          (op['path'] as String).split('/').where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) continue;
      var node = _spaceMeta;
      for (var i = 0; i < segments.length - 1; i++) {
        node =
            (node[segments[i]] ??= <String, dynamic>{}) as Map<String, dynamic>;
      }
      node[segments.last] = op['value'];
    }
  }

  @override
  Future<List<Workspace>> fetchSpaces(
          {int limit = 100, int offset = 0}) async =>
      List<Workspace>.of(_spaces);

  @override
  Future<List<WorkspaceRoom>> fetchRoomsForSpace(String spaceId,
          {int limit = 100, int offset = 0}) async =>
      switch (spaceId) {
        homeId => const [
            WorkspaceRoom(id: 'r1', spaceId: homeId, name: 'general'),
            WorkspaceRoom(id: 'r2', spaceId: homeId, name: 'Crypto Alpha'),
          ],
        atlasId => const [
            WorkspaceRoom(id: 'a1', spaceId: atlasId, name: 'general'),
            WorkspaceRoom(id: 'a2', spaceId: atlasId, name: 'Global Macro'),
          ],
        sharedId => const [
            WorkspaceRoom(id: 's1', spaceId: sharedId, name: 'general'),
          ],
        _ => const [],
      };

  @override
  Future<List<SocialPost>> fetchFeed(
      {bool following = false,
      String? spaceId,
      int limit = 50,
      int offset = 0}) async {
    if (following) return const [];
    if (spaceId != null && spaceId.isNotEmpty) {
      return spaceId == atlasId
          ? [
              SocialPost(
                id: 'ws-atlas',
                authorId: homeId,
                spaceId: atlasId,
                body: 'Private note inside Atlas Capital.',
                createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
                tags: const ['UPDATE'],
                likes: 4,
              ),
            ]
          : const <SocialPost>[];
    }
    return [
      SocialPost(
        id: 'p1',
        authorId: homeId,
        body: 'BTC consolidating above weekly VWAP.',
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        tags: const ['LONG', 'BTC'],
        likes: 12,
      ),
    ];
  }

  @override
  Future<List<SocialPost>> fetchSpacesFeed(
          {int limit = 30, int offset = 0}) async =>
      [
        SocialPost(
          id: 'ws1',
          authorId: homeId,
          spaceId: homeId,
          body: 'Private update inside the Home workspace.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
          tags: const ['UPDATE'],
          likes: 3,
        ),
      ];

  @override
  Future<List<SocialPost>> fetchUserPosts(String userId,
          {int limit = 50, int offset = 0}) async =>
      [
        SocialPost(
          id: 'mine1',
          authorId: userId,
          body: 'A post I wrote.',
          createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
          tags: const ['ME'],
          likes: 5,
        ),
      ];

  /// The evaluator's traders: two evaluated, one still queued.
  static const traders = [
    {
      'handle': 'daniel_crypto365',
      'name': 'Daniel Markson',
      'profile_link':
          'https://coinmarketcap.com/community/profile/daniel_crypto365/',
      'followers': 10975,
      'posts_analyzed': 38,
      'status': 'done',
      'rating': 'Advanced',
      'change': 2.5,
      'last_evaluated_at': '2026-10-14T10:00:00+00:00',
      'platform_account': {'id': 'acc-1', 'handle': 'daniel_crypto365'},
      'scores': {
        'overall_score': 84.5,
        'technical_score': 71,
        'fundamental_score': 88,
        'historical_accuracy': 80,
        'consistency': 77,
        'risk_management': 62,
        'timing': 70,
        'confidence': 66,
      },
    },
    {
      'handle': 'vlad_anderson',
      'name': 'Vlad Anderson',
      'followers': 5300,
      'posts_analyzed': 25,
      'status': 'done',
      'rating': 'Average',
      'scores': {
        'overall_score': 63.0,
        'technical_score': 90,
        'fundamental_score': 41,
        'confidence': 52,
      },
    },
    {
      'handle': 'newcomer',
      'name': 'newcomer',
      'status': 'queued',
      'rating': 'Unrated',
      'scores': <String, dynamic>{},
    },
  ];

  final List<String> boardsAsked = [];

  /// The evaluator admin microtools called, with their payloads.
  final List<(String, Map<String, dynamic>)> evaluatorCalls = [];

  @override
  Future<Map<String, dynamic>> evaluatorAdmin(
      String function, Map<String, dynamic> payload) async {
    evaluatorCalls.add((function, payload));
    return switch (function) {
      'trader_credentials' => {
          'trader': payload['handle'],
          'username': 'daniel_crypto365',
          'account_id': 'acc-1',
          'password': 'Pw-7xQ2mK9vL4rT8nZ1a',
        },
      'trader_remove' => {
          'ok': true,
          'removed': payload['handle'],
          'account_deleted': 'daniel_crypto365',
        },
      _ => const <String, dynamic>{},
    };
  }

  @override
  Future<Map<String, dynamic>> fetchTraderLeaderboard(
      {String board = 'overall', int limit = 100}) async {
    boardsAsked.add(board);
    final key = switch (board) {
      'technical' => 'technical_score',
      'fundamental' => 'fundamental_score',
      _ => 'overall_score',
    };
    double? score(Map<String, Object?> t) =>
        ((t['scores'] as Map)[key] as num?)?.toDouble();
    final ranked = [...traders]
      ..sort((a, b) => (score(b) ?? -1).compareTo(score(a) ?? -1));
    return {
      'board': board,
      'total': traders.length,
      'evaluated': 2,
      'updated_at': '2026-10-14T10:00:00+00:00',
      'traders': [
        for (final (i, t) in ranked.indexed)
          {...t, 'rank': score(t) == null ? null : i + 1},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> fetchTraderProfile(String handle) async {
    final t = traders.firstWhere((t) => t['handle'] == handle);
    return {
      ...t,
      'rank': 1,
      'analysed_by': 'agent',
      'analyst': {'bio': 'Crypto Investor & Market Analyst'},
      'history': [
        {'at': '2026-10-13T10:00:00+00:00', 'overall_score': 82},
        {'at': '2026-10-14T10:00:00+00:00', 'overall_score': 84.5},
      ],
      'report': {
        'overall_score': 84.5,
        'strengths': ['Clear invalidation levels'],
        'weaknesses': ['Stops rarely given'],
        'warnings': ['Mostly bullish calls'],
        'technical_analysis': {'trend_analysis': 78, 'risk_reward': 'good'},
        'market_validation': <String, dynamic>{},
      },
    };
  }

  @override
  Future<List<Map<String, dynamic>>> fetchLeaderboard({int limit = 10}) async =>
      const [
        {
          'author_id': homeId,
          'handle': 'Maya Chen',
          'posts': 40,
          'likes': 300,
          'score': 9700
        },
        {
          'author_id': atlasId,
          'handle': 'Alex Rivera',
          'posts': 30,
          'likes': 200,
          'score': 9600
        },
        {
          'author_id': '00000000000000010000000000000004',
          'handle': 'Iris Macro',
          'posts': 20,
          'likes': 100,
          'score': 9500
        },
      ];

  @override
  Future<List<Bot>> fetchBots({int limit = 100, int offset = 0}) async =>
      const [
        Bot(
            id: 'global-agent',
            ownerId: 'someone-else',
            accountId: 'acct-global',
            name: 'AlphaBot',
            kind: 'agent',
            vmType: 'langchain',
            status: 'running'),
      ];

  @override
  Future<Wallet> fetchWallet() async => const Wallet(balance: 100, locked: 0);

  @override
  Future<List<MarketListing>> fetchMarket(
          {String? type,
          String? query,
          int limit = 50,
          int offset = 0}) async =>
      const [];

  @override
  Future<List<Map<String, dynamic>>> fetchLedger(
          {int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<List<Packet>> fetchPackets(
          {String? peer, int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<List<Packet>> fetchPendingRequests(
          {int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<Map<String, dynamic>> fetchMyMetadata() async => const {};

  @override
  Future<List<MarketQuote>> fetchMarketQuotes() async => const [
        MarketQuote(
            symbol: 'BTC',
            price: r'$68,245',
            change: 1.8,
            color: AppColors.warning),
      ];

  @override
  Future<List<Room>> fetchRooms() async => const [
        Room(name: 'general', members: 'Home', status: 'online'),
      ];

  @override
  Future<List<Message>> fetchMessages(String roomId) async => const [];

  @override
  Future<({List<RoomMessage> messages, String working, String workingDetail})>
      fetchRoomMessages(String spaceId, String roomId,
              {int limit = 50, int offset = 0}) async =>
          (
            messages: roomMessages[spaceId + '/' + roomId] ?? const [],
            working: workingAgent,
            workingDetail: workingDetailAgent,
          );

  final Map<String, List<RoomMessage>> roomMessages = {};

  static const directId = '00000000000000010000000000000007';
  static const agentDirectId = '00000000000000010000000000000008';

  /// The messenger's conversations: two direct chats and the Atlas rooms.
  List<ChatSummary> chats = [
    ChatSummary(
      spaceId: directId,
      roomId: 'd1',
      direct: true,
      spaceName: 'Direct',
      roomName: 'general',
      role: 'owner',
      peer: const ChatPeer(
          id: '00000000000000010000000000000042',
          handle: 'maya',
          name: 'Maya Chen'),
      lastBody: 'See you at the desk review tomorrow?',
      lastSenderId: '00000000000000010000000000000042',
      lastSenderName: 'Maya Chen',
      updatedAt: DateTime(2026, 3, 4, 9, 40),
      unread: 2,
    ),
    ChatSummary(
      spaceId: agentDirectId,
      roomId: 'd2',
      direct: true,
      spaceName: 'Direct',
      roomName: 'general',
      role: 'owner',
      peer: const ChatPeer(
          id: '00000000000000010000000000000043',
          handle: 'alphabot',
          name: 'AlphaBot',
          kind: 'bot',
          botId: 'bot-alpha'),
      lastBody: 'Entry 68,200 · stop 66,900 · size 0.31 BTC.',
      lastSenderId: '00000000000000010000000000000043',
      lastSenderName: 'AlphaBot',
      updatedAt: DateTime(2026, 3, 4, 9, 20),
      working: true,
    ),
    ChatSummary(
      spaceId: atlasId,
      roomId: 'a1',
      spaceName: 'Atlas Capital',
      roomName: 'general',
      role: 'owner',
      lastBody: 'Perfect, thanks!',
      lastSenderId: '00000000000000010000000000000001',
      lastSenderName: 'Sam',
      updatedAt: DateTime(2026, 3, 3, 18, 5),
    ),
  ];

  final List<String> seen = [];

  @override
  Future<List<ChatSummary>> fetchChats({String kind = ''}) async => chats
      .where((c) => kind.isEmpty || (kind == 'direct') == c.direct)
      .toList();

  @override
  Future<ChatSummary> openDirect(String peer) async => chats.firstWhere(
      (c) => c.direct && (c.peer?.id == peer || c.peer?.botId == peer),
      orElse: () => ChatSummary(
          spaceId: '00000000000000010000000000000009',
          roomId: 'd9',
          direct: true,
          role: 'owner',
          peer: ChatPeer(id: peer, handle: 'new')));

  @override
  Future<void> markSeen(String spaceId, DateTime at) async => seen.add(spaceId);

  /// What a chat page reads besides its messages, by space id.
  final Map<String, RoomChatPage> chatState = {};

  /// The room chat actions the UI called, as "action:argument".
  final List<String> chatCalls = [];

  @override
  Future<RoomChatPage> fetchRoomChat(String spaceId, String roomId,
      {int limit = 50}) async {
    final extra = chatState[spaceId] ?? const RoomChatPage();
    return RoomChatPage(
        // A fresh list per read, as the node sends.
        messages: List.of(roomMessages[spaceId + '/' + roomId] ?? const []),
        working: workingAgent,
        workingDetail: workingDetailAgent,
        typing: extra.typing,
        peerSeenAt: extra.peerSeenAt,
        blocked: extra.blocked,
        canSend: extra.canSend,
        saved: extra.saved);
  }

  @override
  Future<void> editRoomMessage(String messageId, String body) async {
    chatCalls.add('edit:$messageId');
    for (final list in roomMessages.values) {
      final i = list.indexWhere((m) => m.id == messageId);
      if (i < 0) continue;
      final m = list[i];
      list[i] = RoomMessage(
          id: m.id,
          spaceId: m.spaceId,
          roomId: m.roomId,
          senderId: m.senderId,
          body: body,
          createdAt: m.createdAt,
          replyTo: m.replyTo,
          editedAt: DateTime.now());
    }
  }

  @override
  Future<void> deleteRoomMessage(String spaceId, String messageId) async {
    chatCalls.add('delete:$messageId');
    for (final list in roomMessages.values) {
      list.removeWhere((m) => m.id == messageId);
    }
  }

  @override
  Future<void> setTyping(String spaceId, String roomId, bool typing) async =>
      chatCalls.add('typing:$spaceId');

  @override
  Future<void> pinChat(String spaceId, String roomId, bool pinned) async {
    chatCalls.add('${pinned ? 'pin' : 'unpin'}:$spaceId');
    chats = [
      for (final c in chats)
        c.spaceId == spaceId && c.roomId == roomId
            ? (pinned
                ? c.copyWith(pinnedAt: DateTime.now())
                : c.copyWith(clearPin: true))
            : c
    ];
  }

  @override
  Future<void> clearChat(String spaceId) async =>
      chatCalls.add('clear:$spaceId');

  @override
  Future<void> blockDirect(String spaceId, bool blocked) async {
    chatCalls.add('${blocked ? 'block' : 'unblock'}:$spaceId');
    chatState[spaceId] = RoomChatPage(blocked: blocked, canSend: !blocked);
  }

  @override
  Future<void> reportChat(String spaceId, String roomId,
          {String messageId = '',
          required String reason,
          String note = ''}) async =>
      chatCalls
          .add('report:${messageId.isEmpty ? spaceId : messageId}:$reason');

  @override
  Future<ChatSummary> openSaved() async => const ChatSummary(
      spaceId: '00000000000000010000000000000010',
      roomId: 's1',
      direct: true,
      saved: true,
      role: 'owner',
      peer: ChatPeer(id: '00000000000000010000000000000001', handle: 'test'));

  /// Simulates the backend "working agent" signal for the room indicator.
  String workingAgent = '';

  /// Simulates the backend live status sentence ("running in the sandbox…").
  String workingDetailAgent = '';

  @override
  Future<({List<WorkRun> live, List<WorkRun> queued, List<WorkEntry> entries})>
      roomWork(String spaceId, {int limit = 40}) async =>
          (live: <WorkRun>[], queued: <WorkRun>[], entries: <WorkEntry>[]);

  @override
  Future<({int seq, List<LiveActivity> activity})> roomLive(
          String spaceId, String roomId,
          {int seq = 0}) async =>
      (seq: seq + 1, activity: <LiveActivity>[]);

  @override
  Future<List<AgentQuestion>> agentQuestions(String spaceId) async => const [];

  @override
  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) async {
    final resolved = <UploadedFile>[];
    for (final id in attachments) {
      for (final f in _files[spaceId] ?? const <UploadedFile>[]) {
        if (f.id == id) {
          resolved.add(f);
          break;
        }
      }
    }
    final msg = RoomMessage(
        id: 'msg-${roomMessages.length}',
        spaceId: spaceId,
        roomId: roomId,
        senderId: '00000000000000010000000000000099',
        body: body,
        mentions: mentions,
        attachments: resolved,
        replyTo: replyTo,
        createdAt: DateTime.now());
    roomMessages.putIfAbsent(spaceId + '/' + roomId, () => []).add(msg);
    return msg;
  }

  @override
  Future<UploadedFile> uploadFile(
    String spaceId, {
    String roomId = '',
    required String name,
    required String mime,
    required Uint8List bytes,
  }) async {
    final id = 'file-${_fileSeq++}';
    final f = UploadedFile(
      id: id,
      name: name,
      mime: mime,
      size: bytes.length,
      spaceId: spaceId,
      roomId: roomId,
      contentUrl: '/v1/files/$id/content',
      bytes: bytes,
      createdAt: DateTime.now(),
    );
    _files.putIfAbsent(spaceId, () => []).add(f);
    return f;
  }

  @override
  Future<UploadedFile> fetchFile(String fileId, {bool withData = false}) async {
    for (final list in _files.values) {
      for (final f in list) {
        if (f.id == fileId) {
          if (withData && f.bytes != null) {
            return UploadedFile(
              id: f.id,
              name: f.name,
              mime: f.mime,
              size: f.size,
              spaceId: f.spaceId,
              roomId: f.roomId,
              public: f.public,
              contentUrl: f.contentUrl,
              createdAt: f.createdAt,
              bytes: f.bytes,
            );
          }
          return f;
        }
      }
    }
    throw const ApiException('NOT_FOUND', 'file not found', status: 404);
  }

  @override
  Future<Uint8List> downloadFile(String fileId) async {
    final f = await fetchFile(fileId, withData: true);
    return f.bytes ?? Uint8List(0);
  }

  @override
  Future<List<UploadedFile>> fetchSpaceFiles(String spaceId,
          {String? roomId, int limit = 100, int offset = 0}) async =>
      List<UploadedFile>.of(_files[spaceId] ?? const <UploadedFile>[]);

  @override
  Future<void> deleteFile(String fileId) async {
    _files.updateAll((_, list) => list.where((f) => f.id != fileId).toList());
  }

  @override
  Future<List<Map<String, dynamic>>> fetchFiles(String spaceId,
      {String? roomId, int limit = 100, int offset = 0}) async {
    return (_files[spaceId] ?? const <UploadedFile>[])
        .where((f) => roomId == null || roomId.isEmpty || f.roomId == roomId)
        .skip(offset)
        .take(limit)
        .map((f) => {
              'file_id': f.id,
              'id': f.id,
              'name': f.name,
              'mime': f.mime,
              'size': f.size,
              'space_id': f.spaceId,
              'room_id': f.roomId,
              'content_url': f.contentUrl,
              'created_at': f.createdAt?.toIso8601String() ?? '',
            })
        .toList();
  }

  @override
  Future<List<Bot>> fetchSpaceBots(String spaceId) async {
    if (spaceId == atlasId) {
      return const [
        Bot(
            id: 'agent-1',
            ownerId: 'me',
            accountId: 'acct-1',
            name: 'SignalBot',
            kind: 'agent',
            vmType: 'langchain',
            status: 'running'),
      ];
    }
    // A newly created space has no bots until one is explicitly added.
    return const [];
  }

  @override
  Future<void> addBotToSpace(String spaceId, String botId,
      {String roomId = ''}) async {}

  @override
  Future<void> removeBotFromSpace(String spaceId, String botId,
      {String roomId = ''}) async {}

  @override
  Future<List<DeskWidgetDsl>> fetchRoomWidgets(
          String spaceId, String roomId) async =>
      const [];

  @override
  Future<Bot> fetchBot(String botId) async => Bot(
        id: botId,
        ownerId: 'me',
        accountId: 'acct-$botId',
        name: 'Sandbox',
        kind: 'tool',
        vmType: 'docker',
        status: 'running',
      );

  @override
  Future<String> sandboxExec(String spaceId, String command) async => 'ok';

  @override
  Future<Map<String, dynamic>> sandboxStatus(String spaceId) async => {
        'space_id': spaceId,
        'bot_id': 'sbx-1',
        'name': 'sbx',
        'status': 'running'
      };

  @override
  Future<Map<String, dynamic>> sandboxStart(String spaceId) async =>
      {'bot_id': 'sbx-1', 'status': 'running'};

  @override
  Future<Map<String, dynamic>> sandboxStop(String spaceId) async =>
      {'bot_id': 'sbx-1', 'status': 'stopped'};

  // ── entity profiles ───────────────────────────────────────────────────────

  @override
  Future<UserProfile> fetchUserProfile(String accountId) async {
    final me = client.session?.accountId ?? '';
    return UserProfile(
      id: accountId,
      handle: accountId == me ? 'me' : 'trader-$accountId',
      kind: 'user',
      status: 'active',
      displayName: 'Trader ${accountId.substring(0, 4)}',
      bio: 'Systematic macro trader.',
      followers: _follows.where((f) => f.endsWith('>$accountId')).length,
      following: _follows.where((f) => f.startsWith('$accountId>')).length,
      amFollowing: _follows.contains('$me>$accountId'),
    );
  }

  @override
  Future<void> followUser(String accountId) async {
    final me = client.session?.accountId ?? '';
    _follows.add('$me>$accountId');
  }

  @override
  Future<void> unfollowUser(String accountId) async {
    final me = client.session?.accountId ?? '';
    _follows.remove('$me>$accountId');
  }

  @override
  Future<List<AccountSummary>> fetchFollowing(
          {String? accountId, int limit = 50, int offset = 0}) async =>
      [
        const AccountSummary(
            id: 'u1', handle: 'macroalex', kind: 'user', status: 'active'),
      ];

  @override
  Future<List<AccountSummary>> fetchFollowers(
          {String? accountId, int limit = 50, int offset = 0}) async =>
      const [];

  @override
  Future<BotProfile> fetchBotProfile(String botId) async => BotProfile(
        id: botId,
        name: botId == 'agent-1' ? 'SignalBot' : 'Sandbox',
        kind: 'agent',
        vmType: 'langchain',
        status: 'running',
        ownerHandle: 'me',
        description: 'Live market intelligence agent.',
        resources: const {'cpu': 1, 'memory_mb': 512, 'disk_mb': 512},
        cost: const {'per_minute': 1},
        usage: const {'uptime_sec': 3600, 'tokens': 1200},
        entities: const ['backend', 'spec', 'frontend'],
        hasFrontend: true,
        listing: const {'installs': 42, 'price': 0, 'category': 'analytics'},
      );

  @override
  Future<SpaceProfile> fetchSpaceProfile(String spaceId) async {
    final name = switch (spaceId) {
      homeId => 'Home',
      sharedId => 'Shared Desk',
      _ => 'Atlas Capital',
    };
    final owner = switch (spaceId) {
      sharedId => 'u1',
      _ => 'me',
    };
    return SpaceProfile(
      id: spaceId,
      name: name,
      description: '$name workspace',
      public: spaceId != homeId,
      ownerHandle: owner,
      memberCount: spaceId == homeId ? 1 : 3,
      agentCount: 1,
      roomCount: 2,
      rooms: const ['general', 'Crypto Alpha'],
      postCount: 4,
      fileCount: 2,
      amMember: true,
    );
  }

  @override
  Future<RoomProfile> fetchRoomProfile(String roomId) async => RoomProfile(
        id: roomId,
        name: 'general',
        topic: 'Room topic',
        spaceId: homeId,
        spaceName: 'Home',
        memberCount: 3,
        agentCount: 1,
        messageCount: 5,
        fileCount: 2,
        amMember: true,
        recentMessages: const [
          {
            'sender_id': 'u1',
            'body': 'Morning levels look strong.',
            'created_at': '2026-10-01T09:00:00Z'
          },
        ],
      );

  @override
  Future<List<Map<String, dynamic>>> searchBots(String query,
      {String kind = '', int limit = 20, int offset = 0}) async {
    final bots = await fetchBots();
    return bots
        .where((b) => kind.isEmpty || kind.split(',').any((k) => k == b.kind))
        .where((b) => b.name.toLowerCase().contains(query.toLowerCase()))
        .skip(offset)
        .take(limit)
        .map((b) => {
              'id': b.id,
              'name': b.name,
              'kind': b.kind,
              'vm_type': b.vmType,
              'status': b.status,
            })
        .toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchSpaceMembers(String spaceId,
      {int limit = 50, int offset = 0}) async {
    final list = switch (spaceId) {
      homeId => <Map<String, dynamic>>[
          {
            'member_id': 'me',
            'handle': 'test',
            'kind': 'user',
            'role': 'owner'
          },
        ],
      sharedId => <Map<String, dynamic>>[
          {
            'member_id': 'u1',
            'handle': 'trader-u1',
            'kind': 'user',
            'role': 'owner'
          },
          {
            'member_id': 'me',
            'handle': 'test',
            'kind': 'user',
            'role': 'member'
          },
        ],
      _ => <Map<String, dynamic>>[
          {
            'member_id': 'me',
            'handle': 'test',
            'kind': 'user',
            'role': 'owner'
          },
          {
            'member_id': 'u1',
            'handle': 'trader-u1',
            'kind': 'user',
            'role': 'member'
          },
        ],
    };
    return list.skip(offset).take(limit).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> searchSpaceMessages(String spaceId,
      {String query = '', int limit = 50, int offset = 0}) async {
    return [
      {
        'sender_id': 'u1',
        'body': 'Morning levels look strong.',
        'created_at': '2026-10-01T09:00:00Z',
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> fetchUsageSummary(String spaceId,
          {int limit = 200}) async =>
      {
        'space_id': spaceId,
        'total_in': 1250,
        'total_out': 380,
        'total_cost': 12,
        'rooms': [
          {
            'key': 'r1',
            'label': 'general',
            'requests': 4,
            'tokens_in': 800,
            'tokens_out': 200,
            'cost': 7
          },
          {
            'key': 'r2',
            'label': 'Crypto Alpha',
            'requests': 2,
            'tokens_in': 450,
            'tokens_out': 180,
            'cost': 5
          },
        ],
        'agents': [
          {
            'key': 'agent-1',
            'label': 'SignalBot',
            'requests': 3,
            'tokens_in': 900,
            'tokens_out': 280,
            'cost': 9
          },
          {
            'key': '',
            'label': 'tradera',
            'requests': 2,
            'tokens_in': 350,
            'tokens_out': 100,
            'cost': 3
          },
        ],
      };

  @override
  Future<List<Map<String, dynamic>>> fetchUsageList(String spaceId,
          {String roomId = '',
          String botId = '',
          int limit = 50,
          int offset = 0}) async =>
      [
        {
          'space_id': spaceId,
          'bot_name': 'SignalBot',
          'tokens_in': 100,
          'tokens_out': 20,
          'cost': 1
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> searchSpaces(String query,
      {int limit = 20, int offset = 0}) async {
    return [
      {
        'id': atlasId,
        'name': 'Atlas Capital',
        'description': 'Macro desk',
        'owner_id': 'me'
      },
    ];
  }
}
