import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shape.dart';
import '../../../../data/models/bot.dart';
import '../../../../data/models/space.dart';
import '../../../../shared/widgets/mini_tag.dart';
import '../../../home/presentation/widgets/routines_panel.dart';
import '../../../search_feed/presentation/post_editor.dart';
import '../../../search_feed/presentation/rich_post_content.dart';
import '../../../tools/presentation/composed_widget.dart';
import '../../../workflows/presentation/workflow_panel.dart';
import 'attachment_bubble.dart';
import 'workspace_links.dart';

/// A room's conversation: the message list (chat bubbles, agent logs, files,
/// sandbox previews), the live "agent is working" status and the composer
/// (attachments, agent mentions, the message designer). Used by the workspace
/// for project rooms and by the messenger for every chat, direct ones included.
class RoomChat extends StatefulWidget {
  const RoomChat({
    super.key,
    required this.room,
    required this.messages,
    this.working = '',
    this.workingDetail = '',
    this.me = '',
    this.dependencies,
    this.spaceId = '',
    this.roomId = '',
    this.canManageTasks = false,
    this.mentionable = const [],
    this.onSend,
    this.flat = false,
    this.topContentInset = 0,
    this.bare = false,
    this.leading,
    this.avatar,
    this.subtitle,
    this.hint = 'Message room…',
    this.memberNames = const {},
  });
  final String room;
  final List<RoomMessage> messages;
  final String working;
  final String workingDetail;
  final String me;
  final AppDependencies? dependencies;
  final String spaceId;
  final String roomId;
  final bool canManageTasks;
  final List<Bot> mentionable;
  final Future<void> Function(
      String body, List<String> mentions, List<String> attachments)? onSend;
  final bool flat;
  final double topContentInset;

  /// Lays the header, messages and composer out without the floating panel
  /// frame, for a chat that fills its own page.
  final bool bare;

  /// Shown before the avatar in the header (e.g. a back button).
  final Widget? leading;

  /// Replaces the room's initial in the header.
  final Widget? avatar;

  /// Replaces the message count under the title while no agent is working.
  final String? subtitle;
  final String hint;

  /// Display names of members by account id, for senders the room's agents
  /// do not cover (e.g. the other person of a direct chat).
  final Map<String, String> memberNames;
  @override
  State<RoomChat> createState() => _RoomChatState();
}

class _RoomChatState extends State<RoomChat> {
  final input = TextEditingController();
  final Set<String> _mentions = {};
  final Map<String, String> _mentionNames = {};
  final List<_DraftAttachment> _drafts = [];
  final ScrollController _chatScroll = ScrollController();
  final Set<String> _expandedLogs = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(covariant RoomChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    // New messages arrived (async agent replies / logs): follow the bottom when
    // the user was already near it, so tradera's flow appears live.
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      final pos = _chatScroll.position;
      if (pos.maxScrollExtent - pos.pixels < 160) {
        _chatScroll.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  void _toggleLog(String id) {
    setState(() {
      if (!_expandedLogs.remove(id)) _expandedLogs.add(id);
    });
  }

  @override
  void dispose() {
    input.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _pickMention() {
    final agents = widget.mentionable;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No agents in this workspace to mention.')));
      return;
    }
    showModalBottomSheet<Bot>(
        context: context,
        builder: (context) => SafeArea(
                child: SizedBox(
              height: 360,
              child: Column(children: [
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Mention an agent',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w900))),
                Expanded(
                    child: ListView.separated(
                        itemCount: agents.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final b = agents[i];
                          final already = _mentions.contains(b.id);
                          return ListTile(
                              leading: const Icon(Icons.smart_toy_outlined,
                                  size: 20),
                              title: Text(b.name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(b.kind,
                                  style: const TextStyle(fontSize: 10)),
                              trailing: Icon(already
                                  ? Icons.check_circle_rounded
                                  : Icons.add_circle_outline_rounded),
                              onTap: () => Navigator.pop(context, b));
                        })),
              ]),
            ))).then((b) {
      if (b == null || !mounted) return;
      setState(() {
        _mentions.add(b.id);
        _mentionNames[b.id] = b.name;
        if (!input.text.endsWith(' ')) input.text += ' ';
        input.text += '@${b.name} ';
      });
    });
  }

  void _removeMention(String id) {
    setState(() => _mentions.remove(id));
  }

  // Opens the markup message designer (like the post designer) so the user can
  // author a rich message and send it to the room chat.
  Future<void> _openDesigner() async {
    final initial = input.text.trim().isEmpty ? null : input.text.trim();
    final md = await showMessageDesigner(context, initial: initial);
    if (md == null || md.trim().isEmpty || !mounted) return;
    final attachments = _drafts
        .where((d) => d.uploaded && d.fileId.isNotEmpty)
        .map((d) => d.fileId)
        .toList();
    input.text = md;
    try {
      await widget.onSend?.call(md, _mentions.toList(), attachments);
    } catch (_) {
      // The parent reports the error. Keep the designed message and files.
      return;
    }
    if (!mounted) return;
    input.clear();
    setState(() {
      _mentions.clear();
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
    });
  }

  Future<void> _submit(String value) async {
    final drafts =
        _drafts.where((d) => d.uploaded && d.fileId.isNotEmpty).toList();
    final attachments = drafts.map((d) => d.fileId).toList();
    if (value.trim().isEmpty && attachments.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend?.call(value.trim(), _mentions.toList(), attachments);
      if (!mounted) return;
      // Success: drop the sent attachments and clear the composer.
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
      input.clear();
      setState(() => _mentions.clear());
    } catch (_) {
      // Keep the composer + drafts so the user can retry.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── file attachments ────────────────────────────────────────────────────

  void _showAttachSheet() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Attach to message',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurfaceVariant)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 10, runSpacing: 10, children: [
                        _attachOption(Icons.photo_rounded, 'Photo / GIF', () {
                          Navigator.pop(context);
                          _pickFile(_imageTypes);
                        }),
                        _attachOption(Icons.videocam_rounded, 'Video', () {
                          Navigator.pop(context);
                          _pickFile(_videoTypes);
                        }),
                        _attachOption(Icons.mic_rounded, 'Voice / Audio', () {
                          Navigator.pop(context);
                          _pickFile(_audioTypes);
                        }),
                        _attachOption(
                            Icons.insert_drive_file_rounded, 'Document', () {
                          Navigator.pop(context);
                          _pickFile(_documentTypes);
                        }),
                      ]),
                    ]))));
  }

  Widget _attachOption(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
            width: 96,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Icon(icon, color: AppColors.primary, size: 26),
              const SizedBox(height: 6),
              Text(label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700)),
            ])));
  }

  static const _imageTypes = [
    XTypeGroup(
      label: 'Images',
      mimeTypes: ['image/jpeg', 'image/png', 'image/gif', 'image/webp'],
      extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    ),
  ];
  static const _videoTypes = [
    XTypeGroup(
      label: 'Videos',
      mimeTypes: [
        'video/mp4',
        'video/quicktime',
        'video/webm',
        'video/ogg',
        'video/x-msvideo',
      ],
      extensions: ['mp4', 'mov', 'webm', 'ogv', 'avi', 'mkv'],
    ),
  ];
  static const _audioTypes = [
    XTypeGroup(
      label: 'Audio',
      mimeTypes: [
        'audio/mpeg',
        'audio/mp4',
        'audio/wav',
        'audio/x-wav',
        'audio/ogg',
        'audio/webm',
        'audio/aac',
        'audio/x-m4a',
        'audio/opus',
        'audio/amr',
      ],
      extensions: [
        'mp3',
        'm4a',
        'wav',
        'ogg',
        'oga',
        'opus',
        'webm',
        'aac',
        'amr'
      ],
    ),
  ];
  static const _documentTypes = [
    XTypeGroup(
      label: 'Documents',
      mimeTypes: [
        'application/pdf',
        'text/plain',
        'text/csv',
        'text/markdown',
        'application/json',
        'application/zip',
        'application/msword',
        'text/html',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ],
      extensions: [
        'pdf',
        'txt',
        'md',
        'csv',
        'json',
        'log',
        'doc',
        'docx',
        'xls',
        'xlsx',
        'ppt',
        'pptx',
        'zip',
        'rar',
        '7z',
        'tar',
        'gz',
        'yaml',
        'yml',
        'html',
        'htm',
      ],
    ),
  ];

  Future<void> _pickFile(List<XTypeGroup> types) async {
    final deps = widget.dependencies;
    if (deps == null || widget.spaceId.isEmpty) return;
    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: types);
    } catch (_) {
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) return;
      final draft = _DraftAttachment(
          name: picked.name, mime: _mimeFromName(picked.name), bytes: bytes);
      setState(() => _drafts.add(draft));
      await _uploadDraft(draft);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Read failed: $e')));
    }
  }

  Future<void> _uploadDraft(_DraftAttachment draft) async {
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => draft.uploading = true);
    try {
      final uploaded = await deps.service.uploadFile(
        widget.spaceId,
        roomId: widget.roomId,
        name: draft.name,
        mime: draft.mime,
        bytes: draft.bytes,
      );
      draft.fileId = uploaded.id;
      draft.uploaded = true;
    } catch (e) {
      draft.error = e.toString();
    } finally {
      // The upload finished (success or failure) — stop the spinner.
      draft.uploading = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _removeDraft(_DraftAttachment draft) async {
    // Best-effort cleanup of the uploaded file so cancelled drafts don't leak
    // into the workspace file library.
    if (draft.uploaded && draft.fileId.isNotEmpty) {
      try {
        await widget.dependencies?.service.deleteFile(draft.fileId);
      } catch (_) {}
    }
    if (mounted) setState(() => _drafts.remove(draft));
  }

  Widget _draftChip(_DraftAttachment d) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
        width: 160,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          if (d.bytes.isNotEmpty && d.mime.startsWith('image/'))
            ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(d.bytes,
                    width: 30, height: 30, fit: BoxFit.cover))
          else
            Icon(
                d.mime.startsWith('audio/')
                    ? Icons.mic_rounded
                    : d.mime.startsWith('video/')
                        ? Icons.videocam_rounded
                        : Icons.insert_drive_file_rounded,
                size: 22,
                color: AppColors.primary),
          const SizedBox(width: 7),
          Expanded(
              child: d.uploading
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : d.error != null
                      ? const Icon(Icons.error_outline_rounded,
                          color: AppColors.danger, size: 16)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                              Text(d.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700)),
                              const Text('ready to send',
                                  style: TextStyle(
                                      fontSize: 8, color: AppColors.success)),
                            ])),
          const SizedBox(width: 3),
          IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              onPressed: () => _removeDraft(d),
              icon: const Icon(Icons.close_rounded)),
        ]));
  }

  @override
  Widget build(BuildContext context) {
    // Show the conversation chronologically (oldest→newest). message_list
    // returns newest-first, so sort by createdAt with the id as a tiebreaker.
    final messages = [...widget.messages]..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    if (widget.flat) {
      return _Panel(
          flat: true,
          child: Stack(children: [
            Positioned.fill(
                child: CustomPaint(
              painter: _ChatPatternPainter(
                  Theme.of(context).colorScheme.primary, widget.room),
              child: ListView(
                  controller: _chatScroll,
                  padding:
                      EdgeInsets.fromLTRB(12, widget.topContentInset, 12, 94),
                  children: [
                    _chatHeader(),
                    const SizedBox(height: 10),
                    if (messages.isEmpty)
                      const _NoMessages()
                    else ...[
                      ...List.generate(
                          messages.length,
                          (i) => _chatBubble(context, messages[i],
                              previous: i == 0 ? null : messages[i - 1])),
                      if (widget.working.isNotEmpty)
                        _WorkingIndicator(
                            agent: widget.working,
                            detail: widget.workingDetail),
                    ]
                  ]),
            )),
            Positioned(left: 10, right: 10, bottom: 10, child: _composer()),
          ]));
    }
    return _Panel(
      flat: widget.flat || widget.bare,
      child: Column(children: [
        _chatHeader(),
        Expanded(
            child: CustomPaint(
          painter: _ChatPatternPainter(
              Theme.of(context).colorScheme.primary, widget.room),
          child: messages.isEmpty
              ? const _NoMessages()
              : ListView(
                  controller: _chatScroll,
                  padding: const EdgeInsets.all(12),
                  children: List.generate(
                          messages.length,
                          (i) => _chatBubble(context, messages[i],
                              previous: i == 0 ? null : messages[i - 1])) +
                      [
                        if (widget.working.isNotEmpty)
                          _WorkingIndicator(
                              agent: widget.working,
                              detail: widget.workingDetail),
                      ]),
        )),
        Padding(padding: const EdgeInsets.all(10), child: _composer()),
      ]),
    );
  }

  Widget _chatHeader() {
    final scheme = Theme.of(context).colorScheme;
    final deps = widget.dependencies;
    final count = widget.messages.where((m) => m.kind != 'log').length;
    return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(children: [
          if (widget.leading != null) ...[
            widget.leading!,
            const SizedBox(width: 4),
          ],
          widget.avatar ??
              Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(AppShape.control)),
                  child: Text(
                      widget.room.isEmpty ? 'R' : widget.room[0].toUpperCase(),
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                          color: scheme.onPrimaryContainer))),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(widget.room,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Row(children: [
                  Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                          color: widget.working.isNotEmpty
                              ? scheme.primary
                              : AppColors.success,
                          shape: BoxShape.circle)),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(
                          widget.working.isNotEmpty
                              ? '${widget.working} is working'
                              : widget.subtitle ??
                                  (count == 0
                                      ? 'Live room'
                                      : '$count messages'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: scheme.onSurfaceVariant))),
                ]),
              ])),
          IconButton.filledTonal(
              tooltip: 'Agent tasks',
              visualDensity: VisualDensity.compact,
              onPressed: deps == null ||
                      widget.spaceId.isEmpty ||
                      widget.roomId.isEmpty
                  ? null
                  : () => showWorkflowPanel(context, deps.service,
                      widget.spaceId, widget.roomId, widget.room,
                      canManage: widget.canManageTasks),
              icon: const Icon(Icons.account_tree_outlined, size: 18)),
          const SizedBox(width: 4),
          IconButton.filledTonal(
              tooltip: 'Routines',
              visualDensity: VisualDensity.compact,
              onPressed: deps == null
                  ? null
                  : () => showRoutinesSheet(context, deps, widget.spaceId,
                      widget.roomId, widget.room),
              icon: const Icon(Icons.schedule_rounded, size: 18)),
        ]));
  }

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
        color: scheme.surfaceContainerHigh,
        elevation: widget.flat ? 3 : 0,
        shadowColor: Colors.black.withValues(alpha: .25),
        borderRadius: BorderRadius.circular(AppShape.card),
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_drafts.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                    child: SizedBox(
                        height: 42,
                        child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: _drafts.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 6),
                            itemBuilder: (context, index) =>
                                _draftChip(_drafts[index])))),
              if (_mentions.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(spacing: 6, runSpacing: 4, children: [
                          for (final id in _mentions)
                            InputChip(
                                visualDensity: VisualDensity.compact,
                                shape: const StadiumBorder(),
                                avatar: const Icon(Icons.smart_toy_outlined,
                                    size: 16),
                                label: Text('@${_mentionNames[id] ?? id}',
                                    style: const TextStyle(fontSize: 12)),
                                onDeleted: () => _removeMention(id)),
                        ]))),
              LayoutBuilder(builder: (context, box) {
                final actions = [
                  _composerAction(Icons.add_rounded, 'Attach file',
                      _sending ? null : _showAttachSheet),
                  _composerAction(Icons.alternate_email_rounded,
                      'Mention an agent', _pickMention),
                  _composerAction(Icons.auto_awesome_rounded,
                      'Design a message', _sending ? null : _openDesigner),
                ];
                final field = TextField(
                    controller: input,
                    enabled: !_sending,
                    onSubmitted: _submit,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    style: const TextStyle(fontSize: 15),
                    decoration: InputDecoration(
                        hintText: widget.hint,
                        hintMaxLines: 1,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 12),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none));
                final send = IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _sending ? null : () => _submit(input.text),
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send_rounded, size: 20));
                // Narrow panels give the text its own line above the actions.
                if (box.maxWidth < 340) {
                  return Column(mainAxisSize: MainAxisSize.min, children: [
                    field,
                    Row(children: [...actions, const Spacer(), send]),
                  ]);
                }
                return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ...actions,
                      const SizedBox(width: 4),
                      Expanded(child: field),
                      const SizedBox(width: 4),
                      send,
                    ]);
              }),
            ])));
  }

  Widget _composerAction(IconData icon, String tooltip, VoidCallback? onTap) =>
      IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Icon(icon, size: 20));

  // Resolves a sender id to a display name: the agents in the workspace are
  // known by name, other members fall back to a short id.
  ({String name, bool agent}) _sender(String id) {
    for (final b in widget.mentionable) {
      if (b.id == id) return (name: b.name, agent: true);
    }
    final known = widget.memberNames[id];
    if (known != null && known.isNotEmpty) return (name: known, agent: false);
    if (id.isEmpty) return (name: 'Unknown', agent: false);
    return (
      name: id.length > 8 ? 'Member ${id.substring(id.length - 4)}' : id,
      agent: false
    );
  }

  Widget _chatBubble(BuildContext context, RoomMessage m,
      {RoomMessage? previous}) {
    // Agentic-flow content (tradera's plans, dispatches, tool/sandbox outputs)
    // renders as a collapsible log section rather than a chat bubble.
    if (m.kind == 'log') {
      return _LogSection(
        title: _logTitle(m.body),
        body: m.body,
        expanded: _expandedLogs.contains(m.id),
        onToggle: () => _toggleLog(m.id),
        dependencies: widget.dependencies,
      );
    }
    // A widget an agent composed from the space's tools (ui_compose).
    if (m.kind == 'ui') {
      return ComposedWidgetCard(
        body: m.body,
        spaceId: m.spaceId,
        roomId: m.roomId,
        dependencies: widget.dependencies,
        senderName:
            m.senderName.isNotEmpty ? m.senderName : _sender(m.senderId).name,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    final mine = m.senderId == widget.me;
    // Consecutive messages from the same sender are grouped: only the first
    // one shows the sender, and the group sits tighter together.
    final continued = previous != null &&
        previous.kind != 'log' &&
        previous.senderId == m.senderId &&
        m.createdAt.difference(previous.createdAt).inMinutes.abs() < 5;
    final time = _msgTime(m.createdAt);
    final deps = widget.dependencies;
    var sender = _sender(m.senderId);
    if (m.senderName.isNotEmpty &&
        !widget.memberNames.containsKey(m.senderId) &&
        !widget.mentionable.any((b) => b.id == m.senderId)) {
      sender = (name: m.senderName, agent: m.senderIsAgent);
    }
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    const r = Radius.circular(20);
    const tail = Radius.circular(6);
    final bubble = Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
            color: mine ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.only(
                topLeft: !mine && !continued ? tail : r,
                topRight: mine && !continued ? tail : r,
                bottomLeft: r,
                bottomRight: r)),
        child: DefaultTextStyle.merge(
            style: TextStyle(color: fg, fontSize: 14, height: 1.4),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (m.attachments.isNotEmpty)
                ...m.attachments.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: AttachmentBubble(
                        file: f,
                        headers: deps?.service.authHeaders() ?? const {},
                        resolveUrl: deps == null
                            ? null
                            : (file) => deps.service.fileContentUrl(file.id),
                        fetchBytes: (file) =>
                            deps?.service.downloadFile(file.id) ??
                            Future.value(Uint8List(0)),
                        mine: mine,
                      ),
                    )),
              if (m.body.trim().isNotEmpty)
                RichPostContent(m.body,
                    headers: deps?.service.authHeaders() ?? const {},
                    onLinkTap: deps == null
                        ? null
                        : (link) =>
                            openWorkspaceLink(context, deps.service, link)),
              // A gateway proxy message gets an "open in webview" button
              // so the room's users can view the page served from the
              // sandbox behind it.
              if (deps != null && _proxyPathIn(m.body) != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _ProxyOpenButton(
                        title: _proxyTitle(m.body) ?? 'Sandbox service',
                        url:
                            deps.service.proxyUrl(_proxyPathIn(m.body) ?? ''))),
              const SizedBox(height: 2),
              Text(time,
                  style: TextStyle(
                      fontSize: 10, color: fg.withValues(alpha: .65))),
            ])));
    final avatar = SizedBox(
        width: 30,
        child: continued
            ? null
            : CircleAvatar(
                radius: 15,
                backgroundColor: sender.agent
                    ? scheme.tertiaryContainer
                    : scheme.secondaryContainer,
                child: sender.agent
                    ? Icon(Icons.smart_toy_rounded,
                        size: 16, color: scheme.onTertiaryContainer)
                    : Icon(Icons.person_rounded,
                        size: 17, color: scheme.onSecondaryContainer)));
    return Padding(
        padding: EdgeInsets.only(top: continued ? 2 : 10),
        child: Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (mine) const SizedBox(width: 32),
              if (!mine) ...[avatar, const SizedBox(width: 8)],
              Flexible(
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 380),
                      child: Column(
                          crossAxisAlignment: mine
                              ? CrossAxisAlignment.end
                              : CrossAxisAlignment.start,
                          children: [
                            if (!mine && !continued)
                              Padding(
                                  padding:
                                      const EdgeInsets.only(left: 4, bottom: 3),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Flexible(
                                            child: Text(sender.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                    color: sender.agent
                                                        ? scheme.tertiary
                                                        : scheme.primary))),
                                        if (sender.agent) ...[
                                          const SizedBox(width: 6),
                                          MiniTag('AI', scheme.tertiary),
                                        ],
                                      ])),
                            bubble,
                          ]))),
              SizedBox(width: mine ? 4 : 12),
            ]));
  }

  static String _msgTime(DateTime t) =>
      '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

/// A file picked for an in-flight room message. It is uploaded to the space's
/// room as soon as it is picked so the message only references the file id.
class _DraftAttachment {
  _DraftAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
  });

  final String name;
  final String mime;
  final Uint8List bytes;
  bool uploading = false;
  bool uploaded = false;
  String fileId = '';
  String? error;
}

/// Guess a MIME type from a file name extension (mirrors the server-side sniff).
String _mimeFromName(String name) {
  final ext = name.contains('.')
      ? name.substring(name.lastIndexOf('.') + 1).toLowerCase()
      : '';
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mov':
      return 'video/quicktime';
    case 'ogg':
      return 'audio/ogg';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'wav':
      return 'audio/wav';
    case 'opus':
      return 'audio/opus';
    case 'pdf':
      return 'application/pdf';
    case 'json':
      return 'application/json';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'md':
      return 'text/markdown';
    case 'txt':
    case 'log':
      return 'text/plain';
    case 'csv':
      return 'text/csv';
    case 'zip':
      return 'application/zip';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    default:
      return 'application/octet-stream';
  }
}

// _proxyPathIn extracts a gateway proxy path (/v1/proxy/{id}/) from a message
// body, if any.
String? _proxyPathIn(String body) {
  final m = RegExp(r'/v1/proxy/[0-9a-fA-F]{32}/').firstMatch(body);
  return m?.group(0);
}

// _proxyTitle pulls a short title out of a proxy message (the "🔗 **Title**"
// lead), falling back to null.
String? _proxyTitle(String body) {
  final m = RegExp(r'\*\*(.+?)\*\*').firstMatch(body);
  return m?.group(1)?.trim();
}

// _ProxyOpenButton opens the proxied sandbox page. On web the page is opened in
// a new browser tab (reliable); on native platforms it opens the in-app webview.
class _ProxyOpenButton extends StatelessWidget {
  const _ProxyOpenButton({required this.title, required this.url});

  final String title;
  final String url;

  Future<void> _open(BuildContext context) async {
    try {
      await openWorkspacePreview(context, url, title: title);
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Could not open preview. Try again or download the delivered files.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  kIsWeb
                      ? Icons.open_in_new_rounded
                      : Icons.open_in_browser_rounded,
                  size: 16,
                  color: scheme.onPrimary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                    workspacePreviewUsesWebView
                        ? 'Open in webview'
                        : 'Open page',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onPrimary)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NoMessages extends StatelessWidget {
  const _NoMessages();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(AppShape.inner)),
            child: Icon(Icons.forum_rounded,
                size: 30, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(height: 14),
          const Text('No messages yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('Say hello, or mention an agent with @ to put it to work.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

// _WorkingIndicator shows, below the last message, which agent is currently
// working and a live sentence describing what it is doing right now
// ("running in the sandbox…", "generating an image…", "thinking…", …) with a
// minimal pulsing-dots animation.
class _WorkingIndicator extends StatefulWidget {
  const _WorkingIndicator({required this.agent, this.detail = ''});
  final String agent;
  final String detail;

  @override
  State<_WorkingIndicator> createState() => _WorkingIndicatorState();
}

class _WorkingIndicatorState extends State<_WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1300))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final detail =
        widget.detail.trim().isEmpty ? 'agent is working' : widget.detail;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 10, left: 38),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.agent,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant)),
          ),
          const SizedBox(width: 8),
          _WorkingDots(controller: _controller, color: scheme.primary),
        ]),
      ),
    );
  }
}

// _WorkingDots is the minimal animated part: three dots pulsing in sequence.
class _WorkingDots extends StatelessWidget {
  const _WorkingDots({required this.controller, required this.color});
  final AnimationController controller;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => SizedBox(
        width: 22,
        height: 12,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(3, (i) {
            // Staggered phase so the dots pulse left-to-right.
            final t = (controller.value * 3 + (2 - i)) % 1.0;
            final opacity = 0.2 + 0.8 * (0.5 - 0.5 * math.cos(t * 2 * math.pi));
            return Opacity(
              opacity: opacity.clamp(0.2, 1.0),
              child: Container(
                  width: 5,
                  height: 5,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle)),
            );
          }),
        ),
      ),
    );
  }
}

// _logTitle derives a short label for an agentic-flow log message so it can be
// rendered as a collapsible section header.
String _logTitle(String body) {
  final first = body.trim().split('\n').first.trim();
  final lower = first.toLowerCase();
  if (first.startsWith('📋')) return 'Dispatching';
  if (lower.contains('execution plan') || lower.startsWith('1.')) return 'Plan';
  if (first.startsWith('###')) {
    final t = first.replaceAll('#', '').trim();
    return t.isEmpty ? 'Agent contribution' : t;
  }
  if (first.startsWith('exit=') || lower.contains('error'))
    return 'Sandbox output';
  return first.length > 48 ? first.substring(0, 48) + '…' : first;
}

// _LogSection renders an agentic-flow log as a collapsible/expandable section
// between conversation messages.
class _LogSection extends StatelessWidget {
  const _LogSection({
    required this.title,
    required this.body,
    required this.expanded,
    required this.onToggle,
    this.dependencies,
  });

  final String title;
  final String body;
  final bool expanded;
  final VoidCallback onToggle;
  final AppDependencies? dependencies;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppShape.control),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppShape.control),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
            child: Row(children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.terminal_rounded,
                    size: 15, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
              AnimatedRotation(
                turns: expanded ? .5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more_rounded,
                    size: 20, color: scheme.onSurfaceVariant),
              ),
            ]),
          ),
        ),
        if (expanded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: body.trim().isEmpty
                ? Text('(no output)',
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant))
                : RichPostContent(body,
                    headers: dependencies?.service.authHeaders() ?? const {}),
          ),
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.flat = false});
  final Widget child;
  final bool flat;
  @override
  Widget build(BuildContext context) => flat
      ? Material(color: Theme.of(context).colorScheme.surface, child: child)
      : Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: .92),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(
                  color: Theme.of(context)
                      .colorScheme
                      .outlineVariant
                      .withValues(alpha: .6)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: .12),
                    blurRadius: 30,
                    offset: const Offset(0, 12))
              ]),
          child: Material(type: MaterialType.transparency, child: child));
}

class _ChatPatternPainter extends CustomPainter {
  const _ChatPatternPainter(this.color, this.room);
  final Color color;
  final String room;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withValues(alpha: .075),
                Colors.transparent,
                color.withValues(alpha: .035)
              ]).createShader(Offset.zero & size));
    final seed = room.codeUnits.fold(29, (a, b) => a * 37 + b);
    final random = math.Random(seed);
    final count = math.max(18, (size.width * size.height / 12500).round());
    for (var i = 0; i < count; i++) {
      final center = Offset(
          size.width * random.nextDouble(), size.height * random.nextDouble());
      final scale = 7 + random.nextDouble() * 15;
      final paint = Paint()
        ..color = color.withValues(alpha: .035 + random.nextDouble() * .055)
        ..style = PaintingStyle.stroke
        ..strokeWidth = .7 + random.nextDouble();
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(random.nextDouble() * math.pi * 2);
      switch (i % 5) {
        case 0:
          canvas.drawArc(Rect.fromCircle(center: Offset.zero, radius: scale), 0,
              math.pi * 1.45, false, paint);
          canvas.drawCircle(Offset(scale * .8, scale * .5), 2, paint);
          break;
        case 1:
          canvas.drawLine(
              Offset(-scale, scale * .5), Offset(scale, -scale * .5), paint);
          for (var x = -1; x <= 1; x++)
            canvas.drawCircle(
                Offset(x * scale * .65, x.isEven ? -2 : 4), 2.2, paint);
          break;
        case 2:
          final path = Path()
            ..moveTo(0, -scale)
            ..lineTo(scale, 0)
            ..lineTo(0, scale)
            ..lineTo(-scale, 0)
            ..close();
          canvas.drawPath(path, paint);
          break;
        case 3:
          for (var bar = 0; bar < 3; bar++)
            canvas.drawRRect(
                RRect.fromRectAndRadius(
                    Rect.fromLTWH(
                        -scale + bar * scale * .7,
                        -scale * (.3 + random.nextDouble() * .5),
                        scale * .25,
                        scale * (1 + random.nextDouble())),
                    const Radius.circular(2)),
                paint);
          break;
        default:
          canvas.drawCircle(Offset.zero, scale, paint);
          canvas.drawCircle(Offset.zero, scale * .35, paint);
          break;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ChatPatternPainter old) =>
      old.color != color || old.room != room;
}
