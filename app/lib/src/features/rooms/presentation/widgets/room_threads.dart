import 'package:flutter/material.dart';

import '../../../../core/theme/app_shape.dart';
import '../../../../core/theme/theme_roles.dart';
import '../../../../data/models/space.dart';
import '../../../../data/services/aseman_service.dart';
import '../../../../shared/widgets/overlay_panels.dart';

/// Opens the room's conversation threads and returns the one picked (the
/// main thread, another thread, or a new one), or null when dismissed.
///
/// Every thread keeps its own history and its own context for the room's
/// agents; the room's desk, files and members are shared by all of them.
Future<RoomThread?> showRoomThreads(
  BuildContext context, {
  required AsemanService service,
  required String spaceId,
  required String roomId,
  required String currentId,
}) =>
    showAdaptivePanel<RoomThread>(
      context,
      RoomThreadsPanel(
          service: service,
          spaceId: spaceId,
          roomId: roomId,
          currentId: currentId),
      maxWidth: 480,
      maxHeight: 640,
      heightFactor: .8,
    );

class RoomThreadsPanel extends StatefulWidget {
  const RoomThreadsPanel({
    super.key,
    required this.service,
    required this.spaceId,
    required this.roomId,
    required this.currentId,
  });

  final AsemanService service;
  final String spaceId;

  /// The room (its main thread's id).
  final String roomId;

  /// The thread open now (the room's id for the main thread).
  final String currentId;

  @override
  State<RoomThreadsPanel> createState() => _RoomThreadsPanelState();
}

class _RoomThreadsPanelState extends State<RoomThreadsPanel> {
  RoomThread? _main;
  List<RoomThread> _threads = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res =
          await widget.service.fetchRoomThreads(widget.spaceId, widget.roomId);
      if (!mounted) return;
      setState(() {
        _main = res.main;
        _threads = res.threads;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load threads: $e';
        });
      }
    }
  }

  Future<void> _create() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final thread =
          await widget.service.createRoomThread(widget.spaceId, widget.roomId);
      if (mounted) Navigator.of(context).pop(thread);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not open a thread: $e';
        });
      }
    }
  }

  Future<void> _rename(RoomThread thread) async {
    final title = await showAppDialog<String>(
      context: context,
      builder: (_) => _ThreadTitleDialog(initial: thread.title),
    );
    if (title == null || title.trim().isEmpty) return;
    try {
      await widget.service.renameRoomThread(thread.id, title.trim());
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not rename: $e');
    }
  }

  Future<void> _delete(RoomThread thread) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: Text('Delete “${thread.title}”?'),
        content: const Text(
            'Its messages are deleted for everyone, and the agents forget '
            'this conversation. The room and its other threads stay.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.deleteRoomThread(thread.id);
      if (!mounted) return;
      // Deleting the open thread goes back to the main one.
      if (thread.id == widget.currentId && _main != null) {
        Navigator.of(context).pop(_main);
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final main = _main;
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
            child: Row(children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Threads',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(
                          'Each thread has its own history and agent context.',
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant)),
                    ]),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy || _loading ? null : _create,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('New thread'),
              ),
            ]),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12, color: scheme.error)),
            ),
          Flexible(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()))
                : ListView(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                    children: [
                      if (main != null)
                        _tile(main,
                            icon: Icons.forum_rounded,
                            subtitle: 'The room\'s main conversation'),
                      if (_threads.isNotEmpty) const Divider(height: 12),
                      for (final t in _threads)
                        _tile(t, icon: Icons.chat_bubble_outline_rounded),
                      if (_threads.isEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                              'No other threads yet. Open one to start a '
                              'separate conversation without the room\'s '
                              'history.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant)),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tile(RoomThread t, {required IconData icon, String? subtitle}) {
    final scheme = Theme.of(context).colorScheme;
    final selected = t.id == widget.currentId;
    final preview = t.lastBody.replaceAll(RegExp(r'\s+'), ' ').trim();
    return ListTile(
      selected: selected,
      selectedTileColor: ThemeRoles.selectedFill(context),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.innerOf(context))),
      leading: Icon(icon),
      title: Text(t.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
          preview.isNotEmpty ? preview : (subtitle ?? 'No messages yet'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      trailing: t.isMain
          ? (selected ? const Icon(Icons.check_rounded) : null)
          : AppPopupMenuButton<String>(
              tooltip: 'Thread options',
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'rename') _rename(t);
                if (v == 'delete') _delete(t);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'rename',
                    child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Rename'))),
                PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.delete_outline_rounded),
                        title: Text('Delete thread'))),
              ],
            ),
      onTap: () => Navigator.of(context).pop(t),
    );
  }
}

class _ThreadTitleDialog extends StatefulWidget {
  const _ThreadTitleDialog({required this.initial});

  final String initial;

  @override
  State<_ThreadTitleDialog> createState() => _ThreadTitleDialogState();
}

class _ThreadTitleDialogState extends State<_ThreadTitleDialog> {
  late final _title = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename thread'),
        content: TextField(
          controller: _title,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _title.text),
              child: const Text('Save')),
        ],
      );
}
