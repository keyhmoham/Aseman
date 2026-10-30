import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/post.dart';
import '../../../data/models/space.dart';
import '../domain/feed_post.dart';

class SearchFeedViewModel extends ChangeNotifier {
  SearchFeedViewModel({
    this.dependencies,
    String workspace = 'Home',
  }) : _workspace = workspace;

  final AppDependencies? dependencies;

  String _workspace;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  static const pageSize = 20;

  /// The two sources the Following feed mixes: posts of the people and
  /// agents the caller follows, and the private posts of their spaces.
  List<SocialPost> _serverFollowing = [];
  List<SocialPost> _serverSpaces = [];
  final _offsets = [0, 0];
  final _hasMore = [true, true];
  Map<String, String> _spaceNames = {};

  String get workspace => _workspace;

  /// Loads the first page of the feed and the caller's spaces (for post
  /// space names). Chats and the spaces grid live in MessengerPanel /
  /// WorkspacePicker.
  Future<void> load() async {
    final deps = dependencies?.service;
    if (deps == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        deps.fetchFeed(following: true, limit: pageSize),
        deps.fetchSpacesFeed(limit: pageSize),
        deps.fetchSpaces(),
      ]);
      _serverFollowing = (results[0] as List).cast<SocialPost>();
      _serverSpaces = (results[1] as List).cast<SocialPost>();
      final spaces = (results[2] as List).cast<Workspace>();
      _spaceNames = {for (final sp in spaces) sp.id: sp.name};
      _offsets[0] = _serverFollowing.length;
      _offsets[1] = _serverSpaces.length;
      _hasMore[0] = _serverFollowing.length >= pageSize;
      _hasMore[1] = _serverSpaces.length >= pageSize;
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// Fetches the next page of each source that has more and appends it.
  Future<void> loadMore() async {
    if (loading || loadingMore || !_hasMore.contains(true)) return;
    final deps = dependencies?.service;
    if (deps == null) return;
    loadingMore = true;
    notifyListeners();
    try {
      final pages = await Future.wait([
        _hasMore[0]
            ? deps.fetchFeed(
                following: true, limit: pageSize, offset: _offsets[0])
            : Future.value(const <SocialPost>[]),
        _hasMore[1]
            ? deps.fetchSpacesFeed(limit: pageSize, offset: _offsets[1])
            : Future.value(const <SocialPost>[]),
      ]);
      for (final (i, page) in pages.indexed) {
        if (!_hasMore[i]) continue;
        (i == 0 ? _serverFollowing : _serverSpaces).addAll(page);
        _offsets[i] += page.length;
        _hasMore[i] = page.length >= pageSize;
      }
    } catch (e) {
      error = e.toString();
    }
    loadingMore = false;
    notifyListeners();
  }

  /// Publish a post from the composer; returns the created post id or null.
  Future<String?> publish(String body) async {
    final deps = dependencies?.service;
    if (deps == null) return null;
    try {
      final post = await deps.createPost(body);
      await load();
      return post.id;
    } catch (e) {
      error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// Likes or unlikes a post right away and tells the server; a failure
  /// puts it back.
  Future<void> toggleLike(String postId, bool liked) async {
    final deps = dependencies?.service;
    if (deps == null) return;
    _update(postId, (p) => _liked(p, !liked));
    try {
      if (liked) {
        await deps.unlikePost(postId);
      } else {
        await deps.likePost(postId);
      }
    } catch (_) {
      _update(postId, (p) => _liked(p, liked));
    }
  }

  static SocialPost _liked(SocialPost p, bool liked) => p.likedByMe == liked
      ? p
      : p.withLike(
          likes: liked ? p.likes + 1 : (p.likes > 0 ? p.likes - 1 : 0),
          likedByMe: liked);

  /// Shows the new [body] of a post its author edited.
  void edited(String postId, String body) =>
      _update(postId, (p) => p.copyWith(body: body, editedAt: DateTime.now()));

  /// Drops a post its author deleted.
  void deleted(String postId) {
    _serverFollowing.removeWhere((p) => p.id == postId);
    _serverSpaces.removeWhere((p) => p.id == postId);
    notifyListeners();
  }

  void _update(String postId, SocialPost Function(SocialPost) change) {
    for (final list in [_serverFollowing, _serverSpaces]) {
      final i = list.indexWhere((p) => p.id == postId);
      if (i >= 0) list[i] = change(list[i]);
    }
    notifyListeners();
  }

  void setWorkspace(String value) {
    if (_workspace == value) return;
    _workspace = value;
    notifyListeners();
  }

  /// The Following feed: posts of the people and agents the caller follows
  /// mixed with the posts of their spaces, newest first. Each source is paged
  /// on its own, so the list stops at the oldest post every source that has
  /// more has reached: older posts of one source appear once the other's
  /// next page has loaded, keeping the order right.
  List<FeedPost> get followingPosts {
    final byId = <String, SocialPost>{
      for (final p in [..._serverFollowing, ..._serverSpaces]) p.id: p,
    };
    DateTime? cutoff;
    for (final (i, list) in [_serverFollowing, _serverSpaces].indexed) {
      if (!_hasMore[i] || list.isEmpty) continue;
      final last = list.last.createdAt;
      if (cutoff == null || last.isAfter(cutoff)) cutoff = last;
    }
    final mixed = byId.values
        .where((p) => cutoff == null || !p.createdAt.isBefore(cutoff))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return mixed.map(_feedFromServer).toList();
  }

  /// Map a server post onto the UI feed card model.
  FeedPost _feedFromServer(SocialPost p) =>
      feedPostFromServer(p, workspace: _spaceNames[p.spaceId]);
}

/// A server post as the feed's card shows it; [workspace] names the space
/// it was posted in.
FeedPost feedPostFromServer(SocialPost p, {String? workspace}) => FeedPost(
      initials: _initialsOf(p.authorId),
      name: p.authorName.isNotEmpty
          ? p.authorName
          : p.authorHandle.isNotEmpty
              ? '@${p.authorHandle}'
              : '@${p.authorId.substring(0, 8)}',
      handle: p.authorHandle.isNotEmpty
          ? '@${p.authorHandle}'
          : '@${p.authorId.substring(0, 12)}',
      time: _timeAgo(p.createdAt),
      body: p.body,
      tag: p.tags.isEmpty ? 'POST' : p.tags.first.toUpperCase(),
      likes: compactCount(p.likes),
      comments: compactCount(p.comments),
      color: feedColorFor(p.id),
      liked: p.likedByMe,
      serverId: p.id,
      workspace: workspace,
      media: p.attachments,
      source: p.source,
      avatar: p.authorAvatar,
      authorId: p.authorId,
      spaceId: p.spaceId,
      edited: p.editedAt != null,
      forwardOf: p.forwardOf,
      forwardAuthorId: p.forwardAuthorId,
      forwardName: p.forwardAuthorName.isNotEmpty
          ? p.forwardAuthorName
          : p.forwardAuthorHandle.isNotEmpty
              ? '@${p.forwardAuthorHandle}'
              : 'a post',
      forwardHandle: p.forwardAuthorHandle,
      forwardAvatar: p.forwardAuthorAvatar,
    );

String _initialsOf(String id) {
  if (id.length < 4) return 'OC';
  final h = id.hashCode;
  return '${_upper((h & 0xff).toRadixString(16))}${_upper(((h >> 8) & 0xff).toRadixString(16))}';
}

String _upper(String s) => s.toUpperCase();

/// The accent colour the feed gives [id] (a post or an account).
Color feedColorFor(String id) {
  const palette = [
    AppColors.primary,
    AppColors.cyan,
    AppColors.success,
    AppColors.warning,
    Color(0xFF14B8A6),
    Color(0xFFF97316),
    Color(0xFFEC4899),
    Color(0xFF3B82F6),
    Color(0xFF6366F1),
  ];
  return palette[id.hashCode.abs() % palette.length];
}

/// [n] as a short count: 1.2K for 1200.
String compactCount(int n) {
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return '$n';
}

String _timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}
