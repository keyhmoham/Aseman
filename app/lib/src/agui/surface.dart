import 'dart:convert';

/// Aseman AG-UI surface for in-chat generative UI (decillion.surface/v1).
class AgUiSurface {
  const AgUiSurface({
    this.surfaceId = '',
    this.version = 'decillion.surface/v1',
    this.layout = 'chat',
    this.title = '',
    this.root,
    this.data = const {},
  });

  final String surfaceId;
  final String version;
  final String layout;
  final String title;
  final Map<String, dynamic>? root;
  final Map<String, dynamic> data;

  bool get isChat => layout.isEmpty || layout == 'chat';

  factory AgUiSurface.fromJson(Map<String, dynamic> json) {
    final root = json['root'];
    return AgUiSurface(
      surfaceId: '${json['surfaceId'] ?? ''}',
      version: '${json['version'] ?? 'decillion.surface/v1'}',
      layout: '${json['layout'] ?? 'chat'}',
      title: '${json['title'] ?? ''}',
      root: root is Map<String, dynamic>
          ? Map<String, dynamic>.from(root)
          : root is Map
          ? Map<String, dynamic>.from(root)
          : null,
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'] as Map)
          : const {},
    );
  }

  /// Builds a HITL question card (same shape ask_user / ui_present emit).
  factory AgUiSurface.question(
    String question, {
    List<String> options = const [],
  }) => AgUiSurface(
    layout: 'chat',
    title: 'Question',
    root: {
      'c': 'Question',
      'p': {'question': question, 'options': options, 'allowFreeText': true},
    },
  );

  Map<String, dynamic> toJson() => {
    if (surfaceId.isNotEmpty) 'surfaceId': surfaceId,
    'version': version,
    'layout': layout,
    if (title.isNotEmpty) 'title': title,
    if (root != null) 'root': root,
    if (data.isNotEmpty) 'data': data,
  };
}

final _fence = RegExp(
  r'```(?:agui|surface)[ \t]*\r?\n([\s\S]*?)\r?\n[ \t]*```',
  multiLine: true,
);

/// A fence that has been opened and not closed yet: an answer still being
/// written.
final _openFence = RegExp(r'```(?:agui|surface)[ \t]*(?:\r?\n[\s\S]*)?$');

/// Parse the first AG-UI fence from a chat [body]. Returns surface + remaining
/// caption text (fence stripped). `pending` is true while the card is still
/// being written (its fence is open): half a JSON tree is never shown as
/// text, the caller shows a placeholder instead.
({AgUiSurface? surface, String caption, bool pending}) parseAgUiBody(
  String body,
) {
  final m = _fence.firstMatch(body);
  if (m == null) {
    final open = _openFence.firstMatch(body);
    if (open != null) {
      return (
        surface: null,
        caption: body.substring(0, open.start).trim(),
        pending: true,
      );
    }
    return (surface: null, caption: body, pending: false);
  }
  try {
    final raw = jsonDecode(m.group(1)!.trim());
    if (raw is! Map) return (surface: null, caption: body, pending: false);
    final surface = AgUiSurface.fromJson(Map<String, dynamic>.from(raw));
    final caption = body.replaceFirst(m.group(0)!, '').trim();
    return (surface: surface, caption: caption, pending: false);
  } catch (_) {
    return (surface: null, caption: body, pending: false);
  }
}

/// Cards that bring their own frame (a question, an approval…): shown alone
/// the surface does not box them a second time or repeat their title.
const _framed = {
  'Question',
  'Choices',
  'Confirm',
  'Form',
  'Approval',
  'Secret',
  'Handover',
  'Suggestion',
  'Connect',
};

bool isFramedRoot(Map<String, dynamic>? root) =>
    root != null && _framed.contains(typeOf(root));

/// A surface's title when it adds something: not one a card repeats, nor a
/// type's own name.
String visibleTitle(AgUiSurface surface) {
  final title = surface.title.trim();
  final root = surface.root;
  if (title.isEmpty || root == null) return title;
  if (isFramedRoot(root)) return '';
  final rootTitle = '${propsOf(root)['title'] ?? ''}'.trim();
  if (rootTitle.isNotEmpty && rootTitle.toLowerCase() == title.toLowerCase()) {
    return '';
  }
  return title;
}

/// Chart props as the UI kit reads them. AG-UI often sends `points`
/// (`{label, value}`) where the kit reads `data` / `values` / `rows`.
Map<String, dynamic> chartPropsForKit(Map<String, dynamic> props) {
  final next = Map<String, dynamic>.from(props);
  final data =
      props['data'] ?? props['rows'] ?? props['values'] ?? props['points'];
  if (data != null) next['data'] = data;
  if (next['type'] == null && next['kind'] == null) next['type'] = 'bar';
  return next;
}

/// Callout props: AG-UI uses `tone` and `content` / `message`; the kit
/// reads `severity` and `text`.
Map<String, dynamic> calloutPropsForKit(Map<String, dynamic> props) {
  final next = Map<String, dynamic>.from(props);
  final tone = '${props['tone'] ?? props['kind'] ?? ''}'.toLowerCase();
  if (props['severity'] == null && props['status'] == null && tone.isNotEmpty) {
    next['severity'] = switch (tone) {
      'warning' || 'caution' => 'warning',
      'error' || 'danger' || 'important' => 'critical',
      'success' || 'tip' || 'good' => 'good',
      _ => 'info',
    };
  }
  next['text'] ??= props['content'] ?? props['message'] ?? props['body'];
  return next;
}

String typeOf(Map<String, dynamic> node) {
  for (final k in ['c', 'type', '\$type', 'component']) {
    final v = node[k];
    if (v is String && v.trim().isNotEmpty) return v.trim();
  }
  return '';
}

Map<String, dynamic> propsOf(Map<String, dynamic> node) {
  final p = node['p'] ?? node['props'];
  if (p is Map<String, dynamic>) return Map<String, dynamic>.from(p);
  if (p is Map) return Map<String, dynamic>.from(p);
  return {};
}

List<dynamic> childrenOf(Map<String, dynamic> node) {
  final c = node['children'] ?? node['items'];
  if (c is List) return c;
  // Agents often nest the body under props: {c, p: {title, children}}.
  final nested = propsOf(node)['children'];
  if (nested is List) return nested;
  return const [];
}
