import 'package:flutter/material.dart';

import '../../../core/formatting/billing_units.dart';
import '../../../core/theme/app_colors.dart';
import '../../admin/presentation/admin_widgets.dart';

typedef ProjectAction = Future<void> Function(
    String namespace, String action, Map<String, dynamic> initialBody);

class ProjectControlContent extends StatefulWidget {
  const ProjectControlContent({
    super.key,
    required this.area,
    required this.spaceId,
    required this.results,
    required this.onAction,
  });
  final String area;
  final String spaceId;
  final Map<String, dynamic> results;
  final ProjectAction onAction;
  @override
  State<ProjectControlContent> createState() => _ProjectControlContentState();
}

class _ProjectControlContentState extends State<ProjectControlContent> {
  final search = TextEditingController();
  @override
  void didUpdateWidget(covariant ProjectControlContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.area != widget.area) search.clear();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        key: PageStorageKey(widget.area),
        padding: const EdgeInsets.only(top: 2, bottom: 28),
        children: [
          switch (widget.area) {
            'Computer' => _computer(),
            'Files' => _files(),
            'Apps' => _apps(),
            'Routines' => _routines(),
            'Memory' => _memory(),
            'Plugins' => _plugins(),
            'Previews' => _previews(),
            'Usage' => _usage(),
            _ => const SizedBox.shrink(),
          }
        ],
      );

  Widget _computer() {
    final response = _map(widget.results['spaces.computer']);
    final machine = _map(response['machine']).isEmpty
        ? response
        : _map(response['machine']);
    final state = '${machine['state'] ?? 'none'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant)),
        child: Row(children: [
          CircleAvatar(
              radius: 28,
              backgroundColor: _stateColor(state).withValues(alpha: .14),
              child: Icon(Icons.desktop_windows_outlined,
                  color: _stateColor(state), size: 29)),
          const SizedBox(width: 16),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    state == 'none'
                        ? 'No computer provisioned'
                        : 'Computer ${state.toLowerCase()}',
                    style: const TextStyle(
                        fontSize: 19, fontWeight: FontWeight.w900)),
                const SizedBox(height: 3),
                Text(
                    '${machine['provider'] ?? ''}${machine['id'] == null ? '' : ' · ${machine['id']}'}',
                    style: const TextStyle(color: AppColors.muted))
              ])),
          AdminStatusPill(state),
        ]),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
            onPressed: () =>
                _computerAction(state == 'none' ? 'provision' : 'keepalive'),
            icon: Icon(state == 'none'
                ? Icons.add_to_queue_rounded
                : Icons.power_rounded),
            label: Text(
                state == 'none' ? 'Provision computer' : 'Wake / keep alive')),
        OutlinedButton.icon(
            onPressed: () => _computerAction('sleep'),
            icon: const Icon(Icons.bedtime_outlined),
            label: const Text('Sleep')),
        OutlinedButton.icon(
            onPressed: () => _computerAction('replace'),
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Replace')),
        OutlinedButton.icon(
            onPressed: () => widget.onAction(
                'spaces', 'desktop_install', {'space': widget.spaceId}),
            icon: const Icon(Icons.install_desktop_rounded),
            label: const Text('Install desktop')),
      ]),
      const SizedBox(height: 18),
      AdminGrid(minTileWidth: 150, children: [
        AdminStatCard(
            label: 'vCPU',
            value:
                '${machine['cpu'] ?? _map(machine['resources'])['cpu'] ?? '—'}',
            icon: Icons.memory_rounded),
        AdminStatCard(
            label: 'Memory',
            value: _memorySize(
                machine['memory_mb'] ?? _map(machine['resources'])['memory']),
            icon: Icons.developer_board_outlined),
        AdminStatCard(
            label: 'Disk',
            value: _memorySize(
                machine['disk_mb'] ?? _map(machine['resources'])['disk']),
            icon: Icons.storage_outlined),
        AdminStatCard(
            label: 'Last active',
            value: _date(machine['last_active_at']),
            icon: Icons.schedule_rounded),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Machine details',
          child: Column(children: [
            AdminKeyValue('Started',
                _date(machine['started_at'] ?? machine['created_at'])),
            AdminKeyValue('Provider sandbox',
                '${machine['sandbox_id'] ?? machine['id'] ?? '—'}',
                mono: true),
            AdminKeyValue(
                'Workspace', '${machine['workspace'] ?? '/workspace'}',
                mono: true),
            AdminKeyValue('Desktop',
                '${machine['desktop'] ?? machine['desktop_installed'] ?? 'not installed'}')
          ])),
    ]);
  }

  void _computerAction(String operation) => widget.onAction(
      'spaces', 'computer', {'space': widget.spaceId, 'operation': operation});

  Widget _files() {
    final sandbox = _map(widget.results['spaces.sandbox_files']);
    final uploaded = _maps(_map(widget.results['spaces.file_list'])['files']);
    final files = _maps(sandbox['files'] ?? sandbox['entries']);
    final all = files
        .where((f) =>
            search.text.isEmpty ||
            '${f['name']} ${f['path']}'
                .toLowerCase()
                .contains(search.text.toLowerCase()))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: AdminSearchField(
                controller: search,
                hint: 'Search workspace files',
                onChanged: (_) => setState(() {}))),
        const SizedBox(width: 8),
        OutlinedButton.icon(
            onPressed: () => widget.onAction('spaces', 'sandbox_files', {
                  'space': widget.spaceId,
                  'operation': 'mkdir',
                  'path': '/workspace/folder'
                }),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('New folder')),
        const SizedBox(width: 8),
        FilledButton.icon(
            onPressed: () => widget.onAction('spaces', 'sandbox_files', {
                  'space': widget.spaceId,
                  'operation': 'write',
                  'path': '/workspace/file.txt',
                  'content': ''
                }),
            icon: const Icon(Icons.note_add_outlined),
            label: const Text('New file')),
      ]),
      const SizedBox(height: 14),
      AdminDataTable(
        empty: 'The shared workspace is empty.',
        columns: const [
          AdminTableColumn('Name', width: 360),
          AdminTableColumn('Kind', width: 100),
          AdminTableColumn('Size', width: 110, align: TextAlign.right),
          AdminTableColumn('Modified', width: 170),
          AdminTableColumn('Actions', width: 190, align: TextAlign.right)
        ],
        rows: [
          for (final f in all)
            [
              _fileCell(f),
              Text(f['directory'] == true || f['type'] == 'directory'
                  ? 'Folder'
                  : '${f['type'] ?? 'File'}'),
              Text(_bytes(f['size']), textAlign: TextAlign.right),
              Text(_date(f['modified_at'] ?? f['updated_at'])),
              Wrap(alignment: WrapAlignment.end, children: [
                IconButton(
                    tooltip: 'Open',
                    onPressed: () => widget.onAction(
                            'spaces', 'sandbox_files', {
                          'space': widget.spaceId,
                          'operation': 'read',
                          'path': f['path']
                        }),
                    icon: const Icon(Icons.open_in_new_rounded, size: 18)),
                IconButton(
                    tooltip: 'Preview',
                    onPressed: () => widget.onAction(
                            'spaces', 'sandbox_files', {
                          'space': widget.spaceId,
                          'operation': 'preview',
                          'path': f['path']
                        }),
                    icon: const Icon(Icons.visibility_outlined, size: 18)),
                IconButton(
                    tooltip: 'Delete',
                    onPressed: () => widget.onAction(
                            'spaces', 'sandbox_files', {
                          'space': widget.spaceId,
                          'operation': 'delete',
                          'path': f['path']
                        }),
                    icon: const Icon(Icons.delete_outline_rounded, size: 18))
              ])
            ]
        ],
      ),
      if (uploaded.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'Room uploads',
            child: Column(children: [
              for (final f in uploaded)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_fileIcon('${f['mime'] ?? f['name']}')),
                    title: Text('${f['name']}'),
                    subtitle: Text(
                        '${_bytes(f['size'])} · ${_date(f['created_at'])}'),
                    trailing: const Icon(Icons.download_outlined))
            ])),
      ],
    ]);
  }

  Widget _apps() {
    final widgets =
        _maps(_map(widget.results['spaces.widget_list'])['widgets']);
    final tools = _maps(_map(widget.results['spaces.tools_list'])['tools']);
    final commands =
        _maps(_map(widget.results['tools.commands_list'])['commands']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _cards(
          'Installed apps',
          widgets,
          Icons.widgets_outlined,
          (row) => widget.onAction('spaces', 'widget_action', {
                'space': widget.spaceId,
                'widget': row['id'],
                'action': 'open'
              })),
      const SizedBox(height: 18),
      _cards(
          'Connected tools',
          tools,
          Icons.build_outlined,
          (row) => widget.onAction(
              'tools', 'invoke', {'space': widget.spaceId, 'bot': row['id']})),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Commands (${commands.length})',
          child: commands.isEmpty
              ? const Text('No commands are exposed by installed tools.')
              : Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final c in commands)
                    ActionChip(
                        avatar: const Icon(Icons.terminal_rounded, size: 16),
                        label: Text('/${c['name'] ?? c['command']}'),
                        onPressed: () => widget.onAction('tools', 'invoke', {
                              'space': widget.spaceId,
                              'function': c['name'] ?? c['command']
                            }))
                ]))
    ]);
  }

  Widget _cards(String title, List<Map<String, dynamic>> rows, IconData icon,
          ValueChanged<Map<String, dynamic>> open) =>
      AdminSectionCard(
          title: '$title (${rows.length})',
          child: rows.isEmpty
              ? Text('No ${title.toLowerCase()} yet.')
              : Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final row in rows)
                    SizedBox(
                        width: 260,
                        child: Card(
                            child: ListTile(
                                leading: Icon(icon),
                                title: Text(
                                    '${row['name'] ?? row['title'] ?? row['id']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800)),
                                subtitle: Text(
                                    '${row['description'] ?? row['status'] ?? ''}',
                                    maxLines: 2),
                                trailing:
                                    const Icon(Icons.arrow_forward_rounded),
                                onTap: () => open(row))))
                ]));

  Widget _routines() {
    final rows = _maps(_map(widget.results['routines.list'])['routines']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
              onPressed: () => widget
                  .onAction('routines', 'create', {'space': widget.spaceId}),
              icon: const Icon(Icons.add_alarm_rounded),
              label: const Text('New routine'))),
      const SizedBox(height: 14),
      AdminDataTable(
          empty: 'No delayed or recurring work in this project.',
          columns: const [
            AdminTableColumn('Routine', width: 270),
            AdminTableColumn('Schedule', width: 190),
            AdminTableColumn('Room', width: 160),
            AdminTableColumn('Status', width: 120),
            AdminTableColumn('Next run', width: 170),
            AdminTableColumn('Actions', width: 190, align: TextAlign.right)
          ],
          rows: [
            for (final r in rows)
              [
                _primary(
                    '${r['name'] ?? r['prompt'] ?? 'Routine'}', '${r['id']}'),
                Text('${r['schedule'] ?? r['cron'] ?? r['run_at'] ?? '—'}'),
                Text('${r['room_name'] ?? r['room_id'] ?? '—'}'),
                AdminStatusPill(
                    '${r['status'] ?? (r['paused'] == true ? 'paused' : 'active')}'),
                Text(_date(r['next_run_at'])),
                Wrap(alignment: WrapAlignment.end, children: [
                  IconButton(
                      tooltip: r['paused'] == true ? 'Resume' : 'Pause',
                      onPressed: () => widget.onAction(
                          'routines',
                          r['paused'] == true ? 'resume' : 'pause',
                          {'routine': r['id']}),
                      icon: Icon(
                          r['paused'] == true
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          size: 18)),
                  IconButton(
                      tooltip: 'Edit',
                      onPressed: () => widget
                          .onAction('routines', 'update', {'routine': r['id']}),
                      icon: const Icon(Icons.edit_outlined, size: 18)),
                  IconButton(
                      tooltip: 'Delete',
                      onPressed: () => widget
                          .onAction('routines', 'delete', {'routine': r['id']}),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18))
                ])
              ]
          ]),
    ]);
  }

  Widget _memory() {
    final result = _map(widget.results['spaces.sandbox_files']);
    final content = '${result['content'] ?? result['data'] ?? ''}';
    return _MemoryEditor(
        key: ValueKey(content),
        content: content,
        onSave: (text) => widget.onAction('spaces', 'sandbox_files', {
              'space': widget.spaceId,
              'operation': 'write',
              'path': 'AGENTS.md',
              'content': text
            }),
        onAgent: () => widget.onAction('spaces', 'sandbox_files', {
              'space': widget.spaceId,
              'operation': 'read',
              'path': '.tradera/agents/AGENT_ID/AGENTS.md'
            }));
  }

  Widget _plugins() {
    final installed = _maps(_map(widget.results['spaces.tools_list'])['tools']);
    final samples = _maps(_map(widget.results['tools.mcp_samples'])['samples']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
              onPressed: () =>
                  widget.onAction('tools', 'mcp_register', const {}),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add MCP server'))),
      const SizedBox(height: 14),
      AdminSectionCard(
          title: 'Project connections (${installed.length})',
          padding: EdgeInsets.zero,
          child: installed.isEmpty
              ? const AdminEmptyState('No project plugins',
                  'Connect an MCP server or tool to this project.')
              : Column(children: [
                  for (final p in installed)
                    ListTile(
                        leading: const CircleAvatar(
                            child: Icon(Icons.extension_outlined)),
                        title: Text('${p['name'] ?? p['id']}',
                            style:
                                const TextStyle(fontWeight: FontWeight.w800)),
                        subtitle: Text('${p['url'] ?? p['description'] ?? ''}'),
                        trailing: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 5,
                            children: [
                              AdminStatusPill('${p['status'] ?? 'ready'}'),
                              IconButton(
                                  tooltip: 'Connection',
                                  onPressed: () => widget.onAction(
                                          'tools', 'connection_set', {
                                        'space': widget.spaceId,
                                        'bot': p['id']
                                      }),
                                  icon: const Icon(Icons.link_rounded)),
                              IconButton(
                                  tooltip: 'OAuth',
                                  onPressed: () => widget.onAction('tools',
                                      'oauth_prepare', {'bot': p['id']}),
                                  icon: const Icon(Icons.login_rounded))
                            ]))
                ])),
      if (samples.isNotEmpty) ...[
        const SizedBox(height: 18),
        AdminSectionCard(
            title: 'MCP catalog',
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in samples)
                ActionChip(
                    avatar: const Icon(Icons.add_circle_outline, size: 17),
                    label: Text('${s['name'] ?? s['url']}'),
                    onPressed: () => widget.onAction('tools', 'mcp_register',
                        {'name': s['name'], 'url': s['url']}))
            ]))
      ],
    ]);
  }

  Widget _previews() {
    final rows = _maps(_map(widget.results['spaces.proxy_list'])['proxies'] ??
        _map(widget.results['spaces.proxy_list'])['previews']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
              onPressed: () => widget.onAction(
                  'spaces', 'proxy_create', {'space': widget.spaceId}),
              icon: const Icon(Icons.add_link_rounded),
              label: const Text('Publish port'))),
      const SizedBox(height: 14),
      if (rows.isEmpty)
        const AdminEmptyState('No previews',
            'Publish a sandbox port to create a secure preview link.',
            icon: Icons.open_in_browser_outlined)
      else
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final p in rows)
            SizedBox(
                width: 320,
                child: Card(
                    child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                const Icon(Icons.language_rounded),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: Text(
                                        '${p['title'] ?? 'Port ${p['port']}'}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900))),
                                AdminStatusPill('${p['status'] ?? 'live'}')
                              ]),
                              const SizedBox(height: 8),
                              SelectableText('${p['url'] ?? p['id']}',
                                  style: const TextStyle(
                                      fontSize: 11, color: AppColors.muted)),
                              const SizedBox(height: 10),
                              Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    TextButton(
                                        onPressed: () => widget.onAction(
                                            'spaces',
                                            'proxy_delete',
                                            {'proxy': p['id']}),
                                        child: const Text('Remove')),
                                    FilledButton.tonal(
                                        onPressed: () => widget.onAction(
                                            'spaces',
                                            'proxy_open',
                                            {'proxy': p['id']}),
                                        child: const Text('Open'))
                                  ])
                            ]))))
        ]),
    ]);
  }

  Widget _usage() {
    final summary = _map(widget.results['usage.summary']);
    final models = _map(widget.results['usage.model_summary']);
    final total = summary['spent'] ?? summary['total'];
    final events = _maps(summary['events']);
    final byModel = _maps(models['models'] ?? models['by_model']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        FilledButton.tonalIcon(
            onPressed: () => widget.onAction(
                'finance', 'budget_set', {'space': widget.spaceId, 'cap': 0}),
            icon: const Icon(Icons.tune_rounded),
            label: const Text('Set budget'))
      ]),
      const SizedBox(height: 12),
      AdminGrid(minTileWidth: 150, children: [
        AdminStatCard(
            label: 'Total spend',
            value: _credits(total),
            hint: _usd(total),
            icon: Icons.query_stats_rounded),
        AdminStatCard(
            label: 'Agent time',
            value: _credits(summary['agent_time']),
            icon: Icons.smart_toy_outlined),
        AdminStatCard(
            label: 'Computer',
            value: _credits(summary['compute']),
            icon: Icons.computer_outlined),
        AdminStatCard(
            label: 'Models & tools',
            value: _credits(_num(summary['llm']) + _num(summary['tools'])),
            icon: Icons.memory_outlined),
      ]),
      const SizedBox(height: 18),
      AdminSectionCard(
          title: 'Models',
          child: byModel.isEmpty
              ? const Text('No model usage yet.')
              : Column(children: [
                  for (final m in byModel)
                    AdminKeyValue('${m['model'] ?? m['label']}',
                        '${m['tokens_in'] ?? 0} in · ${m['tokens_out'] ?? 0} out · ${m['calls'] ?? 0} calls')
                ])),
      const SizedBox(height: 18),
      AdminDataTable(empty: 'No usage events yet.', columns: const [
        AdminTableColumn('When', width: 170),
        AdminTableColumn('Kind', width: 130),
        AdminTableColumn('Agent / tool', width: 220),
        AdminTableColumn('Room', width: 160),
        AdminTableColumn('Charge', width: 130, align: TextAlign.right)
      ], rows: [
        for (final e in events)
          [
            Text(_date(e['created_at'])),
            Text('${e['kind'] ?? e['type']}'),
            Text('${e['bot_name'] ?? e['tool_name'] ?? '—'}'),
            Text('${e['room_name'] ?? e['room_id'] ?? '—'}'),
            Text(_credits(e['charged'] ?? e['amount']),
                textAlign: TextAlign.right)
          ]
      ]),
    ]);
  }

  Widget _fileCell(Map<String, dynamic> f) => Row(children: [
        Icon(
            f['directory'] == true || f['type'] == 'directory'
                ? Icons.folder_rounded
                : _fileIcon('${f['name']}'),
            size: 19,
            color: f['directory'] == true ? AppColors.warning : AppColors.cyan),
        const SizedBox(width: 9),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${f['name'] ?? f['path']}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          Text('${f['path'] ?? ''}',
              style: const TextStyle(fontSize: 10, color: AppColors.muted),
              overflow: TextOverflow.ellipsis)
        ]))
      ]);
}

class _MemoryEditor extends StatefulWidget {
  const _MemoryEditor(
      {super.key,
      required this.content,
      required this.onSave,
      required this.onAgent});
  final String content;
  final ValueChanged<String> onSave;
  final VoidCallback onAgent;
  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late final TextEditingController controller =
      TextEditingController(text: widget.content);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
              child: Text(
                  'Shared notes and instructions every agent in this project can use.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant))),
          OutlinedButton(
              onPressed: widget.onAgent, child: const Text('Per-agent memory')),
          const SizedBox(width: 8),
          FilledButton.icon(
              onPressed: () => widget.onSave(controller.text),
              icon: const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save'))
        ]),
        const SizedBox(height: 14),
        TextField(
            controller: controller,
            minLines: 18,
            maxLines: 36,
            style: const TextStyle(
                fontFamily: 'monospace', fontSize: 12, height: 1.45),
            decoration: const InputDecoration(
                labelText: 'AGENTS.md',
                hintText:
                    '# Project memory\n\nDecisions, preferences and ways of working…',
                alignLabelWithHint: true)),
      ]);
}

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? v.map((k, x) => MapEntry('$k', x)) : {};
List<dynamic> _list(dynamic v) => v is List ? v : const [];
List<Map<String, dynamic>> _maps(dynamic v) =>
    _list(v).whereType<Map<dynamic, dynamic>>().map(_map).toList();
double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
String _credits(dynamic v) =>
    v == null ? '—' : formatLedgerCredits(_num(v), exact: true);
String _usd(dynamic v) => formatLedgerUsd(_num(v));
String _date(dynamic v) {
  if (v == null || '$v'.isEmpty) return '—';
  final d = DateTime.tryParse('$v');
  if (d == null) return '$v';
  final x = d.toLocal();
  return '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')} ${x.hour.toString().padLeft(2, '0')}:${x.minute.toString().padLeft(2, '0')}';
}

String _bytes(dynamic v) {
  var n = _num(v);
  if (n <= 0) return '—';
  const u = ['B', 'KiB', 'MiB', 'GiB'];
  var i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return '${n.toStringAsFixed(n >= 10 ? 0 : 1)} ${u[i]}';
}

String _memorySize(dynamic mb) =>
    mb == null ? '—' : '${(_num(mb) / 1024).toStringAsFixed(1)} GB';
Color _stateColor(String state) => state == 'awake' || state == 'running'
    ? AppColors.success
    : state == 'failed'
        ? AppColors.danger
        : state == 'starting'
            ? AppColors.warning
            : AppColors.muted;
IconData _fileIcon(String name) {
  final x = name.toLowerCase();
  if (x.endsWith('.png') || x.endsWith('.jpg') || x.contains('image/'))
    return Icons.image_outlined;
  if (x.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
  if (x.endsWith('.mp4') || x.contains('video/')) return Icons.movie_outlined;
  if (x.endsWith('.dart') ||
      x.endsWith('.js') ||
      x.endsWith('.ts') ||
      x.endsWith('.go')) return Icons.code_rounded;
  return Icons.insert_drive_file_outlined;
}

Widget _primary(String a, String b) =>
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(a, style: const TextStyle(fontWeight: FontWeight.w800)),
      if (b.isNotEmpty)
        Text(b, style: const TextStyle(fontSize: 10, color: AppColors.muted))
    ]);
