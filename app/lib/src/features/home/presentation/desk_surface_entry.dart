import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../desk/domain/desk_models.dart';
import 'workspace_screen.dart' deferred as workspace;

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
    workspace.loadLibrary().then((_) {
      if (mounted) setState(() => _ready = true);
    });
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
