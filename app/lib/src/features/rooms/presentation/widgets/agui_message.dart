/// Inline AG-UI Surface Spec surface rendered inside a chat bubble.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../../agui/agui.dart';

/// Parses a KindAgui message body `{title, messages, layout}` into a compact
/// chat surface.
class AgUiChatMessage extends StatelessWidget {
  const AgUiChatMessage({super.key, required this.body, this.maxHeight = 420});

  /// JSON body from the room message.
  final String body;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(body);
      payload = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return Text(body, style: Theme.of(context).textTheme.bodySmall);
    }
    final title = '${payload['title'] ?? ''}';
    final messages = [
      for (final m in (payload['messages'] as List?) ?? const [])
        if (m is Map) Map<String, dynamic>.from(m),
    ];
    if (messages.isEmpty) {
      return Text(title.isEmpty ? 'UI' : title);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: FrontendPresentation(
            display: FrontendDisplay.full,
            child: AgUiView(
              messages: messages,
              // Chat surfaces are self-contained; host actions are no-ops here
              // unless a parent wires them later.
            ),
          ),
        ),
      ],
    );
  }
}
