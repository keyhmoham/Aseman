/// Reading the loosely typed props tool frontends send (JSON from an Elpian
/// program) and formatting values for
/// display.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../elpian/core/lenient.dart';
import '../../../elpian/widgets/elpian_icon.dart';

num? asNum(Object? v) {
  if (v is num) return v.isFinite ? v : null;
  if (v is String) return num.tryParse(v.trim().replaceAll(',', ''));
  if (v is bool) return v ? 1 : 0;
  return null;
}

double asDouble(Object? v, double fallback) => asNum(v)?.toDouble() ?? fallback;

int asInt(Object? v, int fallback) => asNum(v)?.round() ?? fallback;

/// A size: a non-negative number, else [fallback] (Flutter asserts on
/// negative sizes).
double asSize(Object? v, double fallback) {
  final n = asNum(v);
  return n == null || n < 0 ? fallback : n.toDouble();
}

/// A size, or null when absent or negative.
double? asSizeOrNull(Object? v) {
  final n = asNum(v);
  return n == null || n < 0 ? null : n.toDouble();
}

/// A count: a non-negative whole number, else [fallback].
int asCount(Object? v, int fallback) {
  final n = asNum(v);
  return n == null || n < 0 ? fallback : n.round();
}

bool asBool(Object? v, [bool fallback = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    if (v == 'true') return true;
    if (v == 'false') return false;
  }
  return fallback;
}

String asText(Object? v) {
  if (v == null) return '';
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return '$v';
}

/// [v] as a list (a lone value becomes a one-item list, null an empty one).
List<Object?> asList(Object? v) {
  if (v is List) return v;
  if (v is Map) return v.values.toList();
  if (v == null) return const [];
  return [v];
}

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? v.map((k, v) => MapEntry('$k', v)) : <String, dynamic>{};

/// Rows of a data set: maps stay maps; a scalar `x` becomes `{"value": x}`.
List<Map<String, dynamic>> asRows(Object? v) => [
      for (final item in asList(v))
        if (item is Map) asMap(item) else {'value': item, 'label': asText(item)}
    ];

/// A table cell. [key] is tried as written, then [label], then without
/// caring about case. [index] is the column's place, for a row that arrived
/// as a list (`"0"`, `"1"`, …).
Object? looseField(Map<String, dynamic> row, String key,
    {String? label, int? index}) {
  if (key.isNotEmpty && row.containsKey(key)) return row[key];
  if (label != null && label.isNotEmpty && label != key && row.containsKey(label)) {
    return row[label];
  }
  final wants = <String>{
    if (key.isNotEmpty) key.toLowerCase(),
    if (label != null && label.isNotEmpty) label.toLowerCase(),
  };
  if (wants.isNotEmpty) {
    for (final e in row.entries) {
      if (wants.contains(e.key.toLowerCase())) return e.value;
    }
  }
  if (index != null && row.containsKey('$index')) return row['$index'];
  return null;
}

/// Rows of a table. A list of lists is lined up with [fields] (and kept
/// under `"0"`, `"1"`, …). Anything else is [asRows].
List<Map<String, dynamic>> tableRows(Object? raw, List<String> fields) {
  if (raw is! List) return asRows(raw);
  final out = <Map<String, dynamic>>[];
  for (final item in raw) {
    if (item is List) {
      final row = <String, dynamic>{};
      for (var i = 0; i < item.length; i++) {
        row['$i'] = item[i];
        if (i < fields.length && fields[i].isNotEmpty) {
          row.putIfAbsent(fields[i], () => item[i]);
        }
      }
      out.add(row);
    } else if (item is Map) {
      out.add(asMap(item));
    } else {
      out.add({
        'value': item,
        'label': asText(item),
        if (fields.isNotEmpty && fields.first.isNotEmpty) fields.first: item,
      });
    }
  }
  return out;
}

/// When no column name is on the row, line the row's plain values up with
/// the columns in order. A row that already matches is left as it is.
void alignRowToColumns(Map<String, dynamic> row, List<String> fields,
    List<String> labels) {
  if (fields.isEmpty) return;
  final unmatched = <int>[];
  for (var i = 0; i < fields.length; i++) {
    final label = i < labels.length ? labels[i] : null;
    if (looseField(row, fields[i], label: label, index: i) == null) {
      unmatched.add(i);
    }
  }
  if (unmatched.length != fields.length) return;
  final scalars = [
    for (final e in row.entries)
      if (e.value is! Map && e.value is! List) e.value,
  ];
  if (scalars.length < fields.length) return;
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].isEmpty) continue;
    row.putIfAbsent(fields[i], () => scalars[i]);
  }
}

const _pairLabels = [
  'label',
  'key',
  'name',
  'title',
  'k',
  'field',
  'heading',
  'metric',
];
const _pairValues = [
  'value',
  'text',
  'content',
  'v',
  'amount',
  'display',
  'detail',
  'description',
  'reading',
];
const _pairSkip = {
  'format',
  'type',
  'color',
  'icon',
  'style',
  'width',
  'height',
  'variant',
  'align',
  'unit',
};

/// One row of a card: a label, the value to show, and an optional format.
class RecordPair {
  const RecordPair(this.label, this.value, {this.format, this.type});

  final String label;
  final Object value;
  final String? format;
  final String? type;
}

/// Label/value rows from the loose objects a card or a chart is given.
/// A list of `{label, value}` stays that. A map, or a list of one-field
/// maps (`{Humidity: "59%"}`), becomes one row per field. Empty rows are
/// dropped so a card is not a blank slab.
List<RecordPair> recordPairs(
  Object? raw, {
  Map<String, dynamic>? labels,
  Map<String, dynamic>? formats,
}) {
  final out = <RecordPair>[];
  void add(String label, Object? value, {String? format, String? type}) {
    final shown = _shown(value);
    if (shown == null) return;
    if (asText(shown).trim().isEmpty) return;
    out.add(RecordPair(label.trim(), shown, format: format, type: type));
  }

  if (raw is List) {
    for (final item in raw) {
      if (item is List && item.isNotEmpty) {
        add(asText(item.first), item.length > 1 ? item[1] : null);
      } else if (item is Map) {
        final m = asMap(item);
        if (_explicitPair(m)) {
          add(_pairLabel(m), _pairValue(m),
              format: looseStr(m['format']), type: looseStr(m['type']));
        } else {
          for (final e in m.entries) {
            if (_pairSkip.contains(e.key)) continue;
            add(_pairHeading(e.key), e.value);
          }
        }
      } else {
        add('', item);
      }
    }
  } else if (raw is Map) {
    final m = asMap(raw);
    if (_explicitPair(m)) {
      add(_pairLabel(m), _pairValue(m),
          format: looseStr(m['format']), type: looseStr(m['type']));
    } else {
      for (final e in m.entries) {
        if (_pairSkip.contains(e.key)) continue;
        final named = labels != null && labels[e.key] != null
            ? asText(labels[e.key])
            : _pairHeading(e.key);
        add(named, e.value, format: looseStr(formats?[e.key]));
      }
    }
  }
  return out;
}

bool _explicitPair(Map<String, dynamic> m) {
  final hasLabel = _pairLabels.any((k) => m[k] != null && m[k] is! Map);
  final hasValue = _pairValues.any((k) => m[k] != null);
  return hasLabel && hasValue;
}

String _pairLabel(Map<String, dynamic> m) {
  for (final k in _pairLabels) {
    final v = m[k];
    if (v != null && v is! Map && v is! List && asText(v).trim().isNotEmpty) {
      return asText(v).trim();
    }
  }
  return '';
}

Object? _pairValue(Map<String, dynamic> m) {
  for (final k in _pairValues) {
    if (m[k] != null) return m[k];
  }
  return null;
}

Object? _shown(Object? value) {
  if (value is Map) {
    final m = asMap(value);
    for (final k in _pairValues) {
      final v = m[k];
      if (v != null && v is! Map && v is! List) return v;
    }
    return null;
  }
  if (value is List) return null;
  return value;
}

String _pairHeading(String field) {
  final s = field
      .replaceAll(RegExp(r'[_\-.]'), ' ')
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .trim();
  if (s.isEmpty) return field;
  return s[0].toUpperCase() + s.substring(1);
}

/// The value at [path] of [row]: a field name, or a dotted path (`a.b.0`).
Object? field(Object? row, String? path) {
  if (path == null || path.isEmpty) return null;
  if (row is Map && row.containsKey(path)) return row[path];
  Object? cur = row;
  for (final part in path.split(RegExp(r'[./]'))) {
    if (part.isEmpty) continue;
    if (cur is Map) {
      cur = cur[part];
    } else if (cur is List) {
      final i = int.tryParse(part);
      cur = i != null && i >= 0 && i < cur.length ? cur[i] : null;
    } else {
      return null;
    }
  }
  return cur;
}

// ---------------------------------------------------------------------------
// Formats
// ---------------------------------------------------------------------------

/// Formats [v] by [format]: `kind[:arg[:arg]]`, with a leading `+` to sign
/// positive numbers.
///
/// | kind       | args               | 1234.5 →      |
/// |------------|--------------------|---------------|
/// | `number`   | decimals           | `1,234.5`     |
/// | `integer`  |                    | `1,235`       |
/// | `compact`  | decimals           | `1.2K`        |
/// | `percent`  | decimals (a fraction: 0.12 → 12%) |  |
/// | `currency` | code/symbol, decimals | `$1,234.50` |
/// | `date` / `time` / `datetime` | (ISO strings, epoch seconds or ms) | |
/// | `text`     |                    | as is         |
String formatValue(Object? v, [String? format]) {
  if (v == null) return '';
  var spec = (format ?? '').trim();
  if (spec.isEmpty || spec == 'text') {
    final n = v is num ? v : null;
    if (n != null) return formatNumber(n, decimals: _autoDecimals(n));
    return asText(v);
  }
  var signed = false;
  if (spec.startsWith('+')) {
    signed = true;
    spec = spec.substring(1);
  }
  final parts = spec.split(':');
  final kind = parts.first;
  if (kind == 'date' || kind == 'time' || kind == 'datetime') {
    final d = asDate(v);
    return d == null ? asText(v) : formatDate(d, kind);
  }
  final n = asNum(v);
  if (n == null) return asText(v);
  String sign(String s) => signed && n > 0 ? '+$s' : s;
  int? arg(int i) => parts.length > i ? int.tryParse(parts[i]) : null;
  switch (kind) {
    case 'integer':
      return sign(formatNumber(n, decimals: 0));
    case 'compact':
      return sign(formatCompact(n, decimals: arg(1) ?? 1));
    case 'percent':
      return sign('${formatNumber(n * 100, decimals: arg(1) ?? 0)}%');
    case 'currency':
      final code = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'USD';
      final symbol = _currencySymbols[code.toUpperCase()] ?? '$code ';
      final digits = arg(2) ?? 2;
      final body = formatNumber(n.abs(), decimals: digits);
      return n < 0 ? '-$symbol$body' : sign('$symbol$body');
    case 'number':
    default:
      return sign(formatNumber(n, decimals: arg(1) ?? _autoDecimals(n)));
  }
}

const Map<String, String> _currencySymbols = {
  'USD': r'$', 'EUR': '€', 'GBP': '£', 'JPY': '¥', 'CNY': '¥', 'INR': '₹', //
  'KRW': '₩', 'RUB': '₽', 'TRY': '₺', 'IRR': '﷼', 'BTC': '₿', 'ETH': 'Ξ',
  'USDT': '₮', r'$': r'$', '€': '€', '£': '£',
};

int _autoDecimals(num n) {
  if (n is int || n == n.roundToDouble()) return 0;
  final a = n.abs();
  if (a >= 100) return 1;
  if (a >= 1) return 2;
  if (a == 0) return 0;
  // Small values keep three significant digits.
  return math.min(8, (-math.log(a) / math.ln10).floor() + 3);
}

/// [n] with thousands separators and [decimals] fraction digits (trailing
/// zeros kept, as columns of figures align on them).
String formatNumber(num n, {int decimals = 0}) {
  if (!n.isFinite) return '$n';
  final fixed = n.abs().toStringAsFixed(decimals.clamp(0, 12));
  final dot = fixed.indexOf('.');
  final whole = dot < 0 ? fixed : fixed.substring(0, dot);
  final frac = dot < 0 ? '' : fixed.substring(dot);
  final out = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) out.write(',');
    out.write(whole[i]);
  }
  final negative = n < 0 && fixed.replaceAll(RegExp('[0.]'), '').isNotEmpty;
  return '${negative ? '-' : ''}$out$frac';
}

/// 1,284 / 12.9K / 4.2M / 1.1B.
String formatCompact(num n, {int decimals = 1}) {
  final a = n.abs();
  const steps = [(1e12, 'T'), (1e9, 'B'), (1e6, 'M'), (1e3, 'K')];
  for (final (size, suffix) in steps) {
    if (a >= size) {
      var s = (n / size).toStringAsFixed(decimals);
      if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
      return '$s$suffix';
    }
  }
  return formatNumber(n, decimals: n is int || n == n.roundToDouble() ? 0 : 1);
}

DateTime? asDate(Object? v) {
  if (v is DateTime) return v;
  if (v is num) {
    // Seconds before ~2286, milliseconds after.
    final ms = v.abs() < 1e10 ? v * 1000 : v;
    return DateTime.fromMillisecondsSinceEpoch(ms.round());
  }
  if (v is String) return DateTime.tryParse(v);
  return null;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', //
  'Nov', 'Dec',
];

String formatDate(DateTime d, String kind) {
  String two(int x) => x.toString().padLeft(2, '0');
  final date = '${_months[d.month - 1]} ${d.day}, ${d.year}';
  final time = '${two(d.hour)}:${two(d.minute)}';
  return switch (kind) {
    'time' => time,
    'datetime' => '$date $time',
    _ => date,
  };
}

/// Tick values for an axis over [min]..[max]: round steps (1, 2, 2.5, 5 ×
/// 10ⁿ), about [count] of them, covering the range.
List<double> niceTicks(double min, double max, {int count = 5}) {
  if (!min.isFinite || !max.isFinite) return const [0, 1];
  if (min == max) {
    final pad = min == 0 ? 1.0 : min.abs() * 0.1;
    min -= pad;
    max += pad;
  }
  final raw = (max - min) / math.max(1, count - 1);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final step = [1.0, 2.0, 2.5, 5.0, 10.0]
      .map((m) => m * mag)
      .firstWhere((s) => s >= raw, orElse: () => 10 * mag);
  final start = (min / step).floor() * step;
  final end = (max / step).ceil() * step;
  final ticks = <double>[];
  for (var v = start; v <= end + step / 2; v += step) {
    ticks.add(double.parse(v.toStringAsPrecision(12)));
  }
  return ticks;
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

/// The Material icon [name] names (camelCase like `arrowUpward`, Elpian
/// names like `arrow_upward`), or null.
IconData? iconFor(Object? name) {
  if (name is! String || name.isEmpty) return null;
  return ElpianIcon.iconData(name);
}
