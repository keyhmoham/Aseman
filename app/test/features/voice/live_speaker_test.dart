import 'dart:async';
import 'dart:typed_data';

import 'package:aseman/src/features/voice/live/live_speaker.dart';
import 'package:flutter_test/flutter_test.dart';

class _Player implements ClipPlayer {
  final played = <int>[];
  Completer<void>? playing;
  bool hold = false;
  int stops = 0;

  @override
  Future<void> play(SpeechClip clip) async {
    played.add(clip.audio.first);
    if (!hold) return;
    playing = Completer<void>();
    await playing!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    final p = playing;
    if (p != null && !p.isCompleted) p.complete();
  }

  @override
  Future<void> dispose() async {}
}

SpeechClip _clip(String text) =>
    SpeechClip(Uint8List.fromList([text.length]), 'audio/wav');

void main() {
  test('says pieces in order, asking for the next while one plays', () async {
    final player = _Player();
    final asked = <String>[];
    final speaker = LiveSpeaker(
      player: player,
      fetch: (text) async {
        asked.add(text);
        return _clip(text);
      },
    );
    final done = <String>[];
    speaker.speak('one', () => done.add('one'));
    speaker.speak('three', () => done.add('three'));
    speaker.speak('seven!', () => done.add('seven'));
    expect(asked, ['one', 'three', 'seven!']); // all asked for at once
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(player.played, [3, 5, 6]);
    expect(done, ['one', 'three', 'seven']);
  });

  test('a piece the node cannot say is reported and skipped', () async {
    final player = _Player();
    final failures = <Object>[];
    final speaker = LiveSpeaker(
      player: player,
      onFailure: failures.add,
      fetch: (text) async {
        if (text == 'bad') throw StateError('no speech model');
        return _clip(text);
      },
    );
    final done = <String>[];
    speaker.speak('bad', () => done.add('bad'));
    speaker.speak('ok', () => done.add('ok'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(failures, hasLength(1));
    expect(player.played, [2]);
    expect(done, ['bad', 'ok']);
  });

  test('stop cuts off what plays and drops what waits, finishing each',
      () async {
    final player = _Player()..hold = true;
    final speaker = LiveSpeaker(player: player, fetch: (t) async => _clip(t));
    final done = <String>[];
    speaker.speak('first', () => done.add('first'));
    speaker.speak('second', () => done.add('second'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(player.played, [5]);

    await speaker.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(player.played, [5], reason: 'the second piece never plays');
    expect(done.toSet(), {'first', 'second'});
    expect(done, hasLength(2), reason: 'each finishes exactly once');
  });
}
