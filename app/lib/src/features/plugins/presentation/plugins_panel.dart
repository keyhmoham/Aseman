import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/presentation/tool_frontend_view.dart';
import '../data/plugins_api.dart';
import 'plugin_gadgets_controller.dart';

/// A plugin's screen: its Elpian program drawn natively in the person's theme
/// (or its web document in the sandboxed frame), reaching its backend and the
/// platform only through the plugin gate.
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
    // The frontend view gives the screen its plugin gate (and, for Elpian,
    // the SDK and the plugin shim; for web, the sandboxed frame).
    return ToolFrontendView(
      key: ValueKey('plugin-${plugin.id}-$space-$roomId'),
      api: ToolsApi.of(service),
      botId: plugin.id,
      spaceId: space,
      roomId: roomId,
      userId: userId,
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

