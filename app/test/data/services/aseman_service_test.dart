import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/data/services/aseman_service.dart';

/// A client that returns canned responses, shaped exactly like the real
/// gateway (posts carry `liked_by` as a JSON-encoded string).
class _StubClient extends AsemanApiClient {
  _StubClient() : super(baseUrl: 'http://localhost:8080');

  int calls = 0;

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    calls++;
    switch (action) {
      case 'post_feed':
        return const ApiResponse(200, {
          'posts': [
            {
              'id': '0000000000000001d11adae4c08cb079',
              'author_id': '000000000000000119d3757c33cdf520',
              'space_id': '00000000000000000000000000000000',
              'parent_id': '00000000000000000000000000000000',
              'body': 'test global post from cli',
              'created_at': '2026-10-01T06:41:45.970542Z',
              'edited_at': '0001-01-01T00:00:00Z',
              'tags': 'null',
              'media': 'null',
              'liked_by': '["000000000000000119d3757c33cdf520"]',
              'likes': 1,
              'updated_at': '2026-10-01T06:41:45.970542Z',
            },
            {
              'id': '0000000000000001d6c5daa6635d4e84',
              'author_id': '00000000000000013cf67fd23fc49f33',
              'space_id': '00000000000000000000000000000000',
              'parent_id': '00000000000000000000000000000000',
              'body': 'hello everyone!',
              'created_at': '2026-10-01T06:20:30.87674Z',
              'edited_at': '0001-01-01T00:00:00Z',
              'tags': 'null',
              'media': 'null',
              'liked_by': '[]',
              'likes': 0,
              'updated_at': '2026-10-01T06:20:30.87674Z',
            },
          ],
        });
      case 'spaces_feed':
      case 'post_user_posts':
        return const ApiResponse(200, {'posts': <dynamic>[]});
      default:
        return const ApiResponse(200, <String, dynamic>{});
    }
  }
}

void main() {
  test('login and register make the new session the client identity', () async {
    for (final register in [false, true]) {
      final client = _AuthStubClient();
      final service = AsemanService(client);
      final s = register
          ? await service.register(
              handle: 'alice', email: 'a@x.com', password: 'pw')
          : await service.login(account: 'alice', password: 'pw');
      expect(client.session, same(s));
      expect(client.session!.token, 'tok-1');
      await client.call('spaces', 'space_list');
      expect(client.sessions['space_list']?.token, 'tok-1',
          reason:
              'calls after ${register ? 'register' : 'login'} must be authenticated');
    }
  });

  test('provider sign-in sends the SDK identity token in the backend contract',
      () async {
    final client = _AuthStubClient();
    final service = AsemanService(client);

    await service.oauth('google', 'google-id-token');
    await service.oauth('apple', 'apple-identity-token');

    expect(client.bodies['oauth_google'], {'id_token': 'google-id-token'});
    expect(client.bodies['oauth_apple'],
        {'identity_token': 'apple-identity-token'});
    expect(client.session?.token, 'tok-1');
  });

  test('fetchFeed parses posts when liked_by is a JSON string', () async {
    final client = _StubClient();
    final service = AsemanService(client);

    final posts = await service.fetchFeed(following: false, limit: 20);

    expect(posts, hasLength(2));
    expect(posts[0].id, '0000000000000001d11adae4c08cb079');
    expect(posts[0].body, 'test global post from cli');
    expect(posts[1].likes, 0);
    expect(posts[0].tags, isEmpty);
  });

  test('fetchFeed marks likedByMe when caller is in the liked_by string',
      () async {
    final client = _StubClient();
    client.session = const Session(
      accountId: '000000000000000119d3757c33cdf520',
      handle: 'me',
      token: 'tok',
      privateKey: '',
      publicKey: '',
    );
    final service = AsemanService(client);

    final posts = await service.fetchFeed(following: false, limit: 20);

    expect(posts[0].likedByMe, isTrue);
    expect(posts[1].likedByMe, isFalse);
  });
}

/// Answers auth calls like the gateway and records the session each call was
/// made with.
class _AuthStubClient extends AsemanApiClient {
  _AuthStubClient() : super(baseUrl: 'http://localhost:8080');

  final sessions = <String, Session?>{};
  final bodies = <String, Map<String, dynamic>>{};

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
  }) async {
    sessions[action] = session;
    bodies[action] = body;
    return const ApiResponse(200, {
      'account_id': '00000000000000010000000000000001',
      'handle': 'alice',
      'token': 'tok-1',
      'private_key': '',
      'public_key': '',
    });
  }
}
