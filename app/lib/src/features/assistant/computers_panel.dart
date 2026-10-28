import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../app_dependencies.dart';
import 'assistant_common.dart';
import 'host_agent.dart';

final _agents = Expando<HostAgent>();

/// This app's host agent for the signed-in person (one per app).
HostAgent hostAgentFor(AppDependencies deps) =>
    _agents[deps] ??= HostAgent(deps, confirm: _confirmOnDesktop);

/// Every command and write is confirmed on the desktop itself, on top of
/// the node's own policy.
Future<bool> _confirmOnDesktop(String tool, String summary) async {
  final context = AsemanApp.navigatorKey.currentContext;
  if (context == null) return false;
  final ok = await showDialog<bool>(
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

/// The person's computers their agents may use, and on a desktop the switch
/// that lets agents use this one, limited to the folders shared here.
class ComputersPanel extends StatefulWidget {
  const ComputersPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<ComputersPanel> createState() => _ComputersPanelState();
}

class _ComputersPanelState extends State<ComputersPanel> {
  late final agent = hostAgentFor(widget.dependencies);
  late List<String> folders = [...agent.folders];
  bool busy = false;

  Future<void> _toggle(bool on, Future<void> Function() reload) async {
    setState(() => busy = true);
    try {
      if (on) {
        if (folders.isEmpty) await _addFolder();
        if (folders.isEmpty) return;
        await agent.start(folders);
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

  Future<void> _addFolder() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Share with my agents',
    );
    if (path != null && !folders.contains(path))
      setState(() => folders = [...folders, path]);
  }

  @override
  Widget build(BuildContext context) => LoadedPanel(
    title: 'Computers',
    load: () async => jsonMap(
      await widget.dependencies.service.invokeAction('hostaccess', 'hosts'),
    ),
    build: (context, data, reload) {
      final hosts = jsonList(data['hosts']);
      return ListView(
        children: [
          if (HostAgent.supported)
            PanelSection(
              title: 'This computer',
              subtitle:
                  'Your agents can read, write and run commands only inside the folders you share. Each command and write is asked here first.',
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Let agents use this computer'),
                  value: agent.running,
                  onChanged: busy ? null : (v) => _toggle(v, reload),
                ),
                for (final f in folders)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_shared_outlined),
                    title: Text(f),
                    trailing: IconButton(
                      tooltip: 'Stop sharing',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: busy
                          ? null
                          : () async {
                              setState(
                                () => folders = folders
                                    .where((x) => x != f)
                                    .toList(),
                              );
                              if (agent.running) {
                                await _toggle(folders.isNotEmpty, reload);
                              }
                            },
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            await _addFolder();
                            if (agent.running) await _toggle(true, reload);
                          },
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Share a folder'),
                  ),
                ),
              ],
            ),
          PanelSection(
            title: 'Your computers',
            subtitle: HostAgent.supported
                ? null
                : 'Open the Aseman desktop app on a computer to let your agents use it.',
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
                      widget.dependencies,
                      'hostaccess',
                      'set_enabled',
                      {'host': h['id'], 'enabled': v},
                    );
                    if (out != null) await reload();
                  },
                ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      );
    },
  );
}
