import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../computer/preview_view.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../tools/elpian_app/elpian_app_view.dart';
import '../data/plugins_api.dart';
import 'plugin_gadgets_controller.dart';

/// A plugin's screen: the same App UI host as a desk app (Elpian natively, or
/// web in the sandboxed frame), without window chrome.
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
  final String spaceId;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final service = dependencies.service;
    final space = plugin.appWide ? spaceId : plugin.spaceId;
    if (!plugin.isApp) {
      return Center(
        child: Text('This plugin has no App UI preview.',
            style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    final page = plugin.preview;
    final title = plugin.name;
    if (plugin.web || plugin.entry.isEmpty) {
      return LivePreview(
        key: ValueKey('plugin-web-${plugin.id}-$page'),
        service: service,
        spaceId: space,
        title: title,
        page: page,
      );
    }
    return LivePreview(
      key: ValueKey('plugin-elpian-${plugin.id}-$page-${plugin.entry}'),
      service: service,
      spaceId: space,
      title: title,
      page: page,
      content: (_) => ElpianAppView(
        key: ValueKey('plugin-elpian-view-${plugin.id}'),
        service: service,
        page: page,
        entry: plugin.entry,
        spaceId: space,
        roomId: roomId,
        title: title,
      ),
    );
  }
}

/// Opens a plugin as a floating gadget on its surface, or as a page when
/// placement is [PluginPlacement.page].
Future<void> openPlugin(BuildContext context, AppDependencies dependencies,
    PluginInfo plugin,
    {String spaceId = '', String roomId = '', DeskController? desk}) async {
  final gadgets = PluginGadgetsScope.maybeOf(context);

  if (plugin.appWide && gadgets != null) {
    gadgets.open(plugin.id);
    return;
  }

  if (plugin.placement != PluginPlacement.page && gadgets != null) {
    gadgets.open(plugin.id);
    return;
  }

  return openPluginPage(context, dependencies, plugin,
      spaceId: spaceId, roomId: roomId);
}

/// Opens [plugin] as a page of its own, whatever its placement.
Future<void> openPluginPage(BuildContext context, AppDependencies dependencies,
    PluginInfo plugin,
    {String spaceId = '', String roomId = ''}) {
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
