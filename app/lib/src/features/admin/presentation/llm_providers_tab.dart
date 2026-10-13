import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/llm_provider.dart';
import '../../../data/services/tradera_service.dart';
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
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
      });
    } catch (e) {
      if (!mounted) return;
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
          child: Text(_error!, style: TextStyle(color: scheme.error)));
    }
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 18),
      children: [
        Row(children: [
          Expanded(
            child: Text(
              'Agents run on these providers. Token usage is charged to the '
              'agent’s users with the prices below (credits per 1M tokens) '
              'and paid to your wallet.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: () => _edit(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add provider'),
          ),
        ]),
        const SizedBox(height: 12),
        AdminDataTable(
          empty:
              'No providers yet. Agents need an enabled provider with an API key.',
          columns: const [
            AdminTableColumn('Provider', width: 180),
            AdminTableColumn('Endpoint', width: 270),
            AdminTableColumn('API key', width: 120),
            AdminTableColumn('Models', width: 80, align: TextAlign.right),
            AdminTableColumn('Enabled', width: 110),
            AdminTableColumn('Default', width: 130),
            AdminTableColumn('Actions', width: 120, align: TextAlign.right),
          ],
          rows: [
            for (final p in _providers)
              [
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(p.kind,
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
                ]),
                Text(p.baseUrl.isEmpty ? 'Default for the kind' : p.baseUrl,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                    p.hasKey
                        ? (p.keyPreview.isEmpty ? 'Set' : p.keyPreview)
                        : 'Missing',
                    style: TextStyle(
                        color: p.hasKey ? scheme.onSurface : AppColors.danger,
                        fontWeight: FontWeight.w700)),
                Text('${p.models.length}', textAlign: TextAlign.right),
                TextButton(
                    onPressed: () => _quick(p, enabled: !p.enabled),
                    child: Text(p.enabled ? 'Enabled' : 'Disabled')),
                p.isDefault
                    ? const StatusTag('DEFAULT', AppColors.primary)
                    : TextButton(
                        onPressed:
                            p.enabled ? () => _quick(p, isDefault: true) : null,
                        child: const Text('Make default')),
                Wrap(alignment: WrapAlignment.end, children: [
                  IconButton(
                      tooltip: 'Edit',
                      onPressed: () => _edit(p),
                      icon: const Icon(Icons.edit_outlined, size: 18)),
                  IconButton(
                      tooltip: 'Delete',
                      onPressed: () => _delete(p),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18)),
                ]),
              ],
          ],
        ),
        const SizedBox(height: 10),
        Text('Model names and token prices are managed under Models.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

/// One editable model row of the provider form.
class _ModelRow {
  _ModelRow([LlmModel? m])
      : id = TextEditingController(text: m?.id ?? ''),
        name = m?.name ?? '',
        capabilities = m?.capabilities ?? const [],
        input = TextEditingController(
            text: m == null ? '' : formatCredits(m.inputPrice)),
        output = TextEditingController(
            text: m == null ? '' : formatCredits(m.outputPrice));
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
      models.add(LlmModel(
        id: id,
        name: r.name,
        inputPrice: (double.tryParse(r.input.text.trim()) ?? 0) * 10000,
        outputPrice: (double.tryParse(r.output.text.trim()) ?? 0) * 10000,
        capabilities: r.capabilities,
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
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 14),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.psychology_alt_outlined, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(editing ? 'Edit LLM provider' : 'Add LLM provider',
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w900)),
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
                      DropdownButtonFormField<String>(
                        initialValue: kind,
                        decoration: const InputDecoration(
                            labelText: 'Provider',
                            border: OutlineInputBorder(),
                            isDense: true),
                        items: [
                          for (final k in widget.kinds)
                            DropdownMenuItem(
                                value: k.kind, child: Text(k.name)),
                          if (widget.kinds.every((k) => k.kind != kind))
                            DropdownMenuItem(value: kind, child: Text(kind)),
                        ],
                        onChanged: (v) => v == null ? null : _selectKind(v),
                      ),
                      const SizedBox(height: 10),
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
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Enabled',
                            style: TextStyle(fontSize: 13)),
                        value: enabled,
                        onChanged: (v) => setState(() => enabled = v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Default provider',
                            style: TextStyle(fontSize: 13)),
                        subtitle: const Text(
                            'Used by agents created without an explicit provider.',
                            style: TextStyle(fontSize: 10)),
                        value: isDefault,
                        onChanged: (v) => setState(() => isDefault = v),
                      ),
                      const SizedBox(height: 8),
                      _label('MODELS & TOKEN PRICES (CREDITS PER 1M TOKENS)'),
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
                      _label('IMAGE GENERATION (OPTIONAL)'),
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
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
              color: Theme.of(context).colorScheme.primary)));

  Widget _field(String label, TextEditingController c,
          {String? hint, bool obscure = false, bool number = false}) =>
      TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      );
}
