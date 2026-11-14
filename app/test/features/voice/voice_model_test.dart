import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/features/voice/voice_model.dart';

void main() {
  test('formatVoiceClock matches Decillion clocks', () {
    expect(formatVoiceClock(0), '0:00');
    expect(formatVoiceClock(7000), '0:07');
    expect(formatVoiceClock(65000), '1:05');
  });

  test('voiceLongEnough rejects accidental taps', () {
    expect(voiceLongEnough(0), isFalse);
    expect(voiceLongEnough(599), isFalse);
    expect(voiceLongEnough(600), isTrue);
  });

  test('levelsToWaveBars folds levels into 0..100 bars', () {
    expect(levelsToWaveBars(const []), isEmpty);
    final bars = levelsToWaveBars(
      List<double>.generate(200, (i) => i < 100 ? 0.1 : 0.5),
    );
    expect(bars, hasLength(waveBars));
    expect(bars.every((b) => b >= 6 && b <= 100), isTrue);
    expect(bars.last, greaterThan(bars.first));
  });

  test('levelFromPcm16 is quiet for silence and louder for a tone', () {
    final silence = List<int>.filled(200, 0);
    expect(levelFromPcm16(silence), 0);

    final loud = <int>[];
    for (var i = 0; i < 100; i++) {
      const sample = 12000;
      loud.add(sample & 0xff);
      loud.add((sample >> 8) & 0xff);
    }
    expect(levelFromPcm16(loud), greaterThan(0.2));
  });
}
