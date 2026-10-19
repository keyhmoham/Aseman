import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/llm_provider.dart';
import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/status_tag.dart';
import 'admin_widgets.dart';

/// Admin panel section managing the node's LLM providers: API keys (owned by
/// the admin's account), the models agents can choose as their backbone and the
/// input/output token prices users are charged (credits per 1M tokens). LLM
/// usage charges are paid to the admin wallet that owns the keys.
class LlmProvidersTab extends StatefulWidget {
  const LlmProvidersTab({super.key, required this.service});
  final TraderaService service;
  @override
  State<LlmProvidersTab> createState() => _LlmProvidersTabState();
}

class _LlmProvidersTabState extends State<LlmProvidersTab> {
  List<LlmProvider> _providers = const [];
  List<LlmKind> _kinds = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Spinner only on the first load; later reloads swap the data in place.
  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.service.adminLlmProviders(),
        widget.service.adminLlmKinds(),
      ]);
      if (!mounted) return;
      setState(() {
        _providers = results[0] as List<LlmProvider>;
        _kinds = results[1] as List<LlmKind>;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!_loading && _error == null) {
        // Keep the list on screen when a reload fails.
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not refresh: $e')));
        return;
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _edit([LlmProvider? provider]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ProviderDialog(
          service: widget.service, kinds: _kinds, provider: provider),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(LlmProvider p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${p.name}?'),
        content: const Text(
            'Agents using this provider fall back to the default provider.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.adminDeleteLlmProvider(p.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _quick(LlmProvider p, {bool? enabled, bool? isDefault}) async {
    try {
      await widget.service.adminSetLlmProvider(
        id: p.id,
        name: p.name,
        kind: p.kind,
        baseUrl: p.baseUrl,
        enabled: enabled ?? p.enabled,
        isDefault: isDefault ?? p.isDefault,
        models: p.models,
        imageModel: p.imageModel,
        imagePrice: p.imagePrice,
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update provider: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
          child: AdminEmptyState('Could not load providers', _error!,
              icon: Icons.cloud_off_rounded));
    }
    final enabled = _providers.where((p) => p.enabled).length;
    final missing = _providers.where((p) => !p.hasKey).length;
    final models = _providers.fold<int>(0, (sum, p) => sum + p.models.length);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 48),
      children: [
        AdminGrid(children: [
          AdminStatCard(
              label: 'Providers',
              value: '${_providers.length}',
              icon: Icons.hub_rounded,
              hint: '$enabled enabled',
              progress: _providers.isEmpty ? 0 : enabled / _providers.length),
          AdminStatCard(
              label: 'Models',
              value: '$models',
              icon: Icons.memory_rounded,
              tone: AppColors.cyan,
              hint: 'Prices are set under Models'),
          AdminStatCard(
              label: 'Missing keys',
              value: '$missing',
              icon: Icons.key_off_rounded,
              tone: missing > 0 ? AppColors.danger : AppColors.success,
              hint:
                  missing > 0 ? 'Agents cannot use these' : 'Every key is set'),
        ]),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, constraints) {
          final text = Text(
            'Agents run on these providers. Token usage is charged to the '
            'agent’s users at each model’s price and paid to your wallet.',
            style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
          );
          final add = FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add provider'),
          );
          if (constraints.maxWidth < 560) {
            return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [text, const SizedBox(height: 10), add]);
          }
          return Row(children: [
            Expanded(child: text),
            const SizedBox(width: 12),
            add,
          ]);
        }),
        const SizedBox(height: 14),
        if (_providers.isEmpty)
          const AdminEmptyState('No providers yet',
              'Agents need an enabled provider with an API key.',
              icon: Icons.hub_outlined)
        else
          AdminGrid(maxColumns: 2, minTileWidth: 360, children: [
            for (final p in _providers) _card(p),
          ]),
      ],
    );
  }

  Widget _card(LlmProvider p) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.card)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            AdminAvatar(p.name, size: 44, icon: Icons.hub_rounded),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w800)),
                    Text(p.kind,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ]),
            ),
            if (p.isDefault) const StatusTag('DEFAULT', AppColors.primary),
            Switch(
              value: p.enabled,
              thumbIcon: WidgetStateProperty.resolveWith((states) => Icon(
                  states.contains(WidgetState.selected)
                      ? Icons.check_rounded
                      : Icons.close_rounded)),
              onChanged: (v) => _quick(p, enabled: v),
            ),
          ]),
          const SizedBox(height: 14),
          AdminKeyValue('Endpoint',
              p.baseUrl.isEmpty ? 'Default for the kind' : p.baseUrl),
          Row(children: [
            Expanded(
                child: Text('API key',
                    style: TextStyle(
                        fontSize: 13, color: scheme.onSurfaceVariant))),
            AdminStatusPill(p.hasKey ? 'ok' : 'error'),
            const SizedBox(width: 8),
            Text(
                p.hasKey
                    ? (p.keyPreview.isEmpty ? 'Set' : p.keyPreview)
                    : 'Missing',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: p.hasKey ? scheme.onSurface : AppColors.danger)),
          ]),
          const SizedBox(height: 4),
          AdminKeyValue('Models', '${p.models.length}'),
          const SizedBox(height: 4),
          Row(children: [
            if (!p.isDefault)
              TextButton.icon(
                  onPressed:
                      p.enabled ? () => _quick(p, isDefault: true) : null,
                  icon: const Icon(Icons.star_outline_rounded, size: 18),
                  label: const Text('Make default')),
            const Spacer(),
            IconButton(
                tooltip: 'Edit',
                onPressed: () => _edit(p),
                icon: const Icon(Icons.edit_outlined, size: 20)),
            IconButton(
                tooltip: 'Delete',
                onPressed: () => _delete(p),
                icon: const Icon(Icons.delete_outline_rounded, size: 20)),
          ]),
        ]),
      ),
    );
  }
}

/// One editable model row of the provider form.
class _ModelRow {
  _ModelRow([this.original])
      : id = TextEditingController(text: original?.id ?? ''),
        name = original?.name ?? '',
        capabilities = original?.capabilities ?? const [],
        input = TextEditingController(
            text: original == null ? '' : formatCredits(original.inputPrice)),
        output = TextEditingController(
            text: original == null ? '' : formatCredits(original.outputPrice));

  /// The model as the node had it (null for a new row).
  final LlmModel? original;
  final TextEditingController id;
  final String name;
  final List<String> capabilities;
  final TextEditingController input;
  final TextEditingController output;

  void dispose() {
    id.dispose();
    input.dispose();
    output.dispose();
  }
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog(
      {required this.service, required this.kinds, this.provider});
  final TraderaService service;
  final List<LlmKind> kinds;
  final LlmProvider? provider;
  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late String kind;
  late final TextEditingController name;
  late final TextEditingController baseUrl;
  final apiKey = TextEditingController();
  late final TextEditingController imageModel;
  late final TextEditingController imagePrice;
  late bool enabled;
  late bool isDefault;
  late final List<_ModelRow> rows;
  bool saving = false;

  bool get editing => widget.provider != null;

  @override
  void initState() {
    super.initState();
    final p = widget.provider;
    kind = p?.kind ??
        (widget.kinds.isNotEmpty ? widget.kinds.first.kind : 'openai');
    name = TextEditingController(text: p?.name ?? _kindName(kind));
    baseUrl = TextEditingController(text: p?.baseUrl ?? _kindUrl(kind));
    imageModel = TextEditingController(text: p?.imageModel ?? '');
    imagePrice = TextEditingController(
        text: p == null ? '' : formatCredits(p.imagePrice));
    enabled = p?.enabled ?? true;
    isDefault = p?.isDefault ?? false;
    rows = [
      for (final m in p?.models ?? const <LlmModel>[]) _ModelRow(m),
    ];
    if (rows.isEmpty) rows.add(_ModelRow());
  }

  @override
  void dispose() {
    name.dispose();
    baseUrl.dispose();
    apiKey.dispose();
    imageModel.dispose();
    imagePrice.dispose();
    for (final r in rows) {
      r.dispose();
    }
    super.dispose();
  }

  String _kindName(String k) =>
      widget.kinds.where((x) => x.kind == k).map((x) => x.name).firstOrNull ??
      k;
  String _kindUrl(String k) =>
      widget.kinds
          .where((x) => x.kind == k)
          .map((x) => x.baseUrl)
          .firstOrNull ??
      '';

  void _selectKind(String k) {
    setState(() {
      // Replace the name/URL only while they still hold the previous preset.
      if (name.text.trim().isEmpty || name.text == _kindName(kind)) {
        name.text = _kindName(k);
      }
      if (baseUrl.text.trim().isEmpty || baseUrl.text == _kindUrl(kind)) {
        baseUrl.text = _kindUrl(k);
      }
      kind = k;
    });
  }

  Future<void> _save() async {
    final models = <LlmModel>[];
    for (final r in rows) {
      final id = r.id.text.trim();
      if (id.isEmpty) continue;
      final input = (double.tryParse(r.input.text.trim()) ?? 0) * 10000;
      final output = (double.tryParse(r.output.text.trim()) ?? 0) * 10000;
      // What the node stores beyond these fields stays; a price typed here is
      // no longer an import's price plus its markup.
      final extra = {...?r.original?.extra};
      final repriced = r.original != null &&
          (input != r.original!.inputPrice ||
              output != r.original!.outputPrice);
      if (repriced) {
        extra
          ..remove('markup')
          ..remove('base_input_price')
          ..remove('base_output_price');
        if (input > 0 || output > 0) extra.remove('unpriced');
      }
      models.add(LlmModel(
        id: id,
        name: r.name,
        inputPrice: input,
        outputPrice: output,
        capabilities: r.capabilities,
        extra: extra,
      ));
    }
    String? problem;
    if (models.isEmpty) problem = 'Add at least one model.';
    if (!editing && apiKey.text.trim().isEmpty) problem = 'API key required.';
    if (problem != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => saving = true);
    try {
      await widget.service.adminSetLlmProvider(
        id: widget.provider?.id,
        name: name.text.trim(),
        kind: kind,
        baseUrl: baseUrl.text.trim(),
        apiKey: apiKey.text.trim(),
        enabled: enabled,
        isDefault: isDefault,
        models: models,
        imageModel: imageModel.text.trim(),
        imagePrice: (double.tryParse(imagePrice.text.trim()) ?? 0) * 10000,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 780),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 22, 20, 18),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(
                width: 48,
                height: 48,
                decoration: ShapeDecoration(
                    color: scheme.primaryContainer,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
                child:
                    Icon(Icons.hub_rounded, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(editing ? 'Edit LLM provider' : 'Add LLM provider',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppChoiceField<String>(
                        label: 'Provider',
                        value: kind,
                        onChanged: _selectKind,
                        choices: [
                          for (final k in widget.kinds)
                            AppChoice(k.kind, k.name, icon: Icons.hub_outlined),
                          if (widget.kinds.every((k) => k.kind != kind))
                            AppChoice(kind, kind, icon: Icons.hub_outlined),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _field('Display name', name),
                      const SizedBox(height: 10),
                      _field('Base URL (OpenAI-compatible)', baseUrl,
                          hint: 'https://…/v1'),
                      const SizedBox(height: 10),
                      _field(
                        'API key',
                        apiKey,
                        obscure: true,
                        hint: editing
                            ? 'Leave empty to keep ${widget.provider!.keyPreview}'
                            : 'Paste the provider API key',
                      ),
                      const SizedBox(height: 6),
                      const SizedBox(height: 10),
                      AppSwitchCard(
                        icon: Icons.power_rounded,
                        title: 'Enabled',
                        subtitle: 'Agents can run on this provider.',
                        value: enabled,
                        onChanged: (v) => setState(() => enabled = v),
                      ),
                      const SizedBox(height: 10),
                      AppSwitchCard(
                        icon: Icons.star_rounded,
                        title: 'Default provider',
                        subtitle:
                            'Used by agents created without an explicit provider.',
                        value: isDefault,
                        onChanged: (v) => setState(() => isDefault = v),
                      ),
                      const SizedBox(height: 18),
                      _label('Models and token prices (credits per 1M tokens)'),
                      for (var i = 0; i < rows.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: LayoutBuilder(builder: (context, box) {
                            final id = _field('Model id', rows[i].id,
                                hint: 'e.g. gpt-5.4');
                            final prices = [
                              Expanded(
                                  flex: 2,
                                  child: _field('Input price', rows[i].input,
                                      number: true)),
                              const SizedBox(width: 8),
                              Expanded(
                                  flex: 2,
                                  child: _field('Output price', rows[i].output,
                                      number: true)),
                              IconButton(
                                tooltip: 'Remove model',
                                onPressed: rows.length == 1
                                    ? null
                                    : () => setState(() {
                                          rows.removeAt(i).dispose();
                                        }),
                                icon: const Icon(Icons.remove_circle_outline,
                                    size: 18),
                              ),
                            ];
                            // On phones the id gets its own line.
                            if (box.maxWidth < 440) {
                              return Column(children: [
                                id,
                                const SizedBox(height: 8),
                                Row(children: prices),
                              ]);
                            }
                            return Row(children: [
                              Expanded(flex: 3, child: id),
                              const SizedBox(width: 8),
                              ...prices,
                            ]);
                          }),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () =>
                              setState(() => rows.add(_ModelRow())),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add model'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _label('Image generation (optional)'),
                      Row(children: [
                        Expanded(
                            flex: 3,
                            child: _field('Image model', imageModel,
                                hint: 'e.g. gpt-image-1')),
                        const SizedBox(width: 8),
                        Expanded(
                            flex: 2,
                            child: _field('Credits / image', imagePrice,
                                number: true)),
                      ]),
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
                onPressed: saving ? null : _save,
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check_rounded, size: 18),
                label: const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)));

  Widget _field(String label, TextEditingController c,
          {String? hint, bool obscure = false, bool number = false}) =>
      TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        decoration: InputDecoration(labelText: label, hintText: hint),
      );
}
