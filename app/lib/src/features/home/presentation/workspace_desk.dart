part of 'workspace_screen.dart';

/// The room's desk: tools' frontends as floating card windows (opened by
/// people from the library and by agents showing results) and the dock. An
/// empty desk shows the machine. On desktop, [underlay] holds the left/right
/// panels under the windows so cards can float over them.
class _CenterDesk extends StatelessWidget {
  const _CenterDesk({
    required this.workspace,
    required this.room,
    required this.pointer,
    required this.controller,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    this.underlay,
    this.topContentInset = 0,
  });
  final String workspace;
  final String? room;
  final Offset pointer;
  final DeskController controller;
  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final Widget? underlay;
  final double topContentInset;

  Widget _frontend(String tool, ShownResult? shown) => ToolFrontendView(
    key: ValueKey('$tool/${shown?.microtool}/${shown?.args}'),
    api: ToolsApi.of(dependencies.service),
    botId: tool,
    spaceId: spaceId,
    roomId: roomId,
    userId: dependencies.sessionController.session?.accountId ?? '',
    shown: shown,
  );

  /// A window's frontend, whatever its kind; the enclosing
  /// [FrontendPresentation] says whether in full or as a compact widget.
  Widget _windowContent(BuildContext context, DeskWindow w) =>
      DeskSurfaceContent(
        dependencies: dependencies,
        spaceId: spaceId,
        roomId: roomId,
        window: w,
      );

  Widget _pinPreview(DeskPin p) => p.isWeb
      ? _WebPinPreview(title: p.label)
      : p.isAgui
      ? CompactSummaryView(
          summary: CompactSummary(
            title: p.label.isEmpty ? 'Visualization' : p.label,
            caption: 'AG-UI',
            icon: 'dashboard',
          ),
        )
      : p.isComputer
      ? const CompactSummaryView(
          summary: CompactSummary(
            title: 'Computer',
            caption: 'The project’s desktop',
            icon: 'computer',
          ),
        )
      : p.isFile
      ? _FilePreview(path: p.fileId.isEmpty ? p.filePath : p.label)
      : p.isApp
      ? _AppPinPreview(name: p.name)
      : _frontend(p.tool, p.shown);

  Widget _emptyState(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 150, child: _MachineFace(pointer: pointer)),
            const SizedBox(height: 8),
            Text(
              room == null ? 'My desk' : '$room desk',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                'App results open here as windows. Ask an agent, or open an app from the library.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _WorkspacePatternPainter(workspace)),
            ),
          ),
          Positioned.fill(
            // Every window's images, videos and audio load from the space's
            // project files, stored files and the node, as this person.
            child: ElpianMediaScope(
              resolver: ToolMedia.forSpace(dependencies.service, spaceId).call,
              // Phones: the windows as compact widgets on a board, each
              // opened in a bottom sheet; wider screens: floating card windows.
              child: LayoutBuilder(
                builder: (context, box) => box.maxWidth < compactDeskWidth
                    ? CompactDesk(
                        controller: controller,
                        topInset: topContentInset,
                        windowContent: _windowContent,
                        pinPreview: _pinPreview,
                        emptyState: _emptyState(context),
                      )
                    : FloatingDesk(
                        controller: controller,
                        topInset: topContentInset,
                        underlay: underlay,
                        windowContent: _windowContent,
                        pinPreview: _pinPreview,
                        emptyState: _emptyState(context),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A desk window's frontend, in full or as the compact widget the enclosing
/// [FrontendPresentation] asks for. Shared by a room desk and the feed canvas.
class DeskSurfaceContent extends StatelessWidget {
  const DeskSurfaceContent({
    super.key,
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.window,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final DeskWindow window;

  Widget _frontend(String tool, ShownResult? shown) => ToolFrontendView(
    key: ValueKey('$tool/${shown?.microtool}/${shown?.args}'),
    api: ToolsApi.of(dependencies.service),
    botId: tool,
    spaceId: spaceId,
    roomId: roomId,
    userId: dependencies.sessionController.session?.accountId ?? '',
    shown: shown,
  );

  /// A web page window: the page itself, or, as a phone-board widget, a
  /// summary that opens it. An Elpian app ([elpian], its program) runs
  /// natively instead of as a web page.
  Widget _page(
    BuildContext context,
    String id,
    String page,
    String title, {
    String elpian = '',
    String widget = '',
  }) => FrontendPresentation.isCompact(context)
      ? (widget.isEmpty
            ? CompactSummaryView(
                summary: CompactSummary(
                  title: title.isEmpty ? 'Web page' : title,
                  caption: 'Tap to open',
                  icon: 'language',
                ),
              )
            : LivePreview(
                key: ValueKey('widget-$id-$page-$widget'),
                service: dependencies.service,
                spaceId: spaceId,
                title: title,
                page: page,
                compact: true,
                content: (_) => IgnorePointer(
                  child: ElpianAppView(
                    key: ValueKey('elpian-widget-$id-$page-$widget'),
                    service: dependencies.service,
                    page: page,
                    entry: widget,
                    spaceId: spaceId,
                    roomId: roomId,
                    title: title,
                  ),
                ),
              ))
      : LivePreview(
          key: ValueKey('web-$id-$page-$elpian'),
          service: dependencies.service,
          spaceId: spaceId,
          title: title,
          page: page,
          content: elpian.isEmpty
              ? null
              : (_) => ElpianAppView(
                  key: ValueKey('elpian-$id-$page-$elpian'),
                  service: dependencies.service,
                  page: page,
                  entry: elpian,
                  spaceId: spaceId,
                  roomId: roomId,
                  title: title,
                ),
        );

  Widget _agui(BuildContext context, DeskWindow w) {
    if (FrontendPresentation.isCompact(context)) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: w.label.isEmpty ? 'Visualization' : w.label,
          caption: 'AG-UI · tap to open',
          icon: 'dashboard',
        ),
      );
    }
    final raw = w.aguiSurface;
    if (raw == null) {
      return const Center(child: Text('Empty AG-UI surface'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: AgUiSurfaceView(
        key: ValueKey('agui-${w.id}'),
        surface: AgUiSurface.fromJson(raw),
        compact: false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = window;
    return w.isWeb
        ? _page(
            context,
            w.id,
            w.page,
            w.label,
            elpian: w.elpian,
            widget: w.widget,
          )
        : w.isAgui
        ? _agui(context, w)
        : w.isComputer
        ? (FrontendPresentation.isCompact(context)
              ? const CompactSummaryView(
                  summary: CompactSummary(
                    title: 'Computer',
                    caption: 'Tap to open',
                    icon: 'computer',
                  ),
                )
              : ComputerSession(
                  key: ValueKey('computer-${w.id}'),
                  service: dependencies.service,
                  spaceId: spaceId,
                ))
        : w.isFile
        ? (FrontendPresentation.isCompact(context)
              ? _FilePreview(path: w.fileId.isEmpty ? w.filePath : w.label)
              : w.fileId.isNotEmpty
              ? SharedFileWindow(
                  key: ValueKey('shared-${w.id}-${w.fileId}'),
                  service: dependencies.service,
                  fileId: w.fileId,
                )
              : WorkspaceFileViewer(
                  key: ValueKey('file-${w.id}-${w.filePath}'),
                  service: dependencies.service,
                  spaceId: spaceId,
                  path: w.filePath,
                  showHeader: false,
                ))
        : w.isApp
        ? (FrontendPresentation.isCompact(context)
              ? CompactSummaryView(
                  summary: CompactSummary(
                    title: w.microtool.isEmpty ? w.name : w.microtool,
                    caption: w.argsSummary,
                    icon: 'apps',
                  ),
                )
              : McpAppView(
                  key: ValueKey('app-${w.id}'),
                  api: ToolsApi.of(dependencies.service),
                  botId: w.tool,
                  spaceId: spaceId,
                  roomId: roomId,
                  microtool: w.microtool,
                  args: w.args,
                ))
        : _frontend(w.tool, w.shown);
  }
}

/// A pinned result shown with a tool's app: the app runs once the pin is
/// opened, not in the preview.
/// A pinned web page: it loads when opened, not in the preview.
class _WebPinPreview extends StatelessWidget {
  const _WebPinPreview({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.language_rounded, color: scheme.primary, size: 32),
          const SizedBox(height: 8),
          Text(
            title.isEmpty ? 'Web page' : title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'An interactive page of the space',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// A workspace file's icon, name and folder: a pinned file, or a file
/// window as a phone-board widget.
class _FilePreview extends StatelessWidget {
  const _FilePreview({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = path.split('/').last;
    final type = FileType.of(name);
    final folder = path.substring(0, path.length - name.length);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(type.icon, color: type.color, size: 32),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                folder,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppPinPreview extends StatelessWidget {
  const _AppPinPreview({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.widgets_outlined, color: scheme.primary, size: 32),
          const SizedBox(height: 8),
          Text(
            name.isEmpty ? 'This app' : name,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            'Opens with its own interface',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _MachineFace extends StatelessWidget {
  const _MachineFace({required this.pointer});
  final Offset pointer;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final dx = ((pointer.dx - size.width / 2) / size.width).clamp(-.5, .5) * 18;
    final dy =
        ((pointer.dy - size.height / 3) / size.height).clamp(-.4, .4) * 12;
    return Center(
      child: Transform.translate(
        offset: Offset(dx, dy),
        child: Transform.rotate(
          angle: dx / 800,
          child: Container(
            width: 168,
            height: 168,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: .28),
                  blurRadius: 48,
                ),
              ],
            ),
            child: Image.asset('assets/images/only_orb.png'),
          ),
        ),
      ),
    );
  }
}

