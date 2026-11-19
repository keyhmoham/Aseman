import 'dart:convert';
import 'dart:typed_data';

import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/data/services/aseman_service.dart';
import 'package:aseman/src/data/services/backend_capabilities.dart';
import 'package:aseman/src/features/voice/live/live_voice_backend.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.namespace, this.action, this.body, this.timeout);
  final String namespace;
  final String action;
  final Map<String, dynamic> body;
  final Duration? timeout;
}

/// A node that answers the voice actions as Decillion's `users` plugin does.
class _Node extends AsemanApiClient {
  _Node() : super(baseUrl: 'http://localhost:8080');

  final calls = <_Call>[];

  @override
  Future<ApiResponse> call(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? requestTimeout,
    bool anonymous = false,
  }) async {
    calls.add(_Call(namespace, action, body, requestTimeout));
    return ApiResponse(200, switch (action) {
      'voice_config' => {'speech': true, 'transcription': true, 'live': true},
      'voice_transcribe_chunk' => {'text': '  hello there '},
      'voice_speak' => {'audio': base64Encode([1, 2, 3]), 'mime': 'audio/mpeg'},
      'dm_send' => {'id': 'note-1', 'peer': 'peer', 'ok': true},
      'dm_list' => {
          'messages': [
            {'id': 'a1', 'from_id': 'agent', 'reply_to': 'note-1', 'body': 'Hi.'},
          ],
        },
      _ => {'ok': true},
    });
  }
}

void main() {
  late _Node node;
  late ServiceLiveVoiceBackend backend;

  setUp(() {
    node = _Node();
    backend = ServiceLiveVoiceBackend(AsemanService(node), peer: 'peer');
  });

  test('every voice action the live chat calls is in the client contract', () {
    for (final action in [
      'voice_config',
      'voice_transcribe_chunk',
      'voice_speak',
    ]) {
      expect(BackendCapabilities.contains('users', action), isTrue, reason: action);
    }
  });

  test('reads which voice models the node has on', () async {
    final config = await backend.config();
    expect(config.ready, isTrue);
    expect(node.calls.single.action, 'voice_config');
  });

  test('sends a chunk as WAV and gets its text', () async {
    final text = await backend.transcribeChunk(Uint8List.fromList([9, 8, 7]));
    expect(text, 'hello there');
    final call = node.calls.single;
    expect((call.namespace, call.action), ('users', 'voice_transcribe_chunk'));
    expect(call.body['mime'], 'audio/wav');
    expect(base64Decode(call.body['audio'] as String), [9, 8, 7]);
    expect(call.timeout, const Duration(seconds: 20));
  });

  test("has the node's speech model say a piece", () async {
    final clip = await backend.speak('Good morning.');
    expect(clip.audio, [1, 2, 3]);
    expect(clip.mime, 'audio/mpeg');
    final call = node.calls.single;
    expect(call.action, 'voice_speak');
    expect(call.body, {'text': 'Good morning.'});
    expect(call.timeout, const Duration(seconds: 45));
  });

  test('what is said goes out as a spoken note, like any typed one', () async {
    expect(await backend.sendNote('what is on my calendar'), 'note-1');
    final call = node.calls.single;
    expect((call.namespace, call.action), ('users', 'dm_send'));
    expect(call.body['to'], 'peer');
    expect(call.body['body'], 'what is on my calendar');
    expect(call.body['voice'], isTrue);
  });

  test('a typed message does not claim to be spoken', () async {
    await AsemanService(node).sendDirectMessage('peer', 'typed');
    expect(node.calls.single.body.containsKey('voice'), isFalse);
  });

  test('looks for the answer in the conversation with the peer', () async {
    final snapshot = await backend.snapshot('note-1');
    expect(snapshot.answer?.text, 'Hi.');
    expect(snapshot.answer?.done, isTrue);
    final call = node.calls.single;
    expect((call.action, call.body['peer']), ('dm_list', 'peer'));
  });

  test('confirming goes through brain_confirm', () async {
    await backend.confirm('a1', approve: true);
    final call = node.calls.single;
    expect(call.action, 'brain_confirm');
    expect(call.body, {'message': 'a1', 'approve': true});
  });
}
