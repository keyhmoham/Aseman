import 'dart:typed_data';

import 'package:aseman/src/features/assistant/dictation_button.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wav wraps 16-bit mono PCM in a RIFF header', () {
    final pcm = Uint8List.fromList(List.filled(32000, 1));
    final out = wav(pcm, 16000);
    final header = ByteData.sublistView(out, 0, 44);
    expect(String.fromCharCodes(out.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(out.sublist(8, 12)), 'WAVE');
    expect(header.getUint32(24, Endian.little), 16000);
    expect(header.getUint32(40, Endian.little), pcm.length);
    expect(out.length, 44 + pcm.length);
  });
}
