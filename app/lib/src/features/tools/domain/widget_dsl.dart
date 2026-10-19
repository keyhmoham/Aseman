/// Desk-widget DSL served by the backend for a miniapp installed in a room.
///
/// The DSL describes the UI rendered on a room desk. It is refreshed by the
/// client on a fixed interval ([refreshSec], default 10s) and may contain
/// actions with inline parameters that make static ask requests to the
/// miniapp's backend VM.
library;

class DeskWidgetDsl {
  const DeskWidgetDsl({
    required this.botId,
    required this.name,
    this.kind = 'miniapp',
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
      botId: (entry['bot_id'] as String?) ?? (d['bot_id'] as String?) ?? '',
      name: (entry['name'] as String?) ?? '',
      kind: (entry['kind'] as String?) ?? 'miniapp',
      status: (entry['status'] as String?) ?? '',
      title: (d['title'] as String?) ?? (entry['name'] as String?) ?? 'Widget',
      version: (d['version'] as num?)?.toInt() ?? 1,
      refreshSec: (d['refresh_sec'] as num?)?.toInt() ?? 10,
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
        type: json['type'] as String? ?? 'label',
        label: json['label'] as String? ?? '',
        text: json['text'] as String? ?? '',
        value: json['value'],
        delta: json['delta'] as String? ?? '',
        color: json['color'] as String? ?? '',
        icon: json['icon'] as String? ?? '',
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
        min: (json['min'] as num?)?.toDouble() ?? 0,
        max: (json['max'] as num?)?.toDouble() ?? 0,
        toggle: json['toggle'] as bool? ?? false,
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
        op: json['op'] as String? ?? '',
        args: (json['args'] as Map?)?.cast<String, dynamic>() ?? const {},
        label: json['label'] as String? ?? '',
        confirm: json['confirm'] as String? ?? '',
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
