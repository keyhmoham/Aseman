import 'package:flutter/material.dart';

import '../../../data/models/uploaded_file.dart';

/// A normalized signal/post shown in the search feed.
class FeedPost {
  const FeedPost({
    required this.initials,
    required this.name,
    required this.handle,
    required this.time,
    required this.body,
    required this.tag,
    required this.likes,
    required this.comments,
    required this.color,
    this.coin,
    this.verified = false,
    this.chart = false,
    this.pinned = false,
    this.liked = false,
    this.serverId,
    this.workspace,
    this.media = const [],
    this.source = '',
    this.avatar = '',
    this.authorId = '',
    this.spaceId = '',
    this.edited = false,
    this.forwardOf = '',
    this.forwardAuthorId = '',
    this.forwardName = '',
    this.forwardHandle = '',
    this.forwardAvatar = '',
  });

  final String initials;
  final String name;
  final String handle;
  final String time;
  final String body;
  final String tag;
  final String likes;
  final String comments;
  final Color color;
  final String? coin;
  final bool verified;
  final bool chart;
  final bool pinned;

  /// Whether the current user liked this post (server-backed).
  final bool liked;

  /// The server post id (posts namespace), when this card is server-backed.
  final String? serverId;

  /// The name of the workspace this post belongs to (private workspace posts).
  final String? workspace;

  /// The post's images, GIFs and videos.
  final List<UploadedFile> media;

  /// Where an imported post was first published ("coinmarketcap").
  final String source;

  /// The author's picture (a stored file's id), "" when they have none.
  final String avatar;

  /// Who posted it (their account id) and the space it was posted in ("" for
  /// the global feed).
  final String authorId;
  final String spaceId;

  /// Whether its author changed it after posting.
  final bool edited;

  /// The post this one shares ("" for an original post) and who wrote that
  /// original: their account id, name, handle and picture.
  final String forwardOf;
  final String forwardAuthorId;
  final String forwardName;
  final String forwardHandle;
  final String forwardAvatar;

  bool get isForward => forwardOf.isNotEmpty;

  /// The same post, liked or not, with [likes], or with another [body].
  FeedPost copyWith(
          {bool? liked, String? likes, String? body, bool? edited}) =>
      FeedPost(
        initials: initials,
        name: name,
        handle: handle,
        time: time,
        body: body ?? this.body,
        tag: tag,
        likes: likes ?? this.likes,
        comments: comments,
        color: color,
        coin: coin,
        verified: verified,
        chart: chart,
        pinned: pinned,
        liked: liked ?? this.liked,
        serverId: serverId,
        workspace: workspace,
        media: media,
        source: source,
        avatar: avatar,
        authorId: authorId,
        spaceId: spaceId,
        edited: edited ?? this.edited,
        forwardOf: forwardOf,
        forwardAuthorId: forwardAuthorId,
        forwardName: forwardName,
        forwardHandle: forwardHandle,
        forwardAvatar: forwardAvatar,
      );
}
