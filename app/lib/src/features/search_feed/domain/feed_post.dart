import 'package:flutter/material.dart';

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
}
