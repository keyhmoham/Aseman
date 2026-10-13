import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../data/models/llm_provider.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../miniapps/presentation/miniapp_sandbox_screen.dart';

/// Result of the structured bot creation form. Sent to the backend which
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
  final String kind; // agent | miniapp | tool
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
}

/// Opens the structured create-bot dialog and returns the filled form result,
/// or null when cancelled. [loadLlmCatalog] lists the LLM providers + models
/// the node admin configured; the agent picks its backbone from them.
Future<BotFormResult?> showCreateBotForm(BuildContext context,
        {Future<List<LlmProvider>> Function()? loadLlmCatalog}) =>
    showAppForm<BotFormResult>(
        context, _CreateBotDialog(loadLlmCatalog: loadLlmCatalog));

class _CreateBotDialog extends StatefulWidget {
  const _CreateBotDialog({this.loadLlmCatalog});
  final Future<List<LlmProvider>> Function()? loadLlmCatalog;
  @override
  State<_CreateBotDialog> createState() => _CreateBotDialogState();
}

class _CreateBotDialogState extends State<_CreateBotDialog> {
  String kind = 'agent';
  String vmType = 'langchain';

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

  // Miniapp / tool fields.
  final module = TextEditingController();
  final customFrontend = TextEditingController();
  final widgetDsl = TextEditingController();
  bool useStarterFrontend = true;

  // Resources.
  int cpu = 1;
  int memory = 512;
  int disk = 512;
  bool advanced = false;

  @override
  void initState() {
    super.initState();
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
        if (catalog.isNotEmpty) {
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
    ('Market scanner', Icons.candlestick_chart_rounded),
    ('Risk analysis', Icons.shield_outlined),
    ('Execution', Icons.bolt_rounded),
    ('Research', Icons.travel_explore_rounded),
    ('Reports', Icons.description_outlined),
    ('Signals', Icons.waves_rounded),
  ];

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    instructions.dispose();
    module.dispose();
    customFrontend.dispose();
    widgetDsl.dispose();
    super.dispose();
  }

  void _selectKind(String value) {
    setState(() {
      kind = value;
      vmType = value == 'agent' ? 'langchain' : 'wasm';
    });
  }

  bool _validate() {
    if (name.text.trim().isEmpty) return false;
    if (kind == 'agent' && instructions.text.trim().isEmpty) return false;
    if (kind == 'agent' && catalog.isNotEmpty && _model == null) return false;
    if (kind == 'miniapp' && module.text.trim().isEmpty) return false;
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
          {
            'name': c,
            'description': 'Agent capability: $c',
            'tools': const <String>[],
          },
      ],
      module: kind == 'miniapp' ? module.text.trim() : '',
      frontend: kind == 'miniapp'
          ? (useStarterFrontend
              ? _starterFrontend(name.text.trim())
              : customFrontend.text.trim())
          : '',
      widgetDsl: kind == 'miniapp'
          ? (widgetDsl.text.trim().isEmpty
              ? _starterWidgetDsl(name.text.trim())
              : widgetDsl.text.trim())
          : '',
      cpu: cpu,
      memoryMb: memory,
      diskMb: disk,
    );
  }

  static String _starterFrontend(String name) {
    final manifest = {'name': name, 'version': '0.1.0', 'runtime': 'quickjs'};
    final bundle = kDefaultMiniappTemplate.replaceAll(
        'Hello from elpian', 'Hello from $name');
    return jsonEncode({'manifest': manifest, 'source': bundle});
  }

  static String _starterWidgetDsl(String name) => jsonEncode({
        'version': 1,
        'title': name,
        'refresh_sec': 10,
        'rows': [
          {
            'type': 'status',
            'label': 'Status',
            'value': 'pending',
            'color': 'info'
          },
          {'type': 'metric', 'label': 'Backend', 'value': 'wasm'},
          {
            'type': 'button',
            'text': 'Ping backend',
            'action': {
              'op': 'ping',
              'args': {'echo': true}
            }
          },
        ],
      });

  static String _mb(int mb) =>
      mb >= 1024 ? '${compactDecimal(mb / 1024)} GB' : '$mb MB';

  @override
  Widget build(BuildContext context) => AppFormFrame(
        icon: kind == 'agent'
            ? Icons.smart_toy_outlined
            : Icons.extension_outlined,
        title: kind == 'agent' ? 'Create agent' : 'Create miniapp',
        subtitle: kind == 'agent'
            ? 'An assistant that works in your rooms with its own model and instructions.'
            : 'A small app with a backend module and a desk widget.',
        submit: 'Create',
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
          AppSegmentedField<String>(
            label: 'What are you making?',
            value: kind,
            onChanged: _selectKind,
            choices: const [
              AppChoice('agent', 'Agent', icon: Icons.smart_toy_outlined),
              AppChoice('miniapp', 'Miniapp', icon: Icons.extension_outlined),
            ],
          ),
          _field(context, 'Name', name,
              hint: 'e.g. Nova Quant', autofocus: true),
          _field(context, 'Description', description,
              hint: 'What does it do?', maxLines: 2),
          if (kind == 'agent')
            ..._agentFields(context)
          else
            ..._miniappFields(context),
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
          choices: const [
            AppChoice(1000, 'Short · 1K'),
            AppChoice(2000, 'Normal · 2K'),
            AppChoice(4000, 'Long · 4K'),
            AppChoice(8000, 'Very long · 8K'),
          ],
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppFieldLabel('Capabilities'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, icon) in _capabilityPool)
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
      return const [LinearProgressIndicator()];
    }
    if (catalog.isEmpty) {
      return [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(AppShape.control),
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

  List<Widget> _miniappFields(BuildContext context) => [
        _field(context, 'Wasm module', module,
            hint: 'module path, e.g. miniapp.wasm',
            autofocus: kind == 'miniapp'),
        AppSwitchCard(
          icon: Icons.auto_awesome_rounded,
          title: 'Use the starter frontend',
          subtitle: 'Generates a working app screen that talks to the backend.',
          value: useStarterFrontend,
          onChanged: (v) => setState(() => useStarterFrontend = v),
        ),
        AppSwitchCard(
          icon: Icons.code_rounded,
          title: 'Advanced',
          subtitle: 'Provide your own frontend bundle and desk widget layout.',
          value: advanced || !useStarterFrontend,
          onChanged: (v) => setState(() => advanced = v),
        ),
        if (advanced || !useStarterFrontend) ...[
          if (!useStarterFrontend)
            _field(context, 'Frontend bundle', customFrontend,
                hint: 'JSON {manifest, source}', maxLines: 4, mono: true),
          _field(context, 'Desk widget layout (optional)', widgetDsl,
              hint: 'JSON widget layout for the room desk',
              maxLines: 3,
              mono: true),
        ],
      ];

  Widget _resourcesFields(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppChoiceField<int>(
            label: 'Computer size',
            hint:
                'What its machine is created with; bigger costs more per minute.',
            value: cpu,
            onChanged: (v) => setState(() => cpu = v),
            choices: const [
              AppChoice(1, '1 vCPU'),
              AppChoice(2, '2 vCPU'),
              AppChoice(4, '4 vCPU'),
            ],
          ),
          const SizedBox(height: 18),
          AppChoiceField<int>(
            label: 'Memory',
            value: memory,
            onChanged: (v) => setState(() => memory = v),
            choices: [
              for (final mb in const [256, 512, 1024, 2048, 4096])
                AppChoice(mb, _mb(mb)),
            ],
          ),
          const SizedBox(height: 18),
          AppChoiceField<int>(
            label: 'Disk',
            value: disk,
            onChanged: (v) => setState(() => disk = v),
            choices: [
              for (final mb in const [512, 1024, 4096, 10240])
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
