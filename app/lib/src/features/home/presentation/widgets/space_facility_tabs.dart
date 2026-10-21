import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../data/models/bot.dart';
import '../../../../shared/widgets/backend_action_ui.dart';
import '../../../admin/presentation/admin_widgets.dart';

// The space's own facilities, shown as tabs of the workspace's left panel:
// its computer, the agent team's memory and the published previews. Files,
// apps, routines and usage live elsewhere (the Sandbox Explorer and file
// tabs, the Apps tab, each room's routines and the space settings).

/// Runs a backend action through its form (which doubles as the
/// confirmation), reports the outcome and reloads the tab.
mixin _SpaceActions<T extends StatefulWidget> on State<T> {
  AppDependencies get dependencies;
  Future<void> reload();

  Future<void> run(
    String namespace,
    String action,
    Map<String, dynamic> body, {
    required String done,
  }) async {
    final form = await showBackendActionForm(
      context,
      namespace: namespace,
      action: action,
      initialBody: body,
    );
    if (form == null || !mounted) return;
    try {
      await dependencies.service.invokeAction(
        namespace,
        action,
        body: form,
        timeout: const Duration(minutes: 10),
      );
      if (!mounted) return;
      context.showMessage(done);
      await reload();
    } catch (e) {
      if (mounted) context.showMessage('$done failed: $e');
    }
  }
}

/// The space's computer: its state, power and lifecycle.
class SpaceComputerTab extends StatefulWidget {
  const SpaceComputerTab({
    super.key,
    required this.dependencies,
    required this.spaceId,
  });
  final AppDependencies dependencies;
  final String spaceId;
  @override
  State<SpaceComputerTab> createState() => _SpaceComputerTabState();
}

class _SpaceComputerTabState extends State<SpaceComputerTab>
    with _SpaceActions {
  Map<String, dynamic> _machine = const {};
  bool _loading = true;

  @override
  AppDependencies get dependencies => widget.dependencies;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> reload() async {
    setState(() => _loading = true);
    Map<String, dynamic> machine = const {};
    try {
      final response = _map(
        await widget.dependencies.service.invokeAction(
          'spaces',
          'computer',
          body: {'space': widget.spaceId, 'operation': 'status'},
          timeout: const Duration(minutes: 5),
        ),
      );
      machine = _map(response['machine']).isEmpty
          ? response
          : _map(response['machine']);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _machine = machine;
      _loading = false;
    });
  }

  void _operate(String operation, String done) => run('spaces', 'computer', {
    'space': widget.spaceId,
    'operation': operation,
  }, done: done);

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    final m = _machine;
    final resources = _map(m['resources']);
    final state = '${m['state'] ?? 'none'}';
    final none = state == 'none';
    return RefreshIndicator(
      onRefresh: reload,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _Card(
            child: Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: _stateColor(state).withValues(alpha: .14),
                  child: Icon(
                    Icons.desktop_windows_outlined,
                    color: _stateColor(state),
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        none
                            ? 'No computer yet'
                            : 'Computer ${state.toLowerCase()}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (!none)
                        Text(
                          '${m['provider'] ?? ''}${m['id'] == null ? '' : ' · ${m['id']}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => none
                ? _operate('provision', 'Computer provisioned')
                : _operate('keepalive', 'Computer awake'),
            icon: Icon(
              none ? Icons.add_to_queue_rounded : Icons.power_rounded,
              size: 17,
            ),
            label: Text(none ? 'Provision' : 'Wake / keep alive'),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _SmallAction(
                icon: Icons.bedtime_outlined,
                label: 'Sleep',
                onTap: () => _operate('sleep', 'Computer asleep'),
              ),
              _SmallAction(
                icon: Icons.restart_alt_rounded,
                label: 'Replace',
                onTap: () => _operate('replace', 'Computer replaced'),
              ),
              // The desktop browser keeps its sign-ins in the workspace, so they
              // survive sleeps and replacements until they are forgotten here.
              _SmallAction(
                icon: Icons.no_accounts_outlined,
                label: 'Forget logins',
                onTap: () =>
                    _operate('forget_logins', 'Browser logins forgotten'),
              ),
              _SmallAction(
                icon: Icons.install_desktop_rounded,
                label: 'Install desktop',
                onTap: () => run('spaces', 'desktop_install', {
                  'space': widget.spaceId,
                }, done: 'Desktop installed'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Card(
            child: Column(
              children: [
                _Fact('vCPU', '${m['cpu'] ?? resources['cpu'] ?? '—'}'),
                _Fact(
                  'Memory',
                  _gigabytes(m['memory_mb'] ?? resources['memory']),
                ),
                _Fact('Disk', _gigabytes(m['disk_mb'] ?? resources['disk'])),
                _Fact('Last active', _date(m['last_active_at'])),
                _Fact('Started', _date(m['started_at'] ?? m['created_at'])),
                _Fact('Workspace', '${m['workspace'] ?? '/workspace'}'),
                _Fact(
                  'Desktop',
                  '${m['desktop'] ?? m['desktop_installed'] ?? 'not installed'}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The agent team's memory: the shared AGENTS.md and each agent's own.
class SpaceMemoryTab extends StatefulWidget {
  const SpaceMemoryTab({
    super.key,
    required this.dependencies,
    required this.spaceId,
    this.agents = const [],
  });
  final AppDependencies dependencies;
  final String spaceId;

  /// The space's agents, each of which keeps its own notes too.
  final List<Bot> agents;
  @override
  State<SpaceMemoryTab> createState() => _SpaceMemoryTabState();
}

class _SpaceMemoryTabState extends State<SpaceMemoryTab> {
  final _text = TextEditingController();

  /// The agent whose notes are open; empty for the shared notes.
  String _agent = '';
  bool _loading = true;
  bool _saving = false;

  String get _path =>
      _agent.isEmpty ? 'AGENTS.md' : '.tradera/agents/$_agent/AGENTS.md';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    var content = '';
    try {
      final result = _map(
        await widget.dependencies.service.invokeAction(
          'spaces',
          'sandbox_files',
          body: {'space': widget.spaceId, 'operation': 'read', 'path': _path},
          timeout: const Duration(minutes: 5),
        ),
      );
      content = '${result['content'] ?? result['data'] ?? ''}';
    } catch (_) {
      // No notes yet: the editor starts empty.
    }
    if (!mounted) return;
    setState(() {
      _text.text = content;
      _loading = false;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.dependencies.service.invokeAction(
        'spaces',
        'sandbox_files',
        body: {
          'space': widget.spaceId,
          'operation': 'write',
          'path': _path,
          'content': _text.text,
        },
        timeout: const Duration(minutes: 5),
      );
      if (mounted) context.showMessage('Memory saved.');
    } catch (e) {
      if (mounted) context.showMessage('Save failed: $e');
    }
    if (mounted) setState(() => _saving = false);
  }

  void _choose(String agent) {
    if (agent == _agent) return;
    setState(() => _agent = agent);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _agent.isEmpty
              ? 'Notes and instructions every agent here uses.'
              : 'This agent’s own notes.',
          style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
        ),
        if (widget.agents.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _agent,
            isExpanded: true,
            isDense: true,
            style: TextStyle(fontSize: 12, color: scheme.onSurface),
            decoration: const InputDecoration(
              labelText: 'Whose memory',
              isDense: true,
            ),
            items: [
              const DropdownMenuItem(value: '', child: Text('Shared')),
              for (final a in widget.agents)
                DropdownMenuItem(
                  value: a.id,
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => _choose(v ?? ''),
          ),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TextField(
                  controller: _text,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'AGENTS.md',
                    hintText:
                        '# Project memory\n\nDecisions, preferences and ways of working…',
                    alignLabelWithHint: true,
                  ),
                ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _loading || _saving ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 17),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

/// The space's published sandbox ports and their secure preview links.
class SpacePreviewsTab extends StatefulWidget {
  const SpacePreviewsTab({
    super.key,
    required this.dependencies,
    required this.spaceId,
  });
  final AppDependencies dependencies;
  final String spaceId;
  @override
  State<SpacePreviewsTab> createState() => _SpacePreviewsTabState();
}

class _SpacePreviewsTabState extends State<SpacePreviewsTab>
    with _SpaceActions {
  List<Map<String, dynamic>> _previews = const [];
  bool _loading = true;

  @override
  AppDependencies get dependencies => widget.dependencies;

  @override
  void initState() {
    super.initState();
    reload();
  }

  @override
  Future<void> reload() async {
    setState(() => _loading = true);
    var previews = const <Map<String, dynamic>>[];
    try {
      final listed = _map(
        await widget.dependencies.service.invokeAction(
          'spaces',
          'proxy_list',
          body: {'space': widget.spaceId},
          timeout: const Duration(minutes: 5),
        ),
      );
      previews = _maps(listed['proxies'] ?? listed['previews']);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _previews = previews;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () => run('spaces', 'proxy_create', {
            'space': widget.spaceId,
          }, done: 'Port published'),
          icon: const Icon(Icons.add_link_rounded, size: 17),
          label: const Text('Publish port'),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _previews.isEmpty
              ? Center(
                  child: Text(
                    'No previews. Publish a sandbox port to get a secure link.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: _previews.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 7),
                  itemBuilder: (context, i) {
                    final p = _previews[i];
                    return _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.language_rounded, size: 16),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${p['title'] ?? 'Port ${p['port']}'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Flexible(
                                child: AdminStatusPill(
                                  '${p['status'] ?? 'live'}',
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          SelectableText(
                            '${p['url'] ?? p['id']}',
                            style: TextStyle(
                              fontSize: 9,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            alignment: WrapAlignment.end,
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              _SmallAction(
                                icon: Icons.link_off_rounded,
                                label: 'Remove',
                                onTap: () => run('spaces', 'proxy_delete', {
                                  'proxy': p['id'],
                                }, done: 'Preview removed'),
                              ),
                              _SmallAction(
                                icon: Icons.open_in_new_rounded,
                                label: 'Open',
                                onTap: () => run('spaces', 'proxy_open', {
                                  'proxy': p['id'],
                                }, done: 'Preview opened'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(17),
    ),
    child: child,
  );
}

class _SmallAction extends StatelessWidget {
  const _SmallAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 10),
    ),
    onPressed: onTap,
    icon: Icon(icon, size: 15),
    label: Text(label, style: const TextStyle(fontSize: 11)),
  );
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : {};
List<Map<String, dynamic>> _maps(dynamic v) =>
    (v is List ? v : const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(_map)
        .toList();
double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
String _date(dynamic v) {
  if (v == null || '$v'.isEmpty) return '—';
  final d = DateTime.tryParse('$v');
  if (d == null) return '$v';
  final x = d.toLocal();
  return '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')} ${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
}

String _gigabytes(dynamic mb) =>
    mb == null ? '—' : '${(_num(mb) / 1024).toStringAsFixed(1)} GB';
Color _stateColor(String state) => state == 'awake' || state == 'running'
    ? AppColors.success
    : state == 'failed'
    ? AppColors.danger
    : state == 'starting'
    ? AppColors.warning
    : AppColors.muted;
