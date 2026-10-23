/// Reading the loosely typed props tool frontends send (JSON from an Elpian
/// program, or AG-UI data the node filled in) and formatting values for
/// display.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../elpian/widgets/elpian_icon.dart';

num? asNum(Object? v) {
  if (v is num) return v.isFinite ? v : null;
  if (v is String) return num.tryParse(v.trim().replaceAll(',', ''));
  if (v is bool) return v ? 1 : 0;
  return null;
}

double asDouble(Object? v, double fallback) => asNum(v)?.toDouble() ?? fallback;

int asInt(Object? v, int fallback) => asNum(v)?.round() ?? fallback;

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

/// The Material icon [name] names (AG-UI names like `arrowUpward`, Elpian
/// names like `arrow_upward`), or null.
IconData? iconFor(Object? name) {
  if (name is! String || name.isEmpty) return null;
  return _extraIcons[name] ?? ElpianIcon.iconData(name);
}

const Map<String, IconData> _extraIcons = {
  'trendingUp': Icons.trending_up,
  'trendingDown': Icons.trending_down,
  'trendingFlat': Icons.trending_flat,
  'showChart': Icons.show_chart,
  'barChart': Icons.bar_chart,
  'pieChart': Icons.pie_chart,
  'table': Icons.table_chart_outlined,
  'wallet': Icons.account_balance_wallet_outlined,
  'bank': Icons.account_balance_outlined,
  'money': Icons.attach_money,
  'clock': Icons.schedule,
  'bolt': Icons.bolt,
  'cloud': Icons.cloud_outlined,
  'sun': Icons.wb_sunny_outlined,
  'rain': Icons.water_drop_outlined,
  'wind': Icons.air,
  'thermometer': Icons.thermostat,
  'user': Icons.person_outline,
  'users': Icons.group_outlined,
  'globe': Icons.public,
  'link': Icons.link,
  'code': Icons.code,
  'database': Icons.storage,
  'server': Icons.dns_outlined,
  'chat': Icons.chat_bubble_outline,
  'flag': Icons.flag_outlined,
  'tag': Icons.sell_outlined,
  'bookmark': Icons.bookmark_outline,
  'filter': Icons.filter_list,
  'sort': Icons.sort,
  'speed': Icons.speed,
  'timeline': Icons.timeline,
  'hub': Icons.hub_outlined,
  'tree': Icons.account_tree_outlined,
};
