/// Value conversion and formatting the A2UI basic catalog prescribes
/// (`en-US` number, currency, date and plural conventions, `openUrl`'s URL
/// checks), shared by Tradera's client functions and components.
library;

import 'dart:convert';

/// A number the way JavaScript's `String(n)` prints it (`1.0` → `1`).
String numberToString(num n) {
  if (n is int) return n.toString();
  if (n.isNaN) return 'NaN';
  if (n.isInfinite) return n > 0 ? 'Infinity' : '-Infinity';
  if (n == n.truncateToDouble() && n.abs() < 1e21) return n.toInt().toString();
  return n.toString();
}

/// Stringify an interpolated value the way the protocol prescribes.
String stringifyValue(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) return numberToString(value);
  if (value is bool) return value.toString();
  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

bool toBool(Object? value) => value == true || value == 'true';

num? toNum(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is String && value.trim().isNotEmpty) {
    final n = num.tryParse(value.trim());
    return n != null && n.isFinite ? n : null;
  }
  return null;
}

final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Group the integer digits of [digits] with commas.
String _group(String digits) {
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// `en-US` decimal formatting: [minFraction]..[maxFraction] digits, optional
/// grouping, half-away-from-zero rounding.
String formatDecimal(num n,
    {int minFraction = 0, int maxFraction = 3, bool grouping = true}) {
  final negative = n < 0;
  var text = n.abs().toStringAsFixed(maxFraction);
  // Trim optional trailing zeros down to minFraction.
  if (maxFraction > minFraction && text.contains('.')) {
    var end = text.length;
    final dot = text.indexOf('.');
    while (end > dot + 1 + minFraction && text[end - 1] == '0') {
      end--;
    }
    if (end == dot + 1) end = dot;
    text = text.substring(0, end);
  }
  final dot = text.indexOf('.');
  final intPart = dot < 0 ? text : text.substring(0, dot);
  final frac = dot < 0 ? '' : text.substring(dot);
  final body = (grouping ? _group(intPart) : intPart) + frac;
  final isZero = double.parse(text) == 0;
  return negative && !isZero ? '-$body' : body;
}

({int min, int max})? _decimalsArg(Map<String, dynamic> args) {
  final decimals = toNum(args['decimals']);
  if (decimals == null) return null;
  final d = decimals.truncate().clamp(0, 20);
  return (min: d, max: d);
}

const Map<String, String> _currencySymbols = {
  'USD': r'$',
  'EUR': '€',
  'GBP': '£',
  'JPY': '¥',
  'INR': '₹',
  'CNY': 'CN¥',
  'CAD': r'CA$',
  'AUD': r'A$',
  'KRW': '₩',
  'BRL': r'R$',
  'MXN': r'MX$',
  'ILS': '₪',
  'VND': '₫',
  'NZD': r'NZ$',
  'HKD': r'HK$',
  'TWD': r'NT$',
  'PHP': '₱',
};

/// Currencies whose minor unit has no digits.
const Set<String> _zeroDecimalCurrencies = {'JPY', 'KRW', 'VND', 'CLP', 'ISK'};

final RegExp _scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):');

/// `openUrl`'s mandatory checks: resolve relative URLs against [base], then
/// allow only `http:` and `https:` (no `javascript:`, `data:`, …).
String validateOpenUrl(Object? url, String? base) {
  if (url is! String || url.trim().isEmpty) {
    throw const FormatException('openUrl: "url" must be a non-empty string');
  }
  final raw = url.trim();
  var resolved = raw;
  if (!_scheme.hasMatch(raw)) {
    if (base == null) {
      throw FormatException('openUrl: cannot resolve relative URL "$raw"');
    }
    try {
      resolved = Uri.parse(base).resolve(raw).toString();
    } catch (_) {
      throw FormatException('openUrl: invalid URL "$raw"');
    }
  }
  final protocol = (_scheme.firstMatch(resolved)?.group(1) ?? '').toLowerCase();
  if (protocol != 'http' && protocol != 'https') {
    throw FormatException(
        'openUrl: the "$protocol:" scheme is not allowed (http and https only)');
  }
  return resolved;
}

// ----------------------------------------------------------------------------
// Dates
// ----------------------------------------------------------------------------

final RegExp _dateOnly = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final RegExp _timeOnly = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?$');

/// Parse an A2UI date value: an ISO 8601 date-time (`2026-02-02T15:17:00Z`),
/// a date (`2026-02-02`, local midnight), a time (`14:30`, today), or epoch
/// milliseconds. The result is in local time.
DateTime? parseDate(Object? value) {
  if (value is DateTime) return value.toLocal();
  if (value is num) {
    return value.isFinite
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;
  }
  if (value is! String || value.trim().isEmpty) return null;
  final s = value.trim();
  var m = _dateOnly.firstMatch(s);
  if (m != null) {
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }
  m = _timeOnly.firstMatch(s);
  if (m != null) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, int.parse(m[1]!),
        int.parse(m[2]!), int.parse(m[3] ?? '0'));
  }
  // A date-time without an offset is local time; with one, absolute.
  return DateTime.tryParse(s)?.toLocal();
}

String _pad(int n, int width) => n.toString().padLeft(width, '0');

const List<String> _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];
const List<String> _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
  'Sunday',
];

final RegExp _letter = RegExp(r'[A-Za-z]');

/// Format [date] with a Unicode TR35 pattern (`yyyy-MM-dd`,
/// `EEEE, MMM d 'at' h:mm a`, …).
String formatDatePattern(DateTime date, String pattern,
    {String locale = 'en-US'}) {
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i];
    if (ch == "'") {
      // Quoted literal; '' is a single quote.
      if (i + 1 < pattern.length && pattern[i + 1] == "'") {
        out.write("'");
        i += 2;
        continue;
      }
      var j = i + 1;
      while (j < pattern.length) {
        if (pattern[j] == "'" &&
            j + 1 < pattern.length &&
            pattern[j + 1] == "'") {
          out.write("'");
          j += 2;
          continue;
        }
        if (pattern[j] == "'") break;
        out.write(pattern[j++]);
      }
      i = j + 1;
      continue;
    }
    if (!_letter.hasMatch(ch)) {
      out.write(ch);
      i++;
      continue;
    }
    var n = 1;
    while (i + n < pattern.length && pattern[i + n] == ch) {
      n++;
    }
    i += n;
    out.write(_field(date, ch, n));
  }
  return out.toString();
}

String _field(DateTime d, String ch, int n) {
  switch (ch) {
    case 'y':
    case 'Y':
    case 'u':
      return n == 2 ? _pad(d.year % 100, 2) : _pad(d.year, n);
    case 'M':
    case 'L':
      if (n >= 4) return _months[d.month - 1];
      if (n == 3) return _months[d.month - 1].substring(0, 3);
      return _pad(d.month, n);
    case 'd':
      return _pad(d.day, n);
    case 'D':
      final start = DateTime(d.year, 1, 1);
      return _pad(
          DateTime(d.year, d.month, d.day).difference(start).inDays + 1, n);
    case 'E':
    case 'e':
    case 'c':
      final name = _weekdays[d.weekday - 1];
      if (n == 5) return name.substring(0, 1);
      if (n >= 4) return name;
      return name.substring(0, 3);
    case 'a':
      return d.hour < 12 ? 'AM' : 'PM';
    case 'h':
      return _pad(d.hour % 12 == 0 ? 12 : d.hour % 12, n);
    case 'K':
      return _pad(d.hour % 12, n);
    case 'H':
      return _pad(d.hour, n);
    case 'k':
      return _pad(d.hour == 0 ? 24 : d.hour, n);
    case 'm':
      return _pad(d.minute, n);
    case 's':
      return _pad(d.second, n);
    case 'S':
      return _pad(d.millisecond, 3).substring(0, n.clamp(1, 3));
    case 'z':
    case 'Z':
    case 'x':
    case 'X':
      final offset = d.timeZoneOffset.inMinutes;
      if (offset == 0 && (ch == 'X' || ch == 'x')) return 'Z';
      final sign = offset >= 0 ? '+' : '-';
      final abs = offset.abs();
      return '$sign${_pad(abs ~/ 60, 2)}:${_pad(abs % 60, 2)}';
    default:
      return ch * n;
  }
}

// ----------------------------------------------------------------------------
// The basic catalog's functions, on resolved arguments. The A2UI spelling of
// each argument is read first, then the one genui's own functions use
// (`decimalPlaces`, `useGrouping`, `currencyCode`, `pattern`).
// ----------------------------------------------------------------------------

bool specRequired(Map<String, Object?> args) {
  final value = args['value'];
  return !(value == null ||
      value == '' ||
      (value is List && value.isEmpty) ||
      (value is Map && value.isEmpty));
}

bool specRegex(Map<String, Object?> args) {
  final pattern = args['pattern'];
  if (pattern is! String) {
    throw const FormatException('regex: "pattern" must be a string');
  }
  final RegExp re;
  try {
    re = RegExp(pattern);
  } catch (_) {
    throw FormatException('regex: invalid pattern "$pattern"');
  }
  return re.hasMatch(stringifyValue(args['value']));
}

bool specLength(Map<String, Object?> args) {
  final v = args['value'];
  final n = v is List
      ? v.length
      : v is Map
          ? v.length
          : stringifyValue(v).length;
  final min = toNum(args['min']);
  final max = toNum(args['max']);
  if (min != null && n < min) return false;
  if (max != null && n > max) return false;
  return true;
}

bool specNumeric(Map<String, Object?> args) {
  final n = toNum(args['value']);
  if (n == null) return false;
  final min = toNum(args['min']);
  final max = toNum(args['max']);
  if (min != null && n < min) return false;
  if (max != null && n > max) return false;
  return true;
}

bool specEmail(Map<String, Object?> args) {
  final value = args['value'];
  return value is String && _emailPattern.hasMatch(value.trim());
}

Map<String, dynamic> _decimalArgs(Map<String, Object?> args) => {
      'decimals': args['decimals'] ?? args['decimalPlaces'],
    };

bool _grouping(Map<String, Object?> args) =>
    (args['grouping'] ?? args['useGrouping']) != false;

String specFormatNumber(Map<String, Object?> args) {
  final n = toNum(args['value']);
  if (n == null) return '';
  final d = _decimalsArg(_decimalArgs(args));
  return formatDecimal(n,
      minFraction: d?.min ?? 0,
      maxFraction: d?.max ?? 3,
      grouping: _grouping(args));
}

String specFormatCurrency(Map<String, Object?> args) {
  final n = toNum(args['value']);
  if (n == null) return '';
  final raw = args['currency'] ?? args['currencyCode'];
  final currency = raw is String && RegExp(r'^[A-Za-z]{3}$').hasMatch(raw)
      ? raw.toUpperCase()
      : 'USD';
  final standard = _zeroDecimalCurrencies.contains(currency) ? 0 : 2;
  final d = _decimalsArg(_decimalArgs(args));
  final body = formatDecimal(n.abs(),
      minFraction: d?.min ?? standard,
      maxFraction: d?.max ?? standard,
      grouping: _grouping(args));
  final symbol = _currencySymbols[currency] ?? '$currency ';
  final negative = n < 0 && double.parse(body.replaceAll(',', '')) != 0;
  return '${negative ? '-' : ''}$symbol$body';
}

String specFormatDate(Map<String, Object?> args) {
  final date = parseDate(args['value']);
  if (date == null) return '';
  final format = args['format'] ?? args['pattern'];
  return formatDatePattern(
      date, format is String && format.isNotEmpty ? format : 'yyyy-MM-dd');
}

String specPluralize(Map<String, Object?> args) {
  final n = toNum(args['value'] ?? args['count']);
  if (n == null) return stringifyValue(args['other']);
  var category = n == 1 ? 'one' : 'other';
  // English reports 0 as "other"; an explicit zero form wins.
  if (n == 0 && args['zero'] != null) category = 'zero';
  return stringifyValue(args[category] ?? args['other']);
}
