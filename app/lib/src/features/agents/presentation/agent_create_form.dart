import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../data/models/llm_provider.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/skeleton.dart';

/// Result of the structured agent creation form (tools have their own form:
/// features/tools/presentation/tool_create_form.dart). Sent to the backend which
/// validates it and renders the VM configuration server-side.
class BotFormResult {
  const BotFormResult({
    required this.name,
    required this.kind,
    required this.vmType,
    this.description = '',
    this.instructions = '',
    this.provider = '',
    this.model = '',
    this.maxTurns = 0,
    this.maxTokens = 0,
    this.skills = const [],
    this.module = '',
    this.frontend = '',
    this.widgetDsl = '',
    this.cpu = 1,
    this.memoryMb = 512,
    this.diskMb = 512,
  });

  final String name;
  final String kind; // agent | tool
  final String vmType;
  final String description;
  final String instructions;
  final String provider; // admin-configured LLM provider id
  final String model;
  final int maxTurns;
  final int maxTokens;
  final List<Map<String, dynamic>> skills;
  final String module;
  final String frontend;
  final String widgetDsl;
  final int cpu;
  final int memoryMb;
  final int diskMb;

  /// An agent as bots.bot_detail reports it to its owner: what its form was
  /// filled with, so it opens in the editor as it is configured today.
  factory BotFormResult.fromDetail(Map<String, dynamic> detail) {
    final agent = (detail['agent'] as Map?)?.cast<String, dynamic>() ?? {};
    final resources =
        (detail['resources'] as Map?)?.cast<String, dynamic>() ?? {};
    String text(Object? v) => v is String ? v : '';
    int number(Object? v, int fallback) =>
        v is num && v > 0 ? v.round() : fallback;
    final description = text(agent['description']);
    return BotFormResult(
      name: text(detail['name']),
      kind: text(detail['kind']).isEmpty ? 'agent' : text(detail['kind']),
      vmType: text(detail['vm_type']),
      description:
          description.isEmpty ? text(detail['description']) : description,
      instructions: text(agent['instructions']),
      provider: text(agent['provider']),
      model: text(agent['model']),
      // Unset, they read as the form's defaults: saving it unchanged then
      // changes nothing.
      maxTurns: number(agent['max_turns'], 6),
      maxTokens: number(agent['max_tokens'], 2000),
      skills: [
        for (final s in (agent['skills'] as List?) ?? const [])
          if (s is Map) s.cast<String, dynamic>(),
      ],
      cpu: number(resources['cpu'], 1),
      memoryMb: number(resources['memory_mb'], 512),
      diskMb: number(resources['disk_mb'], 512),
    );
  }
}

/// Opens the structured create-bot dialog and returns the filled form result,
/// or null when cancelled. [loadLlmCatalog] lists the LLM providers + models
/// the node admin configured; the agent picks its backbone from them. With
/// [initial] it edits an existing agent: the form opens filled with it.
Future<BotFormResult?> showCreateBotForm(BuildContext context,
        {Future<List<LlmProvider>> Function()? loadLlmCatalog,
        BotFormResult? initial}) =>
    showAppForm<BotFormResult>(context,
        _CreateBotDialog(loadLlmCatalog: loadLlmCatalog, initial: initial));

/// Opens the agent form on an existing agent; returns the edited form.
Future<BotFormResult?> showEditBotForm(BuildContext context,
        {required BotFormResult initial,
        Future<List<LlmProvider>> Function()? loadLlmCatalog}) =>
    showCreateBotForm(context,
        loadLlmCatalog: loadLlmCatalog, initial: initial);

class _CreateBotDialog extends StatefulWidget {
  const _CreateBotDialog({this.loadLlmCatalog, this.initial});
  final Future<List<LlmProvider>> Function()? loadLlmCatalog;
  final BotFormResult? initial;
  @override
  State<_CreateBotDialog> createState() => _CreateBotDialogState();
}

class _CreateBotDialogState extends State<_CreateBotDialog> {
  final String kind = 'agent';
  final String vmType = 'harness';

  final name = TextEditingController();
  final description = TextEditingController();

  // Agent fields.
  final instructions = TextEditingController();
  // LLM backbone: provider + model from the admin-configured catalog.
  List<LlmProvider> catalog = const [];
  bool catalogLoading = true;
  String? catalogError;
  String providerId = '';
  String model = '';
  int maxTurns = 6;
  int maxTokens = 2000;
  final Set<String> capabilities = {};

  // Resources.
  int cpu = 1;
  int memory = 512;
  int disk = 512;

  bool get editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      name.text = initial.name;
      description.text = initial.description;
      instructions.text = initial.instructions;
      providerId = initial.provider;
      model = initial.model;
      if (initial.maxTurns > 0) maxTurns = initial.maxTurns.clamp(1, 30);
      if (initial.maxTokens > 0) maxTokens = initial.maxTokens;
      capabilities.addAll([
        for (final s in initial.skills)
          if (s['name'] is String) s['name'] as String,
      ]);
      cpu = initial.cpu;
      memory = initial.memoryMb;
      disk = initial.diskMb;
    }
    _loadCatalog();
  }

  Future<void> _loadCatalog() async {
    final load = widget.loadLlmCatalog;
    if (load == null) {
      setState(() => catalogLoading = false);
      return;
    }
    try {
      final list = await load();
      if (!mounted) return;
      setState(() {
        catalog = list.where((p) => p.models.isNotEmpty).toList();
        catalogLoading = false;
        // An agent being edited keeps its model while it is still offered.
        if (catalog.isNotEmpty && _model == null) {
          final def = catalog.firstWhere((p) => p.isDefault,
              orElse: () => catalog.first);
          providerId = def.id;
          model = def.models.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        catalogError = e.toString();
        catalogLoading = false;
      });
    }
  }

  LlmProvider? get _provider =>
      catalog.where((p) => p.id == providerId).firstOrNull;

  LlmModel? get _model =>
      _provider?.models.where((m) => m.id == model).firstOrNull;

  static const _capabilityPool = [
    ('Research', Icons.travel_explore_rounded),
    ('Writing', Icons.edit_note_rounded),
    ('Coordination', Icons.hub_outlined),
    ('Coding', Icons.code_rounded),
    ('Reports', Icons.description_outlined),
    ('Monitoring', Icons.visibility_outlined),
  ];

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    instructions.dispose();
    super.dispose();
  }

  bool _validate() {
    if (name.text.trim().isEmpty) return false;
    if (kind == 'agent' && instructions.text.trim().isEmpty) return false;
    if (kind == 'agent' && catalog.isNotEmpty && _model == null) return false;
    return true;
  }

  BotFormResult? _submit() {
    if (!_validate()) return null;
    return BotFormResult(
      name: name.text.trim(),
      kind: kind,
      vmType: vmType,
      description: description.text.trim(),
      instructions: instructions.text.trim(),
      provider: kind == 'agent' ? providerId : '',
      model: kind == 'agent' ? model : '',
      maxTurns: maxTurns,
      maxTokens: maxTokens,
      skills: [
        for (final c in capabilities)
          // A capability it already had keeps what it was configured with.
          widget.initial?.skills.where((s) => s['name'] == c).firstOrNull ??
              {
                'name': c,
                'description': 'Agent capability: $c',
                'tools': const <String>[],
              },
      ],
      cpu: cpu,
      memoryMb: memory,
      diskMb: disk,
    );
  }

  /// The offered sizes, plus the one an edited agent has when it is not
  /// among them.
  static List<int> _withCurrent(List<int> offered, int current) =>
      offered.contains(current) ? offered : ([...offered, current]..sort());

  static String _mb(int mb) =>
      mb >= 1024 ? '${compactDecimal(mb / 1024)} GB' : '$mb MB';

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: editing ? Icons.edit_outlined : Icons.smart_toy_outlined,
        title: editing ? 'Edit agent' : 'Create agent',
        subtitle: editing
            ? 'Changes apply to its next conversation; its computer is recreated with them.'
            : 'An assistant that works in your rooms with its own model and instructions.',
        submit: editing ? 'Save changes' : 'Create',
        onSubmit: () {
          final result = _submit();
          if (result == null) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
                content: Text('Please complete the required fields.')));
            return;
          }
          Navigator.pop(context, result);
        },
        children: [
          _field(context, 'Name', name,
              hint: 'e.g. Nova Helper', autofocus: true),
          _field(context, 'Description', description,
              hint: 'What does it do?', maxLines: 2),
          ..._agentFields(context),
          _resourcesFields(context),
        ],
      );

  List<Widget> _agentFields(BuildContext context) => [
        _field(context, 'Instructions', instructions,
            hint: 'Describe the agent’s role, goals and constraints…',
            maxLines: 5),
        ..._llmFields(context),
        AppAmountField(
          label: 'Steps per task',
          hint: 'How many tool calls and replies it may take before stopping.',
          value: maxTurns.toDouble(),
          min: 1,
          max: 30,
          step: 1,
          decimals: 0,
          presets: const [3, 6, 10, 20],
          presetLabel: (v) => '${v.round()}',
          format: (v) => '${v.round()} steps',
          onChanged: (v) => setState(() => maxTurns = v.round()),
        ),
        AppChoiceField<int>(
          label: 'Reply length',
          hint: 'The most tokens one reply may use.',
          value: maxTokens,
          onChanged: (v) => setState(() => maxTokens = v),
          choices: [
            const AppChoice(1000, 'Short · 1K'),
            const AppChoice(2000, 'Normal · 2K'),
            const AppChoice(4000, 'Long · 4K'),
            const AppChoice(8000, 'Very long · 8K'),
            if (!const [1000, 2000, 4000, 8000].contains(maxTokens))
              AppChoice(maxTokens, 'Custom · $maxTokens'),
          ],
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppFieldLabel('Capabilities'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, icon) in [
                ..._capabilityPool,
                // Capabilities it was given elsewhere stay choosable.
                for (final c in capabilities)
                  if (!_capabilityPool.any((p) => p.$1 == c))
                    (c, Icons.extension_outlined),
              ])
                FilterChip(
                  avatar: Icon(icon, size: 17),
                  label: Text(label),
                  selected: capabilities.contains(label),
                  onSelected: (sel) => setState(() {
                    if (sel) {
                      capabilities.add(label);
                    } else {
                      capabilities.remove(label);
                    }
                  }),
                ),
            ],
          ),
        ]),
      ];

  /// Provider + model pickers for the agent's LLM backbone, with the token
  /// prices the agent's users are charged.
  List<Widget> _llmFields(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (catalogLoading) {
      return const [SkeletonField(), SizedBox(height: 12), SkeletonField()];
    }
    if (catalog.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
          ),
          child: Text(
            catalogError != null
                ? 'Could not load LLM models: $catalogError'
                : 'No LLM provider is configured on this node yet. The node '
                    'admin must add one in Admin console → LLM.',
            style: const TextStyle(fontSize: 13),
          ),
        ),
      ];
    }
    final provider = _provider;
    final selected = _model;
    return [
      if (catalog.length > 1)
        AppChoiceField<String>(
          label: 'Provider',
          value: providerId,
          onChanged: (v) => setState(() {
            providerId = v;
            final models = _provider?.models ?? const <LlmModel>[];
            model = models.isEmpty ? '' : models.first.id;
          }),
          choices: [
            for (final p in catalog)
              AppChoice(p.id, p.name, icon: Icons.hub_outlined),
          ],
        ),
      AppChoiceField<String>(
        label: 'Model',
        hint: selected == null
            ? null
            : '${formatLedgerUsdPerMillion(selected.inputPrice)} input · '
                '${formatLedgerUsdPerMillion(selected.outputPrice)} output per 1M tokens',
        value: model,
        onChanged: (v) => setState(() => model = v),
        choices: [
          for (final m in provider?.models ?? const <LlmModel>[])
            AppChoice(m.id, m.label, icon: Icons.memory_rounded),
        ],
      ),
    ];
  }

  Widget _resourcesFields(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppChoiceField<int>(
            label: 'Computer size',
            hint:
                'What its machine is created with; bigger costs more per minute.',
            value: cpu,
            onChanged: (v) => setState(() => cpu = v),
            choices: [
              for (final n in _withCurrent(const [1, 2, 4], cpu))
                AppChoice(n, '$n vCPU'),
            ],
          ),
          const SizedBox(height: 18),
          AppChoiceField<int>(
            label: 'Memory',
            value: memory,
            onChanged: (v) => setState(() => memory = v),
            choices: [
              for (final mb
                  in _withCurrent(const [256, 512, 1024, 2048, 4096], memory))
                AppChoice(mb, _mb(mb)),
            ],
          ),
          const SizedBox(height: 18),
          AppChoiceField<int>(
            label: 'Disk',
            value: disk,
            onChanged: (v) => setState(() => disk = v),
            choices: [
              for (final mb
                  in _withCurrent(const [512, 1024, 4096, 10240], disk))
                AppChoice(mb, _mb(mb)),
            ],
          ),
        ],
      );

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    bool autofocus = false,
    bool mono = false,
  }) =>
      TextField(
        controller: controller,
        autofocus: autofocus,
        minLines: maxLines > 1 ? 2 : 1,
        maxLines: maxLines,
        style: mono
            ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: maxLines > 1,
        ),
      );
}
