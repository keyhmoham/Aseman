import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_shape.dart';
import '../../../../core/theme/theme_roles.dart';
import '../../../../data/models/space.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../messenger/presentation/chat_page.dart' show ChatAvatar;
import '../../../search_feed/presentation/rich_post_content.dart';

/// Opens a picker of the caller's chats and project rooms to forward
/// [message] into. Returns how many destinations received it.
Future<int?> showForwardMessageSheet(
  BuildContext context, {
  required AppDependencies dependencies,
  required RoomMessage message,
  String fromName = '',
  String excludeSpaceId = '',
  String excludeRoomId = '',
}) =>
    showAdaptivePanel<int>(
      context,
      ForwardMessageSheet(
        dependencies: dependencies,
        message: message,
        fromName: fromName,
        excludeSpaceId: excludeSpaceId,
        excludeRoomId: excludeRoomId,
      ),
      breakpoint: 720,
      maxWidth: 520,
      maxHeight: 720,
      heightFactor: .88,
    );

/// Body sent when forwarding [message], with optional [note] and attribution.
@visibleForTesting
String forwardedMessageBody(
  RoomMessage message, {
  String fromName = '',
  String note = '',
}) {
  final who = fromName.trim();
  final attribution = who.isEmpty
      ? '_Forwarded message_'
      : '_Forwarded from **${_escapeMd(who)}**_';
  final original = message.body.trim();
  final core = original.isEmpty ? attribution : '$attribution\n\n$original';
  final n = note.trim();
  return n.isEmpty ? core : '$n\n\n$core';
}

String _escapeMd(String text) =>
    text.replaceAll(r'\', r'\\').replaceAll('*', r'\*').replaceAll('_', r'\_');

class ForwardMessageSheet extends StatefulWidget {
  const ForwardMessageSheet({
    super.key,
    required this.dependencies,
    required this.message,
    this.fromName = '',
    this.excludeSpaceId = '',
    this.excludeRoomId = '',
  });

  final AppDependencies dependencies;
  final RoomMessage message;
  final String fromName;
  final String excludeSpaceId;
  final String excludeRoomId;

  @override
  State<ForwardMessageSheet> createState() => _ForwardMessageSheetState();
}

class _ForwardMessageSheetState extends State<ForwardMessageSheet> {
  List<ChatSummary> _chats = const [];
  bool _loading = true;
  String? _loadError;
  final _selected = <String>{};
  final _query = TextEditingController();
  final _note = TextEditingController();
  bool _sending = false;

  RoomMessage get message => widget.message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final chats = await widget.dependencies.service.fetchChats();
      if (!mounted) return;
      setState(() {
        _chats = [
          for (final c in chats)
            if (c.canSend &&
                !(c.spaceId == widget.excludeSpaceId &&
                    c.roomId == widget.excludeRoomId))
              c
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  String get _q => _query.text.trim().toLowerCase();

  List<ChatSummary> get _visible => _chats
      .where((c) =>
          _q.isEmpty ||
          '${c.title} ${c.spaceName} ${c.peer?.handle ?? ''}'
              .toLowerCase()
              .contains(_q))
      .toList();

  Future<void> _send() async {
    if (_selected.isEmpty || _sending) return;
    setState(() => _sending = true);
    final service = widget.dependencies.service;
    final body = forwardedMessageBody(message,
        fromName: widget.fromName, note: _note.text);
    final attachments = [
      for (final f in message.attachments)
        if (f.id.isNotEmpty) f.id
    ];
    final targets = _chats.where((c) => _selected.contains(c.key)).toList();
    final results = await Future.wait([
      for (final c in targets)
        () async {
          try {
            if (c.direct) {
              await service.sendDirectMessage(
                c.peer?.id ?? c.roomId,
                body,
                attachments: attachments,
              );
            } else {
              await service.sendRoomMessage(c.spaceId, c.roomId, body,
                  attachments: attachments);
            }
            return true;
          } catch (_) {
            return false;
          }
        }()
    ]);
    if (!mounted) return;
    final done = results.where((ok) => ok).length;
    final failed = results.length - done;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (failed == 0) {
      Navigator.pop(context, done);
      messenger?.showSnackBar(SnackBar(
          content: Text(done == 1
              ? 'Forwarded'
              : 'Forwarded to $done chats')));
    } else {
      setState(() => _sending = false);
      messenger?.showSnackBar(SnackBar(
          content: Text(done == 0
              ? 'Could not forward the message'
              : 'Forwarded to $done; $failed failed')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chats = _visible;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Forward to…',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(
                        'Direct chats and project rooms you can write in.',
                        style: TextStyle(
                            fontSize: 13, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: _Preview(
              message: message,
              fromName: widget.fromName,
              headers: widget.dependencies.service.authHeaders(),
              resolveUrl: widget.dependencies.service.resolveContentUrl,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _query,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: 'Search chats',
                filled: true,
                fillColor: scheme.surfaceContainerHighest.withValues(alpha: .55),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(children: [
                      SkeletonListTile(),
                      SkeletonListTile(),
                      SkeletonListTile(),
                    ]),
                  )
                : _loadError != null && _chats.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.cloud_off_rounded,
                                  size: 36, color: scheme.onSurfaceVariant),
                              const SizedBox(height: 10),
                              const Text('Chats could not be loaded',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _loading = true;
                                      _loadError = null;
                                    });
                                    _load();
                                  },
                                  child: const Text('Try again')),
                            ],
                          ),
                        ),
                      )
                    : chats.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Text(
                                _q.isEmpty
                                    ? 'No other chats to forward to yet.'
                                    : 'No chat matches “${_query.text.trim()}”.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 14,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                            itemCount: chats.length,
                            itemBuilder: (context, i) {
                              final c = chats[i];
                              final on = _selected.contains(c.key);
                              return _ChatRow(
                                chat: c,
                                selected: on,
                                userId: widget.dependencies.sessionController
                                        .session?.accountId ??
                                    '',
                                onTap: () => setState(() {
                                  if (!_selected.remove(c.key)) {
                                    _selected.add(c.key);
                                  }
                                }),
                              );
                            },
                          ),
          ),
          _bottomBar(scheme),
        ],
      ),
    );
  }

  Widget _bottomBar(ColorScheme scheme) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .5)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selected.isNotEmpty) ...[
              TextField(
                controller: _note,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.chat_bubble_outline_rounded),
                  hintText: 'Add a message (optional)',
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selected.isEmpty
                        ? 'Pick one or more chats'
                        : '${_selected.length} selected',
                    style: TextStyle(
                        fontSize: 12.5, color: scheme.onSurfaceVariant),
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      _selected.isEmpty || _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.forward_rounded, size: 18),
                  label: Text(_sending ? 'Sending…' : 'Forward'),
                ),
              ],
            ),
          ],
        ),
      );
}

class _Preview extends StatelessWidget {
  const _Preview({
    required this.message,
    required this.fromName,
    required this.headers,
    this.resolveUrl,
  });

  final RoomMessage message;
  final String fromName;
  final Map<String, String> headers;
  final String Function(String url)? resolveUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = fromName.trim().isEmpty ? 'Someone' : fromName.trim();
    final body = message.body.trim();
    final files = message.attachments.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
        border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.forward_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text('From $who',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
              ),
              if (files > 0)
                Text(
                  files == 1 ? '1 file' : '$files files',
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant),
                ),
            ],
          ),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            DefaultTextStyle.merge(
              style: TextStyle(
                  fontSize: 13, height: 1.35, color: scheme.onSurface),
              child: RichPostContent(body,
                  headers: headers, resolveUrl: resolveUrl),
            ),
          ] else if (files > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Attachment',
                  style: TextStyle(
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                      color: scheme.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.selected,
    required this.onTap,
    this.userId = '',
  });

  final ChatSummary chat;
  final bool selected;
  final VoidCallback onTap;
  final String userId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final subtitle = chat.saved
        ? 'Aseman'
        : chat.direct
            ? (chat.peer?.isAgent ?? false)
                ? 'Agent'
                : (chat.peer?.handle.isNotEmpty ?? false)
                    ? '@${chat.peer!.handle}'
                    : 'Direct chat'
            : 'Room · ${chat.spaceName}';
    return Material(
      color: selected
          ? ThemeRoles.selectedFill(context)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          child: Row(
            children: [
              ChatAvatar(
                chat: chat,
                radius: 20,
                userId: userId,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.transparent,
                  border: Border.all(
                    width: 2,
                    color: selected ? scheme.primary : scheme.outline,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check_rounded,
                        size: 14, color: scheme.onPrimary)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
