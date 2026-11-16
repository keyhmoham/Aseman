import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../elpian/core/media.dart' show ElpianMediaScope;
import '../../computer/computer_view.dart';
import '../../computer/preview_view.dart';
import '../../desk/domain/desk_models.dart';
import '../../desk/presentation/compact_desk.dart';
import '../../desk/presentation/compact_summary.dart';
import '../../desk/presentation/desk_controller.dart';
import '../../desk/presentation/desk_report_view.dart';
import '../../desk/presentation/floating_desk.dart';
import '../../desk/presentation/frontend_presentation.dart';
import '../../files/presentation/file_viewer.dart';
import '../../rooms/presentation/widgets/shared_file_viewer.dart';
import '../../tools/data/tools_api.dart';
import '../../tools/elpian_app/elpian_app_view.dart';
import '../../tools/presentation/mcp_app_view.dart';
import '../../tools/presentation/tool_frontend_view.dart';
import '../../tools/runtime/tool_media.dart';

/// Desk surface for a direct chat (per-participant layout from the node).
class DmDeskPanel extends StatelessWidget {
  const DmDeskPanel({
    super.key,
    required this.dependencies,
    required this.controller,
    required this.spaceId,
    required this.roomId,
    required this.title,
    this.topInset = 0,
    this.bottomInset = 0,
    this.board = false,
  });

  final AppDependencies dependencies;
  final DeskController controller;
  final String spaceId;
  final String roomId;
  final String title;
  final double topInset;
  final double bottomInset;

  /// Widget grid, as the workspace room desk. Opening one floats its card.
  final bool board;

  Widget _windowContent(BuildContext context, DeskWindow w) =>
      _DmWindowContent(
        dependencies: dependencies,
        spaceId: spaceId,
        roomId: roomId,
        window: w,
      );

  Widget _pinPreview(DeskPin p) {
    if (p.isAgui || p.isHtmlReport || p.isElpianReport) {
      return DeskKindPreview(pin: p);
    }
    if (p.isWeb) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: p.label.isEmpty ? 'Web page' : p.label,
          caption: 'Preview',
          icon: 'language',
        ),
      );
    }
    if (p.isComputer) {
      return const CompactSummaryView(
        summary: CompactSummary(
          title: 'Computer',
          caption: 'Your personal sandbox',
          icon: 'computer',
        ),
      );
    }
    if (p.isFile) {
      return CompactSummaryView(
        summary: CompactSummary(
          title: p.label.isEmpty ? 'File' : p.label,
          caption: 'File',
          icon: 'description',
        ),
      );
    }
    return CompactSummaryView(
      summary: CompactSummary(
        title: p.label.isEmpty ? p.name : p.label,
        caption: p.argsSummary,
        icon: 'apps',
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.widgets_outlined, size: 40, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              '$title desk',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              'App results and your computer open here. '
              'This desk is yours in this chat.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Surface stays full-bleed; bottomInset clears the floating home tab bar.
    final desk = LayoutBuilder(
      builder: (context, box) {
        final widgets = board || box.maxWidth < compactDeskWidth;
        return widgets
            ? CompactDesk(
                controller: controller,
                topInset: topInset,
                floatOnOpen: board,
                windowContent: _windowContent,
                pinPreview: _pinPreview,
                emptyState: _empty(context),
              )
            : FloatingDesk(
                controller: controller,
                topInset: topInset,
                windowContent: _windowContent,
                pinPreview: _pinPreview,
                emptyState: _empty(context),
              );
      },
    );
    final surface = ElpianMediaScope(
      resolver: ToolMedia.forSpace(dependencies.service, spaceId).call,
      child: bottomInset <= 0
          ? desk
          : Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: desk,
            ),
    );
    // The widget grid asks the controller to present a card. Without this
    // layer nothing draws it, so a tap looks like it did nothing.
    if (!board) return surface;
    final pad = MediaQuery.paddingOf(context);
    return _DmWindowPortal(
      layer: ElpianMediaScope(
        resolver: ToolMedia.forSpace(dependencies.service, spaceId).call,
        child: FloatingDesk(
          controller: controller,
          topInset: pad.top,
          bottomInset: pad.bottom,
          captureSurface: false,
          onlyPresented: true,
          showDock: false,
          windowContent: _windowContent,
          pinPreview: (_) => const SizedBox.shrink(),
        ),
      ),
      child: surface,
    );
  }
}

/// Floating cards over the whole window, the way a room desk opens a widget.
class _DmWindowPortal extends StatefulWidget {
  const _DmWindowPortal({required this.layer, required this.child});

  final Widget layer;
  final Widget child;

  @override
  State<_DmWindowPortal> createState() => _DmWindowPortalState();
}

class _DmWindowPortalState extends State<_DmWindowPortal> {
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _portal.show();
    });
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      // See the workspace desk portal: tooltips in a root-overlay card
      // need their own overlay or hovering the chrome crashes the page.
      overlayChildBuilder: (context) => Overlay.wrap(child: widget.layer),
      child: widget.child,
    );
  }
}

class _DmWindowContent extends StatelessWidget {
  const _DmWindowContent({
    required this.dependencies,
    required this.spaceId,
    required this.roomId,
    required this.window,
  });

  final AppDependencies dependencies;
  final String spaceId;
  final String roomId;
  final DeskWindow window;

  @override
  Widget build(BuildContext context) {
    final w = window;
    if (w.isComputer) {
      if (FrontendPresentation.isCompact(context)) {
        return const CompactSummaryView(
          summary: CompactSummary(
            title: 'Computer',
            caption: 'Tap to open',
            icon: 'computer',
          ),
        );
      }
      return ComputerSession(
        key: ValueKey('computer-${w.id}'),
        service: dependencies.service,
        spaceId: spaceId,
      );
    }
    if (w.isAgui) return DeskAgUiView(window: w);
    if (w.isHtmlReport || w.isElpianReport) {
      return DeskReportView(
        service: dependencies.service,
        window: w,
        spaceId: spaceId,
        roomId: roomId,
      );
    }
    if (w.isFile) {
      if (FrontendPresentation.isCompact(context)) {
        return CompactSummaryView(
          summary: CompactSummary(
            title: w.label.isEmpty ? 'File' : w.label,
            caption: 'Tap to open',
            icon: 'description',
          ),
        );
      }
      if (w.fileId.isNotEmpty) {
        return SharedFileWindow(
          key: ValueKey('shared-${w.id}-${w.fileId}'),
          service: dependencies.service,
          fileId: w.fileId,
        );
      }
      return WorkspaceFileViewer(
        key: ValueKey('file-${w.id}-${w.filePath}'),
        service: dependencies.service,
        spaceId: spaceId,
        path: w.filePath,
        showHeader: false,
      );
    }
    if (w.isWeb) {
      if (FrontendPresentation.isCompact(context)) {
        return CompactSummaryView(
          summary: CompactSummary(
            title: w.label.isEmpty ? 'Web page' : w.label,
            caption: 'Tap to open',
            icon: 'language',
          ),
        );
      }
      return LivePreview(
        key: ValueKey('web-${w.id}-${w.page}'),
        service: dependencies.service,
        spaceId: spaceId,
        title: w.label,
        page: w.page,
        content: w.elpian.isEmpty
            ? null
            : (_) => ElpianAppView(
                service: dependencies.service,
                page: w.page,
                entry: w.elpian,
                spaceId: spaceId,
                roomId: roomId,
                title: w.label,
              ),
      );
    }
    if (w.isApp) {
      if (FrontendPresentation.isCompact(context)) {
        return CompactSummaryView(
          summary: CompactSummary(
            title: w.microtool.isEmpty ? w.name : w.microtool,
            caption: w.argsSummary,
            icon: 'apps',
          ),
        );
      }
      return McpAppView(
        key: ValueKey('app-${w.id}'),
        api: ToolsApi.of(dependencies.service),
        botId: w.tool,
        spaceId: spaceId,
        roomId: roomId,
        microtool: w.microtool,
        args: w.args,
      );
    }
    return ToolFrontendView(
      key: ValueKey('${w.tool}/${w.microtool}/${w.args}'),
      api: ToolsApi.of(dependencies.service),
      botId: w.tool,
      spaceId: spaceId,
      roomId: roomId,
      userId: dependencies.sessionController.session?.accountId ?? '',
      shown: w.shown,
    );
  }
}
