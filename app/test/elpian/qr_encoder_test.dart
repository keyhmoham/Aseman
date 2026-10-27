// The QR encoder against an independent implementation (the qrcode npm
// package): the same bytes, error correction and mask give the same matrix,
// from version 1 to 40.
import 'dart:convert';
import 'dart:io';

import 'package:aseman/src/features/tools/ui_kit/qr_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final cases = (jsonDecode(File('test/elpian/fixtures/qr_reference.json').readAsStringSync())['cases'] as List).cast<Map<String, dynamic>>();

  for (final c in cases) {
    test('v${c['version']} ${c['ecc']} mask ${c['mask']} (${(c['text'] as String).length} chars)', () {
      final qr = QrCode.encode(c['text'] as String, ecc: QrEcc.parse(c['ecc']), mask: c['mask'] as int);
      expect(qr.version, c['version']);
      final rows = [for (var y = 0; y < qr.size; y++) [for (var x = 0; x < qr.size; x++) qr.dark(x, y) ? '1' : '0'].join()];
      expect(rows, c['rows']);
    });
  }

  // Without a forced mask, the encoder picks the mask with the lowest
  // penalty, as the reference (Project Nayuki's qrcodegen) does.
  final auto = (jsonDecode(File('test/elpian/fixtures/qr_auto_mask.json').readAsStringSync())['cases'] as List).cast<Map<String, dynamic>>();
  for (final c in auto) {
    test('auto mask: v${c['version']} ${c['ecc']} picks mask ${c['mask']} (${(c['text'] as String).length} chars)', () {
      final qr = QrCode.encode(c['text'] as String, ecc: QrEcc.parse(c['ecc']));
      final rows = [for (var y = 0; y < qr.size; y++) [for (var x = 0; x < qr.size; x++) qr.dark(x, y) ? '1' : '0'].join()];
      expect(rows, c['rows']);
    });
  }

  test('the code is square', () {
    final qr = QrCode.encode('https://aseman.app/s/abc');
    expect(qr.size, qr.version * 4 + 17);
  });

  test('too much data is an error', () {
    expect(() => QrCode.encode('x' * 3000, ecc: QrEcc.high), throwsArgumentError);
  });
}
