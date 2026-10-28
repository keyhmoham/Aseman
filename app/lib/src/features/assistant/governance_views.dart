import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_dependencies.dart';
import '../rooms/presentation/widgets/download_helper.dart';
import 'assistant_common.dart';

/// The governance views shared by the admin console (the node's scope, no
/// [space]) and a project's settings (its own scope): the action policy, the
/// audit trail, the computer's network policy and saved credentials.

/// The CEL policy: deny rules first, then ask, then allow; anything no rule
/// allows is refused. A dry run shows how a sample action is decided.
class PolicyEditor extends StatefulWidget {
  const PolicyEditor({super.key, required this.dependencies, this.space = ''});
  final AppDependencies dependencies;
  final String space;

  @override
  State<PolicyEditor> createState() => _PolicyEditorState();
}

class _PolicyEditorState extends State<PolicyEditor> {
  final deny = TextEditingController();
  final ask = TextEditingController();
  final allow = TextEditingController();
  final sampleTool = TextEditingController(text: 'gmail_send');
  final sampleCommand = TextEditingController();
  String sampleEffect = 'send';
  String sampleInitiator = 'person';
  List<String> variables = const [];
  List<String> effects = const [
    'read',
    'write',
    'send',
    'pay',
    'sign',
    'delete',
    'external',
  ];
  Map<String, dynamic> defaults = const {};
  bool isDefault = true;
  bool loading = true;
  String error = '';
  String verdict = '';

  Map<String, dynamic> get _scope => {
    if (widget.space.isNotEmpty) 'space': widget.space,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [deny, ask, allow, sampleTool, sampleCommand]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> p) {
    deny.text = jsonStrings(p['deny']).join('\n');
    ask.text = jsonStrings(p['ask']).join('\n');
    allow.text = jsonStrings(p['allow']).join('\n');
  }

  Future<void> _load() async {
    try {
      final out = jsonMap(
        await widget.dependencies.service.invokeAction(
          'governance',
          'policy_get',
          body: _scope,
        ),
      );
      if (!mounted) return;
      setState(() {
        _fill(jsonMap(out['policy']));
        defaults = jsonMap(out['defaults']);
        isDefault = out['default'] == true;
        variables = jsonStrings(out['variables']);
        if (jsonStrings(out['effects']).isNotEmpty)
          effects = jsonStrings(out['effects']);
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(e);
          loading = false;
        });
      }
    }
  }

  List<String> _rules(TextEditingController c) => c.text
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'policy_set',
      {
        ..._scope,
        'deny': _rules(deny),
        'ask': _rules(ask),
        'allow': _rules(allow),
      },
      'Policy saved',
    );
    if (out != null && mounted) setState(() => isDefault = false);
  }

  Future<void> _test() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'policy_test',
      {
        ..._scope,
        'request': {
          'kind': sampleCommand.text.trim().isEmpty ? 'tool' : 'sandbox',
          'tool': sampleTool.text.trim(),
          'effect': sampleEffect,
          if (sampleCommand.text.trim().isNotEmpty)
            'command': sampleCommand.text.trim(),
          'space_id': widget.space,
          'initiator_kind': sampleInitiator,
        },
      },
    );
    if (out == null || !mounted) return;
    setState(
      () => verdict = [
        out['decision'],
        out['rule'],
        out['finding'],
      ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
    );
  }

  Widget _rulesField(String label, String help, TextEditingController c) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          minLines: 3,
          maxLines: 10,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            border: const OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error.isNotEmpty)
      return Text(
        error,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isDefault
              ? 'The default policy is in effect: it asks before sending, paying, signing or deleting, and lets work started on its own only read.'
              : 'This scope has its own policy.',
        ),
        const SizedBox(height: 12),
        _rulesField(
          'Deny',
          'One CEL rule per line. A match refuses the action.',
          deny,
        ),
        _rulesField(
          'Ask',
          'A match asks the person (Allow once, Always allow, Refuse).',
          ask,
        ),
        _rulesField(
          'Allow',
          'A match allows the action. Nothing matching: refused.',
          allow,
        ),
        if (variables.isNotEmpty)
          Text(
            'Variables: ${variables.join(', ')}',
            style: const TextStyle(fontSize: 12),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(onPressed: _save, child: const Text('Save policy')),
            TextButton(
              onPressed: defaults.isEmpty
                  ? null
                  : () => setState(() => _fill(defaults)),
              child: const Text('Start from the default'),
            ),
          ],
        ),
        const Divider(height: 32),
        const Text(
          'Try an action',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 200,
              child: TextField(
                controller: sampleTool,
                decoration: const InputDecoration(labelText: 'Tool'),
              ),
            ),
            DropdownButton<String>(
              value: effects.contains(sampleEffect)
                  ? sampleEffect
                  : effects.first,
              items: [
                for (final e in effects)
                  DropdownMenuItem(value: e, child: Text(e)),
              ],
              onChanged: (v) =>
                  setState(() => sampleEffect = v ?? sampleEffect),
            ),
            DropdownButton<String>(
              value: sampleInitiator,
              items: [
                for (final k in const [
                  'person',
                  'routine',
                  'responsibility',
                  'proactive',
                  'handoff',
                  'channel',
                ])
                  DropdownMenuItem(value: k, child: Text('started by $k')),
              ],
              onChanged: (v) =>
                  setState(() => sampleInitiator = v ?? sampleInitiator),
            ),
            SizedBox(
              width: 240,
              child: TextField(
                controller: sampleCommand,
                decoration: const InputDecoration(
                  labelText: 'Command (optional)',
                ),
              ),
            ),
            OutlinedButton(onPressed: _test, child: const Text('Decide')),
          ],
        ),
        if (verdict.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              verdict,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

/// The audit trail of agent actions: who started each one (a person, a
/// routine, a responsibility, proactive work), what was decided and why.
class AuditView extends StatefulWidget {
  const AuditView({super.key, required this.dependencies, this.space = ''});
  final AppDependencies dependencies;
  final String space;

  @override
  State<AuditView> createState() => _AuditViewState();
}

class _AuditViewState extends State<AuditView> {
  static const _page = 50;
  List<Map<String, dynamic>> events = const [];
  int total = 0;
  int offset = 0;
  String decision = '';
  String initiator = '';
  bool unattended = false;
  bool loading = true;
  String error = '';

  Map<String, dynamic> get _query => {
    if (widget.space.isNotEmpty) 'space': widget.space,
    if (decision.isNotEmpty) 'decision': decision,
    if (initiator.isNotEmpty) 'initiator': initiator,
    if (unattended) 'unattended': true,
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final out = jsonMap(
        await widget.dependencies.service.invokeAction(
          'governance',
          'audit_list',
          body: {..._query, 'limit': _page, 'offset': offset},
        ),
      );
      if (!mounted) return;
      setState(() {
        events = jsonList(out['events']);
        total = (out['total'] as num?)?.toInt() ?? events.length;
        error = '';
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = errorText(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _export() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'audit_export',
      _query,
    );
    if (out == null) return;
    final csv = '${out['csv'] ?? ''}';
    final name =
        'aseman-audit-${DateTime.now().toIso8601String().substring(0, 10)}.csv';
    final saved = await saveBytes(name, utf8.encode(csv));
    if (saved.isEmpty) {
      await launchUrl(
        Uri.dataFromString(csv, mimeType: 'text/csv', encoding: utf8),
      );
    }
    if (!mounted) return;
    final note = out['truncated'] == true
        ? ' (the first ${out['cap']} rows)'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          saved.isEmpty
              ? 'Exported ${out['rows']} rows$note'
              : 'Saved ${out['rows']} rows$note to $saved',
        ),
      ),
    );
  }

  Widget _filter(
    String label,
    String value,
    List<String> options,
    ValueChanged<String> set,
  ) => DropdownButton<String>(
    value: value,
    items: [
      DropdownMenuItem(value: '', child: Text('Any $label')),
      for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
    ],
    onChanged: (v) {
      set(v ?? '');
      offset = 0;
      _load();
    },
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _filter('decision', decision, const [
              'allow',
              'ask',
              'deny',
              'approved',
              'refused',
              'error',
            ], (v) => decision = v),
            _filter('initiator', initiator, const [
              'person',
              'routine',
              'responsibility',
              'proactive',
              'handoff',
              'channel',
              'deployment',
            ], (v) => initiator = v),
            FilterChip(
              label: const Text('Unattended only'),
              selected: unattended,
              onSelected: (v) {
                unattended = v;
                offset = 0;
                _load();
              },
            ),
            OutlinedButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.download_rounded),
              label: const Text('Export CSV'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (error.isNotEmpty)
          Text(error, style: TextStyle(color: scheme.error)),
        if (loading) const LinearProgressIndicator(),
        if (!loading && events.isEmpty && error.isEmpty)
          const Text('Nothing recorded under this filter.'),
        for (final e in events)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(switch ('${e['decision']}') {
              'deny' || 'refused' => Icons.block_rounded,
              'ask' => Icons.help_outline_rounded,
              'error' => Icons.error_outline_rounded,
              _ => Icons.check_rounded,
            }),
            title: Text(
              [
                e['tool'] ?? e['event'],
                e['target'],
              ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
            ),
            subtitle: Text(
              [
                '${e['decision']}${'${e['rule'] ?? ''}'.isEmpty ? '' : ' by ${e['rule']}'}',
                if ('${e['agent_name'] ?? ''}'.isNotEmpty) '${e['agent_name']}',
                'started by ${e['initiator_kind'] ?? 'person'}',
                '${e['created_at'] ?? ''}'
                    .replaceFirst('T', ' ')
                    .split('.')
                    .first,
              ].join(' · '),
            ),
          ),
        if (total > _page)
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text('${offset + 1}–${offset + events.length} of $total'),
              IconButton(
                onPressed: offset == 0
                    ? null
                    : () {
                        offset = (offset - _page).clamp(0, total);
                        _load();
                      },
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                onPressed: offset + _page >= total
                    ? null
                    : () {
                        offset += _page;
                        _load();
                      },
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
      ],
    );
  }
}

/// Where a project's computer may connect, enforced by the egress proxy.
class EgressEditor extends StatefulWidget {
  const EgressEditor({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<EgressEditor> createState() => _EgressEditorState();
}

class _EgressEditorState extends State<EgressEditor> {
  static const _modes = {
    'defaults_plus_allowlist': (
      'Common developer services plus my list',
      'Package registries, Git hosts and model providers, and the hosts below.',
    ),
    'allowlist_only': ('Only my list', 'Nothing but the hosts below.'),
    'allow_all': (
      'Anywhere',
      'The computer connects anywhere except private networks and cloud metadata.',
    ),
    'deny_all': ('Nowhere', 'No connections except to this node.'),
  };

  final allow = TextEditingController();
  String mode = 'defaults_plus_allowlist';
  List<String> always = const [];
  bool canEdit = false;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    allow.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'egress_get',
      {'space': widget.space},
    );
    if (!mounted) return;
    final p = jsonMap(out?['policy']);
    setState(() {
      mode = _modes.containsKey(p['mode']) ? '${p['mode']}' : mode;
      allow.text = jsonStrings(p['allow']).join('\n');
      always = jsonStrings(p['always']);
      canEdit = out?['can_edit'] == true;
      loading = false;
    });
  }

  Future<void> _save() async {
    await runAction(context, widget.dependencies, 'governance', 'egress_set', {
      'space': widget.space,
      'mode': mode,
      'allow': allow.text
          .split(RegExp(r'[\s,]+'))
          .where((h) => h.isNotEmpty)
          .toList(),
    }, 'Saved: the computer follows it from its next connection');
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const LinearProgressIndicator();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioGroup<String>(
          groupValue: mode,
          onChanged: (v) {
            if (canEdit) setState(() => mode = v ?? mode);
          },
          child: Column(
            children: [
              for (final m in _modes.entries)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  value: m.key,
                  enabled: canEdit,
                  title: Text(m.value.$1),
                  subtitle: Text(m.value.$2),
                ),
            ],
          ),
        ),
        TextField(
          controller: allow,
          enabled: canEdit,
          minLines: 2,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Hosts',
            helperText:
                'One per line: api.example.com, or *.example.com for its subdomains',
            border: OutlineInputBorder(),
          ),
        ),
        if (always.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Always reachable: ${always.join(', ')}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const SizedBox(height: 8),
        if (canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          )
        else
          const Text('Only the project\'s owner changes this.'),
      ],
    );
  }
}

/// A project's saved credentials: names and lengths, never values. Agents use
/// them as {{secret:name}} and the node fills them in.
class SecretsView extends StatefulWidget {
  const SecretsView({
    super.key,
    required this.dependencies,
    required this.space,
  });
  final AppDependencies dependencies;
  final String space;

  @override
  State<SecretsView> createState() => _SecretsViewState();
}

class _SecretsViewState extends State<SecretsView> {
  List<Map<String, dynamic>> secrets = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'secret_list',
      {'space': widget.space},
    );
    if (mounted && out != null)
      setState(() => secrets = jsonList(out['secrets']));
  }

  Future<void> _add() async {
    final name = await askText(context, 'Name', hint: 'e.g. stripe_key');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final value = await askText(context, 'Value of $name', obscure: true);
    if (value == null || value.isEmpty || !mounted) return;
    final out = await runAction(
      context,
      widget.dependencies,
      'governance',
      'secret_set',
      {'space': widget.space, 'name': name.trim(), 'value': value},
      'Saved to the vault',
    );
    if (out != null) await _load();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (secrets.isEmpty)
        const Text(
          'No saved credentials. Agents ask for one with a masked box when they need it.',
        ),
      for (final s in secrets)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.key_rounded),
          title: Text('${s['name']}'),
          subtitle: Text(
            [
              '•' * ((s['length'] as num?)?.toInt().clamp(4, 12) ?? 8),
              if ('${s['site'] ?? ''}'.isNotEmpty) '${s['site']}',
              'use as {{secret:${s['name']}}}',
            ].join(' · '),
          ),
          trailing: IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final out = await runAction(
                context,
                widget.dependencies,
                'governance',
                'secret_delete',
                {'id': s['id']},
                'Deleted',
              );
              if (out != null) await _load();
            },
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add a credential'),
        ),
      ),
    ],
  );
}
