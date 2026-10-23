/// A surface in a window: laid out as an app screen when its theme says
/// `{"layout": "app"}` — it gets the window's height and its regions scroll
/// inside it — and otherwise as a page that scrolls as a whole.
library;

import 'package:flutter/material.dart';

import '../protocol/events.dart';

/// Whether [messages] create a surface laid out as an app screen.
bool isAppLayout(List<Map<String, dynamic>> messages) {
  for (final m in messages) {
    if (m['type'] == AgUiEventType.custom &&
        m['name'] == AgUiSurfaceEvent.create) {
      final value = m['value'];
      if (value is Map) {
        if (value['layout'] == 'app') return true;
        final theme = value['theme'];
        if (theme is Map && theme['layout'] == 'app') return true;
      }
    }
    final create = m['createSurface'];
    if (create is Map) {
      final theme = create['theme'];
      if (theme is Map && theme['layout'] == 'app') return true;
    }
  }
  return false;
}

/// Hosts [child], the surface [messages] create, in a window.
class AgUiFrame extends StatelessWidget {
  const AgUiFrame({
    super.key,
    required this.messages,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final List<Map<String, dynamic>> messages;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (!isAppLayout(messages)) {
      return SingleChildScrollView(padding: padding, child: child);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // A window with no height of its own (inside something that
        // scrolls): shown as a page after all.
        if (!constraints.hasBoundedHeight) {
          return Padding(padding: padding, child: child);
        }
        return Padding(
          padding: padding,
          child: SizedBox(
            height: (constraints.maxHeight - padding.vertical).clamp(
              0,
              double.infinity,
            ),
            child: child,
          ),
        );
      },
    );
  }
}
