import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/deferred/deferred_loader.dart';
import '../../desk/domain/desk_models.dart';
import 'workspace_screen.dart' deferred as workspace;

/// The workspace library a desk surface draws with, loaded on first use.
final _workspaceDesk = DeferredLoader(() => workspace.loadLibrary());

/// Loads what a desk surface draws with.
Future<void> loadDeskSurfaces() async => _workspaceDesk.ensure();

/// Lazy [DeskSurfaceContent] so the feed canvas does not pull the full
/// workspace + Elpian desk stack until a desk surface is actually painted.
class DeskSurfaceContent extends StatefulWidget {
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

  @override
  State<DeskSurfaceContent> createState() => _DeskSurfaceContentState();
}

class _DeskSurfaceContentState extends State<DeskSurfaceContent> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // Loaded already: draw the surface in this frame.
    _ready = _workspaceDesk.isLoaded;
    if (!_ready) {
      _workspaceDesk.ensure()?.then((_) {
        if (mounted) setState(() => _ready = true);
      }).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const SizedBox.shrink();
    }
    return workspace.DeskSurfaceContent(
      dependencies: widget.dependencies,
      spaceId: widget.spaceId,
      roomId: widget.roomId,
      window: widget.window,
    );
  }
}
