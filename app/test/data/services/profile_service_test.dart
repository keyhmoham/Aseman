import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/services/tradera_service.dart';

class _ProfileStubClient extends TraderaApiClient {
  _ProfileStubClient() : super(baseUrl: 'http://localhost');

  final follows = <String>[];

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    switch (action) {
      case 'account_get':
        return const ApiResponse(200, {
          'id': 'u-1',
          'handle': 'macroalex',
          'kind': 'user',
          'status': 'active',
          'profile': {'display_name': 'Alex Rivera', 'bio': 'Macro trader.'},
          'followers': 12,
          'following': 3,
          'am_following': true,
        });
      case 'follow':
        follows.add('u-1');
        return const ApiResponse(200, {'ok': true, 'following': true});
      case 'unfollow':
        follows.remove('u-1');
        return const ApiResponse(200, {'ok': true, 'following': false});
      case 'following_list':
        return const ApiResponse(200, {
          'users': [
            {
              'id': 'u-2',
              'handle': 'algoquant',
              'kind': 'user',
              'status': 'active'
            },
          ],
        });
      case 'bot_profile':
        return const ApiResponse(200, {
          'id': 'b-1',
          'name': 'SignalBot',
          'kind': 'agent',
          'vm_type': 'langchain',
          'status': 'running',
          'owner_id': 'u-1',
          'owner_handle': 'macroalex',
          'description': 'Live signals.',
          'resources': const {'cpu': 1, 'memory_mb': 512, 'disk_mb': 512},
          'cost': const {'per_minute': 2},
          'usage': const {'uptime_sec': 7200, 'tokens': 500},
          'entities': ['backend', 'spec'],
          'has_frontend': true,
          'listing': const {'installs': 42, 'price': 0, 'category': 'signals'},
        });
      case 'space_profile':
        return const ApiResponse(200, {
          'id': 's-1',
          'name': 'Atlas Capital',
          'description': 'Macro desk',
          'public': true,
          'owner_handle': 'macroalex',
          'member_count': 8,
          'agent_count': 2,
          'room_count': 3,
          'rooms': ['general', 'research', 'risk'],
          'post_count': 20,
          'file_count': 5,
          'am_member': false,
        });
      case 'room_profile':
        return const ApiResponse(200, {
          'id': 'r-1',
          'name': 'general',
          'topic': 'Markets',
          'space_id': 's-1',
          'space_name': 'Atlas Capital',
          'member_count': 6,
          'agent_count': 1,
          'message_count': 50,
          'file_count': 3,
          'am_member': true,
          'recent_messages': [
            {
              'sender_id': 'u-2',
              'body': 'levels strong',
              'created_at': '2026-10-01T09:00:00Z'
            },
          ],
        });
      case 'join':
        return const ApiResponse(200, {'ok': true, 'joined': true});
      default:
        return const ApiResponse(200, <String, dynamic>{});
    }
  }
}

void main() {
  test('fetchUserProfile parses profile + follow relationship', () async {
    final client = _ProfileStubClient();
    final service = TraderaService(client);

    final p = await service.fetchUserProfile('u-1');
    expect(p.handle, 'macroalex');
    expect(p.displayName, 'Alex Rivera');
    expect(p.bio, 'Macro trader.');
    expect(p.followers, 12);
    expect(p.following, 3);
    expect(p.amFollowing, isTrue);
  });

  test('follow/unfollow update the relationship', () async {
    final client = _ProfileStubClient();
    final service = TraderaService(client);

    await service.followUser('u-1');
    expect(client.follows, contains('u-1'));
    await service.unfollowUser('u-1');
    expect(client.follows, isNot(contains('u-1')));
  });

  test('fetchFollowing parses account summaries', () async {
    final service = TraderaService(_ProfileStubClient());
    final list = await service.fetchFollowing(accountId: 'u-1');
    expect(list.single.handle, 'algoquant');
  });

  test('fetchBotProfile parses resources, usage, entities and listing',
      () async {
    final service = TraderaService(_ProfileStubClient());
    final b = await service.fetchBotProfile('b-1');
    expect(b.name, 'SignalBot');
    expect(b.kind, 'agent');
    expect(b.vmType, 'langchain');
    expect(b.resources['cpu'], 1);
    expect(b.uptimeSec, 7200);
    expect(b.tokens, 500);
    expect(b.entities, ['backend', 'spec']);
    expect(b.hasFrontend, isTrue);
    expect(b.installs, 42);
    expect(b.ownerHandle, 'macroalex');
  });

  test('fetchSpaceProfile parses counts and rooms', () async {
    final service = TraderaService(_ProfileStubClient());
    final s = await service.fetchSpaceProfile('s-1');
    expect(s.name, 'Atlas Capital');
    expect(s.memberCount, 8);
    expect(s.agentCount, 2);
    expect(s.rooms, ['general', 'research', 'risk']);
    expect(s.amMember, isFalse);
  });

  test('fetchRoomProfile parses activity and counts', () async {
    final service = TraderaService(_ProfileStubClient());
    final r = await service.fetchRoomProfile('r-1');
    expect(r.spaceName, 'Atlas Capital');
    expect(r.messageCount, 50);
    expect(r.recentMessages, hasLength(1));
    expect(r.amMember, isTrue);
  });

  test('joinSpace calls the join action', () async {
    final service = TraderaService(_ProfileStubClient());
    await service.joinSpace('s-1');
  });
}
