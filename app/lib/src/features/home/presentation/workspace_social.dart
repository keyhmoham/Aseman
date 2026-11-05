part of 'workspace_screen.dart';

class _SocialFeed extends StatefulWidget {
  const _SocialFeed({
    super.key,
    required this.workspace,
    this.dependencies,
    this.spaceId = '',
    this.flat = false,
    this.topContentInset = 0,
  });
  final String workspace;
  final AppDependencies? dependencies;
  final String spaceId;
  final bool flat;
  final double topContentInset;
  @override
  State<_SocialFeed> createState() => _SocialFeedState();
}

class _SocialFeedState extends State<_SocialFeed> {
  static const _pageSize = 20;
  List<SocialPost> posts = [];
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = true;
  int _offset = 0;
  bool _publishing = false;

  /// Bumps when the feed's space changes so a late response for the previous
  /// space (or the unfiltered global feed) cannot paint over the new one.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    // Wait for the workspace's space id; fetching with an empty id returns
    // the global/following feed and flashes the wrong posts.
    if (widget.spaceId.isNotEmpty) _load();
  }

  @override
  void didUpdateWidget(covariant _SocialFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace != widget.workspace ||
        oldWidget.spaceId != widget.spaceId) {
      posts = [];
      _offset = 0;
      hasMore = true;
      loading = true;
      loadingMore = false;
      _loadGen++;
      if (widget.spaceId.isNotEmpty) {
        _load();
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _publish([String body = '']) async {
    final md = (body.isEmpty ? null : body) ?? '';
    final deps = widget.dependencies;
    if (md.trim().isEmpty ||
        _publishing ||
        deps == null ||
        widget.spaceId.isEmpty) {
      return;
    }
    setState(() => _publishing = true);
    try {
      await deps.service.createPost(md.trim(), spaceId: widget.spaceId);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Posted to this workspace')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Post failed: $e')));
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  Future<void> _openComposer() async {
    final md = await showPostEditor(
      context,
      hint: 'Write to ${widget.workspace}…',
    );
    if (md == null || md.trim().isEmpty) return;
    await _publish(md);
  }

  Future<void> _load({bool more = false}) async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => loading = false);
      return;
    }
    // Spaces list is still resolving; keep the skeleton up.
    if (widget.spaceId.isEmpty) {
      if (!more && mounted) setState(() => loading = true);
      return;
    }
    if (more) {
      if (loadingMore || !hasMore || loading) return;
      setState(() => loadingMore = true);
    } else {
      setState(() => loading = true);
    }
    final gen = _loadGen;
    final spaceId = widget.spaceId;
    try {
      final offset = more ? _offset : 0;
      final feed = await deps.service.fetchFeed(
        spaceId: spaceId,
        limit: _pageSize,
        offset: offset,
      );
      if (!mounted || gen != _loadGen || widget.spaceId != spaceId) return;
      setState(() {
        if (more) {
          posts.addAll(feed);
          _offset += feed.length;
        } else {
          posts = feed;
          _offset = feed.length;
        }
        hasMore = feed.length >= _pageSize;
        loading = false;
        loadingMore = false;
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() {
        loading = false;
        loadingMore = false;
      });
    }
  }

  void _replace(String id, SocialPost Function(SocialPost) change) {
    final i = posts.indexWhere((p) => p.id == id);
    if (i >= 0) setState(() => posts[i] = change(posts[i]));
  }

  Future<void> _toggleLike(SocialPost post) async {
    final deps = widget.dependencies;
    if (deps == null || post.id.isEmpty) return;
    final index = posts.indexWhere((p) => p.id == post.id);
    if (index < 0) return;
    final liked = !post.likedByMe;
    setState(() {
      posts[index] = post.withLike(
        likes: post.likes + (liked ? 1 : -1),
        likedByMe: liked,
      );
    });
    try {
      if (liked) {
        await deps.service.likePost(post.id);
      } else {
        await deps.service.unlikePost(post.id);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        posts[index] = post;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final workspace = widget.workspace;
    final header = Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  workspace == 'Home' ? 'Universal feed' : '$workspace feed',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  workspace == 'Home'
                      ? 'Public platform posts'
                      : 'Posts from this workspace',
                  style: const TextStyle(fontSize: 9),
                ),
              ],
            ),
          ),
          const Icon(Icons.tune, size: 18),
        ],
      ),
    );
    final postWidgets = [if (widget.spaceId.isNotEmpty) _composer(context)];
    if (loading) {
      postWidgets.add(const SkeletonList(itemCount: 3, item: SkeletonPost()));
    } else if (posts.isEmpty) {
      postWidgets.add(
        Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Text(
              'No posts in this workspace yet.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    } else {
      final deps = widget.dependencies;
      postWidgets.addAll(
        posts.map(
          (p) => deps == null
              ? const SizedBox.shrink()
              : FeedPostCard(
                  key: ValueKey('space-post-${p.id}'),
                  post: feedPostFromServer(p),
                  dependencies: deps,
                  onToggleLike: () => _toggleLike(p),
                  onEdited: (body) => _replace(
                    p.id,
                    (old) => old.copyWith(body: body, editedAt: DateTime.now()),
                  ),
                  onDeleted: () => setState(
                    () => posts.removeWhere((old) => old.id == p.id),
                  ),
                  onShared: _load,
                ),
        ),
      );
    }
    if (loadingMore) {
      postWidgets.add(const SkeletonPost());
    }
    final body = NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (hasMore &&
            !loadingMore &&
            n.metrics.extentAfter < 250 &&
            n.metrics.maxScrollExtent > 0) {
          unawaited(_load(more: true));
        }
        return false;
      },
      child: widget.flat
          ? ListView(
              padding: EdgeInsets.fromLTRB(12, widget.topContentInset, 12, 24),
              children: [header, ...postWidgets],
            )
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: postWidgets,
            ),
    );
    if (widget.flat) return _Panel(flat: true, child: body);
    return _Panel(
      flat: widget.flat,
      child: Column(
        children: [
          header,
          Expanded(child: body),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final shell = ThemeChrome.inputShell(context);
    return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: EdgeInsets.symmetric(
      horizontal: shell.padding.horizontal / 2,
      vertical: 4,
    ),
    decoration: BoxDecoration(
      color: shell.color,
      borderRadius: shell.radius,
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: InkWell(
      onTap: _publishing ? null : _openComposer,
      borderRadius: shell.radius,
      child: Row(
        children: [
          const Icon(Icons.edit_note_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _publishing ? 'Publishing…' : 'Write a post for this workspace…',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            onPressed: _publishing ? null : _openComposer,
            icon: _publishing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded, size: 20),
          ),
        ],
      ),
    ),
  );
  }
}

