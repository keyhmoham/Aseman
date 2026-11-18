part of 'developer_console.dart';

// ── the workflow installer ───────────────────────────────────────────────────

/// A small installer to start from: a space with an agent, and a web page
/// written to the space's computer and served.
const String kWorkflowStarter = '''{
  "\$schema": "https://raw.githubusercontent.com/keyhmoham/Decillion/main/docs/workflows/workflow.schema.json",
  "decillion_workflow": "1",
  "name": "my-product",
  "inputs": {
    "product": {"type": "string", "default": "My Product"}
  },
  "steps": [
    {"id": "space", "upsert": {"resource": "space", "with": {"name": "\${{ inputs.product }}"}}},
    {"id": "agent", "upsert": {"resource": "agent", "with": {"name": "Builder", "instructions": "You build \${{ inputs.product }}."}}},
    {"id": "member", "upsert": {"resource": "space_bot", "with": {"space": "\${{ steps.space.outputs.id }}", "bot": "\${{ steps.agent.outputs.id }}"}}},
    {"id": "site", "sandbox": {
      "space": "\${{ steps.space.outputs.id }}", "start": true, "root": "site",
      "files": {"index.html": "<h1>\${{ inputs.product }}</h1>"}, "render": true,
      "proxy": {"port": 8000, "title": "\${{ inputs.product }}", "start": "python3 -m http.server 8000"}
    }}
  ],
  "outputs": {"space": "\${{ steps.space.outputs.id }}", "preview": "\${{ steps.site.outputs.proxy.url }}"}
}
''';

/// The Decillion node only accepts its own names. A document opened from
/// Aseman is rewritten in place: the format key and the toolchain names.
String decillionWorkflowDocument(String text) {
  return text
      .replaceAll(
        'https://raw.githubusercontent.com/keyhmoham/Aseman/main/docs/workflows/workflow.schema.json',
        'https://raw.githubusercontent.com/keyhmoham/Decillion/main/docs/workflows/workflow.schema.json',
      )
      .replaceAll('aseman_workflow', 'decillion_workflow')
      .replaceAll('ASEMAN_DEVELOPER_API_URL', 'DECILLION_DEVELOPER_API_URL')
      .replaceAll('ASEMAN_DEVELOPER_KEY', 'DECILLION_DEVELOPER_KEY')
      .replaceAll('ASEMAN_APPUI_ROOT', 'DECILLION_APPUI_ROOT')
      .replaceAll('/opt/aseman-appui', '/opt/decillion-appui')
      .replaceAll('aseman-elpian', 'decillion-elpian')
      .replaceAll('aseman-appui', 'decillion-appui');
}

String? _jsonProblem(String text, {bool object = true}) {
  if (text.trim().isEmpty)
    return object ? 'Write or open a workflow first.' : null;
  try {
    final v = jsonDecode(text);
    if (object && v is! Map) return 'A workflow is a JSON object.';
    return null;
  } on FormatException catch (e) {
    return 'Not valid JSON: ${e.message}${e.offset != null ? ' (at ${e.offset})' : ''}';
  }
}

bool _active(dynamic status) => status == 'running' || status == 'cancelling';

IconData _statusIcon(String status) => switch (status) {
  'succeeded' => Icons.check_circle_rounded,
  'planned' => Icons.fact_check_outlined,
  'reused' => Icons.replay_rounded,
  'failed' || 'interrupted' => Icons.error_rounded,
  'rolled_back' => Icons.undo_rounded,
  'cancelled' => Icons.cancel_outlined,
  'skipped' => Icons.skip_next_rounded,
  'running' || 'cancelling' => Icons.timelapse_rounded,
  _ => Icons.circle_outlined,
};

Color _statusColor(BuildContext context, String status) {
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    'succeeded' || 'planned' || 'reused' => Colors.green.shade600,
    'failed' || 'interrupted' || 'rolled_back' => scheme.error,
    'running' || 'cancelling' => scheme.primary,
    _ => scheme.onSurfaceVariant,
  };
}

class _Workflows extends _Loaded {
  const _Workflows({super.key, required super.service, required super.org});
  @override
  State<_Workflows> createState() => _WorkflowsState();
}

class _WorkflowsState extends _LoadedState<_Workflows> {
  final _doc = TextEditingController();
  final _inputs = TextEditingController(text: '{}');
  final Map<String, TextEditingController> _secrets = {};
  _Json? _validation;
  String _busy = '';
  Timer? _poll;

  @override
  Future<_Json> fetch() => call('workflow_runs', {'limit': 30});

  @override
  Future<void> reload() async {
    await super.reload();
    _schedulePoll();
  }

  /// While a run is going, the list follows it.
  void _schedulePoll() {
    _poll?.cancel();
    if (!mounted) return;
    if (_maps(data['runs']).any((r) => _active(r['status']))) {
      _poll = Timer(const Duration(seconds: 3), reload);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _doc.dispose();
    _inputs.dispose();
    for (final c in _secrets.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _open() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Workflow', extensions: ['json']),
      ],
    );
    if (file == null) return;
    final text = decillionWorkflowDocument(await file.readAsString());
    setState(() {
      _doc.text = text;
      _validation = null;
    });
    await _validate(quiet: true);
  }

  /// How to write a rich, professional workflow — the same guide the API
  /// gives models (docs/workflows/AUTHORING.md).
  Future<void> _guide() async {
    final String text;
    try {
      text = '${(await call('workflow_guide'))['content'] ?? ''}';
    } catch (e) {
      if (mounted) _snack(context, '$e');
      return;
    }
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Writing workflows'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: text)),
            child: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _starter() {
    setState(() {
      _doc.text = kWorkflowStarter;
      _validation = null;
    });
    unawaited(_validate(quiet: true));
  }

  void _useDecillionDocument() {
    final next = decillionWorkflowDocument(_doc.text);
    if (next != _doc.text) _doc.text = next;
  }

  Future<void> _validate({bool quiet = false}) async {
    _useDecillionDocument();
    final problem = _jsonProblem(_doc.text);
    if (problem != null) {
      setState(
        () => _validation = {
          'valid': false,
          'issues': [
            {'severity': 'error', 'path': '', 'message': problem},
          ],
        },
      );
      return;
    }
    setState(() => _busy = 'validate');
    try {
      final v = await call('workflow_validate', {'workflow': _doc.text});
      if (!mounted) return;
      setState(() {
        _validation = v;
        for (final s in _maps(v['secrets'])) {
          _secrets.putIfAbsent('${s['name']}', TextEditingController.new);
        }
      });
    } catch (e) {
      if (mounted && !quiet) _snack(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  _Json? _request() {
    _useDecillionDocument();
    final problem = _jsonProblem(_doc.text) ?? _jsonProblem(_inputs.text);
    if (problem != null) {
      _snack(context, problem);
      return null;
    }
    final declared = {
      for (final s in _maps(_validation?['secrets'])) '${s['name']}',
    };
    return {
      'workflow': _doc.text,
      'inputs': jsonDecode(_inputs.text.trim().isEmpty ? '{}' : _inputs.text),
      'secrets': {
        for (final e in _secrets.entries)
          if (declared.contains(e.key) && e.value.text.isNotEmpty)
            e.key: e.value.text,
      },
    };
  }

  Future<void> _start(String mode, {String resume = ''}) async {
    // A resume runs the earlier run's document with its inputs again; only
    // the secrets, never stored, are given anew.
    final req = resume.isEmpty
        ? _request()
        : <String, dynamic>{
            'secrets': {
              for (final e in _secrets.entries)
                if (e.value.text.isNotEmpty) e.key: e.value.text,
            },
          };
    if (req == null) return;
    if (mode == 'run' && resume.isEmpty) {
      final ok = await _confirm(
        context,
        'Run this workflow?',
        'It acts as you: it can create and change spaces, agents, apps, '
            'keys and your organization\'s platform, and spend from its '
            'wallet. Plan it first to see what it would do.',
        action: 'Run',
      );
      if (!ok) return;
    }
    setState(() => _busy = mode);
    try {
      final run = mode == 'plan'
          ? await call('workflow_plan', {...req, 'wait_seconds': 150})
          : await call('workflow_run', {
              ...req,
              'async': true,
              if (resume.isNotEmpty) 'resume_from': resume,
            });
      if (!mounted) return;
      unawaited(reload());
      await _show(run);
    } catch (e) {
      if (mounted) _snack(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _show(_Json run) async {
    await showAppDialog<void>(
      context: context,
      builder: (context) => _RunDialog(
        service: widget.service,
        org: widget.org,
        run: run,
        onResume: (id) {
          Navigator.pop(context);
          _start('run', resume: id);
        },
      ),
    );
    if (mounted) await reload();
  }

  Future<void> _openRun(_Json run) async {
    try {
      await _show(await call('workflow_run_get', {'id': run['id']}));
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  Widget _issues(BuildContext context) {
    final v = _validation;
    if (v == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final issues = _maps(v['issues']);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (v['valid'] == true)
            Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: Colors.green.shade600,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Valid: ${v['name']} · ${v['steps']} step(s) · ${v['assets'] ?? 0} asset(s)',
                    style: TextStyle(color: scheme.onSurface),
                  ),
                ),
              ],
            ),
          for (final i in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    i['severity'] == 'error'
                        ? Icons.error_outline_rounded
                        : Icons.warning_amber_rounded,
                    size: 18,
                    color: i['severity'] == 'error'
                        ? scheme.error
                        : Colors.orange.shade700,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: SelectableText(
                      '${'${i['path']}'.isEmpty ? '' : '${i['path']}: '}${i['message']}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context) {
    final secrets = _maps(_validation?['secrets']);
    return _Card(
      title: 'Installer',
      icon: Icons.account_tree_rounded,
      trailing: Wrap(
        spacing: AppSpacing.xs,
        children: [
          TextButton.icon(
            onPressed: _open,
            icon: const Icon(Icons.file_open_outlined, size: 18),
            label: const Text('Open file'),
          ),
          TextButton.icon(
            onPressed: _guide,
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('Writing guide'),
          ),
          TextButton.icon(
            onPressed: _starter,
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('Start from a template'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'One JSON document that brings a product up in order — your '
            'organization\'s platform and keys, spaces, agents, apps, and '
            'an app\'s full source installed and served on a space\'s '
            'computer. Running it again changes only what differs.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const ValueKey('workflow-document'),
            controller: _doc,
            minLines: 10,
            maxLines: 22,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: const InputDecoration(
              labelText: 'Workflow (JSON)',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_validation != null) setState(() => _validation = null);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            key: const ValueKey('workflow-inputs'),
            controller: _inputs,
            minLines: 1,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            decoration: const InputDecoration(
              labelText: 'Inputs (JSON object)',
              hintText: '{"product": "Acme"}',
              border: OutlineInputBorder(),
            ),
          ),
          for (final s in secrets) ...[
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _secrets['${s['name']}'],
              obscureText: true,
              decoration: InputDecoration(
                labelText:
                    'Secret ${s['name']}${s['required'] == true ? ' (required)' : ''}',
                helperText: '${s['description'] ?? ''}'.isEmpty
                    ? 'Never stored; hidden in the run\'s report.'
                    : '${s['description']}',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          _issues(context),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              OutlinedButton.icon(
                onPressed: _busy.isEmpty ? () => _validate() : null,
                icon: const Icon(Icons.rule_rounded, size: 18),
                label: Text(_busy == 'validate' ? 'Checking…' : 'Validate'),
              ),
              OutlinedButton.icon(
                onPressed: _busy.isEmpty ? () => _start('plan') : null,
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: Text(_busy == 'plan' ? 'Planning…' : 'Plan'),
              ),
              FilledButton.icon(
                onPressed: _busy.isEmpty ? () => _start('run') : null,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(_busy == 'run' ? 'Starting…' : 'Run'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _runs(BuildContext context) {
    final runs = _maps(data['runs']);
    return _Card(
      title: 'Runs',
      icon: Icons.history_rounded,
      trailing: IconButton(
        tooltip: 'Refresh',
        onPressed: reload,
        icon: const Icon(Icons.refresh_rounded),
      ),
      child: runs.isEmpty
          ? _empty(context, 'No runs yet. Plan or run a workflow above.')
          : Column(
              children: [
                for (final r in runs)
                  QuietTile(
                    icon: _statusIcon('${r['status']}'),
                    label: '${r['name']}',
                    subtitle:
                        '${r['status']} · ${r['mode']} · ${_date(r['started_at'])}${'${r['key'] ?? ''}'.isEmpty ? '' : ' · API key'}',
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _openRun(r),
                  ),
              ],
            ),
    );
  }

  @override
  Widget content(BuildContext context) => ListView(
    padding: const EdgeInsets.all(AppSpacing.md),
    children: [_editor(context), _runs(context)],
  );
}

/// One run: its steps, outputs and log, followed while it is going.
class _RunDialog extends StatefulWidget {
  const _RunDialog({
    required this.service,
    required this.org,
    required this.run,
    required this.onResume,
  });
  final AsemanService service;
  final String org;
  final _Json run;
  final void Function(String id) onResume;

  @override
  State<_RunDialog> createState() => _RunDialogState();
}

class _RunDialogState extends State<_RunDialog> {
  late _Json _run = widget.run;
  Timer? _poll;
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _follow() {
    _poll?.cancel();
    if (!_active(_run['status'])) return;
    _poll = Timer(const Duration(seconds: 2), () async {
      try {
        final r = await widget.service.developer('workflow_run_get', {
          'org': widget.org,
          'id': _run['id'],
        });
        if (!mounted) return;
        setState(() => _run = r);
      } catch (_) {}
      if (mounted) _follow();
    });
  }

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    try {
      final r = await widget.service.developer('workflow_run_cancel', {
        'org': widget.org,
        'id': _run['id'],
      });
      if (mounted)
        setState(() => _run = {..._run, 'status': r['status'] ?? 'cancelling'});
      _follow();
    } catch (e) {
      if (mounted) _snack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = '${_run['status']}';
    final report = _map(_run['report']);
    final steps = _maps(report['steps']);
    final rollback = _maps(report['rollback']);
    final events = _maps(report['events']);
    final outputs = _map(report['outputs']);
    final counts = _map(report['counts']);
    final error = '${_run['error'] ?? report['error'] ?? ''}';

    Widget stepTile(_Json s) {
      final st = '${s['status']}';
      final op = '${s['operation'] ?? ''}';
      final err = '${s['error'] ?? ''}';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_statusIcon(st), size: 18, color: _statusColor(context, st)),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${s['path']}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TextSpan(
                          text:
                              '  ${s['action'] ?? s['kind'] ?? ''}${op.isEmpty ? '' : ' · $op'}',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                  if ('${s['reason'] ?? ''}'.isNotEmpty)
                    Text(
                      '${s['reason']}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  if (err.isNotEmpty)
                    SelectableText(
                      err,
                      style: TextStyle(fontSize: 12.5, color: scheme.error),
                    ),
                ],
              ),
            ),
            if (s['duration_ms'] is num && (s['duration_ms'] as num) > 0)
              Text(
                '${((s['duration_ms'] as num) / 1000).toStringAsFixed(1)}s',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      );
    }

    return AlertDialog(
      title: Row(
        children: [
          Icon(_statusIcon(status), color: _statusColor(context, status)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text('${_run['name']} · $status')),
          if (_active(status))
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      content: SizedBox(
        width: 760,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '${_run['mode'] == 'plan' ? 'Plan' : 'Run'} ${_run['id']} · started ${_date(_run['started_at'])}'
              '${counts.isEmpty ? '' : ' · ${counts['created'] ?? 0} created, ${counts['updated'] ?? 0} updated, ${counts['unchanged'] ?? 0} unchanged'}',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            if (error.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              SelectableText(error, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text('Steps', style: Theme.of(context).textTheme.titleSmall),
            if (steps.isEmpty)
              _empty(context, _active(status) ? 'Starting…' : 'No steps ran.'),
            for (final s in steps) stepTile(s),
            if (rollback.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Rolled back',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final s in rollback) stepTile(s),
            ],
            if (outputs.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Outputs', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(outputs),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
              ),
            ],
            if (events.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  'Log (${events.length})',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                children: [
                  for (final e in events)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        '${e['level']}  ${'${e['path'] ?? ''}'.isEmpty ? '' : '${e['path']}  '}${e['message']}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: e['level'] == 'error'
                              ? scheme.error
                              : scheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        if (_active(status))
          TextButton(
            onPressed: _cancelling ? null : _cancel,
            child: Text(_cancelling ? 'Cancelling…' : 'Cancel run'),
          ),
        if (_run['mode'] == 'run' &&
            const {
              'failed',
              'cancelled',
              'rolled_back',
              'interrupted',
            }.contains(status))
          TextButton(
            onPressed: () => widget.onResume('${_run['id']}'),
            child: const Text('Resume'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
