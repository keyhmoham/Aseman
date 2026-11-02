import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_surfaces.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/bot_avatar.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_empty.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';
import '../../../shared/widgets/skeleton.dart';
import '../../files/presentation/file_tree.dart';
import '../../files/presentation/file_viewer.dart';
import '../../home/presentation/widgets/space_facility_tabs.dart';
import '../../tools/connect/add_app.dart';
import '../../tools/connect/mcp_connect_dialog.dart';

/// Multi-tab bottom sheet for a direct chat's room facilities — the DM
/// counterpart to a space library drawer.
Future<void> showDmFacilitySheet(
  BuildContext context, {
  required AppDependencies dependencies,
  required String spaceId,
  required String roomId,
  required String title,
  List<Bot> agents = const [],
  List<Bot> apps = const [],
  ChatPeer? peer,
  Future<void> Function()? onChanged,
}) {
  final sheet = MediaQuery.sizeOf(context).width < 820;
  final panel = DmFacilitySheet(
    dependencies: dependencies,
    spaceId: spaceId,
    roomId: roomId,
    title: title,
    initialAgents: agents,
    initialApps: apps,
    peer: peer,
    onChanged: onChanged,
  );
  if (sheet) {
    return showAppSheet<void>(context, panel, heightFactor: .92);
  }
  return showFloatingPanel(
    context,
    panel,
    maxWidth: 560,
    maxHeight: 820,
    barrierLabel: 'Close room',
  );
}

class DmFacilitySheet extends StatefulWidget {
  const DmFacilitySheet({
    super.key,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.title,
    this.initialAgents = const [],
    this.initialApps = const [],
    this.peer,
    this.onChanged,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final String title;
  final List<Bot> initialAgents;
  final List<Bot> initialApps;

  /// The founding conversation peer (person or agent). The peer agent of an
  /// AI direct cannot be removed — only additionally installed subagents.
  final ChatPeer? peer;
  final Future<void> Function()? onChanged;

  static const labels = [
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

  static const icons = [
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

  @override
  State<DmFacilitySheet> createState() => _DmFacilitySheetState();
}

class _DmFacilitySheetState extends State<DmFacilitySheet> {
  int _tab = 0;
  late List<Bot> _agents = List.of(widget.initialAgents);
  late List<Bot> _apps = List.of(widget.initialApps);
  List<Bot> _allBots = const [];
  bool _loadingBots = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loadingBots = true);
    try {
      final space = await widget.dependencies.service.fetchSpaceBots(
        widget.spaceId,
      );
      final all = await widget.dependencies.service.fetchBots();
      if (!mounted) return;
      setState(() {
        _agents = space.where((b) => b.isAgent).toList();
        _apps = space.where((b) => b.isTool && !b.isSandbox).toList();
        _allBots = all;
        _loadingBots = false;
      });
      await widget.onChanged?.call();
    } catch (_) {
      if (mounted) setState(() => _loadingBots = false);
    }
  }

  Future<void> _addAgent(Bot bot) async {
    try {
      await widget.dependencies.service.addBotToSpace(widget.spaceId, bot.id);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add agent: $e')),
      );
    }
  }

  /// True when [bot] is the founding agent peer of this direct (not a
  /// subagent someone installed later).
  bool _isPeerAgent(Bot bot) {
    final peer = widget.peer;
    if (peer == null || !peer.isAgent) return false;
    return bot.id == peer.botId ||
        bot.accountId == peer.id ||
        bot.id == peer.id ||
        (peer.botId.isNotEmpty && bot.accountId == peer.botId);
  }

  Future<void> _removeBot(Bot bot) async {
    if (_isPeerAgent(bot)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The other participant cannot be removed from this chat.'),
        ),
      );
      return;
    }
    try {
      await widget.dependencies.service.removeBotFromSpace(
        widget.spaceId,
        bot.id,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not remove: $e')),
      );
    }
  }

  Future<void> _addApp() async {
    final added = await showAddApp(
      context,
      widget.dependencies.service,
      spaceId: widget.spaceId,
    );
    if (added) await _reload();
  }

  Future<void> _pickAgent() async {
    final candidates = _allBots
        .where((b) => b.isAgent && !_agents.any((a) => a.id == b.id))
        .toList();
    if (candidates.isEmpty) {
      await showAppDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nothing to add'),
          content: const Text(
            'No other agents are available. Create one in My bots or install from the market.',
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
    final picked = await showAppPicker<Bot>(
      context: context,
      anchor: context,
      showDragHandle: false,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Add agent',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
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
                        userId: widget.dependencies.sessionController
                                .session?.accountId ??
                            '',
                      ),
                      title: Text(b.name),
                      subtitle: Text('${b.kind} · ${b.vmType}'),
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
    );
    if (picked != null) await _addAgent(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.title} room',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedTabBar(
                labels: DmFacilitySheet.labels,
                icons: DmFacilitySheet.icons,
                selectedIndex: _tab,
                onTap: (i) => setState(() => _tab = i),
                compact: true,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: GlassSurface(
                  alpha: AppSurfaces.cardAlpha,
                  blur: AppSurfaces.blurSigma,
                  borderRadius: BorderRadius.circular(22),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _body(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_tab) {
      case 0:
        if (_loadingBots && _agents.isEmpty) {
          return const SkeletonList();
        }
        return _BotList(
          bots: _agents,
          emptyIcon: Icons.smart_toy_outlined,
          emptyTitle: 'No agents yet',
          emptyMessage:
              'Agents you add here are yours in this chat and use your personal sandbox.',
          onAdd: _pickAgent,
          onRemove: _removeBot,
          canRemove: (b) => !_isPeerAgent(b),
          userId: widget.dependencies.sessionController.session?.accountId ?? '',
          addLabel: 'Add agent',
        );
      case 1:
        if (_loadingBots && _apps.isEmpty) {
          return const SkeletonList();
        }
        return _BotList(
          bots: _apps,
          emptyIcon: Icons.extension_outlined,
          emptyTitle: 'No apps yet',
          emptyMessage:
              'Apps you install here are scoped to this chat in your personal sandbox.',
          onAdd: _addApp,
          onRemove: _removeBot,
          addLabel: 'Add app',
          onOpen: (bot) async {
            await connectMcpToolIfNeeded(
              context,
              widget.dependencies.service,
              botId: bot.id,
              spaceId: widget.spaceId,
              name: bot.name,
            );
          },
        );
      case 2:
        return _MimeFiles(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          kind: _MimeKind.docs,
        );
      case 3:
        return _MimeFiles(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          kind: _MimeKind.links,
        );
      case 4:
        return _MimeFiles(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          kind: _MimeKind.gifs,
        );
      case 5:
        return _MimeFiles(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          kind: _MimeKind.media,
        );
      case 6:
        return _MimeFiles(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          roomId: widget.roomId,
          kind: _MimeKind.audio,
        );
      case 7:
        return WorkspaceFileTree(
          service: widget.dependencies.service,
          spaceId: widget.spaceId,
          onOpen: (entry) {
            if (entry.isDirectory) return;
            showFloatingPanel(
              context,
              WorkspaceFileViewer(
                service: widget.dependencies.service,
                spaceId: widget.spaceId,
                path: entry.path,
              ),
              maxWidth: 920,
              barrierLabel: 'Close file',
            );
          },
        );
      case 8:
        return SpaceComputerTab(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
        );
      case 9:
        return SpaceMemoryTab(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
          agents: _agents,
        );
      case 10:
        return SpacePreviewsTab(
          dependencies: widget.dependencies,
          spaceId: widget.spaceId,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _BotList extends StatelessWidget {
  const _BotList({
    required this.bots,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.onAdd,
    required this.onRemove,
    required this.addLabel,
    this.userId = '',
    this.canRemove,
    this.onOpen,
  });

  final List<Bot> bots;
  final IconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final VoidCallback onAdd;
  final Future<void> Function(Bot bot) onRemove;
  final String addLabel;
  final String userId;

  /// When set, only bots that return true show a Remove control.
  final bool Function(Bot bot)? canRemove;
  final Future<void> Function(Bot bot)? onOpen;

  @override
  Widget build(BuildContext context) {
    if (bots.isEmpty) {
      return Column(
        children: [
          Expanded(
            child: PanelEmpty(
              icon: emptyIcon,
              title: emptyTitle,
              message: emptyMessage,
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(addLabel),
          ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: bots.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final bot = bots[i];
              final removable = canRemove?.call(bot) ?? true;
              return ListTile(
                onTap: onOpen == null ? null : () => onOpen!(bot),
                leading: BotAvatar(
                  bot: bot,
                  radius: 20,
                  userId: userId,
                ),
                title: Text(
                  bot.name,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  bot.isAgent
                      ? bot.kindLabel
                      : '${bot.toolModeLabel} · ${bot.status}',
                ),
                trailing: removable
                    ? IconButton(
                        tooltip: 'Remove',
                        onPressed: () => onRemove(bot),
                        icon: const Icon(Icons.remove_circle_outline),
                      )
                    : null,
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: Text(addLabel),
          ),
        ),
      ],
    );
  }
}

enum _MimeKind { docs, links, gifs, media, audio }

class _MimeFiles extends StatefulWidget {
  const _MimeFiles({
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.kind,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final _MimeKind kind;

  @override
  State<_MimeFiles> createState() => _MimeFilesState();
}

class _MimeFilesState extends State<_MimeFiles> {
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
  void didUpdateWidget(covariant _MimeFiles old) {
    super.didUpdateWidget(old);
    if (old.spaceId != widget.spaceId ||
        old.roomId != widget.roomId ||
        old.kind != widget.kind) {
      _load();
    }
  }

  bool _matches(Map<String, dynamic> file) {
    final mime = (file['mime'] as String? ?? '').toLowerCase();
    switch (widget.kind) {
      case _MimeKind.docs:
        return mime.contains('pdf') ||
            mime.contains('text') ||
            mime.contains('markdown') ||
            mime.contains('doc');
      case _MimeKind.links:
        return mime.contains('html') || mime.contains('url');
      case _MimeKind.gifs:
        return mime == 'image/gif';
      case _MimeKind.media:
        return (mime.startsWith('image/') && mime != 'image/gif') ||
            mime.startsWith('video/');
      case _MimeKind.audio:
        return mime.startsWith('audio/');
    }
  }

  Future<void> _load({bool more = false}) async {
    if (widget.spaceId.isEmpty) {
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
      final all = await widget.dependencies.service.fetchFiles(
        widget.spaceId,
        roomId: widget.roomId,
        limit: _pageSize,
        offset: offset,
      );
      final files = all.where(_matches).toList();
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

  IconData _iconFor(String mime) {
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.movie_outlined;
    if (mime.startsWith('audio/')) return Icons.graphic_eq_rounded;
    if (mime.contains('pdf')) return Icons.picture_as_pdf_outlined;
    if (mime.contains('html') || mime.contains('url')) return Icons.link;
    return Icons.insert_drive_file_outlined;
  }

  static String _humanSize(int bytes) {
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SkeletonList();
    if (_files.isEmpty) {
      return const PanelEmpty(
        icon: Icons.folder_outlined,
        title: 'Nothing here yet',
        message: 'Files shared in this chat show up in these tabs.',
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (_hasMore && !_loadingMore && n.metrics.extentAfter < 250) {
          // ignore: discarded_futures
          _load(more: true);
        }
        return false;
      },
      child: ListView.separated(
        itemCount: _files.length + (_hasMore || _loadingMore ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (index >= _files.length) return const SkeletonListTile();
          final file = _files[index];
          final name = file['name'] as String? ?? 'file';
          final mime = file['mime'] as String? ?? '';
          final size = (file['size'] as num?)?.toInt() ?? 0;
          return ListTile(
            leading: Icon(_iconFor(mime)),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('$mime · ${_humanSize(size)}'),
          );
        },
      ),
    );
  }
}
