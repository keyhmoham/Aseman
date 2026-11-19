import 'package:flutter/material.dart';
import '../core/theme/app_shape.dart';
import 'card_frame.dart';

/// Shared human-in-the-loop controls for AG-UI chat (and RoomWorkNeeds).
/// One implementation — no duplicate chips elsewhere.

typedef AgUiReply = void Function(String value, {Map<String, dynamic>? meta});

/// What people answered in this session, by message and place in the card: a
/// list that redraws (a message scrolled away and back) keeps its answers, so
/// a question is not asked twice.
abstract final class AgUiAnswers {
  static final Map<String, String> _store = {};
  static String? read(String key) => key.isEmpty ? null : _store[key];
  static void write(String key, String value) {
    if (key.isNotEmpty) _store[key] = value;
  }
}

enum AgUiOptionState { idle, picked, off }

/// One option an agent offers: a tap sends it. After the answer the others
/// fall back and the chosen one stays marked.
class AgUiOption extends StatelessWidget {
  const AgUiOption({
    super.key,
    required this.label,
    this.state = AgUiOptionState.idle,
    this.onTap,
  });

  final String label;
  final AgUiOptionState state;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final picked = state == AgUiOptionState.picked;
    final off = state == AgUiOptionState.off;
    final active = state == AgUiOptionState.idle && onTap != null;
    final shape = StadiumBorder(
      side: BorderSide(color: picked ? scheme.primary : scheme.outlineVariant),
    );
    return Semantics(
      button: true,
      selected: picked,
      enabled: active,
      label: label,
      excludeSemantics: true,
      child: Opacity(
        opacity: off || (!active && !picked) ? .45 : 1,
        child: Material(
          color: picked ? scheme.primary : scheme.surface,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            onTap: active ? onTap : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (picked) ...[
                      Icon(
                        Icons.check_rounded,
                        size: 16,
                        color: scheme.onPrimary,
                      ),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: picked ? scheme.onPrimary : scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-select options.
class AgUiChoices extends StatelessWidget {
  const AgUiChoices({
    super.key,
    required this.options,
    this.selected,
    this.enabled = true,
    this.onSelect,
  });

  final List<String> options;
  final String? selected;
  final bool enabled;
  final void Function(String value)? onSelect;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          AgUiOption(
            label: o,
            state: selected == null
                ? AgUiOptionState.idle
                : selected == o
                ? AgUiOptionState.picked
                : AgUiOptionState.off,
            onTap: !enabled || onSelect == null ? null : () => onSelect!(o),
          ),
      ],
    );
  }
}

/// The replies an agent offers under its latest message: a tap sends one;
/// then they stay, the chosen one marked.
class AgUiReplyChips extends StatefulWidget {
  const AgUiReplyChips({
    super.key,
    required this.replies,
    required this.onPick,
  });
  final List<String> replies;
  final void Function(String reply) onPick;

  @override
  State<AgUiReplyChips> createState() => _AgUiReplyChipsState();
}

class _AgUiReplyChipsState extends State<AgUiReplyChips> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Suggested replies',
      container: true,
      child: AgUiChoices(
        options: widget.replies,
        selected: _picked,
        onSelect: (r) {
          setState(() => _picked = r);
          widget.onPick(r);
        },
      ),
    );
  }
}

InputDecoration _fieldLook(
  BuildContext context, {
  String hint = '',
  String? label,
  Widget? suffix,
}) {
  final scheme = Theme.of(context).colorScheme;
  final radius = AppShape.borderRadius(context, 12);
  OutlineInputBorder border(Color color) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: color),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: scheme.surface,
    hintText: hint.isEmpty ? null : hint,
    labelText: label,
    suffixIcon: suffix,
    border: border(scheme.outlineVariant),
    enabledBorder: border(scheme.outlineVariant),
    focusedBorder: border(scheme.primary),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
  );
}

/// Question with optional choices and a free-text field.
class AgUiQuestion extends StatefulWidget {
  const AgUiQuestion({
    super.key,
    required this.question,
    this.options = const [],
    this.allowFreeText = true,
    this.onReply,
    this.dense = false,
    this.stateKey = '',
  });

  final String question;
  final List<String> options;
  final bool allowFreeText;
  final AgUiReply? onReply;
  final bool dense;

  /// Where this card is (message + place): what was answered is kept by it.
  final String stateKey;

  @override
  State<AgUiQuestion> createState() => _AgUiQuestionState();
}

class _AgUiQuestionState extends State<AgUiQuestion> {
  final _ctrl = TextEditingController();
  String? _answer;

  @override
  void initState() {
    super.initState();
    _answer = AgUiAnswers.read(widget.stateKey);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send(String value) {
    final v = value.trim();
    if (_answer != null || v.isEmpty || widget.onReply == null) return;
    AgUiAnswers.write(widget.stateKey, v);
    setState(() => _answer = v);
    widget.onReply!(v, meta: {'kind': 'question'});
  }

  @override
  Widget build(BuildContext context) {
    final answered = _answer != null;
    return AgUiCard(
      icon: Icons.help_outline_rounded,
      title: widget.question.isEmpty ? 'A question' : widget.question,
      children: [
        if (widget.options.isNotEmpty)
          AgUiChoices(
            options: widget.options,
            selected: _answer,
            enabled: !answered && widget.onReply != null,
            onSelect: _send,
          ),
        if (widget.allowFreeText && !answered && widget.onReply != null)
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: const TextStyle(fontSize: 13.5),
                  textInputAction: TextInputAction.send,
                  decoration: _fieldLook(
                    context,
                    hint: widget.options.isEmpty
                        ? 'Your answer'
                        : 'Or write an answer',
                  ),
                  onSubmitted: _send,
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _ctrl,
                builder: (_, value, __) => IconButton.filled(
                  tooltip: 'Send answer',
                  onPressed: value.text.trim().isEmpty
                      ? null
                      : () => _send(_ctrl.text),
                  icon: const Icon(Icons.send_rounded, size: 18),
                ),
              ),
            ],
          ),
        if (widget.onReply == null && !answered)
          const AgUiNote('Only people who can write here can answer.'),
        if (answered) AgUiAnswered(text: _answer!),
      ],
    );
  }
}

/// A set of options as a card of its own (the `Choices` part).
class AgUiChoicesCard extends StatefulWidget {
  const AgUiChoicesCard({
    super.key,
    required this.label,
    required this.options,
    this.onReply,
    this.stateKey = '',
  });

  final String label;
  final List<String> options;
  final AgUiReply? onReply;
  final String stateKey;

  @override
  State<AgUiChoicesCard> createState() => _AgUiChoicesCardState();
}

class _AgUiChoicesCardState extends State<AgUiChoicesCard> {
  String? _answer;

  @override
  void initState() {
    super.initState();
    _answer = AgUiAnswers.read(widget.stateKey);
  }

  @override
  Widget build(BuildContext context) {
    return AgUiCard(
      icon: Icons.touch_app_outlined,
      title: widget.label.isEmpty ? 'Choose one' : widget.label,
      children: [
        AgUiChoices(
          options: widget.options,
          selected: _answer,
          enabled: _answer == null && widget.onReply != null,
          onSelect: (v) {
            if (_answer != null || widget.onReply == null) return;
            AgUiAnswers.write(widget.stateKey, v);
            setState(() => _answer = v);
            widget.onReply!(v, meta: {'kind': 'choices'});
          },
        ),
        if (_answer != null) AgUiAnswered(text: _answer!),
      ],
    );
  }
}

/// Yes / No confirm card.
class AgUiConfirm extends StatefulWidget {
  const AgUiConfirm({
    super.key,
    this.label = 'Continue?',
    this.detail = '',
    this.confirmLabel = 'Yes',
    this.cancelLabel = 'No',
    this.onReply,
    this.stateKey = '',
  });

  final String label;
  final String detail;
  final String confirmLabel;
  final String cancelLabel;
  final AgUiReply? onReply;
  final String stateKey;

  @override
  State<AgUiConfirm> createState() => _AgUiConfirmState();
}

class _AgUiConfirmState extends State<AgUiConfirm> {
  String? _picked;

  @override
  void initState() {
    super.initState();
    _picked = AgUiAnswers.read(widget.stateKey);
  }

  void _say(String value, bool ok) {
    if (_picked != null || widget.onReply == null) return;
    AgUiAnswers.write(widget.stateKey, value);
    setState(() => _picked = value);
    widget.onReply!(value, meta: {'kind': 'confirm', 'ok': ok});
  }

  @override
  Widget build(BuildContext context) {
    return AgUiCard(
      icon: Icons.help_outline_rounded,
      title: widget.label,
      subtitle: widget.detail,
      children: [
        if (_picked != null)
          AgUiAnswered(text: _picked!)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: widget.onReply == null
                    ? null
                    : () => _say(widget.confirmLabel, true),
                child: Text(widget.confirmLabel),
              ),
              OutlinedButton(
                onPressed: widget.onReply == null
                    ? null
                    : () => _say(widget.cancelLabel, false),
                child: Text(widget.cancelLabel),
              ),
            ],
          ),
      ],
    );
  }
}

/// A form field as the agent described it, with a key of its own.
class AgUiField {
  const AgUiField({
    required this.key,
    required this.label,
    this.type = 'text',
    this.placeholder = '',
    this.required = false,
    this.options = const [],
    this.value = '',
  });

  final String key;
  final String label;

  /// text, password, textarea, number, email, select or checkbox.
  final String type;
  final String placeholder;
  final bool required;
  final List<String> options;
  final String value;
}

/// A form's fields. A field with only a label no longer shares the key
/// "null" with the others: every field has a key of its own.
List<AgUiField> agUiFormFields(dynamic raw) {
  final out = <AgUiField>[];
  final seen = <String>{};
  final list = raw is List ? raw : const <dynamic>[];
  for (var i = 0; i < list.length; i++) {
    final entry = list[i];
    final f = entry is Map
        ? Map<String, dynamic>.from(entry)
        : entry is String
        ? <String, dynamic>{'label': entry}
        : null;
    if (f == null) continue;
    String text(Object? v) => v == null ? '' : '$v'.trim();
    final label = [
      f['label'],
      f['name'],
      f['key'],
    ].map(text).firstWhere((s) => s.isNotEmpty, orElse: () => 'Field ${i + 1}');
    var key = [
      f['name'],
      f['key'],
      f['label'],
    ].map(text).firstWhere((s) => s.isNotEmpty, orElse: () => 'field$i');
    while (!seen.add(key)) {
      key = '${key}_$i';
    }
    final options = [
      for (final o in (f['options'] is List ? f['options'] as List : const []))
        if (text(o).isNotEmpty) text(o),
    ];
    final kind = text(f['type']).toLowerCase();
    final type = options.isNotEmpty
        ? 'select'
        : const <String>[
            'password',
            'textarea',
            'number',
            'email',
            'checkbox',
          ].contains(kind)
        ? kind
        : 'text';
    out.add(
      AgUiField(
        key: key,
        label: label,
        type: type,
        placeholder: text(f['placeholder'] ?? f['hint']),
        required: f['required'] == true,
        options: options,
        value: text(f['value'] ?? f['default']),
      ),
    );
  }
  return out;
}

/// The answer a form sends: one `Label: value` line per field with a value.
String agUiFormReply(List<AgUiField> fields, Map<String, String> values) => [
  for (final f in fields)
    if ((values[f.key] ?? '').trim().isNotEmpty)
      '${f.label}: ${values[f.key]!.trim()}',
].join('\n');

/// Whether every required field has a value, and something is filled in.
bool agUiFormReady(List<AgUiField> fields, Map<String, String> values) =>
    fields.every(
      (f) => !f.required || (values[f.key] ?? '').trim().isNotEmpty,
    ) &&
    fields.any((f) => (values[f.key] ?? '').trim().isNotEmpty);

/// Field group + submit (HITL form).
class AgUiForm extends StatefulWidget {
  const AgUiForm({
    super.key,
    required this.fields,
    this.title = '',
    this.submitLabel = 'Submit',
    this.onReply,
    this.stateKey = '',
  });

  /// Each field: {name, label?, hint?, value?, type?, required?, options?}
  final List<Map<String, dynamic>> fields;
  final String title;
  final String submitLabel;
  final AgUiReply? onReply;
  final String stateKey;

  @override
  State<AgUiForm> createState() => _AgUiFormState();
}

class _AgUiFormState extends State<AgUiForm> {
  late final List<AgUiField> _fields = agUiFormFields(widget.fields);
  late final Map<String, TextEditingController> _ctrls = {
    for (final f in _fields) f.key: TextEditingController(text: f.value),
  };
  late final Map<String, String> _picked = {
    for (final f in _fields)
      if (f.type == 'select' || f.type == 'checkbox') f.key: f.value,
  };
  String? _sent;

  @override
  void initState() {
    super.initState();
    _sent = AgUiAnswers.read(widget.stateKey);
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _values => {
    for (final f in _fields)
      f.key: _ctrls[f.key] != null && f.type != 'select' && f.type != 'checkbox'
          ? _ctrls[f.key]!.text
          : _picked[f.key] ?? '',
  };

  void _submit() {
    if (_sent != null || widget.onReply == null) return;
    final values = _values;
    if (!agUiFormReady(_fields, values)) return;
    final reply = agUiFormReply(_fields, values);
    AgUiAnswers.write(widget.stateKey, reply);
    setState(() => _sent = reply);
    widget.onReply!(reply, meta: {'kind': 'form', 'values': values});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final locked = _sent != null || widget.onReply == null;
    return AgUiCard(
      icon: Icons.edit_note_rounded,
      title: widget.title.isEmpty ? 'A few details' : widget.title,
      children: [
        for (final f in _fields)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(
                TextSpan(
                  text: f.label,
                  children: [
                    if (f.required)
                      TextSpan(
                        text: ' *',
                        style: TextStyle(color: scheme.error),
                      ),
                  ],
                ),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              if (f.type == 'select')
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in f.options)
                      AgUiOption(
                        label: o,
                        state: _picked[f.key] == o
                            ? AgUiOptionState.picked
                            : _sent != null
                            ? AgUiOptionState.off
                            : AgUiOptionState.idle,
                        onTap: locked
                            ? null
                            : () => setState(() => _picked[f.key] = o),
                      ),
                  ],
                )
              else if (f.type == 'checkbox')
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _picked[f.key] == 'Yes',
                  title: Text(f.placeholder.isEmpty ? f.label : f.placeholder),
                  onChanged: locked
                      ? null
                      : (v) => setState(
                          () => _picked[f.key] = v == true ? 'Yes' : '',
                        ),
                )
              else
                TextField(
                  controller: _ctrls[f.key],
                  enabled: !locked,
                  obscureText: f.type == 'password',
                  keyboardType: f.type == 'number'
                      ? TextInputType.number
                      : f.type == 'email'
                      ? TextInputType.emailAddress
                      : f.type == 'textarea'
                      ? TextInputType.multiline
                      : TextInputType.text,
                  minLines: f.type == 'textarea' ? 3 : 1,
                  maxLines: f.type == 'textarea' ? 6 : 1,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: _fieldLook(context, hint: f.placeholder),
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ),
        if (_sent != null)
          const AgUiAnswered(prefix: 'Sent')
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: locked || !agUiFormReady(_fields, _values)
                  ? null
                  : _submit,
              child: Text(widget.submitLabel),
            ),
          ),
      ],
    );
  }
}

String jsonLine(Map<String, String> values) {
  final parts = values.entries
      .where((e) => e.value.isNotEmpty)
      .map((e) => '${e.key}: ${e.value}');
  return parts.join('\n');
}
