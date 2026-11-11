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
  factory AgUiSurface.question(String question, {List<String> options = const []}) =>
      AgUiSurface(
        layout: 'chat',
        title: 'Question',
        root: {
          'c': 'Question',
          'p': {
            'question': question,
            'options': options,
            'allowFreeText': true,
          },
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

final _fence = RegExp(r'```(?:agui|surface)\s*\n([\s\S]*?)\n```', multiLine: true);

/// Parse the first AG-UI fence from a chat [body]. Returns surface + remaining
/// caption text (fence stripped).
({AgUiSurface? surface, String caption}) parseAgUiBody(String body) {
  final m = _fence.firstMatch(body);
  if (m == null) return (surface: null, caption: body);
  try {
    final raw = jsonDecode(m.group(1)!.trim());
    if (raw is! Map) return (surface: null, caption: body);
    final surface = AgUiSurface.fromJson(Map<String, dynamic>.from(raw));
    final caption = body.replaceFirst(m.group(0)!, '').trim();
    return (surface: surface, caption: caption);
  } catch (_) {
    return (surface: null, caption: body);
  }
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
  return const [];
}
