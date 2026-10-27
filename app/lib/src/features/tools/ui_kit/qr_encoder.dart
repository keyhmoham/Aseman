/// A QR Code encoder (ISO/IEC 18004): byte mode, versions 1–40, error
/// correction L/M/Q/H, the mask with the lowest penalty. After Project
/// Nayuki's reference implementation (MIT).
library;

import 'dart:convert';
import 'dart:math' as math;

enum QrEcc {
  low(1, 0),
  medium(0, 1),
  quartile(3, 2),
  high(2, 3);

  const QrEcc(this.formatBits, this.ordinal);
  final int formatBits;
  final int ordinal;

  static QrEcc parse(Object? v) => switch ('${v ?? ''}'.toUpperCase()) {
        'L' || 'LOW' => low,
        'Q' || 'QUARTILE' => quartile,
        'H' || 'HIGH' => high,
        _ => medium,
      };
}

class QrCode {
  QrCode._(this.version, this.size, this.modules);

  final int version;
  final int size;

  /// modules[y][x]: true is dark.
  final List<List<bool>> modules;

  bool dark(int x, int y) => modules[y][x];

  /// Encodes [text] (UTF-8) at the smallest version that fits with [ecc];
  /// [mask] forces a mask pattern (0–7) instead of choosing the best.
  static QrCode encode(String text, {QrEcc ecc = QrEcc.medium, int? mask}) => encodeBytes(utf8.encode(text), ecc: ecc, mask: mask);

  static QrCode encodeBytes(List<int> data, {QrEcc ecc = QrEcc.medium, int? mask}) {
    int version = 1;
    int usedBits = 0;
    for (;; version++) {
      final capacity = _numDataCodewords(version, ecc) * 8;
      usedBits = 4 + (version < 10 ? 8 : 16) + data.length * 8;
      if (usedBits <= capacity) break;
      if (version >= 40) throw ArgumentError('Data too long for a QR code (${data.length} bytes)');
    }
    final bits = <int>[];
    void append(int value, int len) {
      for (var i = len - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    append(0x4, 4);
    append(data.length, version < 10 ? 8 : 16);
    for (final b in data) {
      append(b & 0xFF, 8);
    }
    final capacityBits = _numDataCodewords(version, ecc) * 8;
    append(0, math.min(4, capacityBits - bits.length));
    append(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < capacityBits; pad ^= 0xEC ^ 0x11) {
      append(pad, 8);
    }
    final codewords = List<int>.filled(bits.length ~/ 8, 0);
    for (var i = 0; i < bits.length; i++) {
      codewords[i >> 3] |= bits[i] << (7 - (i & 7));
    }
    return _Builder(version, ecc).build(_addEccAndInterleave(codewords, version, ecc), mask);
  }

  static const _eccPerBlock = [
    [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  ];
  static const _numBlocks = [
    [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
  ];

  static int _numRawDataModules(int ver) {
    var result = (16 * ver + 128) * ver + 64;
    if (ver >= 2) {
      final numAlign = ver ~/ 7 + 2;
      result -= (25 * numAlign - 10) * numAlign - 55;
      if (ver >= 7) result -= 36;
    }
    return result;
  }

  static int _numDataCodewords(int ver, QrEcc ecc) =>
      _numRawDataModules(ver) ~/ 8 - _eccPerBlock[ecc.ordinal][ver] * _numBlocks[ecc.ordinal][ver];

  static List<int> _addEccAndInterleave(List<int> data, int ver, QrEcc ecc) {
    final numBlocks = _numBlocks[ecc.ordinal][ver];
    final blockEccLen = _eccPerBlock[ecc.ordinal][ver];
    final rawCodewords = _numRawDataModules(ver) ~/ 8;
    final numShortBlocks = numBlocks - rawCodewords % numBlocks;
    final shortBlockLen = rawCodewords ~/ numBlocks;
    final divisor = _rsDivisor(blockEccLen);
    final blocks = <List<int>>[];
    var k = 0;
    for (var i = 0; i < numBlocks; i++) {
      final len = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1);
      final dat = data.sublist(k, k + len);
      k += len;
      final ecc0 = _rsRemainder(dat, divisor);
      blocks.add([...dat, if (i < numShortBlocks) 0, ...ecc0]);
    }
    final result = <int>[];
    for (var i = 0; i < blocks[0].length; i++) {
      for (var j = 0; j < blocks.length; j++) {
        if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) result.add(blocks[j][i]);
      }
    }
    return result;
  }

  static List<int> _rsDivisor(int degree) {
    final result = List<int>.filled(degree, 0)..[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _mul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _mul(root, 0x02);
    }
    return result;
  }

  static List<int> _rsRemainder(List<int> data, List<int> divisor) {
    final result = List<int>.filled(divisor.length, 0, growable: true);
    for (final b in data) {
      final factor = b ^ result.removeAt(0);
      result.add(0);
      for (var i = 0; i < result.length; i++) {
        result[i] ^= _mul(divisor[i], factor);
      }
    }
    return result;
  }

  static int _mul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z & 0xFF;
  }
}

class _Builder {
  _Builder(this.version, this.ecc)
      : size = version * 4 + 17,
        modules = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false)),
        isFunction = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false));

  final int version;
  final QrEcc ecc;
  final int size;
  final List<List<bool>> modules;
  final List<List<bool>> isFunction;

  QrCode build(List<int> codewords, int? forcedMask) {
    _drawFunctionPatterns();
    _drawCodewords(codewords);
    var mask = forcedMask ?? -1;
    if (mask < 0) {
      var minPenalty = 1 << 30;
      for (var i = 0; i < 8; i++) {
        _applyMask(i);
        _drawFormatBits(i);
        final penalty = _penalty();
        if (penalty < minPenalty) {
          mask = i;
          minPenalty = penalty;
        }
        _applyMask(i);
      }
    }
    _applyMask(mask);
    _drawFormatBits(mask);
    return QrCode._(version, size, modules);
  }

  void _set(int x, int y, bool dark) {
    modules[y][x] = dark;
    isFunction[y][x] = true;
  }

  void _drawFunctionPatterns() {
    for (var i = 0; i < size; i++) {
      _set(6, i, i % 2 == 0);
      _set(i, 6, i % 2 == 0);
    }
    _finder(3, 3);
    _finder(size - 4, 3);
    _finder(3, size - 4);
    final pos = _alignmentPositions();
    final n = pos.length;
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (!(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0)) _alignment(pos[i], pos[j]);
      }
    }
    _drawFormatBits(0);
    _drawVersion();
  }

  void _finder(int x, int y) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final dist = math.max(dx.abs(), dy.abs());
        final xx = x + dx, yy = y + dy;
        if (xx >= 0 && xx < size && yy >= 0 && yy < size) _set(xx, yy, dist != 2 && dist != 4);
      }
    }
  }

  void _alignment(int x, int y) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        _set(x + dx, y + dy, math.max(dx.abs(), dy.abs()) != 1);
      }
    }
  }

  List<int> _alignmentPositions() {
    if (version == 1) return const [];
    final numAlign = version ~/ 7 + 2;
    final step = version == 32 ? 26 : ((version * 4 + numAlign * 2 + 1) ~/ (numAlign * 2 - 2)) * 2;
    final result = <int>[6];
    for (var pos = size - 7; result.length < numAlign; pos -= step) {
      result.insert(1, pos);
    }
    return result;
  }

  static bool _bit(int x, int i) => ((x >> i) & 1) != 0;

  void _drawFormatBits(int mask) {
    final data = ecc.formatBits << 3 | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    for (var i = 0; i <= 5; i++) {
      _set(8, i, _bit(bits, i));
    }
    _set(8, 7, _bit(bits, 6));
    _set(8, 8, _bit(bits, 7));
    _set(7, 8, _bit(bits, 8));
    for (var i = 9; i < 15; i++) {
      _set(14 - i, 8, _bit(bits, i));
    }
    for (var i = 0; i < 8; i++) {
      _set(size - 1 - i, 8, _bit(bits, i));
    }
    for (var i = 8; i < 15; i++) {
      _set(8, size - 15 + i, _bit(bits, i));
    }
    _set(8, size - 8, true);
  }

  void _drawVersion() {
    if (version < 7) return;
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = version << 12 | rem;
    for (var i = 0; i < 18; i++) {
      final b = _bit(bits, i);
      final a = size - 11 + i % 3, c = i ~/ 3;
      _set(a, c, b);
      _set(c, a, b);
    }
  }

  void _drawCodewords(List<int> data) {
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = ((right + 1) & 2) == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!isFunction[y][x] && i < data.length * 8) {
            modules[y][x] = _bit(data[i >> 3], 7 - (i & 7));
            i++;
          }
        }
      }
    }
  }

  void _applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final invert = switch (mask) {
          0 => (x + y) % 2 == 0,
          1 => y % 2 == 0,
          2 => x % 3 == 0,
          3 => (x + y) % 3 == 0,
          4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
          5 => x * y % 2 + x * y % 3 == 0,
          6 => (x * y % 2 + x * y % 3) % 2 == 0,
          _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
        };
        if (invert && !isFunction[y][x]) modules[y][x] = !modules[y][x];
      }
    }
  }

  int _penalty() {
    var result = 0;
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        var runColor = false;
        var run = 0;
        final history = List<int>.filled(7, 0);
        for (var b = 0; b < size; b++) {
          final m = pass == 0 ? modules[a][b] : modules[b][a];
          if (m == runColor) {
            run++;
            if (run == 5) {
              result += 3;
            } else if (run > 5) {
              result++;
            }
          } else {
            _addHistory(run, history);
            if (!runColor) result += _countPatterns(history) * 40;
            runColor = m;
            run = 1;
          }
        }
        result += _terminate(runColor, run, history) * 40;
      }
    }
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = modules[y][x];
        if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += 3;
      }
    }
    var dark = 0;
    for (final row in modules) {
      for (final m in row) {
        if (m) dark++;
      }
    }
    final total = size * size;
    final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
    return result + k * 10;
  }

  int _countPatterns(List<int> h) {
    final n = h[1];
    final core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
    return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
  }

  int _terminate(bool runColor, int run, List<int> history) {
    if (runColor) {
      _addHistory(run, history);
      run = 0;
    }
    run += size;
    _addHistory(run, history);
    return _countPatterns(history);
  }

  void _addHistory(int run, List<int> history) {
    if (history[0] == 0) run += size;
    history.setRange(1, 7, history.sublist(0, 6));
    history[0] = run;
  }
}
