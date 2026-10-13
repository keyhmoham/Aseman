import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/post.dart';
import '../../../data/models/space.dart';
import '../domain/feed_post.dart';
import '../domain/trader.dart';

class SearchFeedViewModel extends ChangeNotifier {
  SearchFeedViewModel({
    this.dependencies,
    String workspace = 'Home',
  }) : _workspace = workspace;

  final AppDependencies? dependencies;

  String _workspace;
  String query = '';
  bool loading = false;
  bool loadingMore = false;
  String? error;
  static const pageSize = 20;
  List<SocialPost> _serverGlobal = [];
  List<SocialPost> _serverFollowing = [];
  List<SocialPost> _serverSpaces = [];
  List<SocialPost> _serverMine = [];
  final _offsets = [0, 0, 0, 0];
  final _hasMore = [true, true, true, true];
  Map<String, String> _spaceNames = {};
  List<Trader> _serverTraders = const [];

  String get workspace => _workspace;

  /// Loads the first page of every feed tab from the server.
  Future<void> load() async {
    final deps = dependencies?.service;
    if (deps == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final me = dependencies?.sessionController.session?.accountId ?? '';
      final results = await Future.wait([
        deps.fetchFeed(following: false, limit: pageSize),
        deps.fetchFeed(following: true, limit: pageSize),
        deps.fetchLeaderboard(limit: 10),
        deps.fetchSpacesFeed(limit: pageSize),
        me.isEmpty
            ? Future.value(const <SocialPost>[])
            : deps.fetchUserPosts(me, limit: pageSize),
        deps.fetchSpaces(),
      ]);
      _serverGlobal = (results[0] as List).cast<SocialPost>();
      _serverFollowing = (results[1] as List).cast<SocialPost>();
      _serverTraders = (results[2] as List<Map<String, dynamic>>)
          .map(_traderFromServer)
          .toList();
      _serverSpaces = (results[3] as List).cast<SocialPost>();
      _serverMine = (results[4] as List).cast<SocialPost>();
      _spaceNames = {
        for (final sp in (results[5] as List).cast<Workspace>()) sp.id: sp.name,
      };
      _offsets[0] = _serverGlobal.length;
      _offsets[1] = _serverFollowing.length;
      _offsets[2] = _serverSpaces.length;
      _offsets[3] = _serverMine.length;
      _hasMore[0] = _serverGlobal.length >= pageSize;
      _hasMore[1] = _serverFollowing.length >= pageSize;
      _hasMore[2] = _serverSpaces.length >= pageSize;
      _hasMore[3] = _serverMine.length >= pageSize;
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  /// Fetches the next page of the given feed tab and appends it.
  Future<void> loadMore(int tab) async {
    if (tab < 0 || tab > 3 || loading || loadingMore || !_hasMore[tab]) return;
    final deps = dependencies?.service;
    if (deps == null) return;
    loadingMore = true;
    notifyListeners();
    try {
      final me = dependencies?.sessionController.session?.accountId ?? '';
      final offset = _offsets[tab];
      final List<SocialPost> page = switch (tab) {
        0 => await deps.fetchFeed(
            following: false, limit: pageSize, offset: offset),
        1 => await deps.fetchFeed(
            following: true, limit: pageSize, offset: offset),
        2 => await deps.fetchSpacesFeed(limit: pageSize, offset: offset),
        _ => me.isEmpty
            ? const <SocialPost>[]
            : await deps.fetchUserPosts(me, limit: pageSize, offset: offset),
      };
      _listFor(tab).addAll(page);
      _offsets[tab] = offset + page.length;
      _hasMore[tab] = page.length >= pageSize;
    } catch (e) {
      error = e.toString();
    }
    loadingMore = false;
    notifyListeners();
  }

  List<SocialPost> _listFor(int tab) => switch (tab) {
        0 => _serverGlobal,
        1 => _serverFollowing,
        2 => _serverSpaces,
        _ => _serverMine,
      };

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

  Future<void> toggleLike(String postId, bool liked) async {
    final deps = dependencies?.service;
    if (deps == null) return;
    try {
      if (liked) {
        await deps.unlikePost(postId);
      } else {
        await deps.likePost(postId);
      }
      await load();
    } catch (_) {}
  }

  void setWorkspace(String value) {
    if (_workspace == value) return;
    _workspace = value;
    notifyListeners();
  }

  void setQuery(String value) {
    if (query == value) return;
    query = value;
    notifyListeners();
  }

  /// Posts for a feed tab: 0 = Global, 1 = Following, 2 = Spaces, 3 = Me.
  List<FeedPost> postsFor(int tab) => switch (tab) {
        0 => globalPosts,
        1 => followingPosts,
        2 => spacesPosts,
        _ => myPosts,
      };

  /// All leaderboard traders, ranked by score.
  List<Trader> get traders => _serverTraders;

  /// Map a server leaderboard entry onto the UI trader model.
  Trader _traderFromServer(Map<String, dynamic> e) {
    final handle = (e['handle'] as String?) ?? 'user';
    final likes = (e['likes'] as num?)?.toInt() ?? 0;
    final posts = (e['posts'] as num?)?.toInt() ?? 0;
    final score = (e['score'] as num?)?.toDouble() ?? 0;
    const palette = [
      Color(0xFF14B8A6),
      AppColors.primary,
      Color(0xFF6366F1),
      AppColors.cyan,
      Color(0xFF3B82F6),
      Color(0xFFEC4899),
      Color(0xFFF97316),
      AppColors.success,
      AppColors.warning,
      Color(0xFF8B5CF6),
    ];
    return Trader(
      initials: handle.length >= 2 ? handle.substring(0, 2).toUpperCase() : 'U',
      name: handle,
      handle: '@$handle',
      score: score <= 0 ? 0 : (score / 100).clamp(0, 100),
      roi: '+$posts posts',
      accuracy: '$likes likes',
      followers: '$posts',
      color: palette[handle.hashCode.abs() % palette.length],
      change: '+${likes % 10}.${(posts % 10)}',
      verified: false,
    );
  }

  List<Trader> searchTraders(List<Trader> source) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return source;
    return source
        .where((t) =>
            t.name.toLowerCase().contains(q) ||
            t.handle.toLowerCase().contains(q))
        .toList();
  }

  List<FeedPost> get globalPosts => _serverGlobal.map(_feedFromServer).toList();

  List<FeedPost> get followingPosts =>
      _serverFollowing.map(_feedFromServer).toList();

  /// Private posts across all workspaces the caller is a member of.
  List<FeedPost> get spacesPosts => _serverSpaces.map(_feedFromServer).toList();

  /// Only the caller's own posts.
  List<FeedPost> get myPosts => _serverMine.map(_feedFromServer).toList();

  /// Map a server post onto the UI feed card model.
  FeedPost _feedFromServer(SocialPost p) => FeedPost(
        initials: _initialsOf(p.authorId),
        name: '@${p.authorId.substring(0, 8)}',
        handle: '@${p.authorId.substring(0, 12)}',
        time: _timeAgo(p.createdAt),
        body: p.body,
        tag: p.tags.isEmpty ? 'POST' : p.tags.first.toUpperCase(),
        likes: _compact(p.likes),
        comments: '0',
        color: _colorFor(p.id),
        liked: p.likedByMe,
        serverId: p.id,
        workspace: _spaceNames[p.spaceId],
      );

  String _initialsOf(String id) {
    if (id.length < 4) return 'OC';
    final h = id.hashCode;
    return '${_upper((h & 0xff).toRadixString(16))}${_upper(((h >> 8) & 0xff).toRadixString(16))}';
  }

  String _upper(String s) => s.toUpperCase();

  Color _colorFor(String id) {
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

  static String _compact(int n) {
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  static String _timeAgo(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    return '${d.inDays}d';
  }

  List<FeedPost> search(List<FeedPost> source) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return source;
    return source
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.handle.toLowerCase().contains(q) ||
            p.body.toLowerCase().contains(q) ||
            p.tag.toLowerCase().contains(q) ||
            (p.coin ?? '').toLowerCase().contains(q))
        .toList();
  }
}
