import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/data/services/aseman_service.dart';

/// Records what the app sends, and answers the way a Decillion node does.
class _RecordingClient extends AsemanApiClient {
  _RecordingClient() : super(baseUrl: 'http://localhost:8080');

  final sent = <String, Map<String, dynamic>>{};

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
    bool anonymous = false,
  }) async {
    sent['$namespace.$action'] = body;
    switch ('$namespace.$action') {
      case 'auth.config':
        return const ApiResponse(200, {
          'signup': 'invite',
          'email_verify': true,
          'email_delivery': 'log',
          'google': true,
          'google_client_id': 'id.apps.googleusercontent.com',
          'apple': false,
        });
      case 'auth.send_verification':
        return const ApiResponse(200, {'ok': true, 'delivery': 'log'});
      default:
        return const ApiResponse(200, {
          'account_id': '0000000000000001aaaaaaaaaaaaaaaa',
          'handle': 'ada',
          'token': 't',
          'private_key': '',
          'public_key': '',
        });
    }
  }
}

void main() {
  test('reads how the node takes new people', () async {
    final config = await AsemanService(_RecordingClient()).authConfig();
    expect(config.inviteOnly, isTrue);
    expect(config.signupClosed, isFalse);
    expect(config.emailVerify, isTrue);
    expect(config.googleClientId, 'id.apps.googleusercontent.com');
    expect(AuthConfig.fromJson(const {}).signup, 'open');
    expect(
      AuthConfig.fromJson(const {'signup': 'CLOSED'}).signupClosed,
      isTrue,
    );
    expect(AuthConfig.fromJson(const {'signup': 'something'}).signup, 'open');
  });

  test(
    'a sign-up carries its invite code; without one it sends none',
    () async {
      final client = _RecordingClient();
      final service = AsemanService(client);
      await service.register(
        handle: 'ada',
        email: 'a@x.io',
        password: 'secret123',
        inviteCode: ' C0DE ',
      );
      expect(client.sent['auth.register']!['invite_code'], 'C0DE');
      await service.register(
        handle: 'ada',
        email: 'a@x.io',
        password: 'secret123',
      );
      expect(client.sent['auth.register']!.containsKey('invite_code'), isFalse);
    },
  );

  test('a first Google sign-in carries the invite code', () async {
    final client = _RecordingClient();
    await AsemanService(client).oauth('google', 'tok', inviteCode: 'C0DE');
    expect(
      client.sent['auth.oauth_google'],
      containsPair('invite_code', 'C0DE'),
    );
    expect(client.sent['auth.oauth_google'], containsPair('id_token', 'tok'));
  });

  test('a verification code is sent, and says how it is delivered', () async {
    final client = _RecordingClient();
    expect(await AsemanService(client).sendVerification('a@x.io'), 'log');
    expect(
      client.sent['auth.send_verification'],
      containsPair('email', 'a@x.io'),
    );
  });
}
