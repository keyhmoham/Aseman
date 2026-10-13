import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../shared/widgets/backend_action_ui.dart';
import '../../../shared/widgets/panel_header.dart';
import 'project_control_content.dart';

class _ProjectCall {
  const _ProjectCall(this.namespace, this.action, this.body);
  final String namespace;
  final String action;
  final Map<String, dynamic> body;
  String get label => '$namespace.$action';
}

class _ProjectArea {
  const _ProjectArea(this.label, this.icon, this.hint,
      {required this.loads, required this.actions});
  final String label;
  final IconData icon;
  final String hint;
  final List<_ProjectCall> loads;
  final List<_ProjectCall> actions;
}

/// Project facilities shared by every room: files, computer, apps, routines,
/// memory, plugins, previews and usage. Requests go directly to backend
/// actions and are pre-scoped to this project.
class ProjectControlScreen extends StatefulWidget {
  const ProjectControlScreen({
    super.key,
    required this.dependencies,
    required this.spaceId,
    required this.spaceName,
  });
  final AppDependencies dependencies;
  final String spaceId;
  final String spaceName;

  @override
  State<ProjectControlScreen> createState() => _ProjectControlScreenState();
}

class _ProjectControlScreenState extends State<ProjectControlScreen> {
  late final List<_ProjectArea> areas = [
    _ProjectArea('Computer', Icons.desktop_windows_outlined,
        'Power, desktop and machine lifecycle',
        loads: [
          _ProjectCall('spaces', 'computer',
              {'space': widget.spaceId, 'operation': 'status'}),
        ],
        actions: [
          _ProjectCall('spaces', 'computer',
              {'space': widget.spaceId, 'operation': 'provision'}),
          _ProjectCall('spaces', 'computer',
              {'space': widget.spaceId, 'operation': 'keepalive'}),
          _ProjectCall('spaces', 'computer',
              {'space': widget.spaceId, 'operation': 'sleep'}),
          _ProjectCall('spaces', 'computer',
              {'space': widget.spaceId, 'operation': 'replace'}),
          _ProjectCall('spaces', 'desktop_install', {'space': widget.spaceId}),
          _ProjectCall(
              'spaces', 'desktop_uninstall', {'space': widget.spaceId}),
        ]),
    _ProjectArea('Files', Icons.folder_open_outlined,
        'Browse, read, edit and preview the shared workspace',
        loads: [
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'list',
            'path': '/workspace'
          }),
          _ProjectCall(
              'spaces', 'file_list', {'space': widget.spaceId, 'limit': 200}),
        ],
        actions: [
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'read',
            'path': '/workspace/README.md'
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'write',
            'path': '/workspace/file.txt',
            'content': ''
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'mkdir',
            'path': '/workspace/folder'
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'delete',
            'path': '/workspace/file.txt'
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'preview',
            'path': '/workspace/file.txt'
          }),
        ]),
    _ProjectArea('Apps', Icons.apps_outlined,
        'Installed widgets, commands and app connections',
        loads: [
          _ProjectCall('spaces', 'widget_list', {'space': widget.spaceId}),
          _ProjectCall('spaces', 'tools_list', {'space': widget.spaceId}),
          _ProjectCall('tools', 'commands_list', {'space': widget.spaceId}),
        ],
        actions: [
          _ProjectCall('tools', 'invoke', {'space': widget.spaceId}),
          _ProjectCall('tools', 'connection_set', {'space': widget.spaceId}),
          _ProjectCall('spaces', 'widget_action', {'space': widget.spaceId}),
        ]),
    _ProjectArea('Routines', Icons.schedule_outlined,
        'Delayed and recurring work in project rooms',
        loads: [
          _ProjectCall('routines', 'list', {'space': widget.spaceId}),
        ],
        actions: [
          _ProjectCall('routines', 'create', {'space': widget.spaceId}),
          const _ProjectCall('routines', 'get', {}),
          const _ProjectCall('routines', 'update', {}),
          const _ProjectCall('routines', 'pause', {}),
          const _ProjectCall('routines', 'resume', {}),
          const _ProjectCall('routines', 'delete', {}),
        ]),
    _ProjectArea('Memory', Icons.psychology_outlined,
        'Shared and per-agent notes used by the agent team',
        loads: [
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'read',
            'path': 'AGENTS.md'
          }),
        ],
        actions: [
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'write',
            'path': 'AGENTS.md',
            'content': ''
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'read',
            'path': '.tradera/agents/AGENT_ID/AGENTS.md'
          }),
          _ProjectCall('spaces', 'sandbox_files', {
            'space': widget.spaceId,
            'operation': 'write',
            'path': '.tradera/agents/AGENT_ID/AGENTS.md',
            'content': ''
          }),
        ]),
    _ProjectArea('Plugins', Icons.extension_outlined,
        'MCP servers, OAuth and credentials for project tools',
        loads: [
          _ProjectCall('spaces', 'tools_list', {'space': widget.spaceId}),
          const _ProjectCall('tools', 'mcp_samples', {}),
        ],
        actions: [
          const _ProjectCall('tools', 'mcp_register', {}),
          const _ProjectCall('tools', 'mcp_update', {}),
          const _ProjectCall('tools', 'mcp_delete', {}),
          const _ProjectCall('tools', 'mcp_oauth_get', {}),
          const _ProjectCall('tools', 'mcp_oauth_set', {}),
          const _ProjectCall('tools', 'oauth_prepare', {}),
          const _ProjectCall('tools', 'oauth_exchange', {}),
          _ProjectCall('tools', 'connection_set', {'space': widget.spaceId}),
        ]),
    _ProjectArea('Previews', Icons.open_in_browser_outlined,
        'Published sandbox ports and secure preview links',
        loads: [
          _ProjectCall('spaces', 'proxy_list', {'space': widget.spaceId}),
        ],
        actions: [
          _ProjectCall('spaces', 'proxy_create', {'space': widget.spaceId}),
          const _ProjectCall('spaces', 'proxy_open', {}),
          const _ProjectCall('spaces', 'proxy_delete', {}),
        ]),
    _ProjectArea('Usage', Icons.query_stats_outlined,
        'Spend by room, agent, tool, computer and model',
        loads: [
          _ProjectCall(
              'usage', 'summary', {'space': widget.spaceId, 'limit': 500}),
          _ProjectCall('usage', 'model_summary', {'space': widget.spaceId}),
          _ProjectCall('usage', 'projects', {'space': widget.spaceId}),
        ],
        actions: [
          _ProjectCall(
              'finance', 'budget_set', {'space': widget.spaceId, 'cap': 0}),
        ]),
  ];

  int selected = 0;
  bool loading = false;
  Map<String, dynamic> results = const {};

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final area = areas[selected];
    setState(() {
      loading = true;
      results = const {};
    });
    final values = await Future.wait(area.loads.map((call) async {
      try {
        return MapEntry(
            call.label,
            await widget.dependencies.service.invokeAction(
                call.namespace, call.action,
                body: call.body, timeout: const Duration(minutes: 5)));
      } catch (error) {
        return MapEntry<String, dynamic>(call.label, {'error': '$error'});
      }
    }));
    if (!mounted || !identical(area, areas[selected])) return;
    setState(() {
      results = Map.fromEntries(values);
      loading = false;
    });
  }

  void choose(int index) {
    setState(() => selected = index);
    load();
  }

  Future<void> run(_ProjectCall call) async {
    final body = await showBackendActionForm(
      context,
      namespace: call.namespace,
      action: call.action,
      initialBody: call.body,
    );
    if (body == null || !mounted) return;
    try {
      final value = await widget.dependencies.service.invokeAction(
          call.namespace, call.action,
          body: body, timeout: const Duration(minutes: 10));
      if (!mounted) return;
      setState(() => results = {...results, call.label: value});
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${call.label} completed')));
      await load();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${call.label}: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final area = areas[selected];
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 14 : 24, compact ? 14 : 20, compact ? 14 : 24, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PanelHeader(
          icon: area.icon,
          title: area.label,
          subtitle: '${widget.spaceName} · ${area.hint}',
          onClose: () => Navigator.pop(context),
          actions: [
            IconButton(onPressed: load, icon: const Icon(Icons.refresh_rounded))
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: areas.length,
              separatorBuilder: (_, __) => const SizedBox(width: 7),
              itemBuilder: (_, index) => ChoiceChip(
                selected: selected == index,
                avatar: Icon(areas[index].icon, size: 17),
                label: Text(areas[index].label),
                onSelected: (_) => choose(index),
              ),
            )),
        const SizedBox(height: 10),
        Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : ProjectControlContent(
                    key: ValueKey(area.label),
                    area: area.label,
                    spaceId: widget.spaceId,
                    results: results,
                    onAction: (namespace, action, body) =>
                        run(_ProjectCall(namespace, action, body)),
                  )),
      ]),
    );
  }
}
