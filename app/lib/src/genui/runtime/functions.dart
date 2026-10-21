/// Aseman's client functions: the basic catalog's (to the A2UI spec's
/// argument names and `en-US` conventions) and Aseman's own —
///
/// * formatting in the kit's format language (`format`, `formatPercent`,
///   `formatCompact`, `formatRelative`) and a live clock (`now`);
/// * math and aggregates (`add`, `subtract`, `multiply`, `divide`, `round`,
///   `abs`, `clamp`, `percentChange`, `sum`, `average`, `min`, `max`,
///   `count`);
/// * comparison and logic (`equals`, `notEquals`, `greaterThan`, `lessThan`,
///   `isEmpty`, `contains`, `if`, `coalesce`);
/// * text (`concat`, `join`, `upper`, `lower`, `truncate`) and lookup (`get`);
/// * client-side state, for a Button's `functionCall` action — UI that
///   reacts without a round trip (`setValue`, `toggle`, `increment`,
///   `append`, `removeAt`, `copyToClipboard`, `showToast`, `openUrl`).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:genui/genui.dart';
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/tools/ui_kit/values.dart' as kit;
import 'dynamic_values.dart';
import 'format.dart';

typedef _Impl = Object? Function(JsonMap args, ExecutionContext context);

/// A synchronous function from a name, a description, its arguments and an
/// implementation.
class AsemanFunction extends SynchronousClientFunction {
  const AsemanFunction(
    this.name,
    this.description,
    this._args,
    this._impl, {
    this.returnType = ClientFunctionReturnType.any,
    this.required = const [],
  });

  @override
  final String name;
  @override
  final String description;
  @override
  final ClientFunctionReturnType returnType;
  final Map<String, Schema> _args;
  final List<String> required;
  final _Impl _impl;

  @override
  Schema get argumentSchema =>
      S.object(properties: _args, required: required);

  @override
  Object? executeSync(JsonMap args, ExecutionContext context) =>
      _impl(args, context);

  /// genui resolves top-level arguments only; bindings and calls inside
  /// list or map arguments (`and`'s `values`: a DynamicBooleanList) are
  /// resolved here.
  @override
  Stream<Object?> execute(JsonMap args, ExecutionContext context) {
    if (!args.values.any(containsDynamic)) return super.execute(args, context);
    final keys = args.keys.toList();
    return [for (final k in keys) deepResolve(context, args[k])]
        .combineLatestAll()
        .switchMap((values) => super.execute(
            {for (var i = 0; i < keys.length; i++) keys[i]: values[i]},
            context));
  }
}

/// [v] with every binding and call inside it resolved, kept current.
Stream<Object?> deepResolve(ExecutionContext context, Object? v) {
  if (isDynamic(v)) return context.resolve(v);
  if (v is Map && containsDynamic(v)) {
    final keys = [for (final k in v.keys) '$k'];
    return [for (final k in v.keys) deepResolve(context, v[k])]
        .combineLatestAll()
        .map((values) => <String, Object?>{
              for (var i = 0; i < keys.length; i++) keys[i]: values[i],
            });
  }
  if (v is List && containsDynamic(v)) {
    return [for (final x in v) deepResolve(context, x)].combineLatestAll();
  }
  return Stream.value(v);
}

/// A function whose result changes over time (a clock): [ticks] emits its
/// value now and then every [every].
class TickingFunction implements ClientFunction {
  const TickingFunction(this.name, this.description, this._args, this._impl,
      {this.every = const Duration(seconds: 1),
      this.returnType = ClientFunctionReturnType.string});

  @override
  final String name;
  @override
  final String description;
  @override
  final ClientFunctionReturnType returnType;
  final Map<String, Schema> _args;
  final Object? Function(JsonMap args) _impl;
  final Duration every;

  @override
  Schema get argumentSchema => S.object(properties: _args);

  @override
  Stream<Object?> execute(JsonMap args, ExecutionContext context) {
    late StreamController<Object?> controller;
    Timer? timer;
    controller = StreamController<Object?>(
      onListen: () {
        controller.add(_impl(args));
        timer = Timer.periodic(every, (_) => controller.add(_impl(args)));
      },
      onCancel: () {
        timer?.cancel();
        return controller.close();
      },
    );
    return controller.stream;
  }
}

final Schema _any = S.any();
final Schema _num = S.number();
final Schema _str = S.string();
final Schema _bool = S.boolean();
final Schema _list = S.list(items: S.any());
const _string = ClientFunctionReturnType.string;
const _number = ClientFunctionReturnType.number;
const _boolean = ClientFunctionReturnType.boolean;
const _void = ClientFunctionReturnType.empty;

num? _n(Object? v) => kit.asNum(v);

/// The numbers of a list (optionally a [field] of each row).
List<num> _numbers(Object? values, [Object? field]) => [
      for (final v in values is List ? values : const [])
        if (_n(field is String && field.isNotEmpty ? kit.field(v, field) : v)
            case final num n)
          n
    ];

num _tidy(num n) => n is double && n == n.roundToDouble() && n.abs() < 1e15
    ? n.toInt()
    : n;

bool _equal(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  final na = _n(a), nb = _n(b);
  if (na != null && nb != null && (a is num || b is num)) return na == nb;
  return stringifyValue(a) == stringifyValue(b);
}

int _compare(Object? a, Object? b) {
  final na = _n(a), nb = _n(b);
  if (na != null && nb != null) return na.compareTo(nb);
  return stringifyValue(a).compareTo(stringifyValue(b));
}

String _relative(DateTime date) {
  final diff = DateTime.now().difference(date);
  final future = diff.isNegative;
  final d = diff.abs();
  String unit;
  if (d.inSeconds < 45) return future ? 'in a moment' : 'just now';
  if (d.inMinutes < 60) {
    unit = '${math.max(1, d.inMinutes)} min';
  } else if (d.inHours < 24) {
    unit = '${d.inHours} h';
  } else if (d.inDays < 30) {
    unit = '${d.inDays} d';
  } else if (d.inDays < 365) {
    unit = '${(d.inDays / 30).floor()} mo';
  } else {
    unit = '${(d.inDays / 365).floor()} y';
  }
  return future ? 'in $unit' : '$unit ago';
}

String _pathArg(JsonMap args) {
  final p = args['path'];
  if (p is! String || p.isEmpty) {
    throw const FormatException('"path" must be a data path such as "/x"');
  }
  return p;
}

/// The basic catalog's functions, to the spec (they replace genui's own of
/// the same names; `formatString` stays genui's).
final List<ClientFunction> specFunctions = [
  AsemanFunction('required', 'True when the value is present and not empty.',
      {'value': _any}, (a, _) => specRequired(a),
      returnType: _boolean),
  AsemanFunction(
      'regex',
      'True when the value matches the regular expression "pattern".',
      {'value': _any, 'pattern': _str},
      (a, _) => specRegex(a),
      returnType: _boolean),
  AsemanFunction(
      'length',
      'True when the length of the value (text, list) is within min/max.',
      {'value': _any, 'min': _num, 'max': _num},
      (a, _) => specLength(a),
      returnType: _boolean),
  AsemanFunction('numeric', 'True when the value is a number within min/max.',
      {'value': _any, 'min': _num, 'max': _num}, (a, _) => specNumeric(a),
      returnType: _boolean),
  AsemanFunction('email', 'True when the value is an email address.',
      {'value': _any}, (a, _) => specEmail(a),
      returnType: _boolean),
  AsemanFunction(
      'formatNumber',
      'Formats a number: "decimals" fraction digits, "grouping" separators.',
      {'value': _any, 'decimals': _num, 'grouping': _bool},
      (a, _) => specFormatNumber(a),
      returnType: _string),
  AsemanFunction(
      'formatCurrency',
      'Formats an amount of "currency" (ISO code, default USD).',
      {'value': _any, 'currency': _str, 'decimals': _num, 'grouping': _bool},
      (a, _) => specFormatCurrency(a),
      returnType: _string),
  AsemanFunction(
      'formatDate',
      'Formats a date (ISO text or epoch ms) with a Unicode pattern '
          '("format", e.g. "MMM d, yyyy HH:mm").',
      {'value': _any, 'format': _str},
      (a, _) => specFormatDate(a),
      returnType: _string),
  AsemanFunction(
      'pluralize',
      'Chooses zero/one/other text for a count ("other" is required).',
      {
        'value': _any,
        'zero': _str,
        'one': _str,
        'two': _str,
        'few': _str,
        'many': _str,
        'other': _str
      },
      (a, _) => specPluralize(a),
      returnType: _string),
  AsemanFunction('and', 'True when every value is true.', {'values': _list},
      (a, _) => (a['values'] is List) && (a['values'] as List).every(toBool),
      returnType: _boolean),
  AsemanFunction('or', 'True when any value is true.', {'values': _list},
      (a, _) => (a['values'] is List) && (a['values'] as List).any(toBool),
      returnType: _boolean),
  AsemanFunction('not', 'Negates a boolean.', {'value': _any},
      (a, _) => !toBool(a['value']),
      returnType: _boolean),
  AsemanFunction(
      'openUrl', 'Opens an http(s) URL in the browser.', {'url': _str},
      (a, _) {
    final url = validateOpenUrl(a['url'], null);
    unawaited(launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
        .catchError((Object _) => false));
    return null;
  }, returnType: _void),
];

/// Aseman's own functions.
final List<ClientFunction> asemanFunctions = [
  // Formatting.
  AsemanFunction(
      'format',
      'Formats a value in the components\' format language: number[:d], '
          'integer, compact, percent[:d], currency[:USD[:d]], date, time, '
          'datetime; a leading + signs positives.',
      {'value': _any, 'format': _str},
      (a, _) => kit.formatValue(a['value'], a['format'] as String?),
      returnType: _string),
  AsemanFunction(
      'formatPercent',
      'Formats a fraction as a percentage (0.12 → 12%); "signed" adds +.',
      {'value': _any, 'decimals': _num, 'signed': _bool},
      (a, _) => kit.formatValue(a['value'],
          '${toBool(a['signed']) ? '+' : ''}percent:${_n(a['decimals'])?.toInt() ?? 1}'),
      returnType: _string),
  AsemanFunction('formatCompact', 'Formats a number compactly (12.9K, 3.4M).',
      {'value': _any, 'decimals': _num}, (a, _) {
    final n = _n(a['value']);
    return n == null
        ? stringifyValue(a['value'])
        : kit.formatCompact(n, decimals: _n(a['decimals'])?.toInt() ?? 1);
  }, returnType: _string),
  TickingFunction(
      'formatRelative',
      'A date relative to now ("5 min ago", "in 2 h"); stays current.',
      {'value': _any}, (a) {
    final date = parseDate(a['value']);
    return date == null ? '' : _relative(date);
  }, every: const Duration(seconds: 30)),
  TickingFunction(
      'now',
      'The current time, ticking every second: ISO 8601, or formatted with '
          'a Unicode "format" pattern.',
      {'format': _str}, (a) {
    final now = DateTime.now();
    final f = a['format'];
    return f is String && f.isNotEmpty
        ? formatDatePattern(now, f)
        : now.toIso8601String();
  }),
  // Math.
  AsemanFunction('add', 'The sum of "values".', {'values': _list},
      (a, _) => _tidy(_numbers(a['values']).fold<num>(0, (s, n) => s + n)),
      returnType: _number),
  AsemanFunction('subtract', 'a − b.', {'a': _any, 'b': _any}, (a, _) {
    final x = _n(a['a']), y = _n(a['b']);
    return x == null || y == null ? null : _tidy(x - y);
  }, returnType: _number),
  AsemanFunction('multiply', 'The product of "values".', {'values': _list},
      (a, _) => _tidy(_numbers(a['values']).fold<num>(1, (s, n) => s * n)),
      returnType: _number),
  AsemanFunction('divide', 'a ÷ b (nothing when b is 0).',
      {'a': _any, 'b': _any}, (a, _) {
    final x = _n(a['a']), y = _n(a['b']);
    return x == null || y == null || y == 0 ? null : _tidy(x / y);
  }, returnType: _number),
  AsemanFunction('round', 'Rounds to "decimals" places (default 0).',
      {'value': _any, 'decimals': _num}, (a, _) {
    final x = _n(a['value']);
    if (x == null) return null;
    final d = (_n(a['decimals']) ?? 0).toInt().clamp(0, 12);
    final f = math.pow(10, d);
    return _tidy((x * f).round() / f);
  }, returnType: _number),
  AsemanFunction('abs', 'The absolute value.', {'value': _any},
      (a, _) => _n(a['value'])?.abs(),
      returnType: _number),
  AsemanFunction('clamp', 'The value kept within min…max.',
      {'value': _any, 'min': _num, 'max': _num}, (a, _) {
    var x = _n(a['value']);
    if (x == null) return null;
    final lo = _n(a['min']), hi = _n(a['max']);
    if (lo != null && x < lo) x = lo;
    if (hi != null && x > hi) x = hi;
    return x;
  }, returnType: _number),
  AsemanFunction(
      'percentChange',
      'The change from "from" to "to" as a fraction ((to − from) / |from|); '
          'format it with formatPercent.',
      {'from': _any, 'to': _any}, (a, _) {
    final x = _n(a['from']), y = _n(a['to']);
    return x == null || y == null || x == 0 ? null : (y - x) / x.abs();
  }, returnType: _number),
  // Aggregates over a list (of numbers, or of rows with "field").
  AsemanFunction('sum', 'The sum of a list (or of a field of its rows).',
      {'values': _any, 'field': _str},
      (a, _) => _tidy(
          _numbers(a['values'], a['field']).fold<num>(0, (s, n) => s + n)),
      returnType: _number),
  AsemanFunction('average', 'The mean of a list (or of a field of its rows).',
      {'values': _any, 'field': _str}, (a, _) {
    final xs = _numbers(a['values'], a['field']);
    return xs.isEmpty ? null : xs.fold<num>(0, (s, n) => s + n) / xs.length;
  }, returnType: _number),
  AsemanFunction('min', 'The smallest number of a list (or of a field).',
      {'values': _any, 'field': _str}, (a, _) {
    final xs = _numbers(a['values'], a['field']);
    return xs.isEmpty ? null : xs.reduce(math.min);
  }, returnType: _number),
  AsemanFunction('max', 'The largest number of a list (or of a field).',
      {'values': _any, 'field': _str}, (a, _) {
    final xs = _numbers(a['values'], a['field']);
    return xs.isEmpty ? null : xs.reduce(math.max);
  }, returnType: _number),
  AsemanFunction('count', 'The number of items of a list, map or text.',
      {'values': _any}, (a, _) {
    final v = a['values'];
    return v is List
        ? v.length
        : v is Map
            ? v.length
            : v is String
                ? v.length
                : 0;
  }, returnType: _number),
  // Comparison and logic.
  AsemanFunction('equals', 'True when a equals b.', {'a': _any, 'b': _any},
      (a, _) => _equal(a['a'], a['b']),
      returnType: _boolean),
  AsemanFunction('notEquals', 'True when a differs from b.',
      {'a': _any, 'b': _any}, (a, _) => !_equal(a['a'], a['b']),
      returnType: _boolean),
  AsemanFunction('greaterThan', 'True when a > b.', {'a': _any, 'b': _any},
      (a, _) => a['a'] != null && a['b'] != null && _compare(a['a'], a['b']) > 0,
      returnType: _boolean),
  AsemanFunction('lessThan', 'True when a < b.', {'a': _any, 'b': _any},
      (a, _) => a['a'] != null && a['b'] != null && _compare(a['a'], a['b']) < 0,
      returnType: _boolean),
  AsemanFunction('isEmpty', 'True when the value is missing or empty.',
      {'value': _any}, (a, _) => !specRequired(a),
      returnType: _boolean),
  AsemanFunction(
      'contains',
      'True when a list holds "item" (or a text contains it).',
      {'value': _any, 'item': _any}, (a, _) {
    final v = a['value'], item = a['item'];
    if (v is List) return v.any((x) => _equal(x, item));
    if (v is Map) return v.containsKey(stringifyValue(item));
    return stringifyValue(v)
        .toLowerCase()
        .contains(stringifyValue(item).toLowerCase());
  }, returnType: _boolean),
  AsemanFunction('if', '"then" when the condition is true, else "else".',
      {'condition': _any, 'then': _any, 'else': _any},
      (a, _) => toBool(a['condition']) ? a['then'] : a['else']),
  AsemanFunction('coalesce', 'The first of "values" that is present.',
      {'values': _list}, (a, _) {
    for (final v in a['values'] is List ? a['values'] as List : const []) {
      if (v != null && v != '') return v;
    }
    return null;
  }),
  // Text and lookup.
  AsemanFunction('concat', 'Joins "values" as text (with "separator").',
      {'values': _list, 'separator': _str}, (a, _) {
    final values = a['values'] is List ? a['values'] as List : const <Object?>[];
    return values.map(stringifyValue).join(stringifyValue(a['separator']));
  }, returnType: _string),
  AsemanFunction(
      'join',
      'Joins a list (or a field of its rows) as text, ", " by default.',
      {'values': _any, 'field': _str, 'separator': _str}, (a, _) {
    final values = a['values'] is List ? a['values'] as List : const <Object?>[];
    final f = a['field'];
    return values
        .map((v) => stringifyValue(f is String ? kit.field(v, f) : v))
        .join(a['separator'] is String ? a['separator'] as String : ', ');
  }, returnType: _string),
  AsemanFunction('upper', 'Upper-cases text.', {'value': _any},
      (a, _) => stringifyValue(a['value']).toUpperCase(),
      returnType: _string),
  AsemanFunction('lower', 'Lower-cases text.', {'value': _any},
      (a, _) => stringifyValue(a['value']).toLowerCase(),
      returnType: _string),
  AsemanFunction('truncate', 'Shortens text to "max" characters with "…".',
      {'value': _any, 'max': _num}, (a, _) {
    final s = stringifyValue(a['value']);
    final max = (_n(a['max']) ?? 80).toInt();
    return s.length <= max ? s : '${s.substring(0, math.max(0, max - 1))}…';
  }, returnType: _string),
  AsemanFunction(
      'get',
      'A field of an object by name or dotted path ("quote.price", "rows.0").',
      {'value': _any, 'path': _str},
      (a, _) => kit.field(a['value'], a['path'] as String?)),
  // Client-side state (for a Button's functionCall action).
  AsemanFunction(
      'setValue',
      'Writes "value" at the data path "path" (no round trip).',
      {'path': _str, 'value': _any}, (a, c) {
    c.update(DataPath(_pathArg(a)), a['value']);
    return true;
  }, returnType: _void),
  AsemanFunction('toggle', 'Flips the boolean at the data path "path".',
      {'path': _str}, (a, c) {
    final path = DataPath(_pathArg(a));
    c.update(path, !toBool(c.getValue<Object?>(path)));
    return true;
  }, returnType: _void),
  AsemanFunction(
      'increment',
      'Adds "by" (default 1; negative to decrement) to the number at "path", '
          'kept within min/max.',
      {'path': _str, 'by': _num, 'min': _num, 'max': _num}, (a, c) {
    final path = DataPath(_pathArg(a));
    var x = (_n(c.getValue<Object?>(path)) ?? 0) + (_n(a['by']) ?? 1);
    final lo = _n(a['min']), hi = _n(a['max']);
    if (lo != null && x < lo) x = lo;
    if (hi != null && x > hi) x = hi;
    c.update(path, _tidy(x));
    return true;
  }, returnType: _void),
  AsemanFunction('append', 'Adds "value" to the end of the list at "path".',
      {'path': _str, 'value': _any}, (a, c) {
    final path = DataPath(_pathArg(a));
    final list = c.getValue<Object?>(path);
    c.update(path, [if (list is List) ...list, a['value']]);
    return true;
  }, returnType: _void),
  AsemanFunction('removeAt', 'Removes item "index" of the list at "path".',
      {'path': _str, 'index': _num}, (a, c) {
    final path = DataPath(_pathArg(a));
    final list = c.getValue<Object?>(path);
    final i = _n(a['index'])?.toInt();
    if (list is List && i != null && i >= 0 && i < list.length) {
      c.update(path, [...list]..removeAt(i));
    }
    return true;
  }, returnType: _void),
  AsemanFunction('copyToClipboard', 'Copies "text" to the clipboard.',
      {'text': _any}, (a, _) {
    unawaited(Clipboard.setData(ClipboardData(text: stringifyValue(a['text']))));
    return true;
  }, returnType: _void),
  // Shown by the action runner (it has the surface's context); as a value
  // it does nothing.
  AsemanFunction('showToast', 'Shows "message" briefly at the bottom.',
      {'message': _any}, (a, _) => true,
      returnType: _void),
];

/// Every function Aseman's catalog offers.
/// (Later definitions replace earlier ones of the same name.)
List<ClientFunction> get allAsemanFunctions => {
      for (final f in [
        ...BasicFunctions.all,
        ...specFunctions,
        ...asemanFunctions,
      ])
        f.name: f,
    }.values.toList();
