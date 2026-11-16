part of 'workspace_screen.dart';

class _MobileTabs extends StatelessWidget {
  const _MobileTabs({
    required this.selected,
    required this.room,
    required this.onSelect,
  });
  final int selected;
  final String? room;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) => SegmentedTabBar(
    selectedIndex: selected,
    onTap: onSelect,
    labels: ['Desk', room == null ? 'Feed' : 'Chat'],
    icons: [
      Icons.dashboard_customize_outlined,
      room == null ? Icons.dynamic_feed_outlined : Icons.forum_outlined,
    ],
  );
}

class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel({
    required this.room,
    required this.workspace,
    required this.rooms,
    required this.tab,
    this.bots = const [],
    this.spaceBots = const [],
    this.allBots = const [],
    this.flat = false,
    this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.fileRevision = 0,
    required this.onTab,
    this.onOpenApp,
    this.onOpenFile,
    this.openFilePath = '',
    this.onCreateRoom,
    this.onSearch,
    this.onAddBot,
    this.onRemoveBot,
    this.onAddApp,
    this.appConnections = const {},
    this.onConnectApp,
    this.onOpenSettings,
    required this.openRoom,
    this.direct = false,
  });
  final String? room;
  final String workspace;
  final List<String> rooms;
  final List<Bot> bots;
  final List<Bot> spaceBots;
  final List<Bot> allBots;
  final int tab;
  final bool flat;
  final AppDependencies? dependencies;
  final String spaceId;
  final String roomId;

  /// Bumped whenever files are uploaded/attached so the file library tabs
  /// (Docs/GIFs/Media/Audio) reload.
  final int fileRevision;
  final ValueChanged<int> onTab;
  final ValueChanged<String> openRoom;
  final ValueChanged<Bot>? onOpenApp;

  /// Opens a workspace file (`/workspace/…`) from the Files tab.
  final ValueChanged<String>? onOpenFile;

  /// The file open now, highlighted in the Files tab.
  final String openFilePath;
  final VoidCallback? onCreateRoom;
  final VoidCallback? onSearch;
  final ValueChanged<Bot>? onAddBot;
  final ValueChanged<Bot>? onRemoveBot;

  /// Adds an MCP app (from the catalog or by its address) to the space.
  final VoidCallback? onAddApp;

  /// Each app's sign-in state here, by bot id: an app each person connects
  /// with their own account offers Connect, or Reconnect once connected.
  final Map<String, ({String auth, bool connected, String name})>
  appConnections;
  final void Function(Bot bot, bool reconnect)? onConnectApp;

  /// Opens the space's settings, from the button under the tabs.
  final VoidCallback? onOpenSettings;

  /// A direct chat: the same rail, without Rooms, Files, Computer, Memory
  /// or Previews. Those belong to a workspace.
  final bool direct;

  /// The first of the space's facility tabs (Files, Computer, Memory,
  /// Previews), which follow the library tabs.
  static const facilitiesTab = 8;
  static const icons = [
    Icons.forum_outlined,
    Icons.smart_toy_outlined,
    Icons.extension_outlined,
    Icons.description_outlined,
    Icons.link,
    Icons.gif_box_outlined,
    Icons.perm_media_outlined,
    Icons.graphic_eq_rounded,
    Icons.folder_copy_outlined,
    Icons.desktop_windows_outlined,
    Icons.psychology_outlined,
    Icons.open_in_browser_outlined,
  ];
  static const labels = [
    'Rooms',
    'Agents',
    'Apps',
    'Docs',
    'Links',
    'GIFs',
    'Media',
    'Audio',
    'Files',
    'Computer',
    'Memory',
    'Previews',
  ];

  /// Tabs a direct chat keeps: agents, apps and the media library.
  static const directTabs = <int>[1, 2, 3, 4, 5, 6, 7];

  int get _active {
    if (!direct) return tab;
    return directTabs.contains(tab) ? tab : directTabs.first;
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final shown = direct
        ? directTabs
        : [for (var i = 0; i < icons.length; i++) i];
    return _Panel(
    flat: flat,
    child: Row(
      children: [
        Container(
          width: 58,
          margin: const EdgeInsets.fromLTRB(8, 10, 6, 10),
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: .58),
            borderRadius: ThemeChrome.softCardCorners(context, AppShape.inner),
          ),
          // The library tabs, then (past a divider) the space's
          // facilities; the rail scrolls when the panel is short. The
          // space's settings stay pinned under them.
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final i in shown) ...[
                          // Rooms, the library, then the space's facilities.
                          // A direct chat splits agents and apps from media.
                          if (direct ? i == 3 : (i == 1 || i == facilitiesTab))
                            Container(
                              width: 26,
                              height: 1,
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              color: Theme.of(
                                context,
                              ).colorScheme.outlineVariant,
                            ),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Tooltip(
                              message: labels[i],
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  onTap: () => onTab(i),
                                  borderRadius: AppShape.borderRadius(context, 16),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 240),
                                    curve: Curves.easeOutCubic,
                                    width: 42,
                                    height: 42,
                                    decoration: BoxDecoration(
                                      color: i == active
                                          ? ThemeRoles.selectedFill(context)
                                          : Colors.transparent,
                                      borderRadius: AppShape.borderRadius(context, 16),
                                    ),
                                    child: Icon(
                                      icons[i],
                                      size: 20,
                                      color: i == active
                                          ? ThemeRoles.selectedInk(context)
                                          : Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (onOpenSettings != null) ...[
                Container(
                  width: 26,
                  height: 1,
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                IconButton(
                  tooltip: 'Workspace settings',
                  onPressed: onOpenSettings,
                  icon: Icon(
                    Icons.settings_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 16, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            labels[active],
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            room ?? workspace,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // A facility tab carries its own actions.
                    if (active < facilitiesTab) ...[
                      IconButton.filledTonal(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Find ${labels[active].toLowerCase()}',
                        onPressed: onSearch,
                        icon: const Icon(Icons.search_rounded, size: 18),
                      ),
                      const SizedBox(width: 3),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: active == 0 ? 'New room' : 'Add',
                        onPressed: active == 0 ? onCreateRoom : null,
                        icon: const Icon(Icons.add_rounded, size: 19),
                      ),
                    ],
                  ],
                ),
                if (spaceBots.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  OrbitStrip(
                    agents: spaceBots.where((b) => b.isAgent).toList(),
                    tools: spaceBots
                        .where((b) => b.isTool && !b.isSandbox)
                        .toList(),
                    userId: dependencies
                            ?.sessionController.session?.accountId ??
                        '',
                  ),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: KeyedSubtree(
                      key: ValueKey('$workspace-$room-$active'),
                      child: _libraryContent(context, active),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  }

  Widget _libraryContent(BuildContext context, int tab) {
    if (tab == 0) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: rooms.length,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          final name = rooms[index];
          return _LibraryRoomCard(
            name: name,
            index: index,
            selected: name == (room ?? _WorkspaceScreenState.hallRoom),
            dependencies: dependencies,
            spaceId: spaceId,
            onTap: () => openRoom(name),
          );
        },
      );
    }
    if (tab >= facilitiesTab) {
      final deps = dependencies;
      if (deps == null || spaceId.isEmpty) {
        return const _LibraryEmpty(
          icon: Icons.cloud_off_outlined,
          message: 'Open a workspace to manage its facilities.',
        );
      }
      if (tab == facilitiesTab) {
        return WorkspaceFileTree(
          service: deps.service,
          spaceId: spaceId,
          selected: openFilePath,
          onOpen: (e) => onOpenFile?.call(e.path),
        );
      }
      if (tab == facilitiesTab + 1) {
        return SpaceComputerTab(dependencies: deps, spaceId: spaceId);
      }
      if (tab == facilitiesTab + 2) {
        return SpaceMemoryTab(
          dependencies: deps,
          spaceId: spaceId,
          agents: spaceBots.where((b) => b.isAgent).toList(),
        );
      }
      return SpacePreviewsTab(dependencies: deps, spaceId: spaceId);
    }
    if (tab >= 3) {
      // Docs / Links / GIFs / Media / Audio are backed by the space's file
      // library (spaces.file_list), filtered by mime type.
      return _LibraryFilesList(
        spaceId: spaceId,
        roomId: roomId,
        kind: tab,
        fileRevision: fileRevision,
        dependencies: dependencies,
      );
    }
    if (tab == 1) {
      // Only agents explicitly added to this workspace are shown.
      final agents = spaceBots.where((b) => b.isAgent).toList();
      final candidates = allBots
          .where((b) => b.isAgent && !spaceBots.any((s) => s.id == b.id))
          .toList();
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: agents.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (index == agents.length) {
            return _AddBotTile(
              label: 'Add agent',
              icon: Icons.smart_toy_outlined,
              candidates: candidates,
              userId: dependencies
                      ?.sessionController.session?.accountId ??
                  '',
              onAdd: (b) => onAddBot?.call(b),
            );
          }
          final bot = agents[index];
          return _LibraryBotCard(
            bot: bot,
            dependencies: dependencies,
            spaceId: spaceId,
            onRemove: onRemoveBot == null ? null : () => onRemoveBot!(bot),
          );
        },
      );
    }
    if (tab == 2) {
      // Only apps explicitly added to this workspace are shown.
      // The space's own computer is its Files tab, not an app.
      final tools = spaceBots.where((b) => b.isTool && !b.isSandbox).toList();
      final addApp = onAddApp;
      // "Add an app" offers the person's own apps too; the plain picker is
      // only for when it is not available.
      final candidates = addApp != null
          ? const <Bot>[]
          : allBots
                .where(
                  (b) =>
                      b.isTool &&
                      !b.isSandbox &&
                      !spaceBots.any((s) => s.id == b.id),
                )
                .toList();
      if (tools.isEmpty && candidates.isEmpty && addApp == null) {
        return const _LibraryEmpty(
          icon: Icons.widgets_outlined,
          message: 'No apps in this workspace yet — add one.',
        );
      }
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount:
            tools.length +
            (candidates.isEmpty ? 0 : 1) +
            (addApp == null ? 0 : 1),
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (addApp != null && index == tools.length) {
            return _AddAppTile(onTap: addApp);
          }
          if (index == tools.length) {
            return _AddBotTile(
              label: 'Add app',
              icon: Icons.widgets_outlined,
              candidates: candidates,
              userId: dependencies
                      ?.sessionController.session?.accountId ??
                  '',
              onAdd: (b) => onAddBot?.call(b),
            );
          }
          final bot = tools[index];
          final connection = appConnections[bot.id];
          final connect = onConnectApp;
          return _LibraryToolCard(
            bot: bot,
            label: bot.name,
            subtitle:
                personalApp(connection?.auth ?? '') && !connection!.connected
                ? 'Needs your sign-in'
                : '${bot.toolModeLabel} · ${bot.status}',
            icon: Icons.widgets_outlined,
            dependencies: dependencies,
            spaceId: spaceId,
            connected: connection?.connected ?? true,
            onConnect: connect == null || !personalApp(connection?.auth ?? '')
                ? null
                : () => connect(bot, connection!.connected),
            onTap: () => onOpenApp?.call(bot),
            onRemove: onRemoveBot == null ? null : () => onRemoveBot!(bot),
          );
        },
      );
    }
    return const _LibraryEmpty(
      icon: Icons.folder_outlined,
      message: 'Nothing here yet. Upload files to your workspace.',
    );
  }
}

/// The workspace library rail for a direct chat: same chrome, without the
/// workspace-only tabs (rooms, files, computer, memory, previews).
class DirectChatLibrary extends StatelessWidget {
  const DirectChatLibrary({
    super.key,
    required this.title,
    required this.tab,
    required this.onTab,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    this.agents = const [],
    this.apps = const [],
    this.allBots = const [],
    this.onAddBot,
    this.onRemoveBot,
    this.onAddApp,
    this.onOpenApp,
    this.appConnections = const {},
    this.onConnectApp,
    this.fileRevision = 0,
    this.card = false,
  });

  final String title;
  final int tab;
  final ValueChanged<int> onTab;
  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final List<Bot> agents;
  final List<Bot> apps;
  final List<Bot> allBots;
  final ValueChanged<Bot>? onAddBot;
  final ValueChanged<Bot>? onRemoveBot;
  final VoidCallback? onAddApp;
  final ValueChanged<Bot>? onOpenApp;
  final Map<String, ({String auth, bool connected, String name})>
  appConnections;
  final void Function(Bot bot, bool reconnect)? onConnectApp;
  final int fileRevision;

  /// Glass card, for the desktop flyout. The drawer stays flat.
  final bool card;

  @override
  Widget build(BuildContext context) {
    return ThemeSlotHost(
      slot: FeatureSlots.workspaceRail,
      child: ThemeSlotHost(
        slot: ThemeChromeSlots.workspaceRail,
        child: _LibraryPanel(
          direct: true,
          room: title,
          workspace: title,
          rooms: const [],
          spaceBots: [...agents, ...apps],
          allBots: allBots,
          tab: tab,
          flat: !card,
          dependencies: dependencies,
          spaceId: spaceId,
          roomId: roomId,
          fileRevision: fileRevision,
          onTab: onTab,
          onAddBot: onAddBot,
          onRemoveBot: onRemoveBot,
          onAddApp: onAddApp,
          onOpenApp: onOpenApp,
          appConnections: appConnections,
          onConnectApp: onConnectApp,
          openRoom: (_) {},
        ),
      ),
    );
  }
}

class _LibraryEmpty extends StatelessWidget {
  const _LibraryEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => PanelEmpty(
        compact: true,
        icon: icon,
        title: 'Nothing here',
        message: message,
      );
}

/// File-backed library content for the Docs/Links/GIFs/Media/Audio tabs.
class _LibraryFilesList extends StatefulWidget {
  const _LibraryFilesList({
    required this.spaceId,
    required this.roomId,
    required this.kind,
    this.fileRevision = 0,
    this.dependencies,
  });
  final String spaceId;
  final String roomId;
  final int kind;
  final int fileRevision;
  final AppDependencies? dependencies;
  @override
  State<_LibraryFilesList> createState() => _LibraryFilesListState();
}

class _LibraryFilesListState extends State<_LibraryFilesList> {
  static const _pageSize = 50;
  List<Map<String, dynamic>> _files = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _LibraryFilesList old) {
    super.didUpdateWidget(old);
    if (old.spaceId != widget.spaceId ||
        old.roomId != widget.roomId ||
        old.kind != widget.kind ||
        old.fileRevision != widget.fileRevision) {
      _load();
    }
  }

  Future<void> _load({bool more = false}) async {
    final deps = widget.dependencies;
    if (deps == null || widget.spaceId.isEmpty) {
      setState(() {
        _files = const [];
        _loading = false;
      });
      return;
    }
    if (more) {
      if (_loadingMore || !_hasMore || _loading) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() => _loading = true);
    }
    try {
      final offset = more ? _offset : 0;
      final all = await deps.service.fetchFiles(
        widget.spaceId,
        roomId: widget.roomId,
        limit: _pageSize,
        offset: offset,
      );
      final files = all.where(_matchesKind).toList();
      if (!mounted) return;
      setState(() {
        if (more) {
          _files = [..._files, ...files];
          _offset += all.length;
        } else {
          _files = files;
          _offset = all.length;
        }
        _hasMore = all.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _files = const [];
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  bool _matchesKind(Map<String, dynamic> file) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (widget.kind) {
      case 3: // Docs
        return mime.contains('pdf') ||
            mime.contains('text') ||
            mime.contains('markdown') ||
            mime.contains('doc');
      case 4: // Links
        return mime.contains('html') || mime.contains('url');
      case 5: // GIFs
        return mime == 'image/gif';
      case 6: // Media
        return mime.startsWith('image/') || mime.startsWith('video/');
      case 7: // Audio
        return mime.startsWith('audio/');
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonList();
    if (_files.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            'No files in this workspace yet. Upload one to see it here.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 10,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_hasMore && !_loadingMore && n.metrics.extentAfter < 250) {
          unawaited(_load(more: true));
        }
        return false;
      },
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: _files.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 7),
        itemBuilder: (context, index) {
          if (index >= _files.length) {
            return const SkeletonListTile();
          }
          final file = _files[index];
          final name = file['name'] as String? ?? 'file';
          final mime = file['mime'] as String? ?? '';
          final size = (file['size'] as num?)?.toInt() ?? 0;
          return _LibraryListCard(
            label: name,
            icon: _iconFor(mime),
            kind: 3,
            index: index,
            subtitle: '$mime · ${_humanSize(size)}',
            dependencies: widget.dependencies,
          );
        },
      ),
    );
  }

  IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.graphic_eq_rounded;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  static String _humanSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }
}

class _LibraryRoomCard extends StatelessWidget {
  const _LibraryRoomCard({
    required this.name,
    required this.index,
    required this.selected,
    required this.onTap,
    this.dependencies,
    this.spaceId = '',
  });
  final String name;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) {
    final hall = name == _WorkspaceScreenState.hallRoom;
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context, selected: selected),
      borderRadius: corners,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary,
                      Theme.of(context).colorScheme.tertiary,
                    ],
                  ),
                  borderRadius: well,
                ),
                child: Center(
                  child: hall
                      ? const Icon(
                          Icons.dynamic_feed_rounded,
                          color: Colors.white,
                          size: 19,
                        )
                      : Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: AppColors.successOf(context),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            hall
                                ? 'Workspace feed · live now'
                                : '${4 + index * 3} active · ${12 + index} new',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Room profile',
                onPressed: () => _openEntityProfile(
                  context,
                  'Rooms',
                  name,
                  dependencies,
                  spaceId,
                ),
                icon: const Icon(Icons.info_outline_rounded, size: 17),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryListCard extends StatelessWidget {
  const _LibraryListCard({
    required this.label,
    required this.icon,
    required this.kind,
    required this.index,
    this.subtitle,
    this.dependencies,
  });
  final String label;
  final IconData icon;
  final int kind, index;
  final String? subtitle;
  final AppDependencies? dependencies;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    child: InkWell(
      onTap: kind == 1 || kind == 2
          ? () => _openEntityProfile(
              context,
              kind == 1 ? 'Agents' : 'Apps',
              label,
              dependencies,
            )
          : null,
      borderRadius: corners,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: well,
              ),
              child: Icon(icon, size: 17),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle ??
                        (kind == 1
                            ? (index == 0
                                  ? 'Running · 4 tasks'
                                  : 'Ready to deploy')
                            : kind == 7
                            ? '${index + 1}:${20 + index * 7} · voice note'
                            : kind == 3
                            ? '${2 + index * 3} pages · edited today'
                            : 'Saved in this workspace'),
                    style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () {},
              icon: const Icon(Icons.more_horiz_rounded, size: 17),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _LibraryBotCard extends StatelessWidget {
  const _LibraryBotCard({
    required this.bot,
    this.dependencies,
    this.spaceId = '',
    this.onRemove,
  });
  final Bot bot;
  final AppDependencies? dependencies;
  final String spaceId;
  final VoidCallback? onRemove;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: () => _openEntityProfile(
          context,
          'Agents',
          bot.name,
          dependencies,
          spaceId,
        ),
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              BotAvatar(
                bot: bot,
                radius: 18,
                userId: dependencies
                        ?.sessionController.session?.accountId ??
                    '',
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bot.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${bot.kind} · ${bot.vmType} · ${bot.status}',
                      style: TextStyle(
                        fontSize: 9,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remove from workspace',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, size: 17),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tile that opens a picker of candidate bots (not yet in the workspace) and
/// adds the selected one.
/// Opens "Add an app": an MCP server from the catalog or by its address,
/// with each person's sign-in right after when it needs one.
class _AddAppTile extends StatelessWidget {
  const _AddAppTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: onTap,
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: well,
                ),
                child: Icon(
                  Icons.add_link_rounded,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add an app',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'MCP server, with sign-in',
                      style: TextStyle(fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddBotTile extends StatelessWidget {
  const _AddBotTile({
    required this.label,
    required this.icon,
    required this.candidates,
    required this.onAdd,
    this.userId = '',
  });
  final String label;
  final IconData icon;
  final List<Bot> candidates;
  final ValueChanged<Bot> onAdd;
  final String userId;

  void _pick(BuildContext context) {
    if (candidates.isEmpty) {
      showAppDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nothing to add'),
          content: const Text(
            'No bots of this type are available yet. Create one in My bots or install from the market.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    showAppPicker<Bot>(
      context: context,
      anchor: context,
      showDragHandle: false,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Add $label',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: candidates.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final b = candidates[i];
                    return ListTile(
                      leading: BotAvatar(
                        bot: b,
                        radius: 16,
                        userId: userId,
                      ),
                      title: Text(b.name, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${b.kind} · ${b.vmType}',
                        style: const TextStyle(fontSize: 10),
                      ),
                      trailing: const Icon(Icons.add_rounded),
                      onTap: () => Navigator.pop(context, b),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    ).then((b) {
      if (b != null) onAdd(b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
      color: ThemeChrome.cardFillColor(context),
      borderRadius: corners,
      child: InkWell(
        onTap: () => _pick(context),
        borderRadius: corners,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .14),
                  borderRadius: well,
                ),
                child:
                    Icon(icon, size: 19, color: AppColors.primaryOf(context)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const Icon(Icons.add_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibraryToolCard extends StatelessWidget {
  const _LibraryToolCard({
    required this.label,
    required this.icon,
    this.bot,
    this.subtitle,
    this.onTap,
    this.onRemove,
    this.onConnect,
    this.connected = true,
    this.dependencies,
    this.spaceId = '',
  });
  final String label;
  final IconData icon;
  final Bot? bot;
  final String? subtitle;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  /// Signs the caller's own account in to an app each person connects;
  /// null for an app everyone shares.
  final VoidCallback? onConnect;
  final bool connected;
  final AppDependencies? dependencies;
  final String spaceId;
  @override
  Widget build(BuildContext context) {
    final corners = ThemeChrome.softCardCorners(context);
    final well = AppShape.borderRadius(context, AppShape.control);
    return Material(
    color: ThemeChrome.cardFillColor(context),
    borderRadius: corners,
    child: InkWell(
      onTap:
          onTap ??
          () =>
              _openEntityProfile(context, 'Apps', label, dependencies, spaceId),
      borderRadius: corners,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            if (bot != null)
              BotAvatar(
                bot: bot!,
                radius: 18,
                userId: dependencies
                        ?.sessionController.session?.accountId ??
                    '',
              )
            else
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .14),
                  borderRadius: well,
                ),
                child: Icon(icon, size: 19, color: AppColors.primaryOf(context)),
              ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: connected
                              ? AppColors.successOf(context)
                              : AppColors.warningOf(context),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          subtitle ?? 'Connected',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onConnect != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: connected
                    ? 'Reconnect your account'
                    : 'Connect your account',
                onPressed: onConnect,
                icon: Icon(
                  connected ? Icons.sync_rounded : Icons.login_rounded,
                  size: 17,
                  color: connected ? null : AppColors.warningOf(context),
                ),
              ),
            if (onRemove != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove from workspace',
                onPressed: onRemove,
                icon: const Icon(Icons.close_rounded, size: 17),
              ),
          ],
        ),
      ),
    ),
    );
  }
}

