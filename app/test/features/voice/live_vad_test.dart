import 'package:aseman/src/features/voice/live/live_vad.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime clock;
  late Vad vad;

  VadEvent? tick(double level, int afterMs, {bool drained = true}) {
    clock = clock.add(Duration(milliseconds: afterMs));
    return vad.tick(level, queueDrained: drained);
  }

  setUp(() {
    clock = DateTime(2026);
    vad = Vad(
      const VadConfig(
        chunkSilence: Duration(milliseconds: 600),
        turnSilence: Duration(milliseconds: 1300),
        maxChunk: Duration(seconds: 5),
      ),
      now: () => clock,
    );
  });

  test('idle silence alone never ends a turn', () {
    for (var i = 0; i < 100; i++) {
      expect(tick(0, 100), isNull);
    }
    expect(vad.pendingSpeech, isFalse);
  });

  test('speech is noticed once per chunk', () {
    expect(tick(0.5, 100), VadEvent.speaking);
    expect(tick(0.5, 100), isNull);
    expect(vad.pendingSpeech, isTrue);
  });

  test('a short silence closes the chunk; a longer one ends the turn', () {
    tick(0.5, 100);
    expect(tick(0, 300), isNull);
    expect(tick(0, 300), VadEvent.chunkBoundary);
    expect(vad.pendingSpeech, isFalse);
    expect(tick(0, 300), isNull);
    expect(tick(0, 400), VadEvent.turnOver);
  });

  test('the turn waits for every chunk sent to come back', () {
    tick(0.5, 100);
    tick(0, 700); // chunk boundary
    expect(tick(0, 1000, drained: false), isNull);
    expect(tick(0, 100), VadEvent.turnOver);
  });

  test('speaking again after a chunk starts the next one', () {
    tick(0.5, 100);
    tick(0, 700);
    expect(tick(0.5, 200), VadEvent.speaking);
    expect(vad.pendingSpeech, isTrue);
  });

  test('a long run of speech is cut so a chunk stays small', () {
    expect(tick(0.5, 100), VadEvent.speaking);
    VadEvent? last;
    for (var i = 0; i < 60 && last == null; i++) {
      last = tick(0.5, 100);
    }
    expect(last, VadEvent.chunkBoundary);
    expect(tick(0.5, 100), VadEvent.speaking);
  });

  test('reset starts a fresh turn', () {
    tick(0.5, 100);
    vad.reset();
    expect(vad.pendingSpeech, isFalse);
    expect(tick(0, 5000), isNull);
  });
}
