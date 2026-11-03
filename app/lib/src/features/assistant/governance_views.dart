import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_dependencies.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_chrome.dart';
import '../../core/theme/theme_roles.dart';
import '../../shared/widgets/avatar_face.dart';
import '../../shared/widgets/app_inputs.dart';
import '../../shared/widgets/glass_surface.dart';
import '../../shared/widgets/skeleton.dart';
import '../rooms/presentation/widgets/download_helper.dart';
import 'assistant_common.dart';

/// The governance views shared by the admin console (the node's scope, no
/// [space]) and a project's settings (its own scope): the action policy, the
/// audit trail, the computer's network policy and saved credentials.

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 20, color: scheme.primary),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.1,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.body, {this.icon});
  final String title;
  final String body;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: ShapeDecoration(
              color: ThemeRoles.wellFill(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
            ),
            child: Icon(
              icon ?? Icons.inbox_outlined,
              color: ThemeRoles.wellInk(context),
            ),
          ),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.label, {this.color});
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tone,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

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
        if (jsonStrings(out['effects']).isNotEmpty) {
          effects = jsonStrings(out['effects']);
        }
        loading = false;
        error = '';
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
            alignLabelWithHint: true,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (loading) return const SkeletonList(itemCount: 3);
    if (error.isNotEmpty) {
      return _Empty('Could not load policy', error, icon: Icons.cloud_off_rounded);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Action policy',
          icon: Icons.policy_rounded,
          subtitle: isDefault
              ? 'The default policy is in effect: it asks before sending, paying, signing or deleting, and lets work started on its own only read.'
              : 'This scope has its own policy.',
          trailing: _Pill(
            isDefault ? 'Default' : 'Custom',
            color: isDefault ? AppColors.successOf(context) : scheme.primary,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Variables: ${variables.join(', ')}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_rounded, size: 18),
                    label: const Text('Save policy'),
                  ),
                  TextButton(
                    onPressed: defaults.isEmpty
                        ? null
                        : () => setState(() => _fill(defaults)),
                    child: const Text('Start from the default'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: 'Try an action',
          icon: Icons.science_outlined,
          subtitle: 'Dry-run a sample request against the rules above.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 200,
                    child: TextField(
                      controller: sampleTool,
                      decoration: const InputDecoration(labelText: 'Tool'),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: DropdownButtonFormField<String>(
                      value: effects.contains(sampleEffect)
                          ? sampleEffect
                          : effects.first,
                      decoration: const InputDecoration(labelText: 'Effect'),
                      items: [
                        for (final e in effects)
                          DropdownMenuItem(value: e, child: Text(e)),
                      ],
                      onChanged: (v) =>
                          setState(() => sampleEffect = v ?? sampleEffect),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<String>(
                      value: sampleInitiator,
                      decoration:
                          const InputDecoration(labelText: 'Started by'),
                      items: [
                        for (final k in const [
                          'person',
                          'routine',
                          'responsibility',
                          'proactive',
                          'handoff',
                          'channel',
                        ])
                          DropdownMenuItem(value: k, child: Text(k)),
                      ],
                      onChanged: (v) => setState(
                        () => sampleInitiator = v ?? sampleInitiator,
                      ),
                    ),
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
                  FilledButton.tonalIcon(
                    onPressed: _test,
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Decide'),
                  ),
                ],
              ),
              if (verdict.isNotEmpty) ...[
                const SizedBox(height: 12),
                GlassSurface(
                  borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
                  color: ThemeRoles.wellFill(context),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      verdict,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ],
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

  Color _decisionColor(String d) => switch (d) {
        'deny' || 'refused' => AppColors.dangerOf(context),
        'ask' => AppColors.warningOf(context),
        'error' => AppColors.dangerOf(context),
        'allow' || 'approved' => AppColors.successOf(context),
        _ => Theme.of(context).colorScheme.onSurfaceVariant,
      };

  IconData _decisionIcon(String d) => switch (d) {
        'deny' || 'refused' => Icons.block_rounded,
        'ask' => Icons.help_outline_rounded,
        'error' => Icons.error_outline_rounded,
        _ => Icons.check_circle_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Section(
          title: 'Audit trail',
          icon: Icons.fact_check_rounded,
          subtitle: 'Every agent action, who started it and what was decided.',
          trailing: OutlinedButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text('Export CSV'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<String>(
                      value: decision,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Decision'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Any decision'),
                        ),
                        for (final o in const [
                          'allow',
                          'ask',
                          'deny',
                          'approved',
                          'refused',
                          'error',
                        ])
                          DropdownMenuItem(value: o, child: Text(o)),
                      ],
                      onChanged: (v) {
                        decision = v ?? '';
                        offset = 0;
                        _load();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<String>(
                      value: initiator,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Initiator'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: Text('Any initiator'),
                        ),
                        for (final o in const [
                          'person',
                          'routine',
                          'responsibility',
                          'proactive',
                          'handoff',
                          'channel',
                          'deployment',
                        ])
                          DropdownMenuItem(value: o, child: Text(o)),
                      ],
                      onChanged: (v) {
                        initiator = v ?? '';
                        offset = 0;
                        _load();
                      },
                    ),
                  ),
                  FilterChip(
                    label: const Text('Unattended only'),
                    selected: unattended,
                    onSelected: (v) {
                      unattended = v;
                      offset = 0;
                      _load();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (error.isNotEmpty)
                Text(error, style: TextStyle(color: scheme.error)),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: SkeletonList(itemCount: 4),
                )
              else if (events.isEmpty && error.isEmpty)
                const _Empty(
                  'Nothing recorded',
                  'Nothing matches this filter yet.',
                  icon: Icons.fact_check_outlined,
                )
              else
                for (final e in events)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    leading: Builder(builder: (context) {
                      const size = 40.0;
                      final corners = context.avatarBorderRadius(size);
                      final color = _decisionColor('${e['decision']}');
                      return AvatarFace(
                        size: size,
                        borderRadius: corners,
                        backgroundColor: color.withValues(alpha: .16),
                        child: Icon(
                          _decisionIcon('${e['decision']}'),
                          color: color,
                          size: 20,
                        ),
                      );
                    }),
                    title: Text(
                      [
                        e['tool'] ?? e['event'],
                        e['target'],
                      ].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        if ('${e['agent_name'] ?? ''}'.isNotEmpty)
                          '${e['agent_name']}',
                        'started by ${e['initiator_kind'] ?? 'person'}',
                        '${e['created_at'] ?? ''}'
                            .replaceFirst('T', ' ')
                            .split('.')
                            .first,
                      ].join(' · '),
                    ),
                    trailing: _Pill(
                      () {
                        final rule = '${e['rule'] ?? ''}';
                        final decision = '${e['decision']}';
                        return rule.isEmpty ? decision : '$decision · $rule';
                      }(),
                      color: _decisionColor('${e['decision']}'),
                    ),
                  ),
              if (total > _page)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '${offset + 1}–${offset + events.length} of $total',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
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
                ),
            ],
          ),
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
      Icons.public_rounded,
    ),
    'allowlist_only': (
      'Only my list',
      'Nothing but the hosts below.',
      Icons.list_alt_rounded,
    ),
    'allow_all': (
      'Anywhere',
      'The computer connects anywhere except private networks and cloud metadata.',
      Icons.travel_explore_rounded,
    ),
    'deny_all': (
      'Nowhere',
      'No connections except to this node.',
      Icons.block_rounded,
    ),
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
    if (loading) return const SkeletonList(itemCount: 3);
    return _Section(
      title: 'Network access',
      icon: Icons.lan_rounded,
      subtitle: 'Where this project’s computer may connect.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in _modes.entries) ...[
            AppSwitchCard(
              icon: m.value.$3,
              title: m.value.$1,
              subtitle: m.value.$2,
              value: mode == m.key,
              onChanged: !canEdit
                  ? null
                  : (v) {
                      if (v) setState(() => mode = m.key);
                    },
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 6),
          TextField(
            controller: allow,
            enabled: canEdit,
            minLines: 2,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Hosts',
              helperText:
                  'One per line: api.example.com, or *.example.com for its subdomains',
              alignLabelWithHint: true,
            ),
          ),
          if (always.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Always reachable: ${always.join(', ')}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('Save'),
              ),
            )
          else
            Text(
              'Only the project’s owner changes this.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
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
  bool loading = true;

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
    if (!mounted) return;
    setState(() {
      if (out != null) secrets = jsonList(out['secrets']);
      loading = false;
    });
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
  Widget build(BuildContext context) {
    if (loading) return const SkeletonList(itemCount: 3);
    return _Section(
      title: 'Saved credentials',
      icon: Icons.key_rounded,
      subtitle:
          'Names and lengths only — never values. Agents use them as {{secret:name}}.',
      trailing: TextButton.icon(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Add'),
      ),
      child: secrets.isEmpty
          ? const _Empty(
              'No saved credentials',
              'Agents ask for one with a masked box when they need it.',
              icon: Icons.key_off_outlined,
            )
          : Column(
              children: [
                for (final s in secrets)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(vertical: 2),
                    leading: Builder(builder: (context) {
                      const size = 40.0;
                      final corners = context.avatarBorderRadius(size);
                      return AvatarFace(
                        size: size,
                        borderRadius: corners,
                        backgroundColor: ThemeRoles.wellFill(context),
                        child: Icon(
                          Icons.key_rounded,
                          color: ThemeRoles.wellInk(context),
                        ),
                      );
                    }),
                    title: Text(
                      '${s['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      [
                        '•' *
                            ((s['length'] as num?)?.toInt().clamp(4, 12) ?? 8),
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
              ],
            ),
    );
  }
}
