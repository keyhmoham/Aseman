part of 'workspace_screen.dart';

/// Opens the profile of the account [accountId] (known as [handle]): who
/// they are, their posts, and following them.
void showAccountProfile(
  BuildContext context,
  AppDependencies dependencies, {
  required String accountId,
  String handle = '',
}) => _openEntityProfile(context, 'Users', handle, dependencies, '', accountId);

void _openEntityProfile(
  BuildContext context,
  String section,
  String title, [
  AppDependencies? dependencies,
  String spaceId = '',
  String entityId = '',
]) {
  final profile = _EntityProfileScreen(
    section: section == 'Spaces' ? 'Workspaces' : section,
    title: title,
    dependencies: dependencies,
    spaceId: spaceId,
    entityId: entityId,
  );
  showFloatingPanel(
    context,
    profile,
    maxWidth: 700,
    maxHeight: 760,
    barrierLabel: 'Close profile',
  );
}

class _EntityProfileScreen extends StatefulWidget {
  const _EntityProfileScreen({
    required this.section,
    required this.title,
    this.dependencies,
    this.spaceId = '',
    this.entityId = '',
  });
  final String section, title;
  final AppDependencies? dependencies;

  /// The entity's id when a search result knows it (a bot, an account or a
  /// space): the profile loads it directly instead of matching [title].
  final String entityId;

  /// The workspace the profile was opened from (used to install agents/tools).
  final String spaceId;
  @override
  State<_EntityProfileScreen> createState() => _EntityProfileScreenState();
}

class _EntityProfileScreenState extends State<_EntityProfileScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;

  // Resolved entity profiles (real backend data).
  BotProfile? _bot;
  UserProfile? _user;
  SpaceProfile? _space;
  RoomProfile? _room;
  List<SocialPost> _posts = const [];
  bool _inSpace =
      false; // agent/tool already installed in the current workspace

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final deps = widget.dependencies;
    if (deps == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final service = deps.service;
      switch (widget.section) {
        case 'Agents':
        case 'Apps':
          if (widget.entityId.isNotEmpty) {
            final prof = await service.fetchBotProfile(widget.entityId);
            if (mounted) {
              setState(() {
                _bot = prof;
                _loading = false;
              });
            }
            return;
          }
          var bots = await service.fetchBots();
          var bot = bots
              .where(
                (b) => widget.section == 'Agents'
                    ? b.isAgent
                    : (b.isTool && !b.isSandbox),
              )
              .where((b) => b.name == widget.title)
              .firstOrNull;
          // Agents/tools opened from a workspace tab are space bots; resolve
          // them from the workspace too when the global list has no match.
          if (bot == null && widget.spaceId.isNotEmpty) {
            try {
              final sb = await service.fetchSpaceBots(widget.spaceId);
              bot = sb
                  .where(
                    (b) => widget.section == 'Agents'
                        ? b.isAgent
                        : (b.isTool && !b.isSandbox),
                  )
                  .where((b) => b.name == widget.title)
                  .firstOrNull;
            } catch (_) {}
          }
          if (bot != null) {
            final resolved = bot;
            final prof = await service.fetchBotProfile(resolved.id);
            var inSpace = false;
            if (widget.spaceId.isNotEmpty) {
              try {
                final sb = await service.fetchSpaceBots(widget.spaceId);
                inSpace = sb.any(
                  (b) =>
                      b.id == resolved.id || b.accountId == resolved.accountId,
                );
              } catch (_) {}
            }
            if (mounted) {
              setState(() {
                _bot = prof;
                _inSpace = inSpace;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Users':
          final String? accountId;
          if (widget.entityId.isNotEmpty) {
            accountId = widget.entityId;
          } else {
            final users = await service.searchUsers(widget.title, limit: 10);
            accountId = users
                .where(
                  (u) =>
                      u.handle == widget.title ||
                      u.handle.contains(widget.title),
                )
                .firstOrNull
                ?.id;
          }
          if (accountId != null) {
            final prof = await service.fetchUserProfile(accountId);
            final posts = await service.fetchUserPosts(accountId);
            if (mounted) {
              setState(() {
                _user = prof;
                _posts = posts;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Workspaces':
          final String? spaceId;
          if (widget.entityId.isNotEmpty) {
            spaceId = widget.entityId;
          } else {
            final spaces = await service.fetchSpaces();
            spaceId = spaces
                .where(
                  (s) =>
                      s.name == widget.title || s.name.contains(widget.title),
                )
                .firstOrNull
                ?.id;
          }
          if (spaceId != null) {
            final prof = await service.fetchSpaceProfile(spaceId);
            if (mounted) {
              setState(() {
                _space = prof;
                _loading = false;
              });
            }
          } else if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        case 'Rooms':
          if (widget.entityId.isNotEmpty) {
            final prof = await service.fetchRoomProfile(widget.entityId);
            if (mounted) {
              setState(() {
                _room = prof;
                _loading = false;
              });
            }
            return;
          }
          // Look in the workspace the room was opened from before the rest.
          final spaceIds = [
            if (widget.spaceId.isNotEmpty) widget.spaceId,
            for (final sp in await service.fetchSpaces())
              if (sp.id != widget.spaceId) sp.id,
          ];
          for (final spaceId in spaceIds) {
            final rooms = await service.fetchRoomsForSpace(spaceId);
            final room = rooms
                .where(
                  (r) =>
                      r.name == widget.title || r.name.contains(widget.title),
                )
                .firstOrNull;
            if (room != null) {
              final prof = await service.fetchRoomProfile(room.id);
              if (mounted) {
                setState(() {
                  _room = prof;
                  _loading = false;
                });
              }
              return;
            }
          }
          if (mounted) {
            setState(() {
              _error = 'Not found';
              _loading = false;
            });
          }
          return;
        default:
          if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _performAction() async {
    final deps = widget.dependencies;
    if (deps == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (widget.section == 'Users') {
        final u = _user;
        if (u == null) return;
        if (u.amFollowing) {
          await deps.service.unfollowUser(u.id);
          _snack('Unfollowed @${u.handle}');
        } else {
          await deps.service.followUser(u.id);
          _snack('Following @${u.handle}');
        }
        final updated = await deps.service.fetchUserProfile(u.id);
        if (mounted) setState(() => _user = updated);
        return;
      }
      if (widget.section == 'Agents' || widget.section == 'Apps') {
        final b = _bot;
        if (b == null) return;
        if (_inSpace) {
          _snack('${b.name} is already in this workspace');
          return;
        }
        if (widget.spaceId.isNotEmpty) {
          await deps.service.addBotToSpace(widget.spaceId, b.id);
          if (mounted) setState(() => _inSpace = true);
          _snack('Added ${b.name} to this workspace');
          if (b.kind == 'tool' && mounted) {
            await connectMcpToolIfNeeded(
              context,
              deps.service,
              botId: b.id,
              spaceId: widget.spaceId,
              name: b.name,
            );
          }
        } else if (b.listing.isNotEmpty) {
          await deps.service.installListing(
            b.listing['listing_id'] as String? ?? '',
          );
          if (mounted) setState(() => _inSpace = true);
          _snack('Installed ${b.name}');
        } else {
          _snack('Open a workspace to install ${b.name}');
        }
        return;
      }
      if (widget.section == 'Workspaces') {
        final s = _space;
        if (s == null) return;
        if (s.amMember) {
          _snack('You are already a member of ${s.name}');
          return;
        }
        await deps.service.joinSpace(s.id);
        if (mounted) {
          setState(
            () => _space = SpaceProfile(
              id: s.id,
              name: s.name,
              description: s.description,
              public: s.public,
              home: s.home,
              ownerId: s.ownerId,
              ownerHandle: s.ownerHandle,
              memberCount: s.memberCount + 1,
              agentCount: s.agentCount,
              roomCount: s.roomCount,
              rooms: s.rooms,
              postCount: s.postCount,
              fileCount: s.fileCount,
              amMember: true,
              metadata: s.metadata,
              avatar: s.avatar,
            ),
          );
        }
        _snack('Joined ${s.name}');
        return;
      }
      if (widget.section == 'Rooms') {
        final r = _room;
        if (r == null) return;
        if (r.amMember) {
          _snack('You are already a member of ${r.name}');
          return;
        }
        if (r.spaceId.isNotEmpty) {
          await deps.service.joinSpace(r.spaceId);
          if (mounted) {
            setState(
              () => _room = RoomProfile(
                id: r.id,
                name: r.name,
                topic: r.topic,
                spaceId: r.spaceId,
                spaceName: r.spaceName,
                memberCount: r.memberCount + 1,
                agentCount: r.agentCount,
                messageCount: r.messageCount,
                fileCount: r.fileCount,
                amMember: true,
                recentMessages: r.recentMessages,
              ),
            );
          }
          _snack('Joined ${r.spaceName}');
        }
        return;
      }
    } catch (e) {
      _snack('Action failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get singular => switch (widget.section) {
    'Users' => 'Person',
    'Agents' => 'Agent',
    'Apps' => 'App',
    'Workspaces' => 'Workspace',
    'Rooms' => 'Room',
    _ => 'Profile',
  };

  /// The picture of the person, agent, app or workspace shown.
  String get _avatar => _user?.avatar ?? _bot?.avatar ?? _space?.avatar ?? '';

  bool get _loaded =>
      _user != null || _bot != null || _space != null || _room != null;

  /// The loaded entity's name, or the title it was opened with until then.
  String get _name {
    final name = _user?.name ?? _bot?.name ?? _space?.name ?? _room?.name ?? '';
    return name.isEmpty ? widget.title : name;
  }

  /// The line under the name: who the entity is, from its loaded profile.
  String get _subtitle {
    final u = _user;
    if (u != null) {
      return [
        '@${u.handle}',
        if (u.kind != 'user') u.kind,
        if (u.status != 'active') u.status,
      ].join(' · ');
    }
    final b = _bot;
    if (b != null) {
      return [
        if (b.vmType.isNotEmpty) b.vmType.toUpperCase(),
        if (b.ownerHandle.isNotEmpty) 'by @${b.ownerHandle}',
      ].join(' · ');
    }
    final s = _space;
    if (s != null) {
      return [
        s.public ? 'Public' : 'Private',
        if (s.ownerHandle.isNotEmpty) 'by @${s.ownerHandle}',
      ].join(' · ');
    }
    final r = _room;
    if (r != null && r.spaceName.isNotEmpty) return 'in ${r.spaceName}';
    return '';
  }

  /// The entity's own words about itself: a bio, description or topic.
  String get _about =>
      _user?.bio ??
      _bot?.description ??
      _space?.description ??
      _room?.topic ??
      '';

  IconData get icon => switch (widget.section) {
    'Users' => Icons.person_rounded,
    'Agents' => Icons.smart_toy_rounded,
    'Apps' => Icons.extension_rounded,
    'Workspaces' => Icons.hub_rounded,
    'Rooms' => Icons.forum_rounded,
    _ => Icons.category_rounded,
  };

  /// The primary action's label and whether it is already done.
  (String, bool)? get _action {
    final u = _user;
    if (u != null)
      return u.amFollowing ? ('Following', true) : ('Follow', false);
    final b = _bot;
    if (b != null)
      return _inSpace ? ('Added', true) : ('Add to workspace', false);
    final s = _space;
    if (s != null)
      return s.amMember ? ('Joined', true) : ('Join workspace', false);
    final r = _room;
    if (r != null) return r.amMember ? ('Joined', true) : ('Join room', false);
    return null;
  }

  List<(String, String, VoidCallback?)> get stats {
    final u = _user;
    final deps = widget.dependencies;
    if (u != null) {
      return [
        (
          '${u.followers}',
          'Followers',
          deps == null
              ? null
              : () => _showAccountList(context, deps, u.id, false),
        ),
        (
          '${u.following}',
          'Following',
          deps == null
              ? null
              : () => _showAccountList(context, deps, u.id, true),
        ),
        ('${_posts.length}', 'Posts', null),
      ];
    }
    final b = _bot;
    if (b != null) {
      return [
        (b.status.isEmpty ? '—' : b.status, 'Status', null),
        ('${b.installs}', 'Installs', null),
        (_fmtDuration(b.uptimeSec), 'Uptime', null),
      ];
    }
    final s = _space;
    if (s != null) {
      return [
        ('${s.memberCount}', 'Members', null),
        ('${s.roomCount}', 'Rooms', null),
        ('${s.postCount}', 'Posts', null),
      ];
    }
    final r = _room;
    if (r != null) {
      return [
        ('${r.memberCount}', 'Members', null),
        ('${r.agentCount}', 'Agents', null),
        ('${r.messageCount}', 'Messages', null),
      ];
    }
    return const [];
  }

  /// Shares the entity through the platform's share sheet, copying the
  /// text instead where there is none.
  Future<void> _share(BuildContext buttonContext) async {
    final u = _user;
    final text = u != null
        ? '$_name (@${u.handle}) on Aseman'
        : '$singular "$_name" on Aseman';
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _about.isEmpty ? text : '$text\n\n$_about',
          subject: text,
          sharePositionOrigin: origin,
        ),
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      _snack('Sharing is not available here; the profile was copied');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final action = _action;
    final subtitle = _subtitle;
    final about = _about;
    final stats = this.stats;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 28),
      children: [
        Row(
          children: [
            MiniTag(singular.toUpperCase(), scheme.primary),
            const Spacer(),
            if (_loaded)
              Builder(
                builder: (buttonContext) => IconButton(
                  tooltip: 'Share profile',
                  onPressed: () => _share(buttonContext),
                  icon: const Icon(Icons.ios_share_rounded, size: 19),
                ),
              ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: ThemeChrome.cardFillColor(context),
            borderRadius: ThemeChrome.softCardCorners(context, AppShape.card),
          ),
          child: Column(
            children: [
              Container(
                height: 104,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primary, scheme.tertiary],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -16,
                      top: -36,
                      child: Icon(
                        icon,
                        size: 160,
                        color: Colors.white.withValues(alpha: .15),
                      ),
                    ),
                  ],
                ),
              ),
              Transform.translate(
                offset: const Offset(0, -31),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _bot != null
                              ? BotAvatar(
                                  bot: Bot(
                                    id: _bot!.id,
                                    ownerId: _bot!.ownerId,
                                    accountId: '',
                                    name: _bot!.name,
                                    kind: _bot!.kind.isEmpty
                                        ? (widget.section == 'Apps'
                                            ? 'tool'
                                            : 'agent')
                                        : _bot!.kind,
                                    vmType: _bot!.vmType,
                                    status: _bot!.status,
                                    avatar: _bot!.avatar,
                                  ),
                                  radius: 31,
                                  userId: widget.dependencies
                                          ?.sessionController
                                          .session
                                          ?.accountId ??
                                      '',
                                )
                              : Builder(builder: (context) {
                                  const size = 62.0;
                                  final corners =
                                      context.avatarBorderRadius(size);
                                  return HaloRing(
                                    pad: 3,
                                    borderRadius: corners,
                                    child: AvatarFace(
                                      size: size,
                                      borderRadius: corners,
                                      backgroundColor:
                                          scheme.surfaceContainerHighest,
                                      child: AvatarPicture(
                                        avatar: _avatar,
                                        size: size,
                                        borderRadius: corners,
                                        fallback: Center(
                                            child: Icon(icon,
                                                size: 31,
                                                color: scheme.primary)),
                                      ),
                                    ),
                                  );
                                }),
                          const Spacer(),
                          if (action != null)
                            FilledButton.icon(
                              onPressed: _busy ? null : _performAction,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 15,
                                      height: 15,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : Icon(
                                      action.$2
                                          ? Icons.check_rounded
                                          : Icons.add_rounded,
                                      size: 17,
                                    ),
                              label: Text(action.$1),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (_loading) ...[
                        const SizedBox(height: 6),
                        const SkeletonParagraph(lines: 2, lineHeight: 10),
                      ] else ...[
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        if (about.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            about,
                            style: const TextStyle(height: 1.4, fontSize: 12),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              style: TextStyle(color: AppColors.dangerOf(context), fontSize: 12),
            ),
          ),
        if (_loading)
          const SkeletonBox(height: 58, radius: 15)
        else if (stats.isNotEmpty)
          Row(
            children: [
              for (final (i, stat) in stats.indexed)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: i == stats.length - 1 ? 0 : 7,
                    ),
                    child: ProfileStat(stat.$1, stat.$2, onTap: stat.$3),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 18),
        if (_user case final u?)
          _PersonProfileDetail(
            user: u,
            posts: _posts,
            dependencies: widget.dependencies,
          )
        else if (_bot case final b?)
          _BotProfileDetail(bot: b, dependencies: widget.dependencies)
        else if (_space case final s?)
          _WorkspaceProfileDetail(space: s, dependencies: widget.dependencies)
        else if (_room case final r?)
          _RoomProfileDetail(room: r, dependencies: widget.dependencies),
      ],
    );
  }

  static void _showAccountList(
    BuildContext context,
    AppDependencies deps,
    String userId,
    bool following,
  ) {
    final title = following ? 'Following' : 'Followers';
    showAppDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          width: 360,
          height: 420,
          child: FutureBuilder<List<AccountSummary>>(
            future: following
                ? deps.service.fetchFollowing(accountId: userId)
                : deps.service.fetchFollowers(accountId: userId),
            builder: (ctx, snap) {
              final list = snap.data ?? const <AccountSummary>[];
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      snap.connectionState == ConnectionState.done
                          ? '$title · ${list.length}'
                          : title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: snap.connectionState != ConnectionState.done
                        ? const Center(child: CircularProgressIndicator())
                        : list.isEmpty
                        ? Center(
                            child: Text(
                              'None yet',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (_, i) => ListTile(
                              dense: true,
                              onTap: () {
                                Navigator.pop(ctx);
                                showAccountProfile(
                                  context,
                                  deps,
                                  accountId: list[i].id,
                                  handle: list[i].handle,
                                );
                              },
                              leading: Builder(builder: (context) {
                                const radius = 16.0;
                                final size = radius * 2;
                                final corners =
                                    context.avatarBorderRadius(size);
                                final picture = Avatars.of(list[i].avatar);
                                return HaloRing(
                                  identity: HaloRingCache.person(list[i].id),
                                  borderRadius: corners,
                                  child: AvatarFace(
                                    size: size,
                                    borderRadius: corners,
                                    foregroundImage: picture,
                                    onImageError: picture == null
                                        ? null
                                        : (_, __) {},
                                    backgroundColor:
                                        ThemeRoles.wellFill(context),
                                    child: Text(
                                      list[i].handle.isEmpty
                                          ? '?'
                                          : list[i].handle[0].toUpperCase(),
                                      style: TextStyle(
                                        color: ThemeRoles.wellInk(context),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                              title: Text(
                                '@${list[i].handle}',
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                list[i].kind,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ProfileDetailCard extends StatelessWidget {
  const _ProfileDetailCard(this.title, this.icon, this.child);
  final String title;
  final IconData icon;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: GlassSurface(
      borderRadius: ThemeChrome.softCardCorners(context, AppShape.inner),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    ),
  );
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 11,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _PersonProfileDetail extends StatelessWidget {
  const _PersonProfileDetail({
    required this.user,
    required this.posts,
    this.dependencies,
  });
  final UserProfile user;
  final List<SocialPost> posts;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) => _ProfileDetailCard(
    'Recent posts',
    Icons.dynamic_feed_rounded,
    posts.isEmpty
        ? const _EmptyNote('No posts yet.')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in posts.take(5))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 12, height: 1.45),
                        child: RichPostContent(
                          p.body,
                          headers:
                              dependencies?.service.authHeaders() ?? const {},
                          resolveUrl: dependencies?.service.resolveContentUrl,
                        ),
                      ),
                      Text(
                        _timeAgo(p.createdAt),
                        style: TextStyle(
                          fontSize: 8,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
  );
}

/// The detail of an agent or an app (tool): both are bots on a VM.
class _BotProfileDetail extends StatelessWidget {
  const _BotProfileDetail({required this.bot, this.dependencies});
  final BotProfile bot;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    final cpu = bot.resources['cpu'] as num?;
    final ram = bot.resources['memory_mb'] as num?;
    final disk = bot.resources['disk_mb'] as num?;
    final costPerMinute = bot.cost['per_minute'] as num?;
    final category = bot.listing['category'] as String? ?? '';
    return Column(
      children: [
        _ProfileDetailCard(
          'Runtime',
          Icons.monitor_heart_rounded,
          Row(
            children: [
              _ResourceCell(
                'VM',
                bot.vmType.isEmpty ? '—' : bot.vmType.toUpperCase(),
              ),
              _ResourceCell('Frontend', bot.hasFrontend ? 'Elpian' : 'None'),
              _ResourceCell('Image', bot.imageRef.isEmpty ? '—' : bot.imageRef),
            ],
          ),
        ),
        if (cpu != null || ram != null || disk != null)
          _ProfileDetailCard(
            'Resources',
            Icons.memory_rounded,
            Row(
              children: [
                if (cpu != null) _ResourceCell('CPU', '$cpu vCPU'),
                if (ram != null) _ResourceCell('RAM', '$ram MB'),
                if (disk != null) _ResourceCell('Disk', '$disk MB'),
              ],
            ),
          ),
        _ProfileDetailCard(
          'Usage',
          Icons.analytics_rounded,
          Row(
            children: [
              _ResourceCell('Tokens', '${bot.tokens}'),
              if (costPerMinute != null)
                _ResourceCell('Cost/min', '$costPerMinute'),
            ],
          ),
        ),
        if (bot.listing.isNotEmpty)
          _ProfileDetailCard(
            'Marketplace',
            Icons.storefront_rounded,
            Row(
              children: [
                _ResourceCell(
                  'Price',
                  bot.price == 0 ? 'Free' : '${bot.price}',
                ),
                if (category.isNotEmpty) _ResourceCell('Category', category),
              ],
            ),
          ),
        if (bot.entities.isNotEmpty)
          _ProfileDetailCard(
            'Entities',
            Icons.folder_copy_rounded,
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final key in bot.entities) Chip(label: Text(key)),
              ],
            ),
          ),
        if (bot.ownerHandle.isNotEmpty)
          _ProfileDetailCard(
            'Owner',
            Icons.person_outline_rounded,
            InkWell(
              onTap: deps == null || bot.ownerId.isEmpty
                  ? null
                  : () => showAccountProfile(
                      context,
                      deps,
                      accountId: bot.ownerId,
                      handle: bot.ownerHandle,
                    ),
              child: Text(
                '@${bot.ownerHandle}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _WorkspaceProfileDetail extends StatelessWidget {
  const _WorkspaceProfileDetail({required this.space, this.dependencies});
  final SpaceProfile space;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    return Column(
      children: [
        _ProfileDetailCard(
          'Rooms',
          Icons.grid_view_rounded,
          space.rooms.isEmpty
              ? const _EmptyNote('No rooms yet.')
              : LayoutBuilder(
                  builder: (context, box) {
                    final columns = box.maxWidth < 420 ? 2 : 3;
                    return GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: columns,
                      mainAxisSpacing: 7,
                      crossAxisSpacing: 7,
                      childAspectRatio: 1.8,
                      children: [
                        for (final r in space.rooms)
                          _WorkspaceRoomPreview(
                            r,
                            Icons.forum_outlined,
                            onTap: () => _openEntityProfile(
                              context,
                              'Rooms',
                              r,
                              deps,
                              space.id,
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
        _ProfileDetailCard(
          'Community',
          Icons.groups_rounded,
          Row(
            children: [
              _ResourceCell('Agents', '${space.agentCount}'),
              _ResourceCell('Files', '${space.fileCount}'),
              if (space.home) const _ResourceCell('Home', 'Yes'),
            ],
          ),
        ),
      ],
    );
  }
}

class _WorkspaceRoomPreview extends StatelessWidget {
  const _WorkspaceRoomPreview(this.label, this.icon, {this.onTap});
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final corners = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      borderRadius: corners,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Icon(icon, size: 15),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _RoomProfileDetail extends StatelessWidget {
  const _RoomProfileDetail({required this.room, this.dependencies});
  final RoomProfile room;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final deps = dependencies;
    return Column(
      children: [
        _ProfileDetailCard(
          'Workspace',
          Icons.hub_rounded,
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: room.spaceId.isEmpty
                      ? null
                      : () => _openEntityProfile(
                          context,
                          'Workspaces',
                          room.spaceName,
                          deps,
                          '',
                          room.spaceId,
                        ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.spaceName.isEmpty ? '—' : room.spaceName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text('Workspace', style: TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              ),
              _ResourceCell('Files', '${room.fileCount}'),
            ],
          ),
        ),
        _ProfileDetailCard(
          'Recent room activity',
          Icons.forum_outlined,
          room.recentMessages.isEmpty
              ? const _EmptyNote('No messages yet.')
              : Column(
                  children: [
                    for (final m in room.recentMessages)
                      _RoomActivityRow(
                        Icons.chat_bubble_outline_rounded,
                        '${_sender(m)}: ${m['body'] as String? ?? ''}',
                        _timeAgo(
                          DateTime.tryParse(m['created_at'] as String? ?? '') ??
                              DateTime.now(),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  static String _sender(Map<String, dynamic> m) {
    final handle = m['sender_handle'] as String? ?? '';
    return handle.isNotEmpty
        ? '@$handle'
        : _short(m['sender_id'] as String? ?? '?', 8);
  }
}

class _ResourceCell extends StatelessWidget {
  const _ResourceCell(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 9)),
      ],
    ),
  );
}

class _RoomActivityRow extends StatelessWidget {
  const _RoomActivityRow(this.icon, this.label, this.time);
  final IconData icon;
  final String label, time;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: [
        Icon(icon, size: 16),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 10))),
        Text(time, style: const TextStyle(fontSize: 8)),
      ],
    ),
  );
}

