/// A social feed post as returned by the posts namespace.
import 'dart:convert';

import 'uploaded_file.dart';

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
    this.attachments = const [],
    this.source = '',
    this.authorName = '',
    this.authorHandle = '',
    this.authorAvatar = '',
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

  /// The post's images, GIFs and videos (stored files, streamed from their
  /// content url).
  final List<UploadedFile> attachments;

  /// Where an imported post was first published ("coinmarketcap"); empty for
  /// posts made here.
  final String source;

  /// Who posted it, as the node described them: their name, handle and
  /// picture (a stored file's id); empty when it did not.
  final String authorName;
  final String authorHandle;
  final String authorAvatar;

  bool get isComment => parentId.isNotEmpty;

  factory SocialPost.fromJson(Map<String, dynamic> json) {
    final likedBy = _strings(json['liked_by']);
    final author = json['author'] is Map
        ? (json['author'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
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
      attachments: [
        for (final a in json['attachments'] as List? ?? const [])
          if (a is Map<String, dynamic>) UploadedFile.fromJson(a),
      ],
      source: json['source'] as String? ?? '',
      authorName: '${author['display_name'] ?? ''}',
      authorHandle: '${author['handle'] ?? ''}',
      authorAvatar: '${author['avatar'] ?? ''}',
    );
  }

  /// This post with another like state.
  SocialPost withLike({required int likes, required bool likedByMe}) =>
      SocialPost(
        id: id,
        authorId: authorId,
        body: body,
        createdAt: createdAt,
        spaceId: spaceId,
        parentId: parentId,
        tags: tags,
        likes: likes,
        likedByMe: likedByMe,
        attachments: attachments,
        source: source,
        authorName: authorName,
        authorHandle: authorHandle,
        authorAvatar: authorAvatar,
      );

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
