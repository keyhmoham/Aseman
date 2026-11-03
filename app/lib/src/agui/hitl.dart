import 'package:flutter/material.dart';
import '../core/theme/app_shape.dart';

/// Shared human-in-the-loop controls for AG-UI chat (and RoomWorkNeeds).
/// One implementation — no duplicate chips elsewhere.

typedef AgUiReply = void Function(String value, {Map<String, dynamic>? meta});

/// Question with optional choice chips and free-text field.
class AgUiQuestion extends StatefulWidget {
  const AgUiQuestion({
    super.key,
    required this.question,
    this.options = const [],
    this.allowFreeText = true,
    this.onReply,
    this.dense = false,
  });

  final String question;
  final List<String> options;
  final bool allowFreeText;
  final AgUiReply? onReply;
  final bool dense;

  @override
  State<AgUiQuestion> createState() => _AgUiQuestionState();
}

class _AgUiQuestionState extends State<AgUiQuestion> {
  final _ctrl = TextEditingController();
  String? _picked;
  bool _sent = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _send(String value) {
    if (_sent || value.trim().isEmpty || widget.onReply == null) return;
    setState(() {
      _sent = true;
      _picked = value;
    });
    widget.onReply!(value.trim(), meta: {'kind': 'question'});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.question,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: widget.dense ? 13 : 14,
                height: 1.35,
                color: scheme.onSurface)),
        if (widget.options.isNotEmpty) ...[
          SizedBox(height: widget.dense ? 6 : 10),
          AgUiChoices(
            options: widget.options,
            selected: _picked,
            enabled: !_sent && widget.onReply != null,
            onSelect: _send,
          ),
        ],
        if (widget.allowFreeText && !_sent) ...[
          SizedBox(height: widget.dense ? 6 : 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                enabled: widget.onReply != null,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.options.isEmpty
                      ? 'Your answer…'
                      : 'Or type another answer…',
                  border: OutlineInputBorder(
                      borderRadius: AppShape.borderRadius(context, 12)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                onSubmitted: _send,
              ),
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              tooltip: 'Send',
              onPressed: widget.onReply == null
                  ? null
                  : () => _send(_ctrl.text),
              icon: const Icon(Icons.send_rounded, size: 18),
            ),
          ]),
        ],
        if (_sent)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Sent: $_picked',
                style: TextStyle(
                    fontSize: 12, color: scheme.primary, fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }
}

/// Single-select option chips.
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
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final o in options)
          ChoiceChip(
            label: Text(o, style: const TextStyle(fontSize: 12)),
            selected: selected == o,
            onSelected: !enabled || onSelect == null
                ? null
                : (_) => onSelect!(o),
          ),
      ],
    );
  }
}

/// Yes / No confirm bar.
class AgUiConfirm extends StatefulWidget {
  const AgUiConfirm({
    super.key,
    this.label = 'Continue?',
    this.confirmLabel = 'Yes',
    this.cancelLabel = 'No',
    this.onReply,
  });

  final String label;
  final String confirmLabel;
  final String cancelLabel;
  final AgUiReply? onReply;

  @override
  State<AgUiConfirm> createState() => _AgUiConfirmState();
}

class _AgUiConfirmState extends State<AgUiConfirm> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final done = _picked != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 8),
        Row(children: [
          FilledButton(
            onPressed: done || widget.onReply == null
                ? null
                : () {
                    setState(() => _picked = widget.confirmLabel);
                    widget.onReply!(widget.confirmLabel, meta: {'kind': 'confirm', 'ok': true});
                  },
            child: Text(widget.confirmLabel),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: done || widget.onReply == null
                ? null
                : () {
                    setState(() => _picked = widget.cancelLabel);
                    widget.onReply!(widget.cancelLabel, meta: {'kind': 'confirm', 'ok': false});
                  },
            child: Text(widget.cancelLabel),
          ),
        ]),
      ],
    );
  }
}

/// Compact field group + submit (HITL form).
class AgUiForm extends StatefulWidget {
  const AgUiForm({
    super.key,
    required this.fields,
    this.submitLabel = 'Submit',
    this.onReply,
  });

  /// Each field: {name, label?, hint?, value?}
  final List<Map<String, dynamic>> fields;
  final String submitLabel;
  final AgUiReply? onReply;

  @override
  State<AgUiForm> createState() => _AgUiFormState();
}

class _AgUiFormState extends State<AgUiForm> {
  late final Map<String, TextEditingController> _ctrls;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _ctrls = {
      for (final f in widget.fields)
        '${f['name']}': TextEditingController(text: '${f['value'] ?? ''}'),
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final f in widget.fields) ...[
          Text('${f['label'] ?? f['name']}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          TextField(
            controller: _ctrls['${f['name']}'],
            enabled: !_sent && widget.onReply != null,
            decoration: InputDecoration(
              isDense: true,
              hintText: '${f['hint'] ?? ''}',
              border:
                  OutlineInputBorder(borderRadius: AppShape.borderRadius(context, 12)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _sent || widget.onReply == null
                ? null
                : () {
                    final map = {
                      for (final e in _ctrls.entries) e.key: e.value.text.trim(),
                    };
                    setState(() => _sent = true);
                    widget.onReply!(jsonLine(map), meta: {'kind': 'form', 'values': map});
                  },
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
