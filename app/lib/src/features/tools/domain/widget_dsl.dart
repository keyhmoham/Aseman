/// Desk-widget DSL served by the backend for an app installed in a room.
///
/// The DSL describes the UI rendered on a room desk. It is refreshed by the
/// client on a fixed interval ([refreshSec], default 10s) and may contain
/// actions with inline parameters that make static ask requests to the
/// app's backend VM.
library;

// Local lenient readers — keep this domain file free of the Elpian engine
// so the always-on API client does not pull ~30k LOC into the web entry chunk.
String? _looseStr(Object? v) =>
    v is String ? v : (v is num || v is bool ? '$v' : null);

num? _looseNum(Object? v) {
  if (v is num) return v;
  if (v is String) {
    final s = v.trim();
    return num.tryParse(s) ??
        num.tryParse(s.replaceFirst(RegExp(r'[a-z%]+$'), ''));
  }
  return null;
}

bool? _looseBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true' || 'yes' || '1':
        return true;
      case 'false' || 'no' || '0' || '':
        return false;
    }
  }
  return null;
}

class DeskWidgetDsl {
  const DeskWidgetDsl({
    required this.botId,
    required this.name,
    this.kind = 'tool',
    this.status = '',
    required this.title,
    this.version = 1,
    this.refreshSec = 10,
    this.rows = const [],
  });

  final String botId;
  final String name;
  final String kind;
  final String status;
  final String title;
  final int version;
  final int refreshSec;
  final List<DslRow> rows;

  factory DeskWidgetDsl.fromWidgetListEntry(Map<String, dynamic> entry) {
    final dsl = entry['dsl'];
    final d = dsl is Map<String, dynamic> ? dsl : <String, dynamic>{};
    return DeskWidgetDsl(
      botId: (_looseStr(entry['bot_id'])) ?? (_looseStr(d['bot_id'])) ?? '',
      name: (_looseStr(entry['name'])) ?? '',
      kind: (_looseStr(entry['kind'])) ?? 'tool',
      status: (_looseStr(entry['status'])) ?? '',
      title: (_looseStr(d['title'])) ?? (_looseStr(entry['name'])) ?? 'Widget',
      version: (_looseNum(d['version']))?.toInt() ?? 1,
      refreshSec: (_looseNum(d['refresh_sec']))?.toInt() ?? 10,
      rows: DslRow.listFrom(d['rows']),
    );
  }
}

class DslRow {
  const DslRow({
    required this.type,
    this.label = '',
    this.text = '',
    this.value,
    this.delta = '',
    this.color = '',
    this.icon = '',
    this.data = const [],
    this.items = const [],
    this.min = 0,
    this.max = 0,
    this.toggle = false,
    this.action,
    this.submit,
  });

  final String
      type; // label | metric | sparkline | gauge | list | progress | status | button | toggle | text_field | divider | markdown
  final String label;
  final String text;
  final Object? value;
  final String delta;
  final String color; // success | danger | warning | info | muted | accent
  final String icon;
  final List<double> data;
  final List<DslRow> items;
  final double min;
  final double max;
  final bool toggle;
  final DslAction? action;
  final DslAction? submit;

  factory DslRow.fromJson(Map<String, dynamic> json) => DslRow(
        type: _looseStr(json['type']) ?? 'label',
        label: _looseStr(json['label']) ?? '',
        text: _looseStr(json['text']) ?? '',
        value: json['value'],
        delta: _looseStr(json['delta']) ?? '',
        color: _looseStr(json['color']) ?? '',
        icon: _looseStr(json['icon']) ?? '',
        data: (json['data'] as List?)
                ?.whereType<num>()
                .map((e) => e.toDouble())
                .toList() ??
            const [],
        items: (json['items'] as List?)
                ?.whereType<Map<dynamic, dynamic>>()
                .map((e) => DslRow.fromJson(e.cast<String, dynamic>()))
                .toList() ??
            const [],
        min: (_looseNum(json['min']))?.toDouble() ?? 0,
        max: (_looseNum(json['max']))?.toDouble() ?? 0,
        toggle: _looseBool(json['toggle']) ?? false,
        action: _action(json['action']),
        submit: _action(json['submit']),
      );

  static List<DslRow> listFrom(Object? raw) {
    final list = raw is List ? raw : const <dynamic>[];
    return list
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => DslRow.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  static DslAction? _action(Object? raw) {
    if (raw is! Map<dynamic, dynamic>) return null;
    return DslAction.fromJson(raw.cast<String, dynamic>());
  }
}

class DslAction {
  const DslAction({
    required this.op,
    this.args = const {},
    this.label = '',
    this.confirm = '',
  });

  final String op;
  final Map<String, dynamic> args;
  final String label;
  final String confirm;

  factory DslAction.fromJson(Map<String, dynamic> json) => DslAction(
        op: _looseStr(json['op']) ?? '',
        args: (json['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        label: _looseStr(json['label']) ?? '',
        confirm: _looseStr(json['confirm']) ?? '',
      );

  /// Renders a copy of this action with `{{placeholder}}` values substituted
  /// from the supplied inline parameters (e.g. a text-field or toggle value).
  DslAction withInlineArgs(Map<String, dynamic> inline) {
    if (inline.isEmpty) return this;
    return DslAction(
      op: op,
      args: args.map((key, value) =>
          MapEntry(key, value is String ? _substitute(value, inline) : value)),
      label: label,
      confirm: confirm,
    );
  }

  static String _substitute(String value, Map<String, dynamic> inline) {
    var out = value;
    inline.forEach((key, v) {
      out = out.replaceAll('{{$key}}', '$v');
    });
    return out;
  }
}
