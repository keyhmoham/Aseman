import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../data/tools_api.dart';
import 'a2ui_view.dart';
import 'tool_frontend_view.dart';

/// A widget an agent composed (ui_compose), as a room message: A2UI built
/// from the space's tools' data, embedding tools' own frontends
/// (`ToolFrontend`), each of which fetches its own data for whoever looks.
class ComposedWidgetCard extends StatelessWidget {
  const ComposedWidgetCard({
    super.key,
    required this.body,
    required this.spaceId,
    this.roomId = '',
    this.dependencies,
    this.senderName = '',
  });

  /// The message body: `{title, messages}`.
  final String body;
  final String spaceId;
  final String roomId;
  final AppDependencies? dependencies;
  final String senderName;

  /// The composed widget a message body holds, or null when it holds none.
  static ({String title, List<Map<String, dynamic>> messages})? parse(
      String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final messages = [
        for (final m in (decoded['messages'] as List?) ?? const <dynamic>[])
          if (m is Map) m.cast<String, dynamic>(),
      ];
      if (messages.isEmpty) return null;
      return (title: '${decoded['title'] ?? ''}', messages: messages);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final widgetSpec = parse(body);
    final deps = dependencies;
    final api = deps == null ? null : ToolsApi.of(deps.service);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Row(children: [
            Icon(Icons.dashboard_customize_outlined,
                size: 16, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  widgetSpec?.title.isNotEmpty == true
                      ? widgetSpec!.title
                      : 'Widget',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800)),
            ),
            if (senderName.isNotEmpty)
              Text(senderName,
                  style:
                      TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          child: widgetSpec == null
              ? Text('This widget could not be read.',
                  style: TextStyle(color: scheme.onSurfaceVariant))
              : A2UIView(
                  messages: widgetSpec.messages,
                  toolFrontend: (context, botId, height, shown) => SizedBox(
                    height: height,
                    child: api == null
                        ? const Center(
                            child: Text('Sign in to open this tool.'))
                        : ToolFrontendView(
                            api: api,
                            botId: botId,
                            spaceId: spaceId,
                            roomId: roomId,
                            userId:
                                deps?.sessionController.session?.accountId ??
                                    '',
                            shown: shown),
                  ),
                ),
        ),
      ]),
    );
  }
}
