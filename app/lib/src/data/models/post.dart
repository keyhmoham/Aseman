/// A social feed post as returned by the posts namespace.
import 'dart:convert';

class SocialPost {
  const SocialPost({
    required this.id,
    required this.authorId,
    required this.body,
    required this.createdAt,
    this.spaceId = '',
    this.parentId = '',
    this.tags = const [],
    this.likes = 0,
    this.likedByMe = false,
  });

  final String id;
  final String authorId;
  final String spaceId;
  final String parentId;
  final String body;
  final DateTime createdAt;
  final List<String> tags;
  final int likes;
  final bool likedByMe;

  bool get isComment => parentId.isNotEmpty;

  factory SocialPost.fromJson(Map<String, dynamic> json) {
    final likedBy = _strings(json['liked_by']);
    return SocialPost(
      id: json['id'] as String? ?? '',
      authorId: json['author_id'] as String? ?? '',
      spaceId: json['space_id'] as String? ?? '',
      parentId: json['parent_id'] as String? ?? '',
      body: json['body'] as String? ?? '',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
      tags: _strings(json['tags']),
      likes: (json['likes'] as num?)?.toInt() ?? likedBy.length,
      likedByMe: false,
    );
  }

  static List<String> _strings(dynamic raw) {
    if (raw is List) {
      return raw.map((e) => e.toString()).toList();
    }
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) return decoded.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return const [];
  }
}
