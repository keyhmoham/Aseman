import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/presentation/tool_frontend_view.dart';
import '../data/plugins_api.dart';
import '../runtime/plugin_host.dart';
import 'plugin_gadgets_controller.dart';

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

/// Opens a plugin as a floating gadget on its surface, or as a page when
/// placement is [PluginPlacement.page]. Desk plugins in a room still open on
/// the desk when a [DeskController] is in scope.
Future<void> openPlugin(BuildContext context, AppDependencies dependencies,
    PluginInfo plugin,
    {String spaceId = '', String roomId = '', DeskController? desk}) async {
  final gadgets = PluginGadgetsScope.maybeOf(context);

  if (plugin.appWide && gadgets != null) {
    gadgets.open(plugin.id);
    return;
  }

  if (plugin.placement == PluginPlacement.desk) {
    desk ??= DeskScope.maybeOf(context);
    if (desk != null) {
      Navigator.of(context).maybePop();
      await desk.open(plugin.id, title: plugin.name);
      return;
    }
  }

  if (plugin.placement != PluginPlacement.page && gadgets != null) {
    gadgets.open(plugin.id);
    return;
  }

  final view = PluginView(
      dependencies: dependencies,
      plugin: plugin,
      spaceId: spaceId,
      roomId: roomId);
  return Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(plugin.name)),
      body: SafeArea(child: view),
    ),
  ));
}

/// The plugins usable here: the person's app-wide ones and, in a space, the
/// space's. Each opens as a gadget on its surface; the person's own can be
/// removed and restored.
class PluginsList extends StatefulWidget {
  const PluginsList({
    super.key,
    required this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.appWideOnly = false,
    this.showRemoved = false,
    this.desk,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final bool appWideOnly;
  final bool showRemoved;

  /// The room's desk, for desk plugins (a sheet is not under the page's).
  final DeskController? desk;

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
      unawaited(PluginGadgetsScope.maybeOf(context)?.refresh(force: true));
      messenger?.showSnackBar(SnackBar(
        content: Text(remove ? '${p.name} removed' : '${p.name} restored'),
        action: remove
            ? SnackBarAction(
                label: 'Undo',
                onPressed: () async {
                  await _api.restore(p.id);
                  unawaited(
                      PluginGadgetsScope.maybeOf(context)?.refresh(force: true));
                  _reload();
                })
            : null,
      ));
    } catch (e) {
      messenger?.showSnackBar(
          SnackBar(content: Text('Could not change ${p.name}: $e')));
    }
    _reload();
  }

  String _where(PluginInfo p) {
    if (p.appWide) return 'Universal gadget';
    return switch (p.placement) {
      PluginPlacement.chat => 'Chat gadget',
      PluginPlacement.rail => 'Left panel gadget',
      PluginPlacement.desk => 'Desk gadget',
      PluginPlacement.page => 'Page',
    };
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
              Text('Could not load the plugins: ${snap.error}',
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              FilledButton.tonal(
                  onPressed: _reload, child: const Text('Retry')),
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
              const Text('No plugins yet',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 6),
              Text(
                widget.appWideOnly || widget.spaceId.isEmpty
                    ? 'Ask your Aseman for one — a tracker, a board, a dashboard. It floats as a gadget across home and your workspaces.'
                    : 'Ask an agent here for one. It floats as a gadget on chat, the left panel, or the desk in this space.',
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
              leading: Icon(p.appWide
                  ? Icons.extension_rounded
                  : Icons.widgets_outlined),
              title: Text(p.name),
              subtitle: Text(
                [
                  if (p.description.isNotEmpty) p.description,
                  _where(p),
                  if (p.removed) 'Removed',
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: p.removed
                  ? null
                  : () => openPlugin(context, widget.dependencies, p,
                      spaceId: widget.spaceId,
                      roomId: widget.roomId,
                      desk: widget.desk),
              trailing: p.ownerId == me
                  ? IconButton(
                      tooltip: p.removed ? 'Restore' : 'Remove',
                      icon: Icon(p.removed
                          ? Icons.restore_rounded
                          : Icons.delete_outline_rounded),
                      onPressed: () => _setRemoved(p, !p.removed),
                    )
                  : null,
            ),
        ]);
      },
    );
  }
}

/// Launches or focuses gadgets for this surface. No longer a centralized
/// plugins sheet — gadgets live on chat, the left rail, the desk, or as
/// universal floaters from Aseman chat.
class PluginsButton extends StatelessWidget {
  const PluginsButton({
    super.key,
    required this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.appWideOnly = false,
    this.desk,
    this.placement,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final bool appWideOnly;

  /// The desk desk plugins open on (else the page's [DeskScope], if any).
  final DeskController? desk;

  /// When set, only show/focus gadgets for this surface placement.
  final PluginPlacement? placement;

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Gadgets',
        icon: const Icon(Icons.extension_outlined),
        onPressed: () => _show(context),
      );

  void _show(BuildContext context) {
    final gadgets = PluginGadgetsScope.maybeOf(context);
    if (gadgets != null) {
      final list = _candidates(gadgets);
      if (list.isNotEmpty) {
        // Focus existing gadgets: open the first docked/hidden, else toggle.
        for (final p in list) {
          final mode = gadgets.layoutOf(p.id).mode;
          if (mode != PluginGadgetMode.open) {
            gadgets.open(p.id);
            return;
          }
        }
        // All open — dock them.
        for (final p in list) {
          gadgets.dock(p.id);
        }
        return;
      }
    }
    // Nothing mounted yet — fall back to a compact picker (manage / open page).
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.5),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Gadgets',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ),
            Flexible(
              child: PluginsList(
                  dependencies: dependencies,
                  spaceId: spaceId,
                  roomId: roomId,
                  appWideOnly: appWideOnly,
                  desk: desk ?? DeskScope.maybeOf(context)),
            ),
          ]),
        ),
      ),
    );
  }

  List<PluginInfo> _candidates(PluginGadgetsController gadgets) {
    if (appWideOnly || spaceId.isEmpty) {
      return gadgets.universal;
    }
    if (placement != null) {
      return [
        ...gadgets.universal,
        ...gadgets.forPlacement(placement!),
      ];
    }
    return [
      ...gadgets.universal,
      ...gadgets.forPlacement(PluginPlacement.chat),
      ...gadgets.forPlacement(PluginPlacement.rail),
      ...gadgets.forPlacement(PluginPlacement.desk),
    ];
  }
}

/// The person's app-wide plugins, removed ones included, to open, remove and
/// restore.
class PluginsPage extends StatelessWidget {
  const PluginsPage({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Your gadgets')),
        body: SafeArea(
          child: PluginsList(
              dependencies: dependencies,
              appWideOnly: true,
              showRemoved: true),
        ),
      );
}
