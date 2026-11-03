import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/presentation/tool_frontend_view.dart';
import '../data/plugins_api.dart';
import '../runtime/plugin_host.dart';

/// A plugin's screen: its Elpian program, drawn natively in the person's
/// theme, reaching its backend and the platform only through the plugin gate.
class PluginView extends StatelessWidget {
  const PluginView({
    super.key,
    required this.dependencies,
    required this.plugin,
    this.spaceId = '',
    this.roomId = '',
  });

  final AppDependencies dependencies;
  final PluginInfo plugin;

  /// Where it is opened (an app-wide plugin may be opened anywhere).
  final String spaceId;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final service = dependencies.service;
    final userId = dependencies.sessionController.session?.accountId ?? '';
    final space = plugin.appWide ? spaceId : plugin.spaceId;
    final host = PluginHost(PluginsApi.of(service),
        plugin: plugin, spaceId: space, roomId: roomId, userId: userId);
    return ToolFrontendView(
      key: ValueKey('plugin-${plugin.id}-$space-$roomId'),
      api: ToolsApi.of(service),
      botId: plugin.id,
      spaceId: space,
      roomId: roomId,
      userId: userId,
      extraHandlers: host.handlers(),
    );
  }
}

/// Opens a plugin where it belongs: beside the conversation on a wide screen
/// (a panel), else (and for a page) a screen of its own.
Future<void> openPlugin(BuildContext context, AppDependencies dependencies,
    PluginInfo plugin,
    {String spaceId = '', String roomId = ''}) {
  final view = PluginView(
      dependencies: dependencies,
      plugin: plugin,
      spaceId: spaceId,
      roomId: roomId);
  final wide = MediaQuery.sizeOf(context).width >= 900;
  if (wide && plugin.placement != PluginPlacement.page) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: plugin.name,
      barrierColor: Colors.black12,
      pageBuilder: (context, _, __) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 8,
          child: SizedBox(
            width: 460,
            height: double.infinity,
            child: Column(children: [
              _PluginBar(plugin: plugin),
              Expanded(child: view),
            ]),
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(plugin.name)),
      body: SafeArea(child: view),
    ),
  ));
}

class _PluginBar extends StatelessWidget {
  const _PluginBar({required this.plugin});

  final PluginInfo plugin;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: const Icon(Icons.extension_rounded),
        title: Text(plugin.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(plugin.appWide ? 'Yours, everywhere' : 'This space'),
        trailing: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      );
}

/// The plugins usable here: the person's app-wide ones and, in a space, the
/// space's. Each opens in its place; the person's own can be removed and
/// restored.
class PluginsList extends StatefulWidget {
  const PluginsList({
    super.key,
    required this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.appWideOnly = false,
    this.showRemoved = false,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final bool appWideOnly;
  final bool showRemoved;

  @override
  State<PluginsList> createState() => _PluginsListState();
}

class _PluginsListState extends State<PluginsList> {
  late final PluginsApi _api = PluginsApi.of(widget.dependencies.service);
  late Future<List<PluginInfo>> _plugins = _load();

  Future<List<PluginInfo>> _load() async {
    final all = await _api.list(
        spaceId: widget.appWideOnly ? '' : widget.spaceId,
        removed: widget.showRemoved);
    return widget.appWideOnly ? [for (final p in all) if (p.appWide) p] : all;
  }

  void _reload() => setState(() => _plugins = _load());

  Future<void> _setRemoved(PluginInfo p, bool remove) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (remove) {
        await _api.remove(p.id);
      } else {
        await _api.restore(p.id);
      }
      messenger?.showSnackBar(SnackBar(
        content: Text(remove ? '${p.name} removed' : '${p.name} restored'),
        action: remove
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  await _api.restore(p.id);
                  _reload();
                })
            : null,
      ));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not change ${p.name}: $e')));
    }
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<PluginInfo>>(
      future: _plugins,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Could not load the plugins: ${snap.error}', textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: _reload, child: const Text('Retry')),
            ]),
          );
        }
        final plugins = snap.data ?? const <PluginInfo>[];
        if (plugins.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.extension_outlined, size: 40, color: scheme.primary),
              const SizedBox(height: 10),
              const Text('No plugins yet', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                widget.appWideOnly || widget.spaceId.isEmpty
                    ? 'Ask your Aseman for one — a tracker, a board, a dashboard. It stays here for you, everywhere in the app.'
                    : 'Ask an agent here for one. It stays in this space for everyone in it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ]),
          );
        }
        return ListView(shrinkWrap: true, children: [
          for (final p in plugins)
            ListTile(
              enabled: !p.removed,
              leading: Icon(p.appWide ? Icons.extension_rounded : Icons.group_work_outlined),
              title: Text(p.name),
              subtitle: Text(
                [
                  if (p.description.isNotEmpty) p.description,
                  p.appWide ? 'Yours, everywhere' : 'This space',
                  if (p.removed) 'Removed',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: p.removed
                  ? null
                  : () => openPlugin(context, widget.dependencies, p,
                      spaceId: widget.spaceId, roomId: widget.roomId),
              trailing: p.ownerId == me
                  ? IconButton(
                      tooltip: p.removed ? 'Restore' : 'Remove',
                      icon: Icon(p.removed ? Icons.restore_rounded : Icons.delete_outline_rounded),
                      onPressed: () => _setRemoved(p, !p.removed),
                    )
                  : null,
            ),
        ]);
      },
    );
  }
}

/// The app-bar button that lists the plugins usable here.
class PluginsButton extends StatelessWidget {
  const PluginsButton({
    super.key,
    required this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.appWideOnly = false,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final bool appWideOnly;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Plugins',
        icon: const Icon(Icons.extension_outlined),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          showDragHandle: true,
          isScrollControlled: true,
          builder: (context) => SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Plugins', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                ),
                Flexible(
                  child: PluginsList(
                      dependencies: dependencies,
                      spaceId: spaceId,
                      roomId: roomId,
                      appWideOnly: appWideOnly),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// The person's app-wide plugins, removed ones included, to open, remove and
/// restore.
class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your plugins')),
        body: SafeArea(
          child: PluginsList(dependencies: dependencies, appWideOnly: true, showRemoved: true),
        ),
      );
}
