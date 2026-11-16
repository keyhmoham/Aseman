part of 'admin_page_content.dart';

class _ModelEditorDialog extends StatefulWidget {
  const _ModelEditorDialog({
    required this.providers,
    required this.provider,
    required this.onSave,
    this.model,
  });

  final List<Map<String, dynamic>> providers;
  final Map<String, dynamic> provider;
  final Map<String, dynamic>? model;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;

  @override
  State<_ModelEditorDialog> createState() => _ModelEditorDialogState();
}

class _ModelEditorDialogState extends State<_ModelEditorDialog> {
  late String providerId;
  late String purpose;
  late bool disabled;
  late final String previousId;
  late final TextEditingController id;
  late final TextEditingController name;
  late final TextEditingController input;
  late final TextEditingController output;
  final units = <String, TextEditingController>{};
  bool saving = false;

  bool get editing => widget.model != null;
  Map<String, dynamic> get previous => widget.model ?? const {};

  @override
  void initState() {
    super.initState();
    final model = previous;
    providerId = '${widget.provider['id']}';
    previousId = '${model['id'] ?? ''}';
    id = TextEditingController(text: previousId);
    name = TextEditingController(text: '${model['name'] ?? ''}');
    input = TextEditingController(
      text: ledgerUsdField(_number(model['input_price'])),
    );
    output = TextEditingController(
      text: ledgerUsdField(_number(model['output_price'])),
    );
    final label = _modelPurpose(model);
    purpose = _modelKinds.firstWhere((k) => k.$2 == label).$1;
    disabled = model['disabled'] == true;
    final stored = _map(model['units']);
    for (final fields in _unitFields.values) {
      for (final (key, quoted, scale) in fields) {
        final v = _number(stored[key]) * scale;
        units[quoted] = TextEditingController(
          text: v > 0
              ? compactDecimal(v / ledgerUnitsPerUsd, decimals: 10)
              : '',
        );
      }
    }
  }

  @override
  void dispose() {
    id.dispose();
    name.dispose();
    input.dispose();
    output.dispose();
    for (final c in units.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> save() async {
    final modelId = id.text.trim();
    final tokens = _tokenPriced.contains(purpose);
    final inputUnits = tokens
        ? parseUsdToLedger(input.text.isEmpty ? '0' : input.text)
        : 0;
    final outputUnits = tokens
        ? parseUsdToLedger(output.text.isEmpty ? '0' : output.text)
        : 0;
    if (modelId.isEmpty || inputUnits == null || outputUnits == null) {
      _say(
        'Enter the provider model id and valid dollar prices (up to six decimals).',
      );
      return;
    }
    // Prices other than tokens: dollars per quoted unit in, ledger units per
    // stored unit out.
    Map<String, dynamic>? nextUnits;
    for (final (key, quoted, scale)
        in _unitFields[purpose] ?? const <(String, String, double)>[]) {
      final raw = units[quoted]!.text.trim().replaceFirst(RegExp(r'^\$'), '');
      if (raw.isEmpty) continue;
      final usd = double.tryParse(raw.replaceAll(',', ''));
      if (usd == null || usd < 0) {
        _say('$quoted: a dollar amount, e.g. 0.04.');
        return;
      }
      if (usd > 0) {
        final v = (usd * ledgerUnitsPerUsd / scale * 100).round() / 100;
        nextUnits = {...?nextUnits, key: v};
      }
    }
    final before = _map(previous['units']);
    // A video priced by resolution keeps those prices while its rate is left
    // as it was.
    if (purpose == 'video' &&
        before['second_by'] != null &&
        _number(nextUnits?['second']) == _number(before['second'])) {
      nextUnits = {...?nextUnits, 'second_by': before['second_by']};
    }
    final provider = widget.providers.firstWhere(
      (p) => '${p['id']}' == providerId,
      orElse: () => widget.provider,
    );
    final models = _listOfMaps(provider['models']);
    if (models.any(
      (m) => '${m['id']}' == modelId && '${m['id']}' != previousId,
    )) {
      _say('$modelId is already listed.');
      return;
    }
    // What an import recorded (source, tags, inputs) stays; a price typed by
    // hand is no longer the source's price plus a markup.
    final kept = {...previous}
      ..remove('_provider')
      ..remove('name')
      ..remove('capabilities')
      ..remove('units')
      ..remove('unpriced')
      ..remove('disabled');
    bool sameUnits(Map<String, dynamic> a, Map<String, dynamic> b) =>
        {...a.keys, ...b.keys}.every(
          (k) => k == 'second_by'
              ? jsonEncode(a[k]) == jsonEncode(b[k])
              : _number(a[k]) == _number(b[k]),
        );
    final repriced =
        editing &&
        (_number(previous['input_price']) != inputUnits ||
            _number(previous['output_price']) != outputUnits ||
            !sameUnits(before, nextUnits ?? const {}));
    if (repriced) {
      kept
        ..remove('markup')
        ..remove('base_input_price')
        ..remove('base_output_price')
        ..remove('base_units');
    }
    final priced = inputUnits > 0 || outputUnits > 0 || nextUnits != null;
    final next = <String, dynamic>{
      ...kept,
      'id': modelId,
      if (name.text.trim().isNotEmpty) 'name': name.text.trim(),
      'input_price': inputUnits,
      'output_price': outputUnits,
      if (nextUnits != null) 'units': nextUnits,
      'capabilities': [purpose],
      // Imported without a price, it is served once one is set.
      if (previous['unpriced'] == true && !priced) 'unpriced': true,
      if (disabled) 'disabled': true,
    };
    final nextModels = <Map<String, dynamic>>[
      for (final current in models)
        if ('${current['id']}' == previousId) next else current,
      if (!editing) next,
    ];
    setState(() => saving = true);
    try {
      await widget.onSave({...provider, 'models': nextModels});
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      _say('Could not save model: $error');
      setState(() => saving = false);
    }
  }

  static const _purposeHints = {
    'chat': 'Agents can use this as their main reasoning model.',
    'decision':
        'Used for app selection, routing, progress, and completion checks. Agents cannot use it as their main model.',
    'embedding':
        'Turns memories into vectors for semantic recall. Agents cannot use it as their main model.',
    'image':
        'Makes images: the node\'s image model and the developer API. Priced per image, by its tokens, or both.',
    'video': 'Makes videos for the developer API, priced per second.',
    'speech':
        'Turns text into speech for Talk (Admin → AI → Voice) and the developer API, priced per character.',
    'transcription':
        'Turns audio into text for Talk (Admin → AI → Voice) and the developer API, priced per minute.',
    'live':
        'Optional realtime speech-to-speech model for Talk. Prefer separate Speech + Transcription for the local sidecar.',
    'rerank':
        'Reranks search results for the developer API, priced per search.',
  };

  Widget _priceField(TextEditingController c, String label, String hint) =>
      TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      );

  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 650, maxHeight: 760),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    editing ? 'Edit model' : 'Add model',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            if ('${previous['source'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                previous['markup'] is num
                    ? 'Imported from ${previous['source']} at its price +${compactDecimal(_number(previous['markup']))}%. Typing a price here sets it by hand.'
                    : 'Imported from ${previous['source']}.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
              initialValue: providerId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Provider',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in widget.providers)
                  DropdownMenuItem(
                    value: '${p['id']}',
                    child: Text(
                      '${p['name']} · ${p['kind']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: editing
                  ? null
                  : (value) => setState(() => providerId = value!),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: id,
              decoration: const InputDecoration(
                labelText: 'Model id',
                hintText: 'gpt-4.1',
                helperText: 'Exactly as the provider names it.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: name,
              decoration: const InputDecoration(
                labelText: 'Display name (optional)',
                hintText: 'GPT-4.1',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            AppChoiceField<String>(
              label: 'What this model is for',
              value: purpose,
              onChanged: (value) => setState(() => purpose = value),
              choices: [
                for (final (value, label) in _modelKinds)
                  AppChoice(
                    value,
                    value == 'chat' ? 'Agent model' : label,
                    hint: _purposeHints[value],
                  ),
              ],
            ),
            const SizedBox(height: 18),
            if (_tokenPriced.contains(purpose))
              Row(
                children: [
                  Expanded(
                    child: _priceField(input, 'Input \$/1M tokens', '2.50'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _priceField(output, 'Output \$/1M tokens', '10.00'),
                  ),
                ],
              ),
            for (final (_, quoted, _)
                in _unitFields[purpose] ??
                    const <(String, String, double)>[]) ...[
              const SizedBox(height: 12),
              _priceField(units[quoted]!, quoted, '0.04'),
            ],
            const SizedBox(height: 14),
            AppSwitchCard(
              icon: Icons.visibility_off_outlined,
              title: disabled ? 'Disabled' : 'Offered',
              subtitle: disabled
                  ? 'Hidden from new agents, the pickers and the developer API. Agents already on it keep running.'
                  : 'Offered for new agents, the pickers and the developer API.',
              value: disabled,
              onChanged: (v) => setState(() => disabled = v),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: saving ? null : save,
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(saving ? 'Saving…' : 'Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// Picks the Vercel provider and the markup for an import.
class _ImportVercelDialog extends StatefulWidget {
  const _ImportVercelDialog({required this.providers, this.markup});
  final List<Map<String, dynamic>> providers;

  /// The markup of the last import, offered again.
  final double? markup;

  @override
  State<_ImportVercelDialog> createState() => _ImportVercelDialogState();
}

class _ImportVercelDialogState extends State<_ImportVercelDialog> {
  late String providerId = '${widget.providers.first['id']}';
  late final markup = TextEditingController(
    text: widget.markup == null ? '' : compactDecimal(widget.markup!),
  );
  String? error;

  @override
  void dispose() {
    markup.dispose();
    super.dispose();
  }

  void submit() {
    final v = double.tryParse(markup.text.trim().replaceFirst('%', ''));
    if (v == null || v < 0 || v > 1000) {
      setState(
        () => error = 'Enter a markup between 0 and 1000 percent, e.g. 20.',
      );
      return;
    }
    Navigator.pop(context, (providerId, v));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.download_rounded),
    title: const Text('Import from Vercel'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Brings Vercel AI Gateway\'s models in at Vercel\'s price plus your markup. Importing again updates them in place; prices you typed by hand stay.',
          ),
          const SizedBox(height: 16),
          if (widget.providers.length > 1) ...[
            AppChoiceField<String>(
              label: 'Into',
              value: providerId,
              onChanged: (v) => setState(() => providerId = v),
              choices: [
                for (final p in widget.providers)
                  AppChoice(
                    '${p['id']}',
                    '${p['name']}',
                    icon: Icons.hub_outlined,
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: markup,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
              labelText: 'Markup',
              suffixText: '%',
              hintText: '20',
              errorText: error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: submit, child: const Text('Import')),
    ],
  );
}

/// A Save bar that appears once something changed.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.dirty,
    required this.busy,
    required this.onSave,
    required this.onReset,
    this.message = 'You have unsaved changes',
  });
  final bool dirty;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onReset;
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: !dirty
          ? const SizedBox(width: double.infinity, key: ValueKey('clean'))
          : Container(
              key: const ValueKey('dirty'),
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
              decoration: BoxDecoration(
                color: scheme.inverseSurface,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                children: [
                  Icon(Icons.edit_note_rounded, color: scheme.onInverseSurface),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      message,
                      style: TextStyle(
                        color: scheme.onInverseSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: busy ? null : onReset,
                    style: TextButton.styleFrom(
                      foregroundColor: scheme.inversePrimary,
                    ),
                    child: const Text('Reset'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: busy ? null : onSave,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(busy ? 'Saving…' : 'Save'),
                  ),
                ],
              ),
            ),
    );
  }
}

class _PricingEditor extends StatefulWidget {
  const _PricingEditor({
    super.key,
    required this.settings,
    required this.onSave,
    required this.onModels,
  });
  final Map<String, dynamic> settings;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;
  final VoidCallback onModels;

  @override
  State<_PricingEditor> createState() => _PricingEditorState();
}

class _PricingEditorState extends State<_PricingEditor> {
  /// Base rates in dollars per minute, resource rates in credits per minute.
  late Map<String, double> values = _initial();
  bool advanced = false;
  bool busy = false;

  Map<String, double> _initial() {
    final p = _map(widget.settings['pricing']);
    final sandbox = _map(p['sandbox']);
    final tool = _map(p['tool']);
    double usd(dynamic v) => ledgerToUsd(_number(v)).toDouble();
    double credits(dynamic v) => ledgerToCredits(_number(v)).toDouble();
    return {
      'agent_per_minute': usd(p['agent_per_minute']),
      'sandbox.per_minute': usd(sandbox['per_minute']),
      'tool.per_minute': usd(tool['per_minute']),
      'sandbox.cpu_per_min': credits(sandbox['cpu_per_min']),
      'sandbox.memory_per_gb_min': credits(sandbox['memory_per_gb_min']),
      'sandbox.disk_per_gb_min': credits(sandbox['disk_per_gb_min']),
      'tool.cpu_per_min': credits(tool['cpu_per_min']),
      'tool.memory_per_gb_min': credits(tool['memory_per_gb_min']),
      'tool.disk_per_gb_min': credits(tool['disk_per_gb_min']),
      // Dollars per GB-month; a node that never set it charges the default.
      'storage_gb_month': p.containsKey('storage_gb_month')
          ? usd(p['storage_gb_month'])
          : .05,
    };
  }

  @override
  void initState() {
    super.initState();
    advanced = values.entries
        .where((e) => e.key.contains('.') && !e.key.endsWith('per_minute'))
        .any((e) => e.value > 0);
  }

  bool get dirty {
    final initial = _initial();
    return values.entries.any((e) => (initial[e.key]! - e.value).abs() > 1e-9);
  }

  Future<void> save() async {
    int usd(String key) => usdToLedger(values[key]!);
    int credits(String key) => creditsToLedger(values[key]!);
    setState(() => busy = true);
    try {
      await widget.onSave({
        'agent_per_minute': usd('agent_per_minute'),
        'sandbox': {
          'per_minute': usd('sandbox.per_minute'),
          'cpu_per_min': credits('sandbox.cpu_per_min'),
          'memory_per_gb_min': credits('sandbox.memory_per_gb_min'),
          'disk_per_gb_min': credits('sandbox.disk_per_gb_min'),
        },
        'tool': {
          'per_minute': usd('tool.per_minute'),
          'cpu_per_min': credits('tool.cpu_per_min'),
          'memory_per_gb_min': credits('tool.memory_per_gb_min'),
          'disk_per_gb_min': credits('tool.disk_per_gb_min'),
        },
        'storage_gb_month': usd('storage_gb_month'),
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget rate(String key, String label, String hint, IconData icon) =>
      AppAmountField(
        label: label,
        hint: '$hint · \$${(values[key]! * 60).toStringAsFixed(2)} an hour',
        value: values[key]!,
        max: 1,
        step: .01,
        decimals: 4,
        unit: '\$ / min',
        presets: const [.01, .02, .05, .1, .25],
        presetLabel: _usd,
        format: (v) => '${_usd(v)} / min',
        onChanged: (v) => setState(() => values[key] = v),
      );

  Widget resource(String key, String label, String unit) => AppAmountField(
    label: label,
    value: values[key]!,
    max: 5,
    step: .1,
    decimals: 2,
    unit: 'credits',
    presets: const [0, .5, 1, 2],
    presetLabel: (v) => v == 0 ? 'None' : compactDecimal(v),
    format: (v) => v == 0 ? 'None' : '${compactDecimal(v)} cr / $unit / min',
    onChanged: (v) => setState(() => values[key] = v),
  );

  @override
  Widget build(BuildContext context) {
    final palette = adminPalette(context);
    final hourly = [
      AdminChartSlice(
        'Agent time',
        values['agent_per_minute']! * 60,
        palette[0],
        display: '\$${(values['agent_per_minute']! * 60).toStringAsFixed(2)}',
      ),
      AdminChartSlice(
        'Project computer',
        values['sandbox.per_minute']! * 60,
        palette[1],
        display: '\$${(values['sandbox.per_minute']! * 60).toStringAsFixed(2)}',
      ),
      AdminChartSlice(
        'Apps',
        values['tool.per_minute']! * 60,
        palette[3],
        display: '\$${(values['tool.per_minute']! * 60).toStringAsFixed(2)}',
      ),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SaveBar(
            dirty: dirty,
            busy: busy,
            onSave: save,
            onReset: () => setState(() => values = _initial()),
          ),
          AdminSectionCard(
            title: 'An hour of busy work costs a user',
            icon: Icons.schedule_rounded,
            subtitle:
                'Agent time, its project computer and apps, before model tokens. Credits are shown at 100 per \$1.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '\$${hourly.fold<double>(0, (sum, s) => sum + s.value).toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 34,
                    letterSpacing: -.8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                AdminStackedBar(slices: hourly, height: 18),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Base rates',
            icon: Icons.sell_rounded,
            subtitle: 'What users pay per minute.',
            child: Column(
              children: [
                rate(
                  'agent_per_minute',
                  'Agent time',
                  'While an agent works',
                  Icons.smart_toy_outlined,
                ),
                const SizedBox(height: 22),
                rate(
                  'sandbox.per_minute',
                  'Project computer',
                  'While the computer is awake',
                  Icons.computer_outlined,
                ),
                const SizedBox(height: 22),
                rate(
                  'tool.per_minute',
                  'Apps',
                  'While one runs',
                  Icons.build_outlined,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Developer storage',
            icon: Icons.cloud_outlined,
            subtitle:
                'What a developer API organization pays for each GB it keeps in Storage, per month.',
            child: AppAmountField(
              label: 'Storage',
              value: values['storage_gb_month']!,
              max: 1,
              step: .01,
              decimals: 3,
              unit: '\$ / GB-month',
              presets: const [0, .02, .05, .1],
              presetLabel: (v) => v == 0 ? 'Free' : _usd(v),
              format: (v) => v == 0 ? 'Free' : '${_usd(v)} / GB-month',
              onChanged: (v) => setState(() => values['storage_gb_month'] = v),
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Model tokens',
            icon: Icons.memory_rounded,
            subtitle: 'Input and output prices are set per model.',
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: widget.onModels,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Edit model prices'),
              ),
            ),
          ),
          const SizedBox(height: 16),
          AppSwitchCard(
            icon: Icons.tune_rounded,
            title: 'Per-resource rates',
            subtitle:
                'Charge extra for each vCPU, GB of RAM and GB of disk. Off means flat pricing.',
            value: advanced,
            onChanged: (v) => setState(() => advanced = v),
          ),
          if (advanced) ...[
            const SizedBox(height: 16),
            AdminSectionCard(
              title: 'Project computer',
              icon: Icons.computer_rounded,
              subtitle: 'Extra credits per minute, per unit.',
              child: Column(
                children: [
                  resource('sandbox.cpu_per_min', 'vCPU', 'vCPU'),
                  const SizedBox(height: 20),
                  resource('sandbox.memory_per_gb_min', 'RAM', 'GB'),
                  const SizedBox(height: 20),
                  resource('sandbox.disk_per_gb_min', 'Disk', 'GB'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            AdminSectionCard(
              title: 'Apps',
              icon: Icons.build_rounded,
              subtitle: 'Extra credits per minute, per unit.',
              child: Column(
                children: [
                  resource('tool.cpu_per_min', 'vCPU', 'vCPU'),
                  const SizedBox(height: 20),
                  resource('tool.memory_per_gb_min', 'RAM', 'GB'),
                  const SizedBox(height: 20),
                  resource('tool.disk_per_gb_min', 'Disk', 'GB'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MachineEditor extends StatefulWidget {
  const _MachineEditor({
    super.key,
    required this.settings,
    required this.onSave,
  });
  final Map<String, dynamic> settings;
  final Future<dynamic> Function(Map<String, dynamic>) onSave;
  @override
  State<_MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<_MachineEditor> {
  /// CPU in vCPUs, memory and disk in GB; null means automatic.
  late Map<String, double?> values = _initial();
  bool busy = false;

  Map<String, double?> _initial() {
    final m = _map(widget.settings['machine']);
    double? gb(dynamic v) => v == null ? null : _number(v) / 1024;
    double? n(dynamic v) => v == null || '$v'.isEmpty ? null : _number(v);
    return {
      'cpu': n(m['cpu']) ?? 2,
      'memory': gb(m['memory_mb']) ?? 2,
      'disk': gb(m['disk_mb']) ?? 4,
      'reserve_cpu': n(m['reserve_cpu']),
      'reserve_memory': gb(m['reserve_memory_mb']),
      'max_cpu': n(m['max_cpu']),
      'max_memory': gb(m['max_memory_mb']),
      'provider_idle_min': n(m['provider_idle_min']) ?? 30,
      'max_lifetime_min': n(m['max_lifetime_min']) ?? 480,
      'command_timeout_sec': n(m['command_timeout_sec']) ?? 300,
    };
  }

  bool get dirty {
    final initial = _initial();
    return values.entries.any((e) => initial[e.key] != e.value);
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      int? mb(double? gb) => gb == null ? null : (gb * 1024).round();
      await widget.onSave({
        'cpu': values['cpu'],
        'memory_mb': mb(values['memory']),
        'disk_mb': mb(values['disk']),
        'reserve_cpu': values['reserve_cpu'],
        'reserve_memory_mb': mb(values['reserve_memory']),
        'max_cpu': values['max_cpu'],
        'max_memory_mb': mb(values['max_memory']),
        'provider_idle_min': values['provider_idle_min']?.round(),
        'max_lifetime_min': values['max_lifetime_min']?.round(),
        'command_timeout_sec': values['command_timeout_sec']?.round(),
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _size(double v, String unit) => '${compactDecimal(v)} $unit';

  Widget sizeChips(
    String key,
    String label,
    List<double> options,
    String unit, {
    bool auto = false,
    String? hint,
  }) {
    final value = values[key];
    final all = <double>{...options, if (value != null) value}.toList()..sort();
    return AppChoiceField<double?>(
      label: label,
      hint: hint,
      value: value,
      onChanged: (v) => setState(() => values[key] = v),
      choices: [
        if (auto)
          const AppChoice<double?>(
            null,
            'Automatic',
            icon: Icons.auto_mode_rounded,
          ),
        for (final o in all) AppChoice<double?>(o, _size(o, unit)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cpu = values['cpu'] ?? 2;
    final memory = values['memory'] ?? 2;
    Widget range(
      String label,
      double? reserve,
      double billed,
      double? max,
      String unit,
    ) {
      final top = [
        billed,
        reserve ?? 0,
        max ?? billed * 2,
      ].reduce((a, b) => a > b ? a : b);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(
            'reserve ${reserve == null ? 'auto' : _size(reserve, unit)} · billed ${_size(billed, unit)} · ceiling ${max == null ? 'auto' : _size(max, unit)}',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          AdminStackedBar(
            legend: false,
            height: 14,
            slices: [
              AdminChartSlice(
                'Reserve',
                reserve ?? billed * .25,
                AppColors.successOf(context),
              ),
              AdminChartSlice(
                'Billed',
                billed - (reserve ?? billed * .25),
                scheme.primary,
              ),
              AdminChartSlice(
                'Burst',
                (max ?? billed * 2) - billed,
                AppColors.cyanOf(context),
              ),
              AdminChartSlice(
                '',
                top - (max ?? billed * 2) + .0001,
                scheme.surfaceContainerHighest,
              ),
            ],
          ),
        ],
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SaveBar(
            dirty: dirty,
            busy: busy,
            onSave: save,
            onReset: () => setState(() => values = _initial()),
          ),
          AdminSectionCard(
            title: 'At a glance',
            icon: Icons.insights_rounded,
            subtitle:
                'From the idle reserve, through the billed size, up to the burst ceiling.',
            child: Column(
              children: [
                range(
                  'CPU',
                  values['reserve_cpu'],
                  cpu,
                  values['max_cpu'],
                  'vCPU',
                ),
                const SizedBox(height: 16),
                range(
                  'RAM',
                  values['reserve_memory'],
                  memory,
                  values['max_memory'],
                  'GB',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    for (final (label, color) in [
                      ('Idle reserve', AppColors.successOf(context)),
                      ('Billed size', scheme.primary),
                      ('Burst', AppColors.cyanOf(context)),
                    ])
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: color,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(label, style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Billed size',
            icon: Icons.developer_board_rounded,
            subtitle: "What a project's computer is sold at and created with.",
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sizeChips('cpu', 'vCPU', const [.5, 1, 2, 4, 8, 16], 'vCPU'),
                const SizedBox(height: 20),
                sizeChips('memory', 'RAM', const [
                  .5,
                  1,
                  2,
                  4,
                  8,
                  16,
                  32,
                ], 'GB'),
                const SizedBox(height: 20),
                AppAmountField(
                  label: 'Disk',
                  value: values['disk'] ?? 4,
                  min: 1,
                  max: 200,
                  step: 1,
                  decimals: 0,
                  unit: 'GB',
                  presets: const [4, 10, 20, 50, 100],
                  presetLabel: (v) => '${compactDecimal(v)} GB',
                  format: (v) => '${compactDecimal(v)} GB',
                  onChanged: (v) => setState(() => values['disk'] = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Idle reserve',
            icon: Icons.bedtime_rounded,
            subtitle:
                'The share guaranteed and billed while a computer is awake and quiet.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sizeChips(
                  'reserve_cpu',
                  'vCPU',
                  const [.25, .5, 1, 2],
                  'vCPU',
                  auto: true,
                ),
                const SizedBox(height: 20),
                sizeChips(
                  'reserve_memory',
                  'RAM',
                  const [.25, .5, 1, 2],
                  'GB',
                  auto: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Ceiling',
            icon: Icons.vertical_align_top_rounded,
            subtitle: 'The most a busy computer can use.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                sizeChips(
                  'max_cpu',
                  'vCPU',
                  const [2, 4, 8, 16],
                  'vCPU',
                  auto: true,
                ),
                const SizedBox(height: 20),
                sizeChips(
                  'max_memory',
                  'RAM',
                  const [4, 8, 16, 32],
                  'GB',
                  auto: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Time limits',
            icon: Icons.timer_outlined,
            subtitle:
                'When an idle computer is stopped at the provider, the longest any computer may run, and how long one command may take.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppAmountField(
                  label: 'Stop when idle for',
                  value: values['provider_idle_min'] ?? 30,
                  min: 5,
                  max: 1440,
                  step: 5,
                  decimals: 0,
                  unit: 'min',
                  presets: const [10, 30, 60, 120],
                  presetLabel: _minutes,
                  format: _minutes,
                  onChanged: (v) => setState(() {
                    values['provider_idle_min'] = v;
                    final life = values['max_lifetime_min'] ?? 480;
                    if (life < v) values['max_lifetime_min'] = v;
                  }),
                ),
                const SizedBox(height: 20),
                AppAmountField(
                  label: 'Longest run',
                  value: values['max_lifetime_min'] ?? 480,
                  min: 30,
                  max: 1440,
                  step: 30,
                  decimals: 0,
                  unit: 'min',
                  presets: const [120, 480, 720, 1440],
                  presetLabel: _minutes,
                  format: _minutes,
                  onChanged: (v) => setState(() {
                    values['max_lifetime_min'] = v;
                    final idle = values['provider_idle_min'] ?? 30;
                    if (idle > v) values['provider_idle_min'] = v;
                  }),
                ),
                const SizedBox(height: 20),
                AppAmountField(
                  label: 'One command may take',
                  value: values['command_timeout_sec'] ?? 300,
                  min: 10,
                  max: 3600,
                  step: 10,
                  decimals: 0,
                  unit: 's',
                  presets: const [60, 300, 900, 3600],
                  presetLabel: _seconds,
                  format: _seconds,
                  onChanged: (v) =>
                      setState(() => values['command_timeout_sec'] = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _minutes(double v) => v >= 60 && v % 60 == 0
      ? '${(v / 60).round()} h'
      : v >= 60
      ? '${(v / 60).floor()} h ${(v % 60).round()} min'
      : '${v.round()} min';

  static String _seconds(double v) =>
      v >= 60 && v % 60 == 0 ? '${(v / 60).round()} min' : '${v.round()} s';
}

class _PromptEditor extends StatefulWidget {
  const _PromptEditor({super.key, required this.value, required this.onSave});
  final String value;
  final Future<dynamic> Function(String) onSave;
  @override
  State<_PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<_PromptEditor> {
  late final TextEditingController controller;
  bool busy = false;
  static const limit = 20000;
  static const snippets = {
    'Reply in the user’s language': 'Always answer in the user’s language.',
    'No invented facts':
        'Never invent facts, figures or dates; say when you are not sure.',
    'Cite sources': 'Cite the source of every figure you use.',
    'Ask before spending':
        'Ask before any action that spends more than 100 credits.',
    'Be concise': 'Keep answers short and lead with the conclusion.',
  };

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
    controller.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  void _insert(String line) {
    final text = controller.text.trimRight();
    controller.text = text.isEmpty ? line : '$text\n$line';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final length = controller.text.trim().length;
    // Roughly four characters a token for English text.
    final tokens = (length / 4).ceil();
    final over = length > limit;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SaveBar(
            dirty: controller.text != widget.value,
            busy: busy || over,
            message: over
                ? 'Too long: shorten to $limit characters to save'
                : 'You have unsaved changes',
            onReset: () => controller.text = widget.value,
            onSave: () async {
              setState(() => busy = true);
              try {
                await widget.onSave(controller.text);
              } finally {
                if (mounted) setState(() => busy = false);
              }
            },
          ),
          AdminGrid(
            maxColumns: 3,
            minTileWidth: 200,
            children: [
              AdminStatCard(
                label: 'Length',
                value: '$length',
                hint: 'of $limit characters',
                icon: Icons.short_text_rounded,
                progress: length / limit,
                tone: over ? AppColors.dangerOf(context) : null,
              ),
              AdminStatCard(
                label: 'Tokens per turn',
                value: '≈$tokens',
                hint: 'Paid on every agent turn',
                icon: Icons.token_outlined,
                tone: tokens > 1500 ? AppColors.warningOf(context) : AppColors.successOf(context),
              ),
              AdminStatCard(
                label: 'Rules',
                value:
                    '${controller.text.split('\n').where((l) => l.trim().isNotEmpty).length}',
                hint: 'Non-empty lines',
                icon: Icons.rule_rounded,
                tone: AppColors.cyanOf(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminSectionCard(
            title: 'Platform rules',
            icon: Icons.description_rounded,
            subtitle:
                'Added to every agent’s instructions. Keep it short — every turn pays for these tokens. Blank means none.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Quick add', style: _labelStyle(scheme)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in snippets.entries)
                      ActionChip(
                        avatar: Icon(
                          controller.text.contains(e.value)
                              ? Icons.check_rounded
                              : Icons.add_rounded,
                          size: 18,
                        ),
                        label: Text(e.key),
                        onPressed: controller.text.contains(e.value)
                            ? null
                            : () => _insert(e.value),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  minLines: 10,
                  maxLines: 24,
                  style: const TextStyle(height: 1.5),
                  decoration: InputDecoration(
                    hintText:
                        "Always answer in the user's language. Never invent delivery dates.",
                    errorText: over ? 'Over the $limit character limit' : null,
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle _labelStyle(ColorScheme scheme) => TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w700,
  color: scheme.onSurfaceVariant,
);

/// The full-screen frame of a detail view: an avatar header, tabs, and
/// the selected tab's content.
class _DetailFrame extends StatelessWidget {
  const _DetailFrame({
    required this.title,
    required this.subtitle,
    required this.avatar,
    required this.tabs,
    required this.tab,
    required this.onTab,
    required this.onRefresh,
    required this.menu,
    required this.loading,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget avatar;
  final List<(String, IconData)> tabs;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onRefresh;
  final Widget menu;
  final bool loading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < Breakpoints.compact;
    return Builder(
      builder: (context) => Dialog.fullscreen(
        backgroundColor: scheme.surface,
        child: DefaultTabController(
          length: tabs.length,
          initialIndex: tab,
          child: Scaffold(
            backgroundColor: scheme.surface,
            appBar: AppBar(
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              toolbarHeight: 72,
              leading: IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
              titleSpacing: 0,
              title: Row(
                children: [
                  avatar,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                menu,
              ],
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(64),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: SegmentedTabBar(
                    width: 600,
                    compact: narrow,
                    onTap: onTab,
                    labels: [for (final (label, _) in tabs) label],
                    icons: [for (final (_, icon) in tabs) icon],
                  ),
                ),
              ),
            ),
            body: loading
                ? const SkeletonPage()
                : AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: ListView(
                      key: ValueKey(tab),
                      padding: EdgeInsets.symmetric(
                        horizontal: narrow ? 16 : 28,
                        vertical: 20,
                      ),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1100),
                            child: child,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _UserDialog extends StatefulWidget {
  const _UserDialog({
    required this.account,
    required this.onAction,
    required this.onEdit,
    required this.loadFinance,
    this.initialTab = 0,
  });
  final Map<String, dynamic> account;
  final AdminAction onAction;
  final VoidCallback onEdit;
  final Future<dynamic> Function() loadFinance;
  final int initialTab;
  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late int tab = widget.initialTab;
  bool loading = true;
  Map<String, dynamic> finance = const {};
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    // Refreshing keeps the current figures visible until new ones arrive.
    try {
      final value = _map(await widget.loadFinance());
      if (mounted) setState(() => finance = value);
    } catch (_) {
      // The caller already reported the failure.
    } finally {
      if (mounted && loading) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.account;
    final name = _displayName(a);
    return _DetailFrame(
      title: name,
      subtitle: '@${a['handle']} · ${a['email'] ?? ''}',
      avatar: AdminAvatar(name, size: 44, avatar: _avatarOf(a)),
      tabs: const [
        ('Summary', Icons.space_dashboard_rounded),
        ('Purchases', Icons.shopping_bag_rounded),
        ('Wallet', Icons.account_balance_wallet_rounded),
        ('Profile & access', Icons.manage_accounts_rounded),
      ],
      tab: tab,
      onTab: (value) => setState(() => tab = value),
      onRefresh: load,
      loading: loading,
      menu: AppPopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'delete') {
            widget.onAction('users', 'account_delete', {
              'account': a['id'],
              '_name': name,
            });
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline_rounded),
              title: Text('Delete user'),
            ),
          ),
        ],
      ),
      child: switch (tab) {
        0 => _summary(),
        1 => _purchases(),
        2 => _wallet(),
        _ => _profile(),
      },
    );
  }

  Widget _summary() {
    final m = _map(finance['summary']).isNotEmpty
        ? _map(finance['summary'])
        : finance;
    final palette = adminPalette(context);
    final kinds = _listOfMaps(m['by_kind'] ?? finance['by_kind']);
    final projects = _listOfMaps(m['projects'] ?? finance['projects']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Balance',
              value: _money(m['balance']),
              icon: Icons.account_balance_wallet_rounded,
              hint:
                  '${_credits(m['balance'])}${_number(m['locked']) > 0 ? ' · ${_credits(m['locked'])} locked' : ''}',
            ),
            AdminStatCard(
              label: 'Bought',
              value: _money(m['bought']),
              icon: Icons.shopping_bag_rounded,
              tone: AppColors.successOf(context),
              hint:
                  '${m['bought_count'] ?? 0} packs · ${_credits(m['bought'])}',
            ),
            AdminStatCard(
              label: 'Added by admin',
              value: _money(m['granted']),
              icon: Icons.card_giftcard_rounded,
              tone: AppColors.cyanOf(context),
              hint: _credits(m['granted']),
            ),
            AdminStatCard(
              label: 'Spent',
              value: _money(m['spent']),
              icon: Icons.trending_down_rounded,
              tone: AppColors.warningOf(context),
              hint: _credits(m['spent']),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminGrid(
          maxColumns: 2,
          minTileWidth: 340,
          children: [
            AdminSectionCard(
              title: 'What was spent on',
              icon: Icons.donut_large_rounded,
              child: AdminDonutPanel(
                size: 132,
                center: _money(m['spent']),
                caption: 'spent',
                emptyLabel: 'Nothing spent',
                slices: [
                  for (final (i, row) in kinds.indexed)
                    AdminChartSlice(
                      '${row['kind'] ?? row['label']}',
                      _number(row['amount'] ?? row['spent']),
                      palette[i % palette.length],
                      display: _money(row['amount'] ?? row['spent']),
                    ),
                ],
              ),
            ),
            AdminSectionCard(
              title: 'Spent per project',
              icon: Icons.folder_rounded,
              child: AdminBarList(
                maxItems: 5,
                empty: 'No project spending yet.',
                items: [
                  for (final row in projects)
                    AdminChartSlice(
                      '${row['name'] ?? row['space_name'] ?? row['space_id']}',
                      _number(row['spent']),
                      palette[1],
                      display: _money(row['spent']),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _purchases() {
    final rows = _listOfMaps(finance['purchases']);
    return AdminDataTable(
      empty: 'No purchases for this user.',
      columns: const [
        AdminTableColumn('Purchased', width: 160),
        AdminTableColumn('Product', width: 220),
        AdminTableColumn('Amount', width: 120, align: TextAlign.right),
        AdminTableColumn('Status', width: 130),
        AdminTableColumn('Transaction', width: 240),
      ],
      rows: [
        for (final p in rows)
          [
            Text(_date(p['created_at'])),
            Text('${p['product_id'] ?? 'Credit pack'}'),
            Text(
              _money(p['amount'] ?? p['listed_amount']),
              textAlign: TextAlign.right,
            ),
            AdminStatusPill('${p['status'] ?? 'credited'}'),
            SelectableText('${p['transaction_id'] ?? p['id']}'),
          ],
      ],
    );
  }

  Widget _wallet() {
    final rows = _listOfMaps(finance['ledger'] ?? finance['entries']);
    return AdminDataTable(
      empty: 'No wallet activity.',
      columns: const [
        AdminTableColumn('When', width: 160),
        AdminTableColumn('Description', width: 320),
        AdminTableColumn('Kind', width: 130),
        AdminTableColumn('Amount', width: 130, align: TextAlign.right),
        AdminTableColumn('Balance', width: 130, align: TextAlign.right),
      ],
      rows: [
        for (final e in rows)
          [
            Text(_date(e['created_at'])),
            Text('${e['description'] ?? e['reason'] ?? e['kind']}'),
            _Tag('${e['kind'] ?? e['type']}'),
            Text(
              _credits(e['amount']),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: _number(e['amount']) < 0
                    ? AppColors.dangerOf(context)
                    : AppColors.successOf(context),
              ),
            ),
            Text(_credits(e['balance']), textAlign: TextAlign.right),
          ],
      ],
    );
  }

  Widget _profile() {
    final a = widget.account;
    final name = _displayName(a);
    final disabled = '${a['status']}' == 'disabled';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionCard(
          title: 'Profile',
          icon: Icons.badge_rounded,
          trailing: FilledButton.tonalIcon(
            onPressed: widget.onEdit,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Edit'),
          ),
          child: Column(
            children: [
              AdminKeyValue('Name', name),
              AdminKeyValue('Username', '@${a['handle']}'),
              AdminKeyValue('Email', '${a['email'] ?? '—'}'),
              AdminKeyValue(
                'Role',
                a['is_admin'] == true || '${a['role']}' == 'admin'
                    ? 'Administrator'
                    : 'Member',
              ),
              AdminKeyValue('Joined', _date(a['created_at'])),
              AdminKeyValue('User id', '${a['id']}', mono: true),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminGrid(
          maxColumns: 3,
          minTileWidth: 220,
          children: [
            _ActionTile(
              icon: disabled ? Icons.lock_open_rounded : Icons.block_rounded,
              title: disabled ? 'Allow sign-in' : 'Block sign-in',
              subtitle: disabled
                  ? 'Currently blocked'
                  : 'Data and wallet are kept',
              tone: disabled ? AppColors.successOf(context) : AppColors.dangerOf(context),
              onTap: widget.onEdit,
            ),
            _ActionTile(
              icon: Icons.password_rounded,
              title: 'Set new password',
              subtitle: 'Replace their sign-in password',
              onTap: () => widget.onAction('users', 'account_password', {
                'account': a['id'],
                '_name': name,
              }),
            ),
            _ActionTile(
              icon: Icons.add_card_rounded,
              title: 'Grant credits',
              subtitle: 'Add credits to their wallet',
              tone: AppColors.successOf(context),
              onTap: () => widget.onAction('finance', 'wallet_mint', {
                'target': a['id'],
                '_name': name,
              }),
            ),
          ],
        ),
      ],
    );
  }
}

/// A large tappable action with an icon badge.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = tone ?? scheme.primary;
    return Material(
      color: scheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.innerOf(context)+ 4),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: ShapeDecoration(
                  color: color.withValues(alpha: .16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({
    required this.project,
    required this.onAction,
    required this.loadDetail,
    required this.loadWork,
    required this.loadFiles,
  });
  final Map<String, dynamic> project;
  final AdminAction onAction;
  final Future<dynamic> Function() loadDetail;
  final Future<dynamic> Function() loadWork;
  final Future<dynamic> Function() loadFiles;
  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  int tab = 0;
  bool loading = true;
  Map<String, dynamic> detail = const {};

  /// spaces.admin_work_log: the project's runs (with their events and where
  /// their time went), metered usage and memory charges. Null until loaded.
  Map<String, dynamic>? workLog;
  List<Map<String, dynamic>> files = const [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    // Refreshing keeps the current detail visible until new data arrives.
    try {
      final value = await widget.loadDetail();
      if (mounted) setState(() => detail = {...widget.project, ..._map(value)});
    } catch (_) {
      if (mounted) setState(() => detail = {...widget.project, ...detail});
    } finally {
      if (mounted && loading) setState(() => loading = false);
    }
  }

  Future<void> loadTab(int value) async {
    setState(() => tab = value);
    try {
      if (value == 4 && workLog == null) {
        final value = await widget.loadWork();
        if (mounted) setState(() => workLog = _map(value));
      }
      if (value == 3 && files.isEmpty) {
        final value = await widget.loadFiles();
        if (mounted) setState(() => files = _listOfMaps(_map(value)['files']));
      }
    } catch (_) {
      // The caller already reported the failure.
    }
  }

  Map<String, dynamic> get budget => _map(detail['budget']);
  dynamic get cap =>
      budget['cap'] ?? (detail['budget'] is num ? detail['budget'] : null);
  dynamic get spent =>
      detail['spent'] ?? _map(detail['usage'])['spent'] ?? budget['spent'];

  void _setBudget(String id) => widget.onAction('finance', 'budget_set', {
    'space': id,
    '_cap': cap,
    '_spent': spent,
  });

  @override
  Widget build(BuildContext context) {
    final id = '${detail['id'] ?? widget.project['id']}';
    final name = '${detail['name'] ?? widget.project['name'] ?? 'Project'}';
    return _DetailFrame(
      title: name,
      subtitle: id,
      avatar: AdminAvatar(
        name,
        size: 44,
        icon: Icons.folder_rounded,
        avatar: _avatarOf(detail).isNotEmpty
            ? _avatarOf(detail)
            : _avatarOf(widget.project),
      ),
      tabs: const [
        ('Overview', Icons.space_dashboard_rounded),
        ('Machine', Icons.computer_rounded),
        ('Cost', Icons.savings_rounded),
        ('Storage', Icons.folder_open_rounded),
        ('Logs', Icons.receipt_long_rounded),
        ('People', Icons.group_rounded),
      ],
      tab: tab,
      onTab: loadTab,
      onRefresh: load,
      loading: loading,
      menu: AppPopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'budget') _setBudget(id);
          if (value == 'delete') {
            widget.onAction('spaces', 'space_delete', {
              'space': id,
              '_name': name,
            });
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'budget',
            child: ListTile(
              leading: Icon(Icons.savings_outlined),
              title: Text('Set budget'),
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
            value: 'delete',
            child: ListTile(
              leading: Icon(Icons.delete_outline_rounded),
              title: Text('Delete project'),
            ),
          ),
        ],
      ),
      child: switch (tab) {
        0 => _overview(),
        1 => _machine(id),
        2 => _cost(id),
        3 => _files(),
        4 => _work(),
        _ => _people(),
      },
    );
  }

  Widget _overview() {
    final machine = _map(detail['machine']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminGrid(
          children: [
            AdminStatCard(
              label: 'Machine',
              value: '${machine['state'] ?? 'none'}',
              hint: '${machine['provider'] ?? ''}',
              icon: Icons.computer_rounded,
              tone: adminToneColor(
                context,
                adminTone('${machine['state'] ?? 'none'}'),
              ),
            ),
            AdminStatCard(
              label: 'Agents',
              value: '${detail['agents'] ?? _list(detail['workers']).length}',
              icon: Icons.smart_toy_rounded,
              tone: AppColors.cyanOf(context),
            ),
            AdminStatCard(
              label: 'Rooms',
              value: '${_list(detail['rooms']).length}',
              icon: Icons.forum_rounded,
              tone: AppColors.successOf(context),
            ),
            AdminStatCard(
              label: 'Budget',
              value: _number(cap) == 0 ? 'No limit' : _credits(cap),
              hint: 'Spent ${_credits(spent)}',
              progress: _number(cap) == 0
                  ? null
                  : _number(spent) / _number(cap),
              icon: Icons.savings_rounded,
              tone: AppColors.warningOf(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        AdminSectionCard(
          title: 'Project',
          icon: Icons.info_outline_rounded,
          child: Column(
            children: [
              AdminKeyValue('Owner', _owner(detail)),
              AdminKeyValue('Created', _date(detail['created_at'])),
              AdminKeyValue('Updated', _date(detail['updated_at'])),
              AdminKeyValue('Project id', '${detail['id']}', mono: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _machine(String id) {
    final machine = _map(detail['machine']);
    const ops = [
      ('status', 'Check state', 'Ask the provider', Icons.info_outline_rounded),
      (
        'provision',
        'Start',
        'Create or wake it',
        Icons.power_settings_new_rounded,
      ),
      ('keepalive', 'Keep awake', 'Reset the idle timer', Icons.coffee_rounded),
      ('sleep', 'Sleep', 'Stop billing; keep files', Icons.bedtime_rounded),
      (
        'replace',
        'Replace',
        'Fresh machine from the image',
        Icons.autorenew_rounded,
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionCard(
          title: 'Computer',
          icon: Icons.computer_rounded,
          trailing: AdminStatusPill('${machine['state'] ?? 'none'}'),
          child: Column(
            children: [
              AdminKeyValue(
                'Provider id',
                '${machine['id'] ?? machine['sandbox_id'] ?? ''}',
                mono: true,
              ),
              AdminKeyValue('Started', _date(machine['started_at'])),
              AdminKeyValue('Last active', _date(machine['last_active_at'])),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdminGrid(
          minTileWidth: 200,
          maxColumns: 5,
          children: [
            for (final (op, label, hint, icon) in ops)
              _ActionTile(
                icon: icon,
                title: label,
                subtitle: hint,
                tone: op == 'replace' || op == 'sleep'
                    ? AppColors.warningOf(context)
                    : null,
                onTap: () => widget.onAction('spaces', 'computer', {
                  'space': id,
                  'operation': op,
                }),
              ),
          ],
        ),
      ],
    );
  }

  Widget _cost(String id) {
    final limit = _number(cap);
    final used = _number(spent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AdminSectionCard(
          title: 'Budget and spend',
          icon: Icons.savings_rounded,
          trailing: FilledButton.tonalIcon(
            onPressed: () => _setBudget(id),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: const Text('Set budget'),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gauge = AdminGauge(
                value: limit == 0 ? 0 : used / limit,
                label: limit == 0 ? 'no limit' : 'of budget',
                display: limit == 0 ? '∞' : null,
              );
              final facts = Column(
                children: [
                  AdminKeyValue(
                    'Budget cap',
                    limit == 0 ? 'No limit' : _credits(cap),
                  ),
                  AdminKeyValue('Spent', _credits(spent)),
                  AdminKeyValue(
                    'Remaining',
                    limit == 0
                        ? '—'
                        : _credits(budget['remaining'] ?? (limit - used)),
                  ),
                ],
              );
              if (constraints.maxWidth < 480) {
                return Column(
                  children: [gauge, const SizedBox(height: 12), facts],
                );
              }
              return Row(
                children: [
                  gauge,
                  const SizedBox(width: 24),
                  Expanded(child: facts),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _files() => AdminDataTable(
    empty: 'No project files.',
    columns: const [
      AdminTableColumn('Path', width: 420),
      AdminTableColumn('Size', width: 120, align: TextAlign.right),
      AdminTableColumn('Modified', width: 160),
    ],
    rows: [
      for (final f in files)
        [
          Row(
            children: [
              Icon(
                '${f['type'] ?? ''}' == 'dir' || f['is_dir'] == true
                    ? Icons.folder_rounded
                    : Icons.insert_drive_file_outlined,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(child: Text('${f['path'] ?? f['name']}')),
            ],
          ),
          Text(_bytes(f['size']), textAlign: TextAlign.right),
          Text(_date(f['modified_at'] ?? f['updated_at'])),
        ],
    ],
  );
  Widget _work() {
    final log = workLog;
    if (log == null) {
      return const SkeletonList(itemCount: 4);
    }
    final scheme = Theme.of(context).colorScheme;
    final runs = _listOfMaps(log['runs']);
    final usage = _listOfMaps(log['usage_events']);
    final memory = _listOfMaps(log['memory_events']);
    String ms(dynamic v) {
      final n = _number(v);
      return n >= 1000
          ? '${(n / 1000).toStringAsFixed(1)} s'
          : '${n.round()} ms';
    }

    String took(Map<String, dynamic> run) {
      final start = DateTime.tryParse('${run['started_at'] ?? ''}');
      final end = DateTime.tryParse('${run['ended_at'] ?? ''}');
      if (start == null ||
          end == null ||
          start.year < 2000 ||
          end.year < 2000) {
        return '';
      }
      return ' · took ${ms(end.difference(start).inMilliseconds)}';
    }

    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          letterSpacing: 1,
          fontWeight: FontWeight.w800,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('RUNS'),
        if (runs.isEmpty)
          const AdminEmptyState(
            'No runs',
            'Agent work in this project shows up here.',
            icon: Icons.receipt_long_outlined,
          )
        else
          for (final run in runs)
            ExpansionTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
              ),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
              ),
              title: Text(
                [
                  _stringList(run['agents']).isNotEmpty
                      ? _stringList(run['agents']).join(', ')
                      : 'Run',
                  if ('${run['actor'] ?? ''}'.isNotEmpty) 'by @${run['actor']}',
                ].join(' · '),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${_date(run['created_at'])}${took(run)} · ${'${run['prompt'] ?? ''}'.replaceAll('\n', ' ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: AdminStatusPill('${run['status'] ?? '—'}'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if ('${run['error'] ?? ''}'.isNotEmpty)
                  AdminKeyValue('Error', '${run['error']}'),
                if (_listOfMaps(run['spans']).isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Where the time went',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  for (final s in _listOfMaps(run['spans']))
                    AdminKeyValue(
                      '${s['name']}',
                      '${ms(s['ms'])}${'${s['detail'] ?? ''}'.isEmpty ? '' : ' · ${s['detail']}'}',
                    ),
                ],
                const SizedBox(height: 6),
                for (final e in _listOfMaps(run['events']))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${e['sender'] ?? '—'} · ${e['kind'] == '' || e['kind'] == null ? 'message' : e['kind']} · ${_date(e['created_at'])}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        KeyedSubtree(
                          key: PageStorageKey<String>('event:${e['id']}'),
                          child: SelectableText(
                            '${e['body'] ?? ''}',
                            maxLines: 8,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        heading('METERED USAGE'),
        AdminDataTable(
          empty: 'No metered usage.',
          columns: const [
            AdminTableColumn('Time', width: 150),
            AdminTableColumn('Agent', width: 150),
            AdminTableColumn('Model', width: 200),
            AdminTableColumn('Usage', width: 320),
            AdminTableColumn('Cost', width: 100, align: TextAlign.right),
          ],
          rows: [
            for (final u in usage)
              [
                Text(_date(u['created_at'])),
                Text('${u['bot_name'] ?? '—'}'),
                _primaryCell('${u['model'] ?? '—'}', '${u['provider'] ?? ''}'),
                Text(
                  [
                    if ('${u['summary'] ?? ''}'.isNotEmpty) '${u['summary']}',
                    if (_integer(u['decision_in']) +
                            _integer(u['decision_out']) >
                        0)
                      'decisions ${_compact(u['decision_in'])} in / ${_compact(u['decision_out'])} out',
                    if (_integer(u['image_count']) > 0)
                      '${_integer(u['image_count'])} image(s)${'${u['image_model'] ?? ''}'.isEmpty ? '' : ' with ${u['image_model']}'}',
                  ].join(' · '),
                ),
                Text(_money(u['cost']), textAlign: TextAlign.right),
              ],
          ],
        ),
        heading('MEMORY'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            'The agents\' memory is charged to the project in batches, apart from any one run.',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
        AdminDataTable(
          empty: 'No memory charges yet.',
          columns: const [
            AdminTableColumn('Time', width: 150),
            AdminTableColumn('Tokens', width: 140, align: TextAlign.right),
            AdminTableColumn(
              'Of which input',
              width: 140,
              align: TextAlign.right,
            ),
            AdminTableColumn('Cost', width: 100, align: TextAlign.right),
          ],
          rows: [
            for (final m in memory)
              [
                Text(_date(m['created_at'])),
                Text(_compact(m['tokens']), textAlign: TextAlign.right),
                Text(_compact(m['tokens_in']), textAlign: TextAlign.right),
                Text(_money(m['cost']), textAlign: TextAlign.right),
              ],
          ],
        ),
      ],
    );
  }

  Widget _people() {
    final people = [..._listOfMaps(detail['members'])];
    if (_map(detail['owner']).isNotEmpty) {
      people.insert(0, {..._map(detail['owner']), 'role': 'owner'});
    }
    return AdminDataTable(
      empty: 'No people attached to this project.',
      columns: const [
        AdminTableColumn('Person', width: 260),
        AdminTableColumn('Role', width: 150),
        AdminTableColumn('Joined', width: 160),
      ],
      rows: [
        for (final p in people)
          [
            Row(
              children: [
                AdminAvatar(_displayName(p), size: 34, avatar: _avatarOf(p)),
                const SizedBox(width: 10),
                Expanded(
                  child: _primaryCell(
                    _displayName(p),
                    '@${p['handle'] ?? _shortId(p['id'])}',
                  ),
                ),
              ],
            ),
            _Tag('${p['role'] ?? 'member'}'),
            Text(_date(p['created_at'] ?? p['joined_at'])),
          ],
      ],
    );
  }
}

/// A small tonal label.
class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.color, this.icon});
  final String text;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color == null
            ? scheme.surfaceContainerHighest
            : tint.withValues(alpha: .15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color ?? scheme.primary),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color ?? scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.admin});
  final bool admin;
  @override
  Widget build(BuildContext context) => admin
      ? _Tag(
          'Admin',
          color: Theme.of(context).colorScheme.primary,
          icon: Icons.shield_rounded,
        )
      : const _Tag('Member');
}

/// The picture of a person, project, agent or app row, as the node sends it
/// (its avatar, a project's avatar id, a profile's or a descriptor's).
String _avatarOf(dynamic row) {
  final m = _map(row);
  for (final v in [
    m['avatar'],
    m['avatar_id'],
    _map(m['profile'])['avatar'],
    _map(m['descriptor'])['avatar'],
  ]) {
    final s = v is String ? v.trim() : '';
    if (s.isNotEmpty && !RegExp(r'^0+$').hasMatch(s)) return s;
  }
  return '';
}

Map<String, dynamic> _map(dynamic value) => value is Map
    ? value.map((key, item) => MapEntry('$key', item))
    : <String, dynamic>{};
List<dynamic> _list(dynamic value) => value is List ? value : const [];
List<Map<String, dynamic>> _listOfMaps(dynamic value) =>
    _list(value).whereType<Map<dynamic, dynamic>>().map(_map).toList();
List<String> _stringList(dynamic value) =>
    _list(value).map((x) => '$x').toList();
List<double> _doubleList(dynamic value) =>
    _list(value).map((x) => _number(x)).toList();
double _number(dynamic value, {double fallback = 0}) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? fallback;
int _integer(dynamic value) => _number(value).round();
String _compact(dynamic value) {
  final n = _number(value);
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '${n.round()}';
}

String _credits(dynamic value) {
  if (value == null || '$value'.isEmpty) return '—';
  return formatLedgerCredits(_number(value), exact: true);
}

String _money(dynamic credits) {
  if (credits == null || '$credits'.isEmpty) return '\$0.00';
  return formatLedgerUsd(_number(credits));
}

/// Dollars with cents, or up to four decimals below a cent.
String _usd(double v) =>
    v >= .01 || v == 0 ? '\$${v.toStringAsFixed(2)}' : '\$${compactDecimal(v)}';

String _perMinute(dynamic units) {
  if (units == null || '$units'.isEmpty || _number(units) == 0)
    return 'Default';
  return '${formatLedgerUsd(_number(units))}/min';
}

String _humanKey(String key) {
  final words = key.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  if (words.isEmpty) return key;
  return words.length <= 4
      ? words.toUpperCase()
      : '${words[0].toUpperCase()}${words.substring(1)}';
}

String _modelPrice(dynamic credits) =>
    '\$${compactDecimal(ledgerToUsd(_number(credits)), decimals: 6)}';
String _date(dynamic value) {
  if (value == null || '$value'.isEmpty || value == 0) return '—';
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse('$value');
  if (date == null) return '$value';
  final local = date.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _time(dynamic value) {
  final date = value is num
      ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
      : DateTime.tryParse('$value');
  if (date == null) return '';
  final local = date.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
}

String _bytes(dynamic value) {
  var n = _number(value);
  if (n <= 0) return '—';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var unit = 0;
  while (n >= 1024 && unit < units.length - 1) {
    n /= 1024;
    unit++;
  }
  return '${n.toStringAsFixed(n >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _shortId(dynamic value) {
  final id = '${value ?? ''}';
  return id.length <= 12 ? id : '${id.substring(0, 8)}…';
}

String _displayName(Map<String, dynamic> user) {
  final profile = _map(user['profile']);
  final name = [
    profile['firstName'] ?? profile['first_name'],
    profile['lastName'] ?? profile['last_name'],
  ].where((x) => x != null && '$x'.trim().isNotEmpty).join(' ');
  return name.isNotEmpty
      ? name
      : '${user['name'] ?? user['handle'] ?? user['id'] ?? 'Unknown'}';
}

String _owner(Map<String, dynamic> space) {
  final owner = _map(space['owner']);
  if (owner['deleted'] == true) return 'Deleted account';
  final handle = owner['handle'] ?? space['owner_handle'];
  return handle == null
      ? _shortId(space['owner_id'])
      : '@${'$handle'.replaceFirst(RegExp(r'^@+'), '')}';
}

String _machineState(Map<String, dynamic> space) =>
    '${_map(space['machine'])['state'] ?? space['machine_state'] ?? 'none'}';
String _rowId(Map<String, dynamic> row) =>
    '${row['transaction_id'] ?? row['id']}';
double _sum(List<Map<String, dynamic>> rows, String key) => rows.fold(
  0,
  (sum, row) =>
      sum + _number(row[key] ?? row['credits'] ?? row['listed_amount']),
);

/// What a model is for: its capability, and the label the console shows.
const _modelKinds = <(String, String)>[
  ('chat', 'Agent'),
  ('decision', 'Decision'),
  ('embedding', 'Embedding'),
  ('image', 'Image'),
  ('video', 'Video'),
  ('speech', 'Speech'),
  ('transcription', 'Transcription'),
  ('live', 'Live'),
  ('rerank', 'Rerank'),
];

String _modelPurpose(Map<String, dynamic> model) {
  final capabilities = _stringList(model['capabilities']);
  for (final (capability, label) in _modelKinds.skip(1)) {
    if (capabilities.any((c) => c.contains(capability))) return label;
  }
  return 'Agent';
}

/// A model's prices other than tokens, as the console edits them: the
/// stored unit, the quoted unit and how many stored units one quoted unit is.
const _unitFields = <String, List<(String, String, double)>>{
  'image': [('image', '\$ per image', 1)],
  'video': [('second', '\$ per second of video', 1)],
  'speech': [('character', '\$ per 1M characters', 1e6)],
  'transcription': [('second', '\$ per minute of audio', 60)],
  'rerank': [('search', '\$ per search', 1)],
};

/// Kinds also, or only, priced by their tokens.
const _tokenPriced = {'chat', 'decision', 'embedding', 'image', 'rerank'};

String _unitUsd(num units) {
  final usd = units / ledgerUnitsPerUsd;
  if (usd <= 0) return '\$0';
  return '\$${usd >= 1 ? usd.toStringAsFixed(2) : compactDecimal(usd, decimals: 8)}';
}

/// What a model costs, in one line: tokens, or its unit, as it is priced.
String _modelPriceText(Map<String, dynamic> m) {
  if (m['unpriced'] == true) return 'needs a price';
  final kind = _modelKinds
      .firstWhere(
        (k) => k.$2 == _modelPurpose(m),
        orElse: () => _modelKinds.first,
      )
      .$1;
  final u = _map(m['units']);
  final parts = <String>[
    if (_number(u['image']) > 0) '${_unitUsd(_number(u['image']))} / image',
    if (kind == 'video' && _map(u['second_by']).isNotEmpty)
      _map(u['second_by']).entries
          .map((e) => '${e.key} ${_unitUsd(_number(e.value))}/s')
          .join(' · ')
    else if (kind == 'video' && _number(u['second']) > 0)
      '${_unitUsd(_number(u['second']))} / second',
    if (kind == 'transcription' && _number(u['second']) > 0)
      '${_unitUsd(_number(u['second']) * 60)} / minute',
    if (_number(u['character']) > 0)
      '${_unitUsd(_number(u['character']) * 1e6)} / 1M characters',
    if (_number(u['search']) > 0) '${_unitUsd(_number(u['search']))} / search',
  ];
  final input = _number(m['input_price']), output = _number(m['output_price']);
  if (input > 0 || output > 0 || parts.isEmpty) {
    parts.add(
      output > 0
          ? '${_modelPrice(input)} in · ${_modelPrice(output)} out / 1M'
          : '${_modelPrice(input)} / 1M tokens',
    );
  }
  return parts.join(' · ');
}

String _logLevel(String value) {
  final v = value.toLowerCase();
  if (v.startsWith('err') || v == 'fatal' || v == 'panic') return 'error';
  if (v.startsWith('warn')) return 'warn';
  if (v == 'debug') return 'debug';
  return 'log';
}

int _healthRank(String status) => status == 'fail' || status == 'error'
    ? 0
    : status == 'warn'
    ? 1
    : 2;
String _uptime(dynamic value) {
  final seconds = _integer(value);
  if (seconds <= 0) return '—';
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  return days > 0
      ? '${days}d ${hours}h'
      : hours > 0
      ? '${hours}h ${minutes}m'
      : '${minutes}m';
}

Widget _primaryCell(String primary, String secondary) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  mainAxisSize: MainAxisSize.min,
  children: [
    Text(
      primary,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontWeight: FontWeight.w800),
    ),
    if (secondary.isNotEmpty)
      Builder(
        builder: (context) => Text(
          secondary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
  ],
);

/// Searchable list of the projects that can be the platform admins space; it
/// pops the chosen one.
class _AdminsSpacePicker extends StatefulWidget {
  const _AdminsSpacePicker({required this.projects, required this.currentId});
  final List<Map<String, dynamic>> projects;
  final String currentId;

  @override
  State<_AdminsSpacePicker> createState() => _AdminsSpacePickerState();
}

class _AdminsSpacePickerState extends State<_AdminsSpacePicker> {
  final query = TextEditingController();

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = query.text.trim().toLowerCase();
    final rows = widget.projects
        .where(
          (s) =>
              q.isEmpty ||
              '${s['name']} ${s['id']} ${_map(s['owner'])['handle']}'
                  .toLowerCase()
                  .contains(q),
        )
        .toList();
    return AlertDialog(
      icon: const Icon(Icons.admin_panel_settings_rounded),
      title: const Text('Choose the admins space'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          children: [
            TextField(
              controller: query,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search title, id, or owner handle',
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        widget.projects.isEmpty
                            ? 'No projects created yet.'
                            : 'No projects match.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final s = rows[i];
                        final selected = '${s['id']}' == widget.currentId;
                        return ListTile(
                          leading: AdminAvatar(
                            '${s['name'] ?? s['id']}',
                            size: 34,
                            icon: Icons.folder_rounded,
                            avatar: _avatarOf(s),
                          ),
                          title: Text('${s['name'] ?? s['id']}'),
                          subtitle: Text('${_owner(s)} · ${_shortId(s['id'])}'),
                          trailing: selected
                              ? const Icon(Icons.check_rounded)
                              : null,
                          selected: selected,
                          onTap: () => Navigator.pop(context, s),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
