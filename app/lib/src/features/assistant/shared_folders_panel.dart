import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../shared/widgets/overlay_panels.dart';

import '../../app.dart';
import '../../app_dependencies.dart';
import 'assistant_common.dart';
import 'host_agent.dart';
import '../../shared/widgets/glass_surface.dart';

final _agents = Expando<HostAgent>();

/// This app's host agent for the signed-in person (one per app).
HostAgent hostAgentFor(AppDependencies deps) =>
    _agents[deps] ??= HostAgent(deps, confirm: _confirmOnDesktop);

/// Every command and write is confirmed on the desktop itself, on top of
/// the node's own policy.
Future<bool> _confirmOnDesktop(String tool, String summary) async {
  final context = AsemanApp.navigatorKey.currentContext;
  if (context == null) return false;
  final ok = await showAppDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: Text(
        tool == 'host_exec'
            ? 'An agent wants to run a command'
            : 'An agent wants to change a file',
      ),
      content: SelectableText(
        summary,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Refuse'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// The folders a person shares with their own agents. They come from the
/// person's project computers: a folder of one project's workspace, which
/// their agents in every project then read (or, with write access, change).
/// Only where an administrator allowed agents on people's own computers does
/// a desktop app also offer "This computer", limited to folders shared there.
class SharedFoldersPanel extends StatefulWidget {
  const SharedFoldersPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<SharedFoldersPanel> createState() => _SharedFoldersPanelState();
}

class _SharedFoldersPanelState extends State<SharedFoldersPanel> {
  late final agent = hostAgentFor(widget.dependencies);
  late List<String> hostFolders = [...agent.folders];
  Map<String, String> projectNames = const {};
  bool busy = false;

  AppDependencies get deps => widget.dependencies;

  Future<Map<String, dynamic>> _load() async {
    final service = deps.service;
    final status = jsonMap(await service.invokeAction('hostaccess', 'status'));
    final hostOn = status['host_enabled'] == true;
    final spaces = await service.fetchSpaces();
    projectNames = {for (final s in spaces) s.id: s.name};
    final hosts = hostOn
        ? jsonList(
            jsonMap(await service.invokeAction('hostaccess', 'hosts'))['hosts'],
          )
        : const <Map<String, dynamic>>[];
    return {...status, 'hosts': hosts};
  }

  Future<void> _share(Future<void> Function() reload) async {
    final picked = await showAppDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) =>
          ProjectFolderPicker(dependencies: deps, projects: projectNames),
    );
    if (picked == null || !mounted) return;
    final out = await runAction(
      context,
      deps,
      'hostaccess',
      'folder_share',
      picked,
      'Shared: your agents in every project can use it',
    );
    if (out != null) await reload();
  }

  Future<void> _toggleHost(bool on, Future<void> Function() reload) async {
    setState(() => busy = true);
    try {
      if (on) {
        if (hostFolders.isEmpty) await _addHostFolder();
        if (hostFolders.isEmpty) return;
        await agent.start(hostFolders);
      } else {
        await agent.stop();
      }
      await reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorText(e))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addHostFolder() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Share with my agents',
    );
    if (path != null && !hostFolders.contains(path))
      setState(() => hostFolders = [...hostFolders, path]);
  }

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Shared folders',
    load: _load,
    build: (context, data, reload) {
      final folders = jsonList(data['folders']);
      final hostOn = data['host_enabled'] == true;
      return ListView(
        children: [
          PanelSection(
            title: 'From your projects',
            subtitle:
                'Share a folder of a project\'s computer with your agents in every project. '
                'It stays on that computer; they read it, or change it if you allow writing.',
            children: [
              if (folders.isEmpty) const Text('Nothing shared yet.'),
              for (final f in folders)
                AppCard(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.folder_shared_outlined),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${f['name']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Switch(
                              value: f['enabled'] == true,
                              onChanged: (v) async {
                                final out = await runAction(
                                  context,
                                  deps,
                                  'hostaccess',
                                  'folder_set',
                                  {
                                    'id': f['id'],
                                    'access': f['access'],
                                    'enabled': v,
                                  },
                                );
                                if (out != null) await reload();
                              },
                            ),
                          ],
                        ),
                        Text(
                          '${projectNames[f['space_id']] ?? 'A project'} · /workspace/${f['path']}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        Row(
                          children: [
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'read',
                                  label: Text('Read'),
                                ),
                                ButtonSegment(
                                  value: 'write',
                                  label: Text('Read and write'),
                                ),
                              ],
                              selected: {'${f['access']}'},
                              onSelectionChanged: (v) async {
                                final out = await runAction(
                                  context,
                                  deps,
                                  'hostaccess',
                                  'folder_set',
                                  {
                                    'id': f['id'],
                                    'access': v.first,
                                    'enabled': f['enabled'] == true,
                                  },
                                );
                                if (out != null) await reload();
                              },
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () async {
                                final out = await runAction(
                                  context,
                                  deps,
                                  'hostaccess',
                                  'folder_unshare',
                                  {'id': f['id']},
                                  'No longer shared',
                                );
                                if (out != null) await reload();
                              },
                              child: const Text('Stop sharing'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: projectNames.isEmpty ? null : () => _share(reload),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Share a folder'),
                ),
              ),
            ],
          ),
          if (hostOn && HostAgent.supported) _thisComputer(reload),
          if (hostOn) _hosts(jsonList(data['hosts']), reload),
          if (!hostOn && HostAgent.supported)
            const PanelSection(
              title: 'This computer',
              children: [
                Text(
                  'Agents cannot reach people\'s own computers on this node: an administrator decides that. '
                  'Share folders from your projects instead.',
                ),
              ],
            ),
          const SizedBox(height: 32),
        ],
      );
    },
  );

  Widget _thisComputer(Future<void> Function() reload) => PanelSection(
    title: 'This computer',
    subtitle:
        'Your administrator allows agents on people\'s own computers. They work only inside the folders '
        'you share here, and each command and write is asked here first.',
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Let agents use this computer'),
        value: agent.running,
        onChanged: busy ? null : (v) => _toggleHost(v, reload),
      ),
      for (final f in hostFolders)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: Text(f),
          trailing: IconButton(
            tooltip: 'Stop sharing',
            icon: const Icon(Icons.close_rounded),
            onPressed: busy
                ? null
                : () async {
                    setState(
                      () => hostFolders = hostFolders
                          .where((x) => x != f)
                          .toList(),
                    );
                    if (agent.running)
                      await _toggleHost(hostFolders.isNotEmpty, reload);
                  },
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: busy
              ? null
              : () async {
                  await _addHostFolder();
                  if (agent.running) await _toggleHost(true, reload);
                },
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Share a folder of this computer'),
        ),
      ),
    ],
  );

  Widget _hosts(
    List<Map<String, dynamic>> hosts,
    Future<void> Function() reload,
  ) => PanelSection(
    title: 'Your computers',
    children: [
      if (hosts.isEmpty) const Text('None connected.'),
      for (final h in hosts)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: const Icon(Icons.computer_rounded),
          title: Text('${h['name']} · ${h['platform']}'),
          subtitle: Text(jsonStrings(h['folders']).join('\n')),
          value: h['enabled'] == true,
          onChanged: (v) async {
            final out = await runAction(
              context,
              deps,
              'hostaccess',
              'set_enabled',
              {'host': h['id'], 'enabled': v},
            );
            if (out != null) await reload();
          },
        ),
    ],
  );
}

/// Picks a folder of one of the person's project computers: the project,
/// then the folder, browsing its workspace, and the access agents get.
class ProjectFolderPicker extends StatefulWidget {
  const ProjectFolderPicker({
    super.key,
    required this.dependencies,
    required this.projects,
    this.initialSpace = '',
    this.attach = false,
  });
  final AppDependencies dependencies;
  final Map<String, String> projects;

  /// The project to start in (the conversation's, when it has a computer).
  final String initialSpace;

  /// Picking attaches the folder to a message (else it is only shared).
  final bool attach;

  @override
  State<ProjectFolderPicker> createState() => _ProjectFolderPickerState();
}

class _ProjectFolderPickerState extends State<ProjectFolderPicker> {
  late String space = widget.projects.containsKey(widget.initialSpace)
      ? widget.initialSpace
      : widget.projects.keys.first;
  String path = '';
  String access = 'read';
  List<String> dirs = const [];
  String note = '';
  bool loading = false;

  @override
  void initState() {
    super.initState();
    _list();
  }

  Future<void> _list() async {
    setState(() {
      loading = true;
      note = '';
    });
    try {
      final out = jsonMap(
        await widget.dependencies.service.invokeAction(
          'spaces',
          'sandbox_files',
          body: {'space': space, 'operation': 'list', 'path': path},
        ),
      );
      final items = jsonList(out['items']);
      setState(() {
        dirs = [
          for (final i in items)
            if (i['type'] == 'dir') '${i['name']}',
        ]..sort();
        note = out['ok'] == false
            ? '${out['error'] ?? ''}'
            : (items.isEmpty ? 'This folder is empty.' : '');
      });
    } catch (e) {
      setState(() => note = errorText(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _open(String next) {
    path = next;
    _list();
  }

  @override
  Widget build(BuildContext context) {
    final parts = path.isEmpty ? <String>[] : path.split('/');
    return AlertDialog(
      title: Text(widget.attach ? 'Attach a project folder' : 'Share a folder'),
      content: SizedBox(
        width: 440,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: space,
              decoration: const InputDecoration(labelText: 'Project'),
              items: [
                for (final p in widget.projects.entries)
                  DropdownMenuItem(value: p.key, child: Text(p.value)),
              ],
              onChanged: (v) {
                if (v == null) return;
                space = v;
                _open('');
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => _open(''),
                  child: const Text('workspace'),
                ),
                for (var i = 0; i < parts.length; i++) ...[
                  const Icon(Icons.chevron_right_rounded, size: 16),
                  TextButton(
                    onPressed: () => _open(parts.sublist(0, i + 1).join('/')),
                    child: Text(parts[i]),
                  ),
                ],
              ],
            ),
            if (loading) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                children: [
                  if (note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(note),
                    ),
                  for (final d in dirs)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(d),
                      onTap: () => _open(path.isEmpty ? d : '$path/$d'),
                    ),
                ],
              ),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'read', label: Text('Read')),
                ButtonSegment(value: 'write', label: Text('Read and write')),
              ],
              selected: {access},
              onSelectionChanged: (v) => setState(() => access = v.first),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.attach)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              openPanel(context, SharedFoldersPanel(dependencies: widget.dependencies));
            },
            child: const Text('Manage shared folders'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'space': space,
            'path': path,
            'access': access,
          }),
          child: Text(
            '${widget.attach ? 'Attach' : 'Share'} ${path.isEmpty ? 'the whole workspace' : parts.last}',
          ),
        ),
      ],
    );
  }
}


/// Lets the person pick a folder of one of their project computers to attach
/// to a message: it is shared with their own agents (read, or read and
/// write) and returned for the message to carry as "folder:<id>". Returns
/// null when cancelled.
Future<Map<String, dynamic>?> attachProjectFolder(
    BuildContext context, AppDependencies deps,
    {String initialSpace = ''}) async {
  final spaces = await deps.service.fetchSpaces();
  if (!context.mounted) return null;
  if (spaces.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have no projects with a computer yet.')));
    return null;
  }
  final picked = await showAppDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => ProjectFolderPicker(
        dependencies: deps,
        projects: {for (final s in spaces) s.id: s.name},
        initialSpace: initialSpace,
        attach: true),
  );
  if (picked == null || !context.mounted) return null;
  final out = await runAction(context, deps, 'hostaccess', 'folder_share', picked);
  final folder = jsonMap(out?['folder']);
  return folder.isEmpty ? null : folder;
}
