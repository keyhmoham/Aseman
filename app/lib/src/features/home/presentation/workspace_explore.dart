part of 'workspace_screen.dart';

/// The Explore panel's key: where its search, sections and results are (for
/// tests and anything that needs to tell it from the page under it).
const exploreKey = ValueKey('explore');

/// Opens Explore from the feed: a search across Aseman with no space scope,
/// so it has no "in this space" tab. [onOpenSpace] opens a space the user is
/// a member of by name.
Future<void> showExplore(
  BuildContext context,
  AppDependencies dependencies, {
  String query = '',
  ValueChanged<String>? onOpenSpace,
}) => showFloatingPanel(
  context,
  _SearchPanel(
    key: exploreKey,
    workspace: '',
    dependencies: dependencies,
    feed: true,
    initialQuery: query,
    onOpenSpace: onOpenSpace,
  ),
  maxWidth: 920,
  barrierLabel: 'Close explore',
);

class _SearchPanel extends StatefulWidget {
  const _SearchPanel({
    super.key,
    required this.workspace,
    this.spaceId = '',
    this.dependencies,
    this.feed = false,
    this.initialQuery = '',
    this.onOpenSpace,
  });
  final String workspace;
  final String spaceId;
  final AppDependencies? dependencies;

  /// Opened from the feed, outside any space: only the platform-wide
  /// sections, without the space/explore tab bar.
  final bool feed;
  final String initialQuery;
  final ValueChanged<String>? onOpenSpace;
  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel>
    with SingleTickerProviderStateMixin {
  late final TabController tabs;
  int localSection = 0;
  int globalSection = 0;
  late String query = widget.initialQuery;
  late final searchField = TextEditingController(text: widget.initialQuery);
  static const local = [
    'Users',
    'Agents',
    'Apps',
    'Media',
    'Documents',
    'Links',
    'GIFs',
    'Messages',
  ];
  static const global = ['Users', 'Agents', 'Apps', 'Posts', 'Workspaces'];

  /// What the feed's search covers: people, the user's and public spaces,
  /// the posts of their Following feed, their direct chats and the market's
  /// agents and apps.
  static const feedSections = [
    'Users',
    'Spaces',
    'Posts',
    'Chats',
    'Agents',
    'Apps',
  ];
  @override
  void initState() {
    super.initState();
    tabs = TabController(length: 2, vsync: this, initialIndex: 0)
      ..addListener(() {
        if (!tabs.indexIsChanging) setState(() {});
      });
  }

  @override
  void dispose() {
    searchField.dispose();
    tabs.dispose();
    super.dispose();
  }

  /// Whether the results are the space's own (the first tab inside a space).
  bool get _local => !widget.feed && tabs.index == 0;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final sections = widget.feed
        ? feedSections
        : _local
        ? local
        : global;
    final selected = _local ? localSection : globalSection;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 14 : 24,
        18,
        compact ? 14 : 24,
        12,
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.travel_explore_rounded, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.feed
                      ? 'Explore'
                      : compact
                      ? 'Discover'
                      : 'Search & discover',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 18),
          TextField(
            controller: searchField,
            autofocus: true,
            onChanged: (value) => setState(() => query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: _local
                  ? 'Search ${widget.workspace}…'
                  : 'Search all of Aseman…',
            ),
          ),
          const SizedBox(height: 9),
          _SearchSectionNav(
            sections: sections,
            selected: selected,
            onSelect: (value) => setState(() {
              if (_local) {
                localSection = value;
              } else {
                globalSection = value;
              }
            }),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: _SearchResults(
                key: ValueKey('${tabs.index}-$selected-$query'),
                section: sections[selected],
                global: !_local,
                feed: widget.feed,
                workspace: widget.workspace,
                spaceId: widget.spaceId,
                query: query,
                onOpenSpace: widget.onOpenSpace,
                dependencies: widget.dependencies,
              ),
            ),
          ),
          // Outside a space there is nothing to scope the search to.
          if (!widget.feed) ...[
            const SizedBox(height: 9),
            SegmentedTabBar(
              controller: tabs,
              compact: compact,
              labels: ['In ${widget.workspace}', 'Explore Aseman'],
              icons: const [Icons.hub_outlined, Icons.travel_explore_rounded],
            ),
          ],
        ],
      ),
    );
  }
}

class _SearchSectionNav extends StatelessWidget {
  const _SearchSectionNav({
    required this.sections,
    required this.selected,
    required this.onSelect,
  });
  final List<String> sections;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => SegmentedTabBar(
      key: ValueKey(sections.join('-')),
      width: box.maxWidth,
      selectedIndex: selected,
      onTap: onSelect,
      labels: sections,
      icons: [for (final section in sections) _sectionIcon(section)],
    ),
  );
}

IconData _sectionIcon(String section) => switch (section) {
  'Users' => Icons.people_outline,
  'Agents' => Icons.smart_toy_outlined,
  'Apps' => Icons.extension_outlined,
  'Media' => Icons.perm_media_outlined,
  'Documents' => Icons.description_outlined,
  'Links' => Icons.link_rounded,
  'GIFs' => Icons.gif_box_outlined,
  'Messages' => Icons.chat_bubble_outline_rounded,
  'Posts' => Icons.dynamic_feed_outlined,
  'Rooms' => Icons.forum_outlined,
  'Workspaces' || 'Spaces' => Icons.hub_outlined,
  'Chats' => Icons.forum_outlined,
  _ => Icons.search_rounded,
};

/// One search result: what its card shows, the entity's id when known, and
/// the record it came from (a chat, a post, a space row).
class _SearchHit {
  const _SearchHit(
    this.title, {
    this.subtitle,
    this.id = '',
    this.payload,
    this.avatar = '',
  });
  final String title;
  final String? subtitle;
  final String id;
  final Object? payload;

  /// The picture of the person, workspace, agent or app found ("" if none).
  final String avatar;
}

class _SearchResults extends StatefulWidget {
  const _SearchResults({
    super.key,
    required this.section,
    required this.global,
    this.feed = false,
    required this.workspace,
    required this.spaceId,
    required this.query,
    this.onOpenSpace,
    this.dependencies,
  });
  final String section;
  final bool global;
  final bool feed;
  final ValueChanged<String>? onOpenSpace;
  final String workspace;
  final String spaceId;
  final String query;
  final AppDependencies? dependencies;
  @override
  State<_SearchResults> createState() => _SearchResultsState();
}

/// Scope + paginated search results. The in-workspace tab searches only the
/// current space (members, installed agents/tools, space files/messages) while
/// the Explore tab searches the whole platform, loading more on scroll.
class _SearchResultsState extends State<_SearchResults> {
  static const _pageSize = 24;
  final ScrollController _scroll = ScrollController();
  List<_SearchHit> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void didUpdateWidget(covariant _SearchResults old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query ||
        old.section != widget.section ||
        old.global != widget.global ||
        old.spaceId != widget.spaceId) {
      _load();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _scroll.position.extentAfter > 300) return;
    unawaited(_loadMore());
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() {
        _items = const [];
        _loading = false;
        _hasMore = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _items = const [];
      _offset = 0;
      _hasMore = true;
    });
    try {
      final page = await _fetchPage(deps, 0);
      if (!mounted) return;
      setState(() {
        _items = page;
        _offset = page.length;
        _hasMore = page.length >= _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _items = const [];
        _loading = false;
        _hasMore = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _fetchPage(deps, _offset);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page];
        _offset += page.length;
        _hasMore = page.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
    }
  }

  /// Fetches one page of results for the active tab + scope.
  Future<List<_SearchHit>> _fetchPage(AppDependencies deps, int offset) async {
    if (widget.feed) return _fetchFeedPage(deps, offset);
    return _fetchTitles(deps, offset);
  }

  /// The feed's search: everything is the server's own search.
  Future<List<_SearchHit>> _fetchFeedPage(
    AppDependencies deps,
    int offset,
  ) async {
    final q = widget.query.trim();
    final service = deps.service;
    switch (widget.section) {
      case 'Users':
        final users = await service.searchUsers(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final u in users)
            _SearchHit(
              u.handle,
              id: u.id,
              subtitle: '@${u.handle}',
              avatar: u.avatar,
            ),
        ];
      case 'Spaces':
        final spaces = await service.searchSpaces(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final sp in spaces)
            _SearchHit(
              '${sp['name'] ?? ''}',
              id: '${sp['id'] ?? ''}',
              subtitle: [
                if ('${sp['description'] ?? ''}'.isNotEmpty)
                  '${sp['description']}',
                sp['member'] == false ? 'Public space' : 'Your space',
              ].join(' · '),
              payload: sp,
              avatar: '${sp['avatar'] ?? ''}',
            ),
        ];
      case 'Posts':
        final posts = await service.searchPosts(
          q,
          following: true,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final p in posts)
            _SearchHit(
              _firstLine(p.body),
              id: p.id,
              subtitle: _afterFirstLine(p.body),
              payload: p,
            ),
        ];
      case 'Chats':
        // The chat list is not paged: one page holds every match.
        if (offset > 0) return const [];
        final chats = await service.fetchChats(kind: 'direct', query: q);
        return [
          for (final c in chats)
            _SearchHit(
              c.title,
              id: c.spaceId,
              subtitle: c.lastBody.isEmpty
                  ? 'Direct chat'
                  : markupPreview(c.lastBody),
              payload: c,
              avatar: c.peer?.avatar ?? '',
            ),
        ];
      case 'Agents':
      case 'Apps':
        final listings = await service.fetchMarket(
          type: widget.section == 'Apps' ? 'tool' : 'agent',
          query: q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final l in listings)
            _SearchHit(
              l.name,
              id: l.botId,
              subtitle: l.description.isEmpty
                  ? 'In the market · ${l.kindLabel}'
                  : l.description,
              payload: l,
              avatar: l.avatar,
            ),
        ];
      default:
        return const [];
    }
  }

  /// A post's text after its first line, for the card's blurb.
  static String _afterFirstLine(String body) {
    final rest = body.trim().split('\n').skip(1).join(' ').trim();
    return rest.isEmpty ? 'From your Following feed' : rest;
  }

  static String _firstLine(String body) {
    final line = body
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'^[#>*\-\s]+'), '').trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => 'Post');
    return line.length > 90 ? '${line.substring(0, 90)}…' : line;
  }

  /// Opens a result: a chat, a post, a space the user is in, or a profile.
  VoidCallback? _opener(_SearchHit hit) {
    final deps = widget.dependencies;
    final payload = hit.payload;
    if (payload is ChatSummary && deps != null) {
      return () => showChat(context, deps, payload);
    }
    if (payload is SocialPost) {
      return () => showFloatingPanel(
        context,
        _PostPreview(post: payload, dependencies: deps),
        maxWidth: 640,
        maxHeight: 700,
        barrierLabel: 'Close post',
      );
    }
    if (widget.section == 'Spaces' &&
        payload is Map &&
        payload['member'] != false &&
        widget.onOpenSpace != null) {
      return () {
        Navigator.of(context).pop();
        widget.onOpenSpace!(hit.title);
      };
    }
    if (const [
      'Users',
      'Agents',
      'Apps',
      'Workspaces',
      'Spaces',
      'Rooms',
    ].contains(widget.section)) {
      return () => _openEntityProfile(
        context,
        widget.section,
        hit.title,
        deps,
        widget.spaceId,
        hit.id,
      );
    }
    return null;
  }

  /// One page of results inside a space or across Aseman.
  Future<List<_SearchHit>> _fetchTitles(
    AppDependencies deps,
    int offset,
  ) async {
    final q = widget.query.trim().toLowerCase();
    final space = widget.spaceId;
    List<_SearchHit> titles(Iterable<String> all) => [
      for (final t in all) _SearchHit(t),
    ];
    switch (widget.section) {
      case 'Users':
        if (widget.global) {
          final users = await deps.service.searchUsers(
            q,
            limit: _pageSize,
            offset: offset,
          );
          return [
            for (final u in users) _SearchHit(u.handle, avatar: u.avatar),
          ];
        }
        if (space.isEmpty) return const [];
        final mems = await deps.service.fetchSpaceMembers(
          space,
          kind: 'user',
          limit: _pageSize,
          offset: offset,
        );
        return [
              for (final m in mems)
                _SearchHit(
                  (m['handle'] as String?) ?? (m['member_id'] as String? ?? ''),
                  avatar: '${m['avatar'] ?? ''}',
                ),
            ]
            .where(
              (h) => h.title.isNotEmpty && h.title.toLowerCase().contains(q),
            )
            .toList();
      case 'Agents':
      case 'Apps':
        final isTool = widget.section == 'Apps';
        if (widget.global) {
          final kinds = isTool ? 'tool' : 'agent';
          final bots = await deps.service.searchBots(
            q,
            kind: kinds,
            limit: _pageSize,
            offset: offset,
          );
          return [
                for (final b in bots)
                  _SearchHit(
                    b['name'] as String? ?? '',
                    avatar: '${b['avatar'] ?? ''}',
                  ),
              ]
              .where(
                (h) => h.title.isNotEmpty && h.title.toLowerCase().contains(q),
              )
              .toList();
        }
        if (space.isEmpty) return const [];
        final sb = await deps.service.fetchSpaceBots(space);
        return sb
            .where((b) => isTool ? (b.isTool && !b.isSandbox) : b.isAgent)
            .where((b) => b.name.toLowerCase().contains(q))
            .skip(offset)
            .take(_pageSize)
            .map((b) => _SearchHit(b.name, avatar: b.avatar))
            .toList();
      case 'Workspaces':
        if (!widget.global) return const [];
        final spaces = await deps.service.searchSpaces(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final s in spaces)
            _SearchHit(
              s['name'] as String? ?? '',
              avatar: '${s['avatar'] ?? ''}',
            ),
        ];
      case 'Posts':
        if (!widget.global) return const [];
        final posts = await deps.service.searchPosts(
          q,
          limit: _pageSize,
          offset: offset,
        );
        return [
          for (final p in posts)
            _SearchHit(_firstLine(p.body), id: p.id, payload: p),
        ];
      case 'Messages':
        if (space.isEmpty) return const [];
        final msgs = await deps.service.searchSpaceMessages(
          space,
          query: q,
          limit: _pageSize,
          offset: offset,
        );
        return titles(
          msgs
              .map((m) => m['body'] as String? ?? '')
              .where((n) => n.isNotEmpty),
        );
      case 'Media':
      case 'Documents':
      case 'Links':
      case 'GIFs':
        if (space.isEmpty) return const [];
        final files = await deps.service.fetchFiles(
          space,
          limit: _pageSize,
          offset: offset,
        );
        // Each file shows as its own card: a player, a picture, a link or
        // a document.
        return [
          for (final f in files)
            if (_fileMatchesSection(f, widget.section))
              _SearchHit(
                f['name'] as String? ?? 'file',
                id: '${f['file_id'] ?? f['id'] ?? ''}',
                payload: UploadedFile.fromJson(f),
              ),
        ].where((h) => h.title.toLowerCase().contains(q)).toList();
      default:
        return const [];
    }
  }

  static String _feedScope(String section) => switch (section) {
    'Spaces' => 'Your spaces and public spaces',
    'Posts' => 'Posts of the people you follow and your spaces',
    'Chats' => 'Your direct chats, by who they are with',
    'Agents' || 'Apps' => 'From the market',
    _ => 'Discover across the platform',
  };

  static bool _fileMatchesSection(Map<String, dynamic> file, String section) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (section) {
      case 'Media':
        return (mime.startsWith('image/') && mime != 'image/gif') ||
            mime.startsWith('video/') ||
            mime.startsWith('audio/');
      case 'Documents':
        return mime.contains('pdf') ||
            mime.contains('text') ||
            mime.contains('markdown') ||
            mime.contains('doc');
      case 'Links':
        return mime.contains('html') || mime.contains('url');
      case 'GIFs':
        return mime == 'image/gif';
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final section = widget.section;
    final count = _loading ? null : _items.length;
    final deps = widget.dependencies;
    // The results that are rows (not posts or files) share one card.
    final rows = _items
        .where((h) => h.payload is! SocialPost && h.payload is! UploadedFile)
        .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 10),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(_sectionIcon(section), size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      section,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      widget.feed
                          ? _feedScope(section)
                          : widget.global
                          ? 'Discover across the platform'
                          : 'Results from ${widget.workspace} workspace',
                      style: const TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
              if (count != null)
                Chip(
                  avatar: const Icon(Icons.auto_awesome_rounded, size: 13),
                  label: Text(
                    '$count found',
                    style: const TextStyle(fontSize: 9),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Builder(
            builder: (context) {
              if (_loading) return const SkeletonList();
              if (_items.isEmpty) {
                return const PanelEmpty(
                  icon: Icons.search_off_rounded,
                  title: 'No matching results',
                  message: 'Try another query or clear filters.',
                );
              }
              return ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 12),
                itemCount: _items.length + (_hasMore || _loadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index >= _items.length) {
                    return const SkeletonListTile();
                  }
                  final hit = _items[index];
                  final payload = hit.payload;
                  // A post shows in full, as the feed shows it.
                  if (payload is SocialPost && deps != null) {
                    return _SearchPostCard(
                      key: ValueKey('post-${payload.id}'),
                      post: payload,
                      dependencies: deps,
                    );
                  }
                  // A file shows as its own card: a player, a picture, a link
                  // or a document.
                  if (payload is UploadedFile && deps != null) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _SearchMediaCard(
                        file: payload,
                        service: deps.service,
                      ),
                    );
                  }
                  // People, agents, apps, spaces and messages sit together on
                  // one card, a row each.
                  final first = identical(rows.first, hit);
                  final last = identical(rows.last, hit);
                  final r = Radius.circular(AppShape.cardOf(context) - 2);
                  return Container(
                    margin: EdgeInsets.only(bottom: last ? 10 : 0),
                    padding: EdgeInsets.fromLTRB(
                      8,
                      first ? 8 : 0,
                      8,
                      last ? 8 : 0,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.vertical(
                        top: first ? r : Radius.zero,
                        bottom: last ? r : Radius.zero,
                      ),
                    ),
                    child: _SearchResultCard(
                      section: section,
                      title: hit.title,
                      avatar: hit.avatar,
                      subtitle: hit.subtitle,
                      feed: widget.feed,
                      spaceId: widget.spaceId,
                      index: index,
                      onOpen: widget.feed ? _opener(hit) : null,
                      dependencies: widget.dependencies,
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A post found by search, in full as the feed shows it; liking it here
/// likes it.
class _SearchPostCard extends StatefulWidget {
  const _SearchPostCard({
    super.key,
    required this.post,
    required this.dependencies,
  });
  final SocialPost post;
  final AppDependencies dependencies;

  @override
  State<_SearchPostCard> createState() => _SearchPostCardState();
}

class _SearchPostCardState extends State<_SearchPostCard> {
  late SocialPost _post = widget.post;
  bool _deleted = false;

  Future<void> _toggleLike() async {
    final was = _post;
    final liked = !was.likedByMe;
    setState(
      () => _post = was.withLike(
        likes: liked ? was.likes + 1 : (was.likes > 0 ? was.likes - 1 : 0),
        likedByMe: liked,
      ),
    );
    try {
      if (liked) {
        await widget.dependencies.service.likePost(was.id);
      } else {
        await widget.dependencies.service.unlikePost(was.id);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _post = was);
    }
  }

  @override
  Widget build(BuildContext context) => _deleted
      ? const SizedBox.shrink()
      : FeedPostCard(
          post: feedPostFromServer(_post),
          dependencies: widget.dependencies,
          onToggleLike: _toggleLike,
          onEdited: (body) => setState(
            () => _post = _post.copyWith(body: body, editedAt: DateTime.now()),
          ),
          onDeleted: () => setState(() => _deleted = true),
        );
}

/// A file found by search, on a card made for its kind: a video under a
/// play button, audio with its waveform, a picture or GIF, a link or a
/// document; with its name and when it was shared.
class _SearchMediaCard extends StatelessWidget {
  const _SearchMediaCard({required this.file, required this.service});
  final UploadedFile file;
  final AsemanService service;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final type = FileType.of(file.name);
    final kind = file.isGif
        ? 'GIF'
        : file.isImage
        ? 'Image'
        : file.isVideo
        ? 'Video'
        : file.isPlayableAudio
        ? 'Audio'
        : type.kind.name[0].toUpperCase() + type.kind.name.substring(1);
    final when = file.createdAt == null ? '' : _timeAgo(file.createdAt!);
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppShape.cardOf(context)- 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    file.isVideo
                        ? Icons.movie_rounded
                        : file.isPlayableAudio
                        ? Icons.graphic_eq_rounded
                        : file.isGif
                        ? Icons.gif_box_rounded
                        : file.isImage
                        ? Icons.image_rounded
                        : type.icon,
                    size: 16,
                    color: type.color,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    [
                      kind,
                      file.humanSize,
                      if (when.isNotEmpty) when,
                    ].join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AttachmentBubble(
                file: file,
                headers: service.authHeaders(),
                resolveUrl: (f) => service.fileContentUrl(f.id),
                fetchBytes: (f) => service.downloadFile(f.id),
                maxWidth: math.min(box.maxWidth, 520),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One search result as a compact row: its icon, name and a line about it.
class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.section,
    required this.title,
    this.subtitle,
    this.feed = false,
    required this.index,
    this.onOpen,
    this.spaceId = '',
    this.avatar = '',
    this.dependencies,
  });
  final String section, title;

  /// The picture of what was found, shown over its icon ("" if none).
  final String avatar;

  /// What the result says about itself (the generic blurb otherwise).
  final String? subtitle;

  /// A feed search result: [onOpen] opens it.
  final bool feed;
  final VoidCallback? onOpen;
  final int index;
  final String spaceId;
  final AppDependencies? dependencies;

  VoidCallback? _open(BuildContext context) => feed
      ? onOpen
      : _hasProfile
      ? () => _openEntityProfile(context, section, title, dependencies, spaceId)
      : null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ThemeRoles.identity(context, '$section::$title');
    final open = _open(context);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              section == 'Agents' || section == 'Apps'
                  ? BotAvatar.fromFields(
                      id: title,
                      name: title,
                      kind: section == 'Apps' ? 'tool' : 'agent',
                      avatar: avatar,
                      radius: 18,
                      userId: dependencies
                              ?.sessionController.session?.accountId ??
                          '',
                    )
                  : Builder(builder: (context) {
                      const radius = 18.0;
                      final size = radius * 2;
                      final corners = context.avatarBorderRadius(size);
                      final picture = Avatars.of(avatar);
                      return HaloRing(
                        accent: color,
                        borderRadius: corners,
                        child: AvatarFace(
                          size: size,
                          borderRadius: corners,
                          backgroundColor: color.withValues(alpha: .18),
                          foregroundImage: picture,
                          onImageError:
                              picture == null ? null : (_, __) {},
                          child: Icon(
                            _sectionIcon(section),
                            color: color,
                            size: 18,
                          ),
                        ),
                      );
                    }),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? _description(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (open != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _description() => switch (section) {
    'Users' => 'Person on Aseman',
    'Agents' => 'Agent',
    'Apps' => 'App',
    'Rooms' => 'Room',
    'Workspaces' || 'Spaces' => 'Space',
    'Documents' => 'Document',
    'Messages' => 'Message',
    'Links' => 'Link',
    'Media' => 'Media',
    'GIFs' => 'GIF',
    'Posts' => 'Post',
    _ => 'Result',
  };
  bool get _hasProfile => const [
    'Users',
    'Agents',
    'Apps',
    'Workspaces',
    'Spaces',
    'Rooms',
  ].contains(section);
}

/// A post found by the feed's search, rendered in full.
class _PostPreview extends StatelessWidget {
  const _PostPreview({required this.post, this.dependencies});
  final SocialPost post;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 14, 8, 4),
          child: Row(
            children: [
              Icon(Icons.article_outlined, color: scheme.primary),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Post',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 22),
            child: DefaultTextStyle.merge(
              style: const TextStyle(fontSize: 15, height: 1.45),
              child: RichPostContent(
                post.body,
                headers: dependencies?.service.authHeaders() ?? const {},
                resolveUrl: dependencies?.service.resolveContentUrl,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

