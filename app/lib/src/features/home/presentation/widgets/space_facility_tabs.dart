import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../data/models/bot.dart';
import '../../../../data/services/aseman_service.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../computer/computer_view.dart';
import '../../../computer/preview_view.dart';
import '../../../computer/space_computer.dart';
import '../../../search_feed/presentation/rich_post_content.dart';

// The space's own facilities, shown as tabs of the workspace's left panel:
// its computer, the agent team's memory and the published previews. Files,
// apps, routines and usage live elsewhere (the file tree and file windows,
// the Apps tab, each room's routines and the space settings).

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

/// The agent team's memory: the shared AGENTS.md every agent reads, and
/// each agent's own notes. Written as Markdown, read back rendered.
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

  /// What is saved: the editor differs from it while there are changes.
  String _saved = '';
  bool _loading = true;
  bool _saving = false;
  bool _preview = false;

  String get _path =>
      _agent.isEmpty ? 'AGENTS.md' : '.aseman/agents/$_agent/AGENTS.md';
  bool get _dirty => !_loading && _text.text != _saved;

  @override
  void initState() {
    super.initState();
    _text.addListener(_edited);
    _load();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool _wasDirty = false;
  void _edited() {
    if (_dirty != _wasDirty) setState(() => _wasDirty = _dirty);
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
      _saved = content;
      _text.text = content;
      _loading = false;
      _wasDirty = false;
    });
  }

  Future<void> _save() async {
    if (!_dirty || _saving) return;
    setState(() => _saving = true);
    final content = _text.text;
    try {
      await widget.dependencies.service.invokeAction(
        'spaces',
        'sandbox_files',
        body: {
          'space': widget.spaceId,
          'operation': 'write',
          'path': _path,
          'content': content,
        },
        timeout: const Duration(minutes: 5),
      );
      _saved = content;
      if (mounted) context.showMessage('Memory saved');
    } catch (e) {
      if (mounted) context.showMessage('Save failed: $e');
    }
    if (mounted) {
      setState(() {
        _saving = false;
        _wasDirty = _dirty;
      });
    }
  }

  void _discard() => setState(() {
    _text.text = _saved;
    _wasDirty = false;
  });

  Future<void> _choose(String agent) async {
    if (agent == _agent) return;
    if (_dirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Discard your changes?'),
          content: const Text('These notes have changes that are not saved.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (leave != true || !mounted) return;
    }
    setState(() => _agent = agent);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = widget.agents.where((a) => a.id == _agent).firstOrNull;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            agent == null
                ? 'What every agent here knows: conventions, decisions, where things are.'
                : 'What ${agent.name} keeps for itself.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          if (widget.agents.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 34,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _WhoseChip(
                    label: 'Shared',
                    icon: Icons.groups_2_outlined,
                    selected: _agent.isEmpty,
                    onTap: () => _choose(''),
                  ),
                  for (final a in widget.agents)
                    _WhoseChip(
                      label: a.name,
                      initial: a.name.isEmpty ? '?' : a.name[0].toUpperCase(),
                      avatar: a.avatar,
                      selected: a.id == _agent,
                      onTap: () => _choose(a.id),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _dirty
                      ? scheme.primary.withValues(alpha: .55)
                      : scheme.outlineVariant.withValues(alpha: .5),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'AGENTS.md',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                _loading
                                    ? 'Loading…'
                                    : _saving
                                    ? 'Saving…'
                                    : _dirty
                                    ? 'Unsaved changes'
                                    : 'Saved',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: _dirty
                                      ? scheme.primary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: _preview ? 'Edit' : 'Preview',
                          visualDensity: VisualDensity.compact,
                          iconSize: 18,
                          isSelected: _preview,
                          onPressed: _loading
                              ? null
                              : () => setState(() => _preview = !_preview),
                          icon: const Icon(Icons.visibility_outlined),
                          selectedIcon: const Icon(Icons.edit_outlined),
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: scheme.outlineVariant.withValues(alpha: .5),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _preview
                        ? (_text.text.trim().isEmpty
                              ? Center(
                                  child: Text(
                                    'Nothing written yet.',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                )
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.all(12),
                                  child: RichPostContent(_text.text),
                                ))
                        : TextField(
                            controller: _text,
                            expands: true,
                            maxLines: null,
                            textAlignVertical: TextAlignVertical.top,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                              height: 1.5,
                            ),
                            decoration: const InputDecoration(
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.all(12),
                              hintText:
                                  '# Project memory\n\nDecisions, preferences and ways of working…',
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_dirty) ...[
                TextButton(
                  onPressed: _saving ? null : _discard,
                  child: const Text('Discard'),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: FilledButton.icon(
                  onPressed: _dirty && !_saving ? _save : null,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _dirty ? Icons.save_outlined : Icons.check_rounded,
                          size: 17,
                        ),
                  label: Text(_dirty ? 'Save' : 'Saved'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WhoseChip extends StatelessWidget {
  const _WhoseChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.initial,
    this.avatar = '',
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? initial;

  /// The agent's picture, shown over its initial.
  final String avatar;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        labelStyle: const TextStyle(fontSize: 11.5),
        avatar: icon != null
            ? Icon(icon, size: 16)
            : CircleAvatar(
                backgroundColor: scheme.tertiaryContainer,
                foregroundImage: Avatars.of(avatar),
                onForegroundImageError: avatar.isEmpty ? null : (_, __) {},
                child: Text(
                  initial ?? '',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
        label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// The pages the space's computer serves through the node's gateway, each
/// shown as a small browser window: live while the computer is awake, dark
/// while it sleeps. Opening one wakes the computer and starts its app when
/// needed, then shows it on the desk or in a sheet.
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

class _SpacePreviewsTabState extends State<SpacePreviewsTab> {
  late final SpaceComputer _computer = SpaceComputer.of(
    widget.dependencies.service,
    widget.spaceId,
  );
  List<PublishedPreview> _previews = const [];
  bool _loading = true;
  String _rev = '';

  @override
  void initState() {
    super.initState();
    _computer.addListener(_computerChanged);
    reload();
  }

  @override
  void dispose() {
    _computer.removeListener(_computerChanged);
    super.dispose();
  }

  void _computerChanged() {
    if (!mounted) return;
    // A computer that changed may have new previews (an agent publishing
    // one as it works): read them again.
    if (_computer.info.rev != _rev) {
      _rev = _computer.info.rev;
      unawaited(reload(quiet: true));
    }
    setState(() {});
  }

  Future<void> reload({bool quiet = false}) async {
    if (!quiet) setState(() => _loading = true);
    var previews = _previews;
    try {
      final listed = _map(
        await widget.dependencies.service.invokeAction(
          'spaces',
          'proxy_list',
          body: {'space': widget.spaceId},
          timeout: const Duration(minutes: 1),
        ),
      );
      previews = [
        for (final m in _maps(listed['proxies'] ?? listed['previews']))
          PublishedPreview.fromJson(m),
      ].where((p) => p.kind == 'preview').toList();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _previews = previews;
      _loading = false;
    });
  }

  void _open(PublishedPreview p) => openPreview(
    context,
    widget.dependencies.service,
    spaceId: widget.spaceId,
    page: p.page,
    title: p.title,
  );

  Future<void> _publish() async {
    final published = await showDialog<PublishedPreview>(
      context: context,
      builder: (_) => _PublishDialog(
        service: widget.dependencies.service,
        spaceId: widget.spaceId,
      ),
    );
    if (published == null || !mounted) return;
    await reload(quiet: true);
    if (mounted) context.showMessage('${published.title} published');
  }

  Future<void> _remove(PublishedPreview p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.link_off_rounded),
        title: Text('Remove ${p.title}?'),
        content: const Text(
          'Its link stops working. The app itself keeps running on the '
          'computer and can be published again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.dependencies.service.invokeAction(
        'spaces',
        'proxy_delete',
        body: {'proxy': p.id},
      );
      setState(() => _previews = [..._previews]..remove(p));
    } catch (e) {
      if (mounted) context.showMessage('Remove failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = _computer.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.tonalIcon(
          onPressed: _publish,
          icon: const Icon(Icons.add_link_rounded, size: 17),
          label: const Text('Publish a port'),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: reload,
                  child: _previews.isEmpty
                      ? ListView(
                          children: [
                            const SizedBox(height: 40),
                            Icon(
                              Icons.web_asset_rounded,
                              size: 40,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'No previews yet',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'When an app runs on the computer, publish its '
                              'port to open it here. Agents publish what they '
                              'build too.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: _previews.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) => _PreviewCard(
                            service: widget.dependencies.service,
                            preview: _previews[i],
                            state: state,
                            onOpen: () => _open(_previews[i]),
                            onRemove: () => _remove(_previews[i]),
                          ),
                        ),
                ),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.service,
    required this.preview,
    required this.state,
    required this.onOpen,
    required this.onRemove,
  });
  final AsemanService service;
  final PublishedPreview preview;
  final ComputerState state;
  final VoidCallback onOpen;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PreviewThumbnail(
                service: service,
                preview: preview,
                state: state,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preview.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'Port ${preview.port}',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    child: const Text('Open'),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    iconSize: 19,
                    padding: EdgeInsets.zero,
                    onSelected: (v) => switch (v) {
                      'copy' => copyPreviewLink(context, service, preview.page),
                      _ => onRemove(),
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'copy',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.link_rounded),
                          title: Text('Copy link'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.link_off_rounded),
                          title: Text('Remove'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Publishes a port of the computer: what is served there gets a link.
class _PublishDialog extends StatefulWidget {
  const _PublishDialog({required this.service, required this.spaceId});
  final AsemanService service;
  final String spaceId;
  @override
  State<_PublishDialog> createState() => _PublishDialogState();
}

class _PublishDialogState extends State<_PublishDialog> {
  final _port = TextEditingController();
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _port.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'A port is a number from 1 to 65535.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = _map(
        await widget.service.invokeAction(
          'spaces',
          'proxy_create',
          body: {
            'space': widget.spaceId,
            'port': port,
            if (_name.text.trim().isNotEmpty) 'title': _name.text.trim(),
          },
          // Publishing wakes the computer when it sleeps.
          timeout: const Duration(minutes: 5),
        ),
      );
      if (!mounted) return;
      Navigator.pop(
        context,
        PublishedPreview.fromJson({...r, 'id': r['proxy_id'] ?? r['id']}),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.add_link_rounded),
    title: const Text('Publish a port'),
    content: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Gives what an app serves on the computer a private link that '
            'members of this space can open.',
            style: TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _port,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'Port',
              hintText: '3000',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              hintText: 'My app',
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Publish'),
      ),
    ],
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
