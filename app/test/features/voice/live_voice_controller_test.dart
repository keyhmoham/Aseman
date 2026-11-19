import 'dart:typed_data';

import 'package:aseman/src/features/voice/live/live_recording_session.dart';
import 'package:aseman/src/features/voice/live/live_speaker.dart';
import 'package:aseman/src/features/voice/live/live_vad.dart';
import 'package:aseman/src/features/voice/live/live_voice_backend.dart';
import 'package:aseman/src/features/voice/live/live_voice_controller.dart';
import 'package:aseman/src/features/voice/live/live_voice_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// A microphone whose loudness the test sets.
class _Mic implements LiveRecordingSession {
  double loudness = 0;
  int cuts = 0;
  bool closed = false;

  @override
  double level() => loudness;

  @override
  Future<Uint8List> cutChunk() async => Uint8List.fromList([++cuts]);

  @override
  void trimTo(Duration keep) {}

  @override
  Future<void> close() async => closed = true;
}

class _Player implements ClipPlayer {
  final played = <Uint8List>[];

  @override
  Future<void> play(SpeechClip clip) async => played.add(clip.audio);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class _Backend implements LiveVoiceBackend {
  LiveVoiceConfig voice = const LiveVoiceConfig(speech: true, transcription: true);
  final heardNext = <String>[]; // what each transcribed chunk comes back as
  final notes = <String>[];
  final confirmed = <(String, bool)>[];
  final spoken = <String>[];
  LiveSnapshot Function(String note, int look) answer =
      (note, look) => const LiveSnapshot();
  int looks = 0;

  @override
  Future<LiveVoiceConfig> config() async => voice;

  @override
  Future<String> transcribeChunk(Uint8List wav) async =>
      heardNext.isEmpty ? '' : heardNext.removeAt(0);

  @override
  Future<SpeechClip> speak(String text) async {
    spoken.add(text);
    return SpeechClip(Uint8List.fromList([spoken.length]), 'audio/wav');
  }

  @override
  Future<String> sendNote(String text) async {
    notes.add(text);
    return 'note-${notes.length}';
  }

  @override
  Future<LiveSnapshot> snapshot(String noteId) async =>
      answer(noteId, ++looks);

  @override
  Future<void> confirm(String proposalId, {required bool approve}) async =>
      confirmed.add((proposalId, approve));
}

const _fast = LiveVoiceTiming(
  vad: VadConfig(
    chunkSilence: Duration(milliseconds: 30),
    turnSilence: Duration(milliseconds: 80),
  ),
  listenTick: Duration(milliseconds: 5),
  pollTick: Duration(milliseconds: 5),
  drainPoll: Duration(milliseconds: 2),
  giveUp: Duration(milliseconds: 300),
);

Future<void> _until(bool Function() ready, [String what = 'it']) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

void main() {
  late _Backend backend;
  late _Player player;
  late List<_Mic> mics;
  late LiveVoiceController voice;

  Future<LiveRecordingSession> openMic() async {
    final mic = _Mic();
    mics.add(mic);
    return mic;
  }

  setUp(() {
    backend = _Backend();
    player = _Player();
    mics = [];
    voice = LiveVoiceController(
      backend: backend,
      player: player,
      timing: _fast,
      openSession: openMic,
    );
  });

  tearDown(() async {
    voice.dispose();
  });

  /// Says something into the current microphone: loud, then quiet.
  Future<void> say(String words) async {
    backend.heardNext.add(words);
    final mic = mics.last;
    mic.loudness = 0.6;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    mic.loudness = 0;
  }

  test('listens, sends what was said as a note, speaks the answer, listens again',
      () async {
    backend.answer = (note, look) => switch (look) {
          1 => const LiveSnapshot(answer: LiveAnswer('Sure, I ', done: false)),
          _ => const LiveSnapshot(
              answer: LiveAnswer('Sure, I can do that. Anything else?', done: true)),
        };

    await voice.start();
    expect(voice.state, LiveState.listening);
    expect(voice.active, isTrue);
    await _until(() => mics.length == 1);

    await say('book a table for two');
    await _until(() => backend.notes.isNotEmpty, 'the note to be sent');
    expect(backend.notes, ['book a table for two']);
    expect(mics.first.closed, isTrue, reason: 'the microphone is closed while it answers');
    expect(voice.heard, 'book a table for two');

    await _until(() => voice.said == 'Sure, I can do that. Anything else?');
    await _until(() => player.played.length == 2, 'both sentences to be spoken');
    expect(backend.spoken, ['Sure, I can do that.', 'Anything else?']);

    await _until(() => mics.length == 2, 'listening again');
    expect(voice.state, LiveState.listening);
  });

  test('a chunk is sent for transcription as soon as its silence passes, and the turn joins them',
      () async {
    await voice.start();
    await _until(() => mics.length == 1);
    final mic = mics.first;

    backend.heardNext.add('first half');
    mic.loudness = 0.6;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    mic.loudness = 0;
    await _until(() => mic.cuts == 1, 'the first chunk to close');
    expect(backend.notes, isEmpty, reason: 'the turn is not over yet');

    backend.heardNext.add('second half');
    mic.loudness = 0.6;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    mic.loudness = 0;

    await _until(() => backend.notes.isNotEmpty);
    expect(backend.notes, ['first half second half']);
  });

  test('tapping while you are mid-sentence sends what you have said so far',
      () async {
    await voice.start();
    await _until(() => mics.length == 1);
    backend.heardNext.add('still talking');
    mics.first.loudness = 0.6;
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await voice.tap();

    await _until(() => backend.notes.isNotEmpty);
    expect(backend.notes, ['still talking']);
  });

  test('a turn with nothing recognized listens again instead of sending',
      () async {
    await voice.start();
    await _until(() => mics.length == 1);
    await say(''); // heard something, but it was not words
    await _until(() => mics.length == 2, 'listening again');
    expect(backend.notes, isEmpty);
  });

  test('after a few silent turns it waits to be tapped', () async {
    final quiet = LiveVoiceController(
      backend: backend,
      player: player,
      timing: const LiveVoiceTiming(
        vad: VadConfig(
          chunkSilence: Duration(milliseconds: 30),
          turnSilence: Duration(milliseconds: 80),
        ),
        listenTick: Duration(milliseconds: 5),
        drainPoll: Duration(milliseconds: 2),
        silentRestarts: 1,
      ),
      openSession: openMic,
    );
    addTearDown(quiet.dispose);
    await quiet.start();
    for (var turn = 1; turn <= 2; turn++) {
      await _until(() => mics.length == turn);
      await say('');
    }
    await _until(() => quiet.state == LiveState.paused, 'it to pause');
    expect(quiet.active, isTrue);
    expect(backend.notes, isEmpty);
  });

  test('a spoken yes never confirms what was proposed', () async {
    backend.answer = (note, look) => const LiveSnapshot(
          answer: LiveAnswer('I can send it. Shall I?', done: true),
          proposal: LiveProposal(id: 'a1', steps: ['Send the email']),
        );
    await voice.start();
    await _until(() => mics.length == 1);
    await say('email Sam the report');
    await _until(() => voice.proposal != null, 'the proposal');
    await _until(() => mics.length == 2, 'listening again');

    await say('yes');
    await _until(() => voice.notice.contains('Tap Confirm'));
    expect(backend.notes, ['email Sam the report'], reason: 'the yes was not sent');
    expect(backend.confirmed, isEmpty);
    expect(voice.proposal?.steps, ['Send the email']);
  });

  test('confirming is a tap, and it settles the proposal', () async {
    backend.answer = (note, look) => const LiveSnapshot(
          answer: LiveAnswer('Shall I?', done: true),
          proposal: LiveProposal(id: 'a1', steps: ['Send']),
        );
    await voice.start();
    await _until(() => mics.length == 1);
    await say('send it');
    await _until(() => voice.proposal != null);

    await voice.confirm(approve: true);

    expect(backend.confirmed, [('a1', true)]);
    expect(voice.proposal, isNull);
    expect(voice.confirming, isFalse);
  });

  test('tapping while it speaks cuts it off and listens', () async {
    backend.answer = (note, look) => const LiveSnapshot(
        answer: LiveAnswer('One. Two. Three.', done: false));
    await voice.start();
    await _until(() => mics.length == 1);
    await say('tell me a story');
    await _until(() => voice.state == LiveState.speaking);

    await voice.tap();

    await _until(() => mics.length == 2, 'listening again');
    expect(voice.state, LiveState.listening);
  });

  test('ending closes the microphone and stops for good', () async {
    await voice.start();
    await _until(() => mics.length == 1);

    await voice.end();

    expect(mics.first.closed, isTrue);
    expect(voice.active, isFalse);
    expect(voice.state, LiveState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(mics, hasLength(1), reason: 'it does not listen again');
  });

  test('without the node\'s voice models it says so and does not listen',
      () async {
    backend.voice = const LiveVoiceConfig(speech: true);

    await voice.start();

    expect(voice.setupNeeded, isTrue);
    expect(voice.notice, liveVoiceSetupMessage);
    expect(voice.active, isFalse);
    expect(mics, isEmpty);
  });

  test('a microphone that cannot open is explained', () async {
    final denied = LiveVoiceController(
      backend: backend,
      player: player,
      timing: _fast,
      openSession: () async =>
          throw const LiveVoiceException('Allow microphone access to talk.'),
    );
    addTearDown(denied.dispose);

    await denied.start();

    expect(denied.state, LiveState.error);
    expect(denied.notice, 'Allow microphone access to talk.');
  });

  test('an answer that never comes ends the wait', () async {
    await voice.start();
    await _until(() => mics.length == 1);
    await say('hello?');
    await _until(() => voice.state == LiveState.error, 'it to give up');
    expect(voice.notice, contains('No answer'));
  });
}
