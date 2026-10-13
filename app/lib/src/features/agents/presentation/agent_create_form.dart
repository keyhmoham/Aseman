import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../data/models/llm_provider.dart';
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
    showDialog<BotFormResult>(
      context: context,
      builder: (_) => _CreateBotDialog(loadLlmCatalog: loadLlmCatalog),
    );

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
  final maxTurns = TextEditingController(text: '6');
  final maxTokens = TextEditingController(text: '2000');
  final Set<String> capabilities = {};

  // Miniapp / tool fields.
  final module = TextEditingController();
  final customFrontend = TextEditingController();
  final widgetDsl = TextEditingController();
  bool useStarterFrontend = true;

  // Resources.
  final cpu = TextEditingController(text: '1');
  final memory = TextEditingController(text: '512');
  final disk = TextEditingController(text: '512');

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
    maxTurns.dispose();
    maxTokens.dispose();
    module.dispose();
    customFrontend.dispose();
    widgetDsl.dispose();
    cpu.dispose();
    memory.dispose();
    disk.dispose();
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
      maxTurns: int.tryParse(maxTurns.text) ?? 0,
      maxTokens: int.tryParse(maxTokens.text) ?? 0,
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
      cpu: int.tryParse(cpu.text) ?? 1,
      memoryMb: int.tryParse(memory.text) ?? 512,
      diskMb: int.tryParse(disk.text) ?? 512,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.add_box_outlined, size: 26),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(
                      kind == 'agent' ? 'Create agent' : 'Create miniapp',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w900))),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 10),
            Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'agent',
                        label: Text('Agent'),
                        icon: Icon(Icons.smart_toy_outlined)),
                    ButtonSegment(
                        value: 'miniapp',
                        label: Text('Miniapp'),
                        icon: Icon(Icons.extension_outlined)),
                  ],
                  selected: {kind},
                  onSelectionChanged: (sel) => _selectKind(sel.first),
                )),
            const SizedBox(height: 14),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _field(context, 'Name', name,
                          hint: 'e.g. Nova Quant', autofocus: true),
                      const SizedBox(height: 10),
                      _field(context, 'Description', description,
                          hint: 'What does it do?'),
                      const SizedBox(height: 16),
                      if (kind == 'agent')
                        ..._agentFields(context)
                      else
                        ..._miniappFields(context),
                      const SizedBox(height: 16),
                      _resourcesFields(context),
                      const SizedBox(height: 6),
                    ]),
              ),
            ),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () {
                  final result = _submit();
                  if (result == null) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Please complete the required fields.')));
                    return;
                  }
                  Navigator.pop(context, result);
                },
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Create'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  List<Widget> _agentFields(BuildContext context) => [
        _sectionLabel(context, 'ROLE & INSTRUCTIONS'),
        _field(context, 'Instructions', instructions,
            hint: 'Describe the agent\u2019s role, goals and constraints…',
            maxLines: 4),
        const SizedBox(height: 12),
        ..._llmFields(context),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: _field(context, 'Max turns', maxTurns,
                  keyboard: TextInputType.number)),
          const SizedBox(width: 10),
          Expanded(
              child: _field(context, 'Max tokens', maxTokens,
                  keyboard: TextInputType.number)),
        ]),
        const SizedBox(height: 14),
        _sectionLabel(context, 'CAPABILITIES'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (label, icon) in _capabilityPool)
              FilterChip(
                avatar: Icon(icon,
                    size: 15,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
                label: Text(label, style: const TextStyle(fontSize: 11)),
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            catalogError != null
                ? 'Could not load LLM models: $catalogError'
                : 'No LLM provider is configured on this node yet. The node '
                    'admin must add one in Admin console → LLM.',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ];
    }
    final provider = _provider;
    final selected = _model;
    return [
      _sectionLabel(context, 'LLM BACKBONE'),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: providerId,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'LLM provider', border: OutlineInputBorder()),
            items: [
              for (final p in catalog)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (v) => setState(() {
              providerId = v ?? providerId;
              final models = _provider?.models ?? const <LlmModel>[];
              model = models.isEmpty ? '' : models.first.id;
            }),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('model-$providerId'),
            initialValue: model.isEmpty ? null : model,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Model', border: OutlineInputBorder()),
            items: [
              for (final m in provider?.models ?? const <LlmModel>[])
                DropdownMenuItem(value: m.id, child: Text(m.label)),
            ],
            onChanged: (v) => setState(() => model = v ?? model),
          ),
        ),
      ]),
      if (selected != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Token pricing: ${formatLedgerUsdPerMillion(selected.inputPrice)} / 1M input '
            '· ${formatLedgerUsdPerMillion(selected.outputPrice)} / 1M output',
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
    ];
  }

  List<Widget> _miniappFields(BuildContext context) => [
        _sectionLabel(context, 'BACKEND MODULE'),
        _field(context, 'Wasm module', module,
            hint: 'module path, e.g. miniapp.wasm',
            autofocus: kind == 'miniapp'),
        const SizedBox(height: 12),
        _sectionLabel(context, 'FRONTEND'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use starter frontend',
              style: TextStyle(fontSize: 13)),
          subtitle: const Text(
              'Generates a working elpian bundle that pings the backend.',
              style: TextStyle(fontSize: 10)),
          value: useStarterFrontend,
          onChanged: (v) => setState(() => useStarterFrontend = v),
        ),
        if (!useStarterFrontend)
          _field(context, 'Frontend bundle', customFrontend,
              hint: 'JSON {manifest, source}', maxLines: 4),
        const SizedBox(height: 12),
        _field(context, 'Desk widget DSL (optional)', widgetDsl,
            hint: 'JSON widget layout for the room desk', maxLines: 3),
      ];

  Widget _resourcesFields(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionLabel(context, 'RESOURCES'),
          Row(children: [
            Expanded(
                child: _field(context, 'CPU (vCPU)', cpu,
                    keyboard: TextInputType.number)),
            const SizedBox(width: 10),
            Expanded(
                child: _field(context, 'Memory (MB)', memory,
                    keyboard: TextInputType.number)),
            const SizedBox(width: 10),
            Expanded(
                child: _field(context, 'Disk (MB)', disk,
                    keyboard: TextInputType.number)),
          ]),
        ],
      );

  Widget _sectionLabel(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
              color: Theme.of(context).colorScheme.primary)));

  Widget _field(
    BuildContext context,
    String label,
    TextEditingController controller, {
    String? hint,
    int maxLines = 1,
    bool autofocus = false,
    TextInputType? keyboard,
  }) =>
      TextField(
        controller: controller,
        autofocus: autofocus,
        maxLines: maxLines,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          hintStyle:
              TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}
