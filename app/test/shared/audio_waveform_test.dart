import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/shared/widgets/audio_waveform.dart';

void main() {
  test('a clip always draws the same bars, all within range', () {
    final a = AudioWaveform.levels('file-1', 40);
    expect(a, AudioWaveform.levels('file-1', 40));
    expect(a, isNot(AudioWaveform.levels('file-2', 40)));
    expect(a.every((l) => l >= .18 && l <= 1), isTrue);
  });

  testWidgets('tapping the waveform seeks to that fraction', (tester) async {
    double? seeked;
    await tester.pumpWidget(MaterialApp(
        home: Center(
            child: SizedBox(
                width: 200,
                child: AudioWaveform(
                    seed: 'clip', progress: .2, onSeek: (f) => seeked = f)))));
    final box = tester.getRect(find.byType(AudioWaveform));
    await tester.tapAt(Offset(box.left + 150, box.center.dy));
    expect(seeked, closeTo(.75, .01));
  });
}
