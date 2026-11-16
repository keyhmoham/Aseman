import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/layout/app_layout.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../data/models/space.dart';
import '../../home/presentation/workspace_entry.dart' as workspace_entry;
import 'chat_page.dart';
import 'messenger_panel.dart';

/// Full-page chat destination for the desktop shell.
///
/// List–detail: the conversation list is a fixed pane and the open thread
/// fills the rest. Selecting a chat stays on this page.
class ChatsPage extends StatefulWidget {
  const ChatsPage({
    super.key,
    required this.dependencies,
    this.onOpenSpaceRoom,
    this.onOpenWorkspace,
  });

  final AppDependencies dependencies;

  /// Opens a room on the workspace page (desk, chat, and the rest).
  final void Function(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  )?
  onOpenSpaceRoom;

  /// Opens a newly created workspace.
  final ValueChanged<String>? onOpenWorkspace;

  @override
  State<ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<ChatsPage> {
  ChatSummary? _selected;

  /// A space opened from this list, shown beside it like a direct chat.
  ({String spaceId, String spaceName, String roomName, String roomId})? _space;

  void _openHere(
    String spaceId,
    String spaceName,
    String roomName,
    String roomId,
  ) {
    setState(() {
      _selected = null;
      _space = (
        spaceId: spaceId,
        spaceName: spaceName,
        roomName: roomName,
        roomId: roomId,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final split =
        !AppHeightClass.fromHeight(size.height).isCompact && size.width >= 720;
    final listWidth = AppLayout.paneWidths(
      innerWidth: size.width,
      leading: true,
      trailing: false,
    ).leading;
    final list = MessengerPanel(
      dependencies: widget.dependencies,
      embedded: true,
      onOpenSpaceRoom: split && widget.onOpenSpaceRoom != null
          ? _openHere
          : widget.onOpenSpaceRoom,
      onOpenWorkspace: widget.onOpenWorkspace,
      onSelect: split
          ? (chat) {
              if (!chat.direct && widget.onOpenSpaceRoom != null) {
                _openHere(
                  chat.spaceId,
                  chat.spaceName,
                  chat.roomName,
                  chat.roomId,
                );
                return;
              }
              setState(() {
                _space = null;
                _selected = chat;
              });
            }
          : null,
    );
    final space = _space;
    final detail = space != null
        ? workspace_entry.deferredWorkspaceScreen(
            key: ValueKey('${space.spaceId}/${space.roomId}'),
            dependencies: widget.dependencies,
            initialWorkspace: space.spaceName,
            initialSpaceId: space.spaceId,
            initialRoom: space.roomName,
            initialRoomId: space.roomId,
            desktopShell: true,
          )
        : _selected == null
        ? const _ChatPlaceholder()
        : ChatPage(
            key: ValueKey('${_selected!.spaceId}/${_selected!.roomId}'),
            dependencies: widget.dependencies,
            chat: _selected!,
            embedded: true,
          );
    return ColoredBox(
      color: scheme.surface,
      child: split
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppPane(width: listWidth, child: list),
                const PaneDivider(),
                Expanded(child: AppPane(child: detail)),
              ],
            )
          : list,
    );
  }
}

class _ChatPlaceholder extends StatelessWidget {
  const _ChatPlaceholder();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 36,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            'Select a chat',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ],
      ),
    );
  }
}
