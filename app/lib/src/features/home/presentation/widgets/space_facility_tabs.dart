import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../data/models/bot.dart';
import '../../../../shared/widgets/backend_action_ui.dart';
import '../../../admin/presentation/admin_widgets.dart';
import '../../../computer/computer_view.dart';
import '../../../computer/space_computer.dart';

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

/// The space's computer: its screen, live, and its power. It follows the
/// node as the computer changes (whoever changed it), so it never needs
/// refreshing; its buttons wake or sleep it, replace it and open it.
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

class _SpaceComputerTabState extends State<SpaceComputerTab> {
  late SpaceComputer _computer = _of(widget);

  static SpaceComputer _of(SpaceComputerTab w) =>
      SpaceComputer.of(w.dependencies.service, w.spaceId);

  @override
  void initState() {
    super.initState();
    _computer.addListener(_changed);
  }

  @override
  void didUpdateWidget(SpaceComputerTab old) {
    super.didUpdateWidget(old);
    final next = _of(widget);
    if (identical(next, _computer)) return;
    _computer.removeListener(_changed);
    _computer = next..addListener(_changed);
  }

  @override
  void dispose() {
    _computer.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _do(Future<void> Function() action, String failed) async {
    try {
      await action();
    } catch (e) {
      if (mounted) context.showMessage('$failed: $e');
    }
  }

  Future<void> _replace() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.restart_alt_rounded),
        title: const Text('Replace the computer?'),
        content: const Text(
          'It is rebuilt from the latest image. Everything in its files is '
          'kept; programs running on it stop.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (ok == true) await _do(_computer.replace, 'Replace failed');
  }

  void _open() =>
      openComputer(context, widget.dependencies.service, widget.spaceId);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = _computer.info;
    final state = info.state;
    final loaded = _computer.loaded;
    final busy = !loaded || state.changing;
    final awake = state == ComputerState.awake;
    final specs = [
      if (info.cpu != null) '${_trim(info.cpu!)} vCPU',
      if (info.memoryMb != null) '${_gigabytes(info.memoryMb)} memory',
      if (info.diskMb != null) '${_gigabytes(info.diskMb)} disk',
    ].join(' · ');
    return ListView(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      children: [
        ComputerMonitor(computer: _computer, onOpen: _open),
        const SizedBox(height: 14),
        Row(
          children: [
            ComputerStateLight(state),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                loaded ? state.label : 'Connecting…',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          !loaded
              ? 'Reading the computer…'
              : awake && info.idleTimeout > Duration.zero
              ? 'Sleeps after ${_minutes(info.idleTimeout)} with nothing using it.'
              : state == ComputerState.none
              ? 'Wake it to start the project’s computer.'
              : state.off
              ? 'Its files are kept while it sleeps.'
              : 'This takes a few seconds.',
          style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
        ),
        if (_computer.error != null && loaded) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.cloud_off_rounded, size: 13, color: scheme.error),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  'Reconnecting to the node…',
                  style: TextStyle(fontSize: 10.5, color: scheme.error),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.open_in_full_rounded, size: 17),
          label: const Text('Open'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: busy
                    ? null
                    : () => awake
                          ? _do(_computer.sleep, 'Sleep failed')
                          : _do(_computer.wake, 'Wake failed'),
                icon: Icon(
                  awake
                      ? Icons.bedtime_outlined
                      : Icons.power_settings_new_rounded,
                  size: 17,
                ),
                label: Text(awake ? 'Sleep' : 'Wake up'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || state == ComputerState.none
                    ? null
                    : _replace,
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: const Text('Replace'),
              ),
            ),
          ],
        ),
        if (specs.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            specs,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

String _trim(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';
String _minutes(Duration d) =>
    d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';

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

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : {};
List<Map<String, dynamic>> _maps(dynamic v) =>
    (v is List ? v : const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(_map)
        .toList();
double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
String _gigabytes(dynamic mb) =>
    mb == null ? '—' : '${(_num(mb) / 1024).toStringAsFixed(1)} GB';
