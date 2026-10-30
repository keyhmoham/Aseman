import 'dart:convert';

import 'package:flutter/material.dart';
import '../../shared/widgets/overlay_panels.dart';
import 'package:flutter/services.dart';

import '../../app_dependencies.dart';
import 'assistant_common.dart';
import '../../shared/widgets/glass_surface.dart';

/// Standing responsibilities: an instruction an agent runs, as the person,
/// when an event from a service, an app, an API or the clock matches. The
/// triggers and their settings come from the node's catalog
/// (responsibilities.triggers), so a new kind of trigger needs no app update.
class ResponsibilitiesView extends StatefulWidget {
  const ResponsibilitiesView({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<ResponsibilitiesView> createState() => _ResponsibilitiesViewState();
}

class _ResponsibilitiesViewState extends State<ResponsibilitiesView> {
  List<Map<String, dynamic>> rows = const [];
  List<Map<String, dynamic>> triggers = const [];

  Map<String, Map<String, dynamic>> get _byId => {
    for (final t in triggers) '${t['id']}': t,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    final catalog = triggers.isEmpty
        ? await runAction(context, deps, 'responsibilities', 'triggers')
        : null;
    if (!mounted) return;
    final out = await runAction(context, deps, 'responsibilities', 'list', {
      'space': widget.space,
    });
    if (!mounted) return;
    setState(() {
      if (catalog != null) triggers = jsonList(catalog['triggers']);
      if (out != null) rows = jsonList(out['responsibilities']);
    });
  }

  Future<void> _create() async {
    if (triggers.isEmpty) return;
    final apps =
        (await widget.dependencies.service.fetchSpaceBots(widget.space))
            .where((b) => b.kind == 'tool')
            .map((b) => (id: b.id, name: b.name))
            .toList();
    if (!mounted) return;
    final input = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ResponsibilityDialog(triggers: triggers, apps: apps),
    );
    if (input == null || !mounted) return;
    final out = await runAction(
      context,
      widget.dependencies,
      'responsibilities',
      'create',
      {'space': widget.space, ...input},
    );
    if (out == null || !mounted) return;
    final trigger = _byId['${input['trigger']}'] ?? const {};
    if ('${out['url'] ?? ''}'.isNotEmpty) {
      await showAppDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Connect ${trigger['label'] ?? 'the source'}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ('${trigger['setup'] ?? ''}'.isNotEmpty)
                Text('${trigger['setup']}'),
              const SizedBox(height: 12),
              _Copy('URL', '${out['url']}'),
              if ('${out['secret'] ?? ''}'.isNotEmpty) ...[
                _Copy('Secret', '${out['secret']}'),
                const Text(
                  'The secret is shown only now.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
    await _load();
  }

  Future<void> _act(
    Map<String, dynamic> r,
    String action, [
    String? done,
  ]) async {
    final out = await runAction(
      context,
      widget.dependencies,
      'responsibilities',
      action,
      {'id': r['id']},
      done,
    );
    if (out != null) await _load();
  }

  String _when(Map<String, dynamic> r) {
    final t = _byId['${r['trigger']}'];
    final label = '${t?['label'] ?? r['trigger']}';
    final filters = [
      for (final k in const [
        'repo',
        'from',
        'subject',
        'label',
        'channel',
        'url',
        'path',
        'function',
        'at',
        'keyword',
      ])
        if ('${r[k] ?? ''}'.isNotEmpty) '${r[k]}',
      if (r['events'] is List && (r['events'] as List).isNotEmpty)
        (r['events'] as List).join(', '),
      if ((r['interval_minutes'] as num? ?? 0) > 0)
        'every ${r['interval_minutes']} min',
    ];
    return filters.isEmpty ? label : '$label · ${filters.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Give an agent an area it owns: when a service, an app, an API or the clock says so, '
        'it acts on your instruction, under the project\'s policy, and the outcome lands in your Tasks.',
      ),
      const SizedBox(height: 8),
      for (final r in rows)
        AppCard(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${r['name']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Switch(
                      value: r['enabled'] == true,
                      onChanged: (v) => _act(r, v ? 'resume' : 'pause'),
                    ),
                  ],
                ),
                Text(_when(r), style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Text('${r['instruction']}'),
                Text(
                  'Fired ${r['fired'] ?? 0} times${'${r['last_result'] ?? ''}'.isEmpty ? '' : ' · ${r['last_result']}'}',
                  style: const TextStyle(fontSize: 12),
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () =>
                          _act(r, 'test', 'Fired with a sample event'),
                      child: const Text('Test'),
                    ),
                    TextButton(
                      onPressed: () => _act(r, 'delete', 'Deleted'),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: triggers.isEmpty ? null : _create,
          icon: const Icon(Icons.add_rounded),
          label: const Text('New responsibility'),
        ),
      ),
    ],
  );
}

class _Copy extends StatelessWidget {
  const _Copy(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SelectableText(
                value,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Copy',
          icon: const Icon(Icons.copy_rounded, size: 18),
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
        ),
      ],
    ),
  );
}

/// Picks a trigger from the catalog, grouped, and fills in its settings.
class _ResponsibilityDialog extends StatefulWidget {
  const _ResponsibilityDialog({required this.triggers, required this.apps});
  final List<Map<String, dynamic>> triggers;
  final List<({String id, String name})> apps;

  @override
  State<_ResponsibilityDialog> createState() => _ResponsibilityDialogState();
}

class _ResponsibilityDialogState extends State<_ResponsibilityDialog> {
  final name = TextEditingController();
  final instruction = TextEditingController();
  final fields = <String, TextEditingController>{};
  late String trigger = '${widget.triggers.first['id']}';
  String? app;
  String error = '';

  Map<String, dynamic> get spec =>
      widget.triggers.firstWhere((t) => t['id'] == trigger);

  TextEditingController _c(String field) =>
      fields.putIfAbsent(field, TextEditingController.new);

  @override
  void dispose() {
    name.dispose();
    instruction.dispose();
    for (final c in fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (name.text.trim().isEmpty || instruction.text.trim().isEmpty) {
      setState(() => error = 'Name it and say what the agent does.');
      return;
    }
    final out = <String, dynamic>{
      'name': name.text.trim(),
      'instruction': instruction.text.trim(),
      'trigger': trigger,
    };
    for (final f in jsonList(spec['fields'])) {
      final key = '${f['name']}';
      final kind = '${f['kind']}';
      if (kind == 'app') {
        if (app != null) out[key] = app;
        continue;
      }
      final v = _c(key).text.trim();
      if (v.isEmpty) continue;
      switch (kind) {
        case 'list':
          out[key] = v
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
        case 'number':
          final n = int.tryParse(v);
          if (n == null) {
            setState(() => error = '${f['label']} is a number.');
            return;
          }
          out[key] = n;
        case 'json':
          try {
            if (jsonDecode(v) is! Map) throw const FormatException();
          } catch (_) {
            setState(() => error = '${f['label']} is a JSON object.');
            return;
          }
          out[key] = v;
        default:
          out[key] = v;
      }
    }
    Navigator.pop(context, out);
  }

  Widget _field(Map<String, dynamic> f) {
    final key = '${f['name']}';
    final kind = '${f['kind']}';
    final label = '${f['label']}${f['required'] == true ? ' *' : ''}';
    final help = '${f['help'] ?? ''}';
    if (kind == 'app') {
      return DropdownButtonFormField<String>(
        initialValue: app,
        decoration: InputDecoration(
          labelText: label,
          helperText: widget.apps.isEmpty
              ? 'Add an app to this project first.'
              : null,
        ),
        items: [
          for (final a in widget.apps)
            DropdownMenuItem(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => setState(() => app = v),
      );
    }
    return TextField(
      controller: _c(key),
      obscureText: kind == 'secret',
      keyboardType: kind == 'number' ? TextInputType.number : null,
      minLines: kind == 'json' ? 2 : 1,
      maxLines: kind == 'json' ? 5 : 1,
      decoration: InputDecoration(
        labelText: label,
        helperText: help.isEmpty ? null : help,
        helperMaxLines: 3,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final t in widget.triggers) {
      groups.putIfAbsent('${t['group']}', () => []).add(t);
    }
    final s = spec;
    return AlertDialog(
      title: const Text('New responsibility'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              DropdownButtonFormField<String>(
                initialValue: trigger,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'When'),
                items: [
                  for (final g in groups.entries) ...[
                    DropdownMenuItem<String>(
                      enabled: false,
                      value: 'group:${g.key}',
                      child: Text(
                        g.key,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    for (final t in g.value)
                      DropdownMenuItem(
                        value: '${t['id']}',
                        child: Text('${t['label']}'),
                      ),
                  ],
                ],
                onChanged: (v) {
                  if (v != null && !v.startsWith('group:')) {
                    setState(() {
                      trigger = v;
                      error = '';
                    });
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${s['help'] ?? ''}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              for (final f in jsonList(s['fields'])) _field(f),
              TextField(
                controller: instruction,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'What the agent does',
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}
