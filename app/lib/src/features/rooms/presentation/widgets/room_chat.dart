import 'dart:async';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../agui/agui.dart';
import '../../../../app_dependencies.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shape.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/halo_ring_cache.dart';
import '../../../../core/theme/theme_chrome.dart';
import '../../../../core/theme/theme_roles.dart';
import '../../../../data/models/agent_humanoid.dart';
import '../../../../data/models/bot.dart';
import '../../../../data/models/space.dart';
import '../../../../data/services/aseman_service.dart';
import '../../../../shared/widgets/avatar.dart';
import '../../../../shared/widgets/bot_avatar.dart';
import '../../../../shared/widgets/mini_tag.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../../shared/widgets/skeleton.dart';
import '../../../../shared/widgets/sky_ui.dart';
import '../../../assistant/assistant.dart';
import '../../../home/presentation/widgets/routines_panel.dart';
import '../../../search_feed/presentation/post_editor.dart';
import '../../../search_feed/presentation/rich_post_content.dart';
import '../../../voice/voice_model.dart';
import '../../../voice/voice_recorder.dart';
import '../../../voice/voice_recorder_bar.dart';
import '../../domain/room_work.dart';
import '../room_chat_scroll.dart';
import '../room_work_controller.dart';
import 'attachment_bubble.dart';
import 'forward_message_sheet.dart';
import 'message_edit_history.dart';
import 'room_threads.dart';
import 'room_work_view.dart';
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
    this.suggestions = false,
    this.mentionable = const [],
    this.onSend,
    this.flat = false,
    this.topContentInset = 0,
    this.bottomContentInset = 0,
    this.showListHeader = true,
    this.bare = false,
    this.leading,
    this.avatar,
    this.subtitle,
    this.hint = 'Message room…',
    this.memberNames = const {},
    this.onEdit,
    this.onDelete,
    this.onReport,
    this.onTyping,
    this.typing = const [],
    this.receipts = false,
    this.peerSeenAt,
    this.composerNotice,
    this.headerActions = const [],
    this.canModerate = false,
    this.hasMore = false,
    this.loading = false,
    this.loadingOlder = false,
    this.onLoadOlder,
    this.threadRoomId = '',
    this.threadTitle = '',
    this.onThread,
    this.direct = false,
    this.saved = false,
    this.peerId = '',
  });
  final String room;
  final List<RoomMessage> messages;
  final String working;
  final String workingDetail;
  final String me;
  final AppDependencies? dependencies;
  final String spaceId;
  final String roomId;

  /// Account id of the other side of a direct chat (not the Direct space room
  /// id). Required for `users.dm_file_upload` / voice notes.
  final String peerId;

  /// Shows the latest suggested task above the composer (the home chat).
  final bool suggestions;
  final List<Bot> mentionable;
  final Future<void> Function(
      String body, List<String> mentions, List<String> attachments,
      {String replyTo})? onSend;
  final bool flat;
  final double topContentInset;

  /// Extra space under the message list and composer so a floating home tab
  /// bar can overlap the surface without covering content.
  final double bottomContentInset;

  /// When false, the in-list chat header is omitted (e.g. an outer avatar bar
  /// already provides title and actions).
  final bool showListHeader;

  /// Lays the header, messages and composer out without the floating panel
  /// frame, for a chat that fills its own page.
  final bool bare;

  /// Shown before the avatar in the header (e.g. a back button).
  final Widget? leading;

  /// Replaces the room's initial in the header.
  final Widget? avatar;

  /// Replaces the message count under the title.
  final String? subtitle;
  final String hint;

  /// Display names of members by account id, for senders the room's agents
  /// do not cover (e.g. the other person of a direct chat).
  final Map<String, String> memberNames;

  /// Change the text of one of the caller's messages; null hides "Edit".
  final Future<void> Function(RoomMessage message, String body)? onEdit;

  /// Delete a message for everyone; null hides "Delete".
  final Future<void> Function(RoomMessage message)? onDelete;

  /// Report someone else's message to the node's admins; null hides "Report".
  final Future<void> Function(RoomMessage message)? onReport;

  /// Called while the caller types (at most every few seconds).
  final VoidCallback? onTyping;

  /// Display names of the others typing now.
  final List<String> typing;

  /// Whether the caller's messages show sent / seen ticks (a direct chat
  /// with a person), and how far the other side has read (null: nothing yet).
  final bool receipts;
  final DateTime? peerSeenAt;

  /// Shown instead of the composer when no one can write (a blocked chat).
  final String? composerNotice;

  /// Extra buttons at the end of the header (e.g. a chat's menu).
  final List<Widget> headerActions;

  /// Whether the caller may delete other people's messages.
  final bool canModerate;

  /// Whether older messages than [messages] still exist; scrolling to the top
  /// of the list asks [onLoadOlder] for the next page.
  final bool hasMore;

  /// First page of the conversation is still loading; show message skeletons
  /// instead of the empty state when [messages] is empty.
  final bool loading;
  final bool loadingOlder;
  final VoidCallback? onLoadOlder;

  /// The room whose threads the header's thread switcher lists (its main
  /// thread's id); empty hides the switcher. [roomId] is then the thread
  /// shown, which is this room itself for its main thread.
  final String threadRoomId;

  /// The open thread's title; empty for the main thread.
  final String threadTitle;

  /// Switches the chat to another thread of the room.
  final void Function(RoomThread thread)? onThread;

  /// Direct (person-to-person) chat.
  final bool direct;

  /// Personal Aseman chat (self-chat).
  final bool saved;
  @override
  State<RoomChat> createState() => _RoomChatState();
}

class _RoomChatState extends State<RoomChat> {
  /// Room message ids the caller hid this session (until the parent reloads).
  final Set<String> _hiddenHere = {};

  /// Optimistic reaction emoji by message id (until the next list refresh).
  final Map<String, String> _myReaction = {};

  /// The message whose reply chips are offered (the newest, from an agent).
  String _repliesFor = '';

  final input = TextEditingController();
  final Set<String> _mentions = {};
  final Map<String, String> _mentionNames = {};
  final List<_DraftAttachment> _drafts = [];
  final ScrollController _chatScroll = ScrollController();
  final Set<String> _expandedLogs = {};
  bool _sending = false;

  /// In-app voice note: recording or stopped-to-preview (Decillion composer).
  VoiceMessageRecorder? _voiceRecorder;
  String? _voicePhase; // 'recording' | 'stopped'
  VoiceNote? _voiceFile;
  DateTime _voiceStartedAt = DateTime.now();

  /// Scroll to restore after this chat was left and opened again; null when
  /// the person has not scrolled this room yet (land on the live bottom).
  RoomChatScroll? _restore;

  /// How many frames a restore may wait for the list to settle.
  static const _maxRestoreFrames = 45;

  /// True once [_restore] has been applied (or abandoned for a fresh bottom).
  bool _didRestore = false;

  /// Skips persist while a programmatic [jumpTo] is in flight so restore
  /// does not overwrite the saved session with a half-laid-out offset.
  bool _suppressPersist = false;

  /// Frames spent waiting for layout before restore; capped so a short chat
  /// that truly does not scroll still lands.
  int _restoreAttempts = 0;

  /// Last [maxScrollExtent] while waiting for layout to settle before restore.
  double? _restoreExtent;

  /// Consecutive frames with an unchanged extent before applying restore.
  int _restoreStableFrames = 0;

  /// Whether the list is following the live end. Kept across remounts when
  /// the saved scroll was near the bottom, so new messages still stick.
  bool _pinToBottom = true;

  /// The room's agent work (runs, live drafts, questions), when the chat
  /// knows its project and room.
  RoomWorkController? _work;

  /// The message the next one answers, and the message being changed.
  RoomMessage? _replyTo;
  RoomMessage? _editing;
  DateTime _typedAt = DateTime.fromMillisecondsSinceEpoch(0);

  void _typed(String _) {
    // The send button turns into Stop on an empty composer, and a leading /
    // offers the prompt commands.
    setState(() {});
    final now = DateTime.now();
    if (widget.onTyping == null ||
        _editing != null ||
        now.difference(_typedAt) < const Duration(seconds: 4)) {
      return;
    }
    _typedAt = now;
    widget.onTyping!();
  }

  @override
  void initState() {
    super.initState();
    _restore = RoomChatScrollStore.read(widget.spaceId, widget.roomId);
    if (_restore != null) _pinToBottom = _restore!.nearBottom;
    _chatScroll.addListener(_onScroll);
    _followWork();
    WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstLayout());
  }

  void _afterFirstLayout() {
    if (!mounted) return;
    if (_tryRestore()) return;
    // First visit to this room in the session: start at the live end.
    if (_restore == null) _jumpToBottom();
  }

  /// Schedules another restore attempt after the next frame (layout may
  /// still be settling or messages still arriving).
  void _scheduleRestoreRetry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didRestore) return;
      if (_tryRestore()) return;
      if (_restore == null) _jumpToBottom();
    });
    // A post-frame callback alone does not schedule a frame; without this,
    // retries stall when nothing else is animating (common in tests and when
    // returning to a settled chat).
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Persists the current offset so a later visit to this room restores it.
  void _persistScroll([String? spaceId, String? roomId]) {
    if (_suppressPersist || !_chatScroll.hasClients) return;
    // Do not overwrite a saved session with a half-restored / unloaded list.
    if (!_didRestore && _restore != null) return;
    final pos = _chatScroll.position;
    final nearBottom = pos.maxScrollExtent - pos.pixels < 160;
    _pinToBottom = nearBottom;
    RoomChatScrollStore.save(
      spaceId ?? widget.spaceId,
      roomId ?? widget.roomId,
      RoomChatScroll(
        offset: pos.pixels,
        nearBottom: nearBottom,
        maxExtent: pos.maxScrollExtent,
      ),
    );
  }

  void _onScroll() {
    if (!_chatScroll.hasClients) return;
    _persistScroll();
    if (widget.onLoadOlder == null ||
        !widget.hasMore ||
        widget.loadingOlder) {
      return;
    }
    // Near the top of an oldest→newest list: ask for the previous page.
    if (_chatScroll.position.pixels <= 80) widget.onLoadOlder!();
  }

  void _runWithoutPersist(VoidCallback fn) {
    _suppressPersist = true;
    try {
      fn();
    } finally {
      _suppressPersist = false;
    }
  }

  /// Applies a saved scroll once the list has laid out. Returns true when
  /// restore is done or still pending another frame of content.
  bool _tryRestore() {
    final saved = _restore;
    if (saved == null || _didRestore) return saved != null && _didRestore;
    // Never retry for ever: a list whose height keeps changing (or that never
    // lays out) would otherwise request a frame every frame.
    if (_restoreAttempts >= _maxRestoreFrames) {
      if (_chatScroll.hasClients) {
        _runWithoutPersist(() => _chatScroll
            .jumpTo(saved.offsetFor(_chatScroll.position.maxScrollExtent)));
      }
      _pinToBottom = saved.nearBottom;
      _didRestore = true;
      _restoreAttempts = 0;
      return true;
    }
    if (!_chatScroll.hasClients) {
      _restoreAttempts++;
      _scheduleRestoreRetry();
      return true;
    }
    // First page still arriving: keep the pending restore until it lands.
    // didUpdateWidget tries again when the messages arrive, so no frames
    // are spent waiting.
    if (widget.messages.isEmpty) {
      if (widget.loading) return true;
      // Truly empty conversation — nothing to restore to.
      _runWithoutPersist(
          () => _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent));
      _pinToBottom = true;
      _didRestore = true;
      return true;
    }
    final max = _chatScroll.position.maxScrollExtent;
    _restoreAttempts++;
    // Children often report max==0 for a frame before layout finishes.
    final expectScroll =
        saved.maxExtent > 0 || saved.offset > 0 || saved.nearBottom;
    if (max <= 0 && expectScroll) {
      _restoreExtent = null;
      _restoreStableFrames = 0;
      _scheduleRestoreRetry();
      return true;
    }
    // Wait until the extent stops changing so proportional restore is not
    // applied against a mid-layout height.
    if (_restoreExtent == null || (_restoreExtent! - max).abs() > 1) {
      _restoreExtent = max;
      _restoreStableFrames = 0;
      _scheduleRestoreRetry();
      return true;
    }
    _restoreStableFrames++;
    if (_restoreStableFrames < 2) {
      _scheduleRestoreRetry();
      return true;
    }
    final target = saved.offsetFor(max);
    _runWithoutPersist(() => _chatScroll.jumpTo(target));
    _pinToBottom = saved.nearBottom;
    _didRestore = true;
    _restoreAttempts = 0;
    _restoreExtent = null;
    _restoreStableFrames = 0;
    // Persist the applied position (now that restore is done) so leave /
    // remount keeps the corrected offset, not a stale pre-layout value.
    _persistScroll();
    return true;
  }

  void _jumpToBottom() {
    if (!_chatScroll.hasClients) return;
    _runWithoutPersist(
        () => _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent));
    _pinToBottom = true;
    _didRestore = true;
    _persistScroll();
  }

  /// The id of the chronologically oldest message, for detecting prepends.
  static String? _oldestId(List<RoomMessage> messages) {
    if (messages.isEmpty) return null;
    var oldest = messages.first;
    for (final m in messages) {
      final c = m.createdAt.compareTo(oldest.createdAt);
      if (c < 0 || (c == 0 && m.id.compareTo(oldest.id) < 0)) oldest = m;
    }
    return oldest.id;
  }

  void _followWork() {
    _work?.removeListener(_workChanged);
    _work?.dispose();
    _work = null;
    final service = widget.dependencies?.service;
    if (service == null || widget.spaceId.isEmpty || widget.roomId.isEmpty) {
      return;
    }
    _work = RoomWorkController(service,
        spaceId: widget.spaceId, roomId: widget.roomId)
      ..addListener(_workChanged)
      ..start();
  }

  void _workChanged() {
    if (!mounted) return;
    setState(() {});
    if (_work?.drafting != null) _scrollToBottom();
  }

  /// Agents are on it in this room.
  bool get _busy => _work?.busy ?? false;

  Future<void> _stopWork() async {
    final work = _work;
    if (work == null) return;
    final error = await work.stopAll();
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Some work could not be stopped: only the person who asked for it or a project manager can stop it.')));
    }
  }

  Future<void> _answer(AgentQuestion q, String answer) async {
    try {
      await _work?.answer(q, answer);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not answer: $e')));
      }
    }
  }

  /// Sends a failed run's prompt to its agent again.
  Future<void> _runAgain(WorkEntry failed) async {
    _work?.dismiss(failed.runId);
    try {
      await widget.onSend
          ?.call(failed.prompt, [failed.botId], const <String>[]);
    } catch (_) {
      // The parent reports the error.
    }
  }

  void _pickCommand(PromptCommand c) {
    final text = '${c.command} ';
    input.value = TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant RoomChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spaceId != widget.spaceId ||
        oldWidget.roomId != widget.roomId) {
      _persistScroll(oldWidget.spaceId, oldWidget.roomId);
      _restore = RoomChatScrollStore.read(widget.spaceId, widget.roomId);
      _didRestore = false;
      _restoreAttempts = 0;
      _restoreExtent = null;
      _restoreStableFrames = 0;
      _pinToBottom = _restore?.nearBottom ?? true;
      _scheduleRestoreRetry();
    }
    if (oldWidget.spaceId != widget.spaceId ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.dependencies != widget.dependencies) {
      _followWork();
    }
    // Finish a pending restore once messages (and layout) have arrived.
    if (!_didRestore && _restore != null) {
      _scheduleRestoreRetry();
      return;
    }
    final oldOldest = _oldestId(oldWidget.messages);
    final newOldest = _oldestId(widget.messages);
    final prepended = oldOldest != null &&
        newOldest != null &&
        oldOldest != newOldest &&
        widget.messages.length > oldWidget.messages.length;
    if (prepended && _chatScroll.hasClients) {
      // Keep the viewport on the same messages when older ones are inserted
      // above (scroll-to-load history).
      final oldMax = _chatScroll.position.maxScrollExtent;
      final oldPixels = _chatScroll.position.pixels;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_chatScroll.hasClients) return;
        final newMax = _chatScroll.position.maxScrollExtent;
        _runWithoutPersist(() => _chatScroll.jumpTo(
            (oldPixels + (newMax - oldMax)).clamp(0.0, newMax)));
        _persistScroll();
      });
      return;
    }
    // New messages arrived (async agent replies / logs): follow the bottom when
    // the user was already near it, so aseman's flow appears live.
    if (widget.messages.length != oldWidget.messages.length) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_chatScroll.hasClients) return;
      final pos = _chatScroll.position;
      if (_pinToBottom || pos.maxScrollExtent - pos.pixels < 160) {
        _runWithoutPersist(() => _chatScroll.jumpTo(pos.maxScrollExtent));
        _pinToBottom = true;
        _persistScroll();
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
    // Only write when we have a trustworthy position (restore finished or
    // there was nothing to restore). Leaving mid-restore keeps the prior save.
    if (_didRestore || _restore == null) _persistScroll();
    _work?.removeListener(_workChanged);
    _work?.dispose();
    unawaited(_voiceRecorder?.dispose() ?? Future<void>.value());
    input.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  void _pickMention([BuildContext? anchor]) {
    final agents = widget.mentionable;
    if (agents.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No agents in this workspace to mention.')));
      return;
    }
    showAppPicker<Bot>(
        context: context,
        anchor: anchor,
        showDragHandle: false,
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
                              leading: BotAvatar(
                                bot: b,
                                radius: 14,
                                userId: widget.me,
                              ),
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
      await widget.onSend?.call(md, _mentions.toList(), attachments,
          replyTo: _replyTo?.id ?? '');
    } catch (_) {
      // The parent reports the error. Keep the designed message and files.
      return;
    }
    if (!mounted) return;
    input.clear();
    setState(() {
      _mentions.clear();
      _replyTo = null;
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
    });
  }

  Future<void> _submit(String value) async {
    final editing = _editing;
    if (editing != null) {
      final body = value.trim();
      if (body.isEmpty || _sending) return;
      setState(() => _sending = true);
      try {
        if (body != editing.body.trim()) {
          await widget.onEdit?.call(editing, body);
        }
        if (!mounted) return;
        input.clear();
        setState(() => _editing = null);
      } catch (_) {
        // The parent reports the error; keep the text to retry.
      } finally {
        if (mounted) setState(() => _sending = false);
      }
      return;
    }
    final drafts =
        _drafts.where((d) => d.uploaded && d.fileId.isNotEmpty).toList();
    final attachments = drafts.map((d) => d.fileId).toList();
    if (value.trim().isEmpty && attachments.isEmpty) return;
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend?.call(value.trim(), _mentions.toList(), attachments,
          replyTo: _replyTo?.id ?? '');
      if (!mounted) return;
      // Success: drop the sent attachments and clear the composer.
      for (final d in _drafts.toList()) {
        _drafts.remove(d);
      }
      input.clear();
      setState(() {
        _mentions.clear();
        _replyTo = null;
      });
    } catch (_) {
      // Keep the composer + drafts so the user can retry.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // ── message actions ─────────────────────────────────────────────────────

  RoomMessage? _byId(String id) {
    for (final m in widget.messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  static const _reactEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  Future<void> _messageMenu(RoomMessage m, {Offset? at, BuildContext? anchor}) async {
    if (m.id.isEmpty || m.kind == 'log') return;
    final mine = m.senderId == widget.me;
    final canWrite = widget.onSend != null && widget.composerNotice == null;
    final canSocial = widget.dependencies != null && m.id.isNotEmpty;
    final actions = <(IconData, String, String)>[
      if (canWrite) (Icons.reply_rounded, 'Reply', 'reply'),
      if (canSocial) (Icons.add_reaction_outlined, 'React', 'react'),
      if (widget.dependencies != null &&
          (m.body.trim().isNotEmpty || m.attachments.isNotEmpty))
        (Icons.forward_rounded, 'Forward', 'forward'),
      if (m.body.trim().isNotEmpty) (Icons.copy_rounded, 'Copy text', 'copy'),
      if (mine && widget.onEdit != null && canWrite && m.body.trim().isNotEmpty)
        (Icons.edit_outlined, 'Edit', 'edit'),
      if (m.edited && widget.dependencies != null)
        (Icons.history_rounded, 'Edit history', 'history'),
      if (canSocial && !mine && m.attachments.isNotEmpty)
        (Icons.bookmark_add_outlined, 'Keep files', 'keep'),
      if (canSocial)
        (Icons.visibility_off_outlined, 'Hide for me', 'hide'),
      if ((mine || widget.canModerate) && widget.onDelete != null)
        (Icons.delete_outline_rounded, 'Delete for everyone', 'delete'),
      if (!mine && widget.onReport != null)
        (Icons.flag_outlined, 'Report', 'report'),
    ];
    if (actions.isEmpty) return;
    final picked = await showAppPicker<String>(
      context: context,
      anchor: anchor,
      anchorPoint: at,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (icon, label, value) in actions)
            ListTile(
                leading: Icon(icon,
                    color: value == 'delete' || value == 'report'
                        ? Theme.of(context).colorScheme.error
                        : null),
                title: Text(label),
                onTap: () => Navigator.pop(context, value)),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || picked == null) return;
    switch (picked) {
      case 'reply':
        setState(() {
          _editing = null;
          _replyTo = m;
        });
      case 'react':
        await _pickReaction(m);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.body));
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('Copied')));
        }
      case 'edit':
        setState(() {
          _replyTo = null;
          _editing = m;
          input.text = m.body;
        });
      case 'forward':
        final deps = widget.dependencies;
        if (deps != null) {
          final from = m.senderId == widget.me
              ? 'you'
              : _senderOf(m).name;
          await showForwardMessageSheet(context,
              dependencies: deps,
              message: m,
              fromName: from,
              excludeSpaceId: widget.spaceId,
              excludeRoomId: widget.roomId);
        }
      case 'history':
        final service = widget.dependencies?.service;
        if (service != null) {
          await showMessageEditHistory(context,
              service: service, message: m);
        }
      case 'keep':
        await _keepFiles(m);
      case 'hide':
        await _hideForMe(m);
      case 'delete':
        final ok = await showAppDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_outline_rounded),
            title: const Text('Delete this message?'),
            content: const Text('It is removed for everyone in the chat.'),
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
        if (ok == true) await widget.onDelete?.call(m);
      case 'report':
        await widget.onReport?.call(m);
    }
  }

  Future<void> _pickReaction(RoomMessage m) async {
    final emoji = await showAppPicker<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final e in _reactEmojis)
                InkWell(
                  borderRadius: AppShape.borderRadius(context, 24),
                  onTap: () => Navigator.pop(context, e),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(e, style: const TextStyle(fontSize: 28)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || emoji == null) return;
    await _react(m, emoji);
  }

  Future<void> _react(RoomMessage m, String emoji) async {
    final service = widget.dependencies?.service;
    if (service == null) return;
    try {
      if (widget.direct) {
        await service.dmReact(m.id, emoji: emoji);
      } else {
        await service.messageReact(widget.spaceId, m.id, emoji: emoji);
      }
      if (mounted) {
        setState(() => _myReaction[m.id] = emoji);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Reacted $emoji')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not react: $e')));
      }
    }
  }

  Future<void> _hideForMe(RoomMessage m) async {
    final service = widget.dependencies?.service;
    if (service == null) return;
    try {
      if (widget.direct) {
        await service.dmHide(m.id);
      } else {
        await service.messageHide(widget.spaceId, m.id);
      }
      if (mounted) {
        setState(() => _hiddenHere.add(m.id));
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hidden for you')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not hide: $e')));
      }
    }
  }

  List<RoomMessage> get _visibleMessages => widget.messages
      .where((m) => !_hiddenHere.contains(m.id))
      .toList(growable: false);

  Future<void> _keepFiles(RoomMessage m) async {
    final service = widget.dependencies?.service;
    if (service == null) return;
    try {
      if (widget.direct) {
        await service.dmKeep(m.id);
      } else {
        await service.messageKeep(widget.spaceId, m.id);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Kept in your storage')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not keep files: $e')));
      }
    }
  }

  Widget _reactionChips(RoomMessage m, Color fg) {
    final counts = <String, int>{};
    for (final r in m.reactions) {
      counts[r.emoji] = (counts[r.emoji] ?? 0) + 1;
    }
    final mine = _myReaction[m.id];
    if (mine != null && mine.isNotEmpty) {
      counts[mine] = (counts[mine] ?? 0) + 1;
    }
    if (counts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final e in counts.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: fg.withValues(alpha: .08),
                borderRadius: AppShape.borderRadius(context, 12),
              ),
              child: Text(
                e.value > 1 ? '${e.key} ${e.value}' : e.key,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  // The banner above the composer while replying to or changing a message.
  Widget _composerBanner() {
    final scheme = Theme.of(context).colorScheme;
    final editing = _editing;
    final target = editing ?? _replyTo!;
    final who =
        target.senderId == widget.me ? 'yourself' : _senderOf(target).name;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 2, 4, 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
          border: Border(left: BorderSide(color: scheme.primary, width: 3))),
      child: Row(children: [
        Icon(editing != null ? Icons.edit_outlined : Icons.reply_rounded,
            size: 18, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(editing != null ? 'Edit message' : 'Reply to $who',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: scheme.primary)),
            Text(_quoteText(target),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ]),
        ),
        IconButton(
            tooltip: editing != null ? 'Cancel edit' : 'Cancel reply',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() {
                  if (_editing != null) input.clear();
                  _editing = null;
                  _replyTo = null;
                }),
            icon: const Icon(Icons.close_rounded, size: 18)),
      ]),
    );
  }

  static String _quoteText(RoomMessage m) {
    // Strip AG-UI fences so reply quotes don't leak raw ```agui JSON.
    final parsed = parseAgUiBody(m.body);
    var body = parsed.caption.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (body.isEmpty && parsed.surface != null) {
      final title = parsed.surface!.title.trim();
      body = title.isNotEmpty ? title : 'Interactive UI';
    }
    if (body.isNotEmpty) return body;
    return m.attachments.isEmpty ? 'Message' : '📎 Attachment';
  }

  /// The picture of [m]'s sender: as the node sent it with the message, else
  /// the agent's own when it is one of the room's.
  String _avatarOf(RoomMessage m) {
    if (m.senderAvatar.isNotEmpty) return m.senderAvatar;
    for (final b in widget.mentionable) {
      if (b.id == m.senderId || b.accountId == m.senderId) return b.avatar;
    }
    return '';
  }

  /// Prefs key for an agent sender: bot record id when known.
  String _agentPrefsId(RoomMessage m) {
    for (final b in widget.mentionable) {
      if (b.id == m.senderId || b.accountId == m.senderId) {
        return b.id.isNotEmpty ? b.id : b.accountId;
      }
    }
    return m.senderId;
  }

  AgentHumanoid? _agentHumanoidOf(RoomMessage m) {
    for (final b in widget.mentionable) {
      if (b.id == m.senderId || b.accountId == m.senderId) {
        return b.humanoid;
      }
    }
    return null;
  }

  Bot? _agentBotOf(RoomMessage m) {
    for (final b in widget.mentionable) {
      if (b.id == m.senderId || b.accountId == m.senderId) return b;
    }
    return null;
  }

  ({String name, bool agent}) _senderOf(RoomMessage m) {
    var sender = _sender(m.senderId);
    if (m.senderName.isNotEmpty &&
        !widget.memberNames.containsKey(m.senderId) &&
        !widget.mentionable.any(
            (b) => b.id == m.senderId || b.accountId == m.senderId)) {
      sender = (name: m.senderName, agent: m.senderIsAgent);
    }
    return sender;
  }

  // The answered message, quoted at the top of a reply.
  Widget _quote(RoomMessage m, Color fg) {
    final original = _byId(m.replyTo);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
          color: fg.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: scheme.primary, width: 3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (original != null)
          Text(
              original.senderId == widget.me ? 'You' : _senderOf(original).name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary)),
        Text(original == null ? 'An earlier message' : _quoteText(original),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12,
                fontStyle:
                    original == null ? FontStyle.italic : FontStyle.normal,
                color: fg.withValues(alpha: .75))),
      ]),
    );
  }

  // ── file attachments ────────────────────────────────────────────────────

  void _showAttachSheet([BuildContext? anchor]) {
    final scheme = Theme.of(context).colorScheme;
    showAppPicker<void>(
        context: context,
        anchor: anchor,
        showDragHandle: false,
        builder: (context) => SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add to message',
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
                        _attachOption(Icons.audiotrack_rounded, 'Audio file',
                            () {
                          Navigator.pop(context);
                          _pickFile(_audioTypes);
                        }),
                        _attachOption(
                            Icons.insert_drive_file_rounded, 'Document', () {
                          Navigator.pop(context);
                          _pickFile(_documentTypes);
                        }),
                        // A folder of a project computer, in the prompt's
                        // context; the agent works in it there.
                        _attachOption(
                            Icons.folder_shared_rounded, 'Project folder', () {
                          Navigator.pop(context);
                          _attachFolder();
                        }),
                        _attachOption(Icons.auto_awesome_rounded,
                            'Design a message', () {
                          Navigator.pop(context);
                          _openDesigner();
                        }),
                      ]),
                    ]))));
  }

  Widget _attachOption(IconData icon, String label, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
        onTap: onTap,
        borderRadius: AppShape.borderRadius(context, 16),
        child: Container(
            width: 96,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: AppShape.borderRadius(context, 16)),
            child: Column(children: [
              Icon(icon, color: AppColors.primaryOf(context), size: 26),
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

  /// Direct chats always store attachments via `users.dm_file_upload` keyed by
  /// the peer account id — even after `ensureDirectSpace` binds a desk space.
  /// `spaces.message_send` for Directs still claims `direct_attachments`, so
  /// `spaces.file_upload` ids 400. Person↔person and person↔agent DMs both use
  /// this path.
  bool get _useDmFileUpload =>
      widget.direct && widget.peerId.isNotEmpty;

  Future<void> _pickFile(List<XTypeGroup> types) async {
    final deps = widget.dependencies;
    // Person DMs: users.dm_file_upload (peer account id). Rooms: spaces.file_upload.
    if (deps == null || (!_useDmFileUpload && widget.spaceId.isEmpty)) return;
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

  Future<void> _attachFolder() async {
    final deps = widget.dependencies;
    if (deps == null) return;
    final folder = await attachProjectFolder(context, deps,
        initialSpace: widget.spaceId);
    if (folder == null || !mounted) return;
    final ref = 'folder:${folder['id']}';
    if (_drafts.any((d) => d.fileId == ref)) return;
    setState(() => _drafts.add(_DraftAttachment(
        name: '${folder['name']}',
        mime: 'inode/directory',
        bytes: Uint8List(0))
      ..fileId = ref
      ..uploaded = true));
  }

  Future<void> _uploadDraft(_DraftAttachment draft) async {
    final deps = widget.dependencies;
    if (deps == null) return;
    setState(() => draft.uploading = true);
    try {
      final uploaded = _useDmFileUpload
          ? await deps.service.dmFileUpload(
              widget.peerId,
              name: draft.name,
              mime: draft.mime,
              bytes: draft.bytes,
              voice: draft.voice,
              durationMs: draft.durationMs,
              waveform: draft.waveform,
            )
          : await deps.service.uploadFile(
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

  /// Empty composer → record a voice note (Decillion: send button is a mic).
  bool get _canRecordVoice {
    if (widget.dependencies == null || widget.composerNotice != null) {
      return false;
    }
    // Saved notes use live voice / dictation, not chat voice notes.
    if (widget.saved) return false;
    if (_sending || _editing != null || _voicePhase != null) return false;
    if (input.text.trim().isNotEmpty || _drafts.isNotEmpty) return false;
    // Person DMs / notes: users.dm_file_upload with voice metadata.
    if (_useDmFileUpload) return true;
    // Project rooms only (not Direct desks): spaces.file_upload audio.
    return !widget.direct && widget.spaceId.isNotEmpty;
  }

  Future<void> _startVoiceMessage() async {
    if (!_canRecordVoice) return;
    final recorder = VoiceMessageRecorder();
    try {
      await recorder.start();
    } catch (e) {
      await recorder.dispose();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
      return;
    }
    if (!mounted) {
      await recorder.dispose();
      return;
    }
    setState(() {
      _voiceRecorder = recorder;
      _voicePhase = 'recording';
      _voiceFile = null;
      _voiceStartedAt = recorder.startedAt;
    });
  }

  Future<void> _stopVoiceForPreview() async {
    final recorder = _voiceRecorder;
    if (recorder == null || _voicePhase != 'recording') return;
    try {
      final file = await recorder.stop();
      if (!mounted) return;
      if (!voiceLongEnough(file.durationMs)) {
        await _cancelVoiceMessage();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'That was too short. Tap the mic and speak, then send.')));
        return;
      }
      setState(() {
        _voicePhase = 'stopped';
        _voiceFile = file;
      });
    } catch (e) {
      await _cancelVoiceMessage();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Record failed: $e')));
    }
  }

  Future<void> _cancelVoiceMessage() async {
    final recorder = _voiceRecorder;
    _voiceRecorder = null;
    _voicePhase = null;
    _voiceFile = null;
    if (recorder != null) {
      try {
        await recorder.cancel();
      } catch (_) {}
      try {
        await recorder.dispose();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> _sendVoiceMessage() async {
    final deps = widget.dependencies;
    if (deps == null || _sending) return;
    var file = _voiceFile;
    final recorder = _voiceRecorder;
    if (file == null && recorder != null && _voicePhase == 'recording') {
      try {
        file = await recorder.stop();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Record failed: $e')));
        return;
      }
    }
    if (file == null) return;
    if (!voiceLongEnough(file.durationMs)) {
      await _cancelVoiceMessage();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('That was too short. Tap the mic and speak, then send.')));
      return;
    }
    setState(() {
      _sending = true;
      _voicePhase = null;
      _voiceFile = null;
      _voiceRecorder = null;
    });
    try {
      await recorder?.dispose();
    } catch (_) {}
    try {
      final draft = _DraftAttachment(
        name: file.name,
        mime: file.mime,
        bytes: file.bytes,
        // Only users.dm_file_upload stores voice / duration_ms / waveform.
        voice: _useDmFileUpload,
        durationMs: file.durationMs,
        waveform: file.waveform,
      );
      await _uploadDraft(draft);
      if (!draft.uploaded || draft.fileId.isEmpty) {
        throw StateError(draft.error ?? 'Upload failed');
      }
      await widget.onSend?.call('', const [], [draft.fileId],
          replyTo: _replyTo?.id ?? '');
      if (!mounted) return;
      setState(() => _replyTo = null);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Voice send failed: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _removeDraft(_DraftAttachment draft) async {
    // Best-effort cleanup of the uploaded file so cancelled drafts don't leak
    // into the workspace file library.
    // An attached folder stays shared; only uploaded files are removed.
    if (draft.uploaded &&
        draft.fileId.isNotEmpty &&
        !draft.fileId.startsWith('folder:')) {
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
            borderRadius: AppShape.borderRadius(context, 12)),
        child: Row(children: [
          if (d.bytes.isNotEmpty && d.mime.startsWith('image/'))
            ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(d.bytes,
                    width: 30, height: 30, fit: BoxFit.cover))
          else
            Icon(
                d.mime == 'inode/directory'
                    ? Icons.folder_shared_rounded
                    : d.mime.startsWith('audio/')
                    ? Icons.mic_rounded
                    : d.mime.startsWith('video/')
                        ? Icons.videocam_rounded
                        : Icons.insert_drive_file_rounded,
                size: 22,
                color: AppColors.primaryOf(context)),
          const SizedBox(width: 7),
          Expanded(
              child: d.uploading
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : d.error != null
                      ? Icon(Icons.error_outline_rounded,
                          color: AppColors.dangerOf(context), size: 16)
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
                              Text('ready to send',
                                  style: TextStyle(
                                      fontSize: 8,
                                      color: AppColors.successOf(context))),
                            ])),
          const SizedBox(width: 3),
          IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 14,
              onPressed: () => _removeDraft(d),
              icon: const Icon(Icons.close_rounded)),
        ]));
  }

  Widget _olderLoading() {
    if (!widget.loadingOlder && !widget.hasMore) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: widget.loadingOlder
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const SizedBox(height: 18),
      ),
    );
  }

  List<Widget> _messageChildren(
      BuildContext context, List<RoomMessage> messages, Widget? working,
      {bool withHeader = false}) {
    return [
      if (withHeader) ...[
        _chatHeader(),
        const SizedBox(height: 10),
      ],
      if (widget.hasMore || widget.loadingOlder) _olderLoading(),
      if (messages.isEmpty && working == null && widget.typing.isEmpty)
        (widget.loading
            ? const SkeletonMessages(
                count: 5, scrollable: false, padding: EdgeInsets.zero)
            : const _NoMessages())
      else ...[
        ...List.generate(
            messages.length,
            (i) => _chatBubble(context, messages[i],
                previous: i == 0 ? null : messages[i - 1])),
        if (working != null) working,
        if (widget.typing.isNotEmpty) _typingRow(),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Show the conversation chronologically (oldest→newest). message_list
    // returns newest-first, so sort by createdAt with the id as a tiebreaker.
    final messages = [..._visibleMessages]..sort((a, b) {
        final c = a.createdAt.compareTo(b.createdAt);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    // Only the newest message's replies are offered: once the conversation
    // moves on, older ones no longer answer anything.
    _repliesFor = '';
    for (final m in messages.reversed) {
      if (m.kind == 'log') continue;
      if (m.senderIsAgent) _repliesFor = m.id;
      break;
    }
    final working = _workingIndicator();
    if (widget.flat) {
      final bottomPad = 72 + widget.bottomContentInset;
      return _Panel(
          flat: true,
          child: Stack(children: [
            Positioned.fill(
                child: CustomPaint(
              painter: _ChatPatternPainter(
                  Theme.of(context).colorScheme.primary, widget.room),
              child: ListView(
                  controller: _chatScroll,
                  padding: EdgeInsets.fromLTRB(
                      12, widget.topContentInset, 12, bottomPad),
                  children: _messageChildren(context, messages, working,
                      withHeader: widget.showListHeader)),
            )),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10 + widget.bottomContentInset,
              child: _composer(),
            ),
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
          child: messages.isEmpty &&
                  widget.typing.isEmpty &&
                  working == null &&
                  !widget.loadingOlder &&
                  !widget.loading
              ? const _NoMessages()
              : messages.isEmpty && widget.loading
                  ? const SkeletonMessages()
                  : ListView(
                      controller: _chatScroll,
                      padding: const EdgeInsets.all(12),
                      children:
                          _messageChildren(context, messages, working)),
        )),
        Padding(padding: const EdgeInsets.all(10), child: _composer()),
      ]),
    );
  }

  /// The one place the room's work shows: below the last message, who is
  /// working and on what (or the answer being written), and how much waits.
  Widget? _workingIndicator() {
    final work = _work;
    final waiting = work?.queued.length ?? 0;
    final draft = work?.drafting;
    if (draft != null) {
      return _WorkingIndicator(
          agent: draft.agent, draft: draft.draft, waiting: waiting);
    }
    final activity = work?.activity ?? const <LiveActivity>[];
    if (activity.isNotEmpty) {
      return _WorkingIndicator(
          agent: activity.first.agent,
          detail: activity.first.detail,
          waiting: waiting);
    }
    final running = work?.running ?? const <WorkRun>[];
    if (running.isNotEmpty) {
      return _WorkingIndicator(
          agent: running.first.botName,
          detail: widget.workingDetail,
          waiting: waiting);
    }
    if (waiting > 0) {
      return _WorkingIndicator(
          agent: work!.queued.first.botName,
          detail: 'waiting to start',
          waiting: waiting - 1);
    }
    if (widget.working.isNotEmpty) {
      return _WorkingIndicator(
          agent: widget.working, detail: widget.workingDetail);
    }
    return null;
  }

  Widget _typingRow() {
    final scheme = Theme.of(context).colorScheme;
    final names = widget.typing;
    final who = names.length == 1
        ? '${names.first} is typing…'
        : names.length == 2
            ? '${names[0]} and ${names[1]} are typing…'
            : 'Several people are typing…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(42, 8, 12, 4),
      child: Text(who,
          style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant)),
    );
  }

  Widget _chatHeader() {
    final scheme = Theme.of(context).colorScheme;
    final deps = widget.dependencies;
    final count = widget.messages.where((m) => m.kind != 'log').length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
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
                    color: ThemeRoles.wellFill(context),
                    borderRadius: BorderRadius.circular(
                      AppShape.controlOf(context),
                    ),
                  ),
                  child: Text(
                    widget.room.isEmpty ? 'R' : widget.room[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: ThemeRoles.selectedInk(context),
                    ),
                  ),
                ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.room,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (widget.threadTitle.isNotEmpty)
                    Text(
                      'Thread · ${widget.threadTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary,
                      ),
                    )
                  else
                    Text(
                      widget.subtitle ??
                          (count == 0 ? 'Live room' : '$count messages'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            ..._roomTools(
              deps,
              compact: !_roomToolsFit(deps, constraints.maxWidth),
            ),
            ...widget.headerActions,
          ],
        ),
      ),
    );
  }

  /// Whether the header's [width] holds its avatar, a readable title, the
  /// room tools as buttons and the host's actions; when not, the tools fold
  /// into one menu.
  bool _roomToolsFit(AppDependencies? deps, double width) {
    const avatar = 42 + 12, title = 110, tool = 44.0, action = 40.0;
    final threads =
        widget.threadRoomId.isNotEmpty &&
        widget.onThread != null &&
        deps != null;
    final needed =
        avatar +
        title +
        (widget.leading != null ? 44 : 0) +
        tool * (threads ? 3 : 2) +
        action * widget.headerActions.length;
    return width >= needed;
  }

  /// The room's own header tools: its threads, the agents' work and its
  /// routines. A narrow header (a phone) folds them into one menu, so the
  /// title keeps its room and nothing runs past the edge.
  List<Widget> _roomTools(AppDependencies? deps, {required bool compact}) {
    final threads =
        widget.threadRoomId.isNotEmpty &&
        widget.onThread != null &&
        deps != null;
    final threadsLabel = widget.threadTitle.isEmpty
        ? 'Threads'
        : 'Threads (in “${widget.threadTitle}”)';
    Future<void> openThreads() async {
      final picked = await showRoomThreads(
        context,
        service: deps!.service,
        spaceId: widget.spaceId,
        roomId: widget.threadRoomId,
        currentId: widget.roomId,
      );
      if (picked != null && mounted) widget.onThread?.call(picked);
    }

    final openWork = _work == null
        ? null
        : () => showRoomWork(
            context,
            _work!,
            onRunAgain: widget.onSend == null ? null : _runAgain,
          );
    final openRoutines = deps == null
        ? null
        : () => showRoutinesSheet(
            context,
            deps,
            widget.spaceId,
            widget.roomId,
            widget.room,
          );

    if (compact) {
      return [
        PopupMenuButton<VoidCallback>(
          tooltip: 'Room actions',
          icon: const Icon(Icons.more_horiz_rounded, size: 20),
          onSelected: (run) => run(),
          itemBuilder: (_) => [
            if (threads)
              PopupMenuItem(
                value: () => unawaited(openThreads()),
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.forum_outlined, size: 18),
                  title: Text(threadsLabel),
                ),
              ),
            PopupMenuItem(
              value: openWork ?? () {},
              enabled: openWork != null,
              child: const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.history_rounded, size: 18),
                title: Text('Work'),
              ),
            ),
            PopupMenuItem(
              value: openRoutines ?? () {},
              enabled: openRoutines != null,
              child: const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.schedule_rounded, size: 18),
                title: Text('Routines'),
              ),
            ),
          ],
        ),
      ];
    }
    return [
      if (threads) ...[
        IconButton.filledTonal(
          tooltip: threadsLabel,
          visualDensity: VisualDensity.compact,
          isSelected: widget.threadTitle.isNotEmpty,
          onPressed: openThreads,
          icon: const Icon(Icons.forum_outlined, size: 18),
          selectedIcon: const Icon(Icons.forum_rounded, size: 18),
        ),
        const SizedBox(width: 4),
      ],
      IconButton.filledTonal(
        tooltip: 'Work',
        visualDensity: VisualDensity.compact,
        onPressed: openWork,
        icon: const Icon(Icons.history_rounded, size: 18),
      ),
      const SizedBox(width: 4),
      IconButton.filledTonal(
        tooltip: 'Routines',
        visualDensity: VisualDensity.compact,
        onPressed: openRoutines,
        icon: const Icon(Icons.schedule_rounded, size: 18),
      ),
    ];
  }

  /// Default single-line message composer height (Material control size).
  static const double _composerHeight = 56;

  /// Shared size for attach / mention / dictate / send in the composer row.
  static const double _composerIconSize = 40;

  /// Uniform gap between composer icon buttons (and the field).
  static const double _composerIconGap = AppSpacing.xs;

  ButtonStyle _composerIconStyle({Color? backgroundColor, Color? foregroundColor}) =>
      IconButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        minimumSize: const Size(_composerIconSize, _composerIconSize),
        maximumSize: const Size(_composerIconSize, _composerIconSize),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );

  ButtonStyle _composerSendStyle({Color? backgroundColor, Color? foregroundColor}) =>
      _composerIconStyle(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
      );

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    final shell = ThemeChrome.inputShell(context, elevated: widget.flat);
    final notice = widget.composerNotice;
    if (notice != null) {
      return Container(
        constraints: const BoxConstraints(minHeight: _composerHeight),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: shell.color,
            borderRadius: shell.radius),
        child: Row(children: [
          Icon(Icons.block_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
              child: Text(notice,
                  style:
                      TextStyle(fontSize: 13, color: scheme.onSurfaceVariant))),
        ]),
      );
    }
    final work = _work;
    final hasChrome = _drafts.isNotEmpty ||
        _mentions.isNotEmpty ||
        _editing != null ||
        _replyTo != null ||
        (_editing == null &&
            _voicePhase == null &&
            PromptCommandSuggestions.matches(input.text)) ||
        _voicePhase != null;
    final inputRow = _composerInputRow(scheme);
    final box = Material(
        color: shell.color,
        elevation: shell.elevation,
        shadowColor: Colors.black.withValues(alpha: .25),
        borderRadius: shell.radius,
        clipBehavior: Clip.antiAlias,
        child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: math.max(6.0, shell.padding.left * 0.75),
              vertical: hasChrome ? 6 : 0,
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_drafts.isNotEmpty)
                Padding(
                    padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final d in _drafts) _draftChip(d)
                            ]))),
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
              if (_editing != null || _replyTo != null) _composerBanner(),
              if (_editing == null &&
                  _voicePhase == null &&
                  PromptCommandSuggestions.matches(input.text))
                PromptCommandSuggestions(
                    typed: input.text, onPick: _pickCommand),
              if (_voicePhase != null)
                VoiceRecorderBar(
                  phase: _voicePhase!,
                  startedAt: _voiceStartedAt,
                  level: () => _voiceRecorder?.level ?? 0,
                  file: _voiceFile,
                  onStop: () => unawaited(_stopVoiceForPreview()),
                  onCancel: () => unawaited(_cancelVoiceMessage()),
                  onSend: () => unawaited(_sendVoiceMessage()),
                  onLimit: () => unawaited(_stopVoiceForPreview()),
                )
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _composerHeight),
                  child: inputRow,
                ),
            ])));
    final deps = widget.dependencies;
    final banner = widget.suggestions && deps != null
        ? Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SuggestionBanner(
                dependencies: deps,
                onOpenTasks: () => showTasksPanel(context, deps)),
          )
        : null;
    if (work == null && banner == null) return box;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (banner != null) banner,
      if (work != null)
        RoomWorkNeeds(work: work, onAnswer: _answer, onRunAgain: _runAgain),
      box,
    ]);
  }

  /// One-row bar: attach / mention, the text field, mic and send.
  Widget _composerInputRow(ColorScheme scheme) {
    final canAttach = !_sending;
    final actions = [
      _composerAction(Icons.add_rounded, 'Attach file',
          canAttach ? (ctx) => _showAttachSheet(ctx) : null),
      _composerAction(Icons.alternate_email_rounded, 'Mention an agent',
          (ctx) => _pickMention(ctx)),
    ];
    final field = TextField(
        controller: input,
        enabled: !_sending,
        onSubmitted: _submit,
        onChanged: _typed,
        minLines: 1,
        maxLines: 5,
        textInputAction: TextInputAction.send,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
            hintText: (_work?.questions.isNotEmpty ?? false)
                ? 'Answer ${_work!.questions.first.agent}…'
                : widget.hint,
            hintMaxLines: 1,
            filled: false,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none));
    // While agents work, an empty composer's button stops them.
    final stop = _busy &&
        !_sending &&
        _editing == null &&
        input.text.trim().isEmpty &&
        _drafts.isEmpty;
    final recordVoice = !stop && _canRecordVoice;
    final Widget send;
    if (stop) {
      send = IconButton.filled(
          tooltip: 'Stop the work in progress',
          style: _composerSendStyle(
              backgroundColor: scheme.error, foregroundColor: scheme.onError),
          onPressed: (_work?.stopping ?? false) ? null : _stopWork,
          icon: const Icon(Icons.stop_rounded, size: 20));
    } else if (recordVoice) {
      // Empty composer: filled mic records a voice note (not STT).
      send = IconButton.filled(
          tooltip: 'Record a voice message',
          style: _composerSendStyle(),
          onPressed: _sending ? null : () => unawaited(_startVoiceMessage()),
          icon: const Icon(Icons.mic_rounded, size: 20));
    } else {
      send = IconButton.filled(
          tooltip: 'Send',
          style: _composerSendStyle(),
          onPressed: _sending ? null : () => _submit(input.text),
          icon: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send_rounded, size: 20));
    }
    final deps = widget.dependencies;
    // Hide STT while the empty-composer mic means "voice note", so tapping
    // the microphone always records a message instead of calling dictate.
    final dictate = deps == null ||
            _sending ||
            _editing != null ||
            recordVoice
        ? null
        : DictationButton(
            dependencies: deps,
            onText: _dictated,
            style: _composerIconStyle(),
          );
    return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        spacing: _composerIconGap,
        children: [
          ...actions,
          Expanded(child: field),
          if (dictate != null) dictate,
          send,
        ]);
  }

  /// Puts dictated text where the cursor is; the person sends it.
  void _dictated(String text) {
    final value = input.value;
    final at = value.selection.isValid ? value.selection.start : value.text.length;
    final end = value.selection.isValid ? value.selection.end : value.text.length;
    final before = value.text.substring(0, at);
    final spaced = before.isEmpty || before.endsWith(' ') ? text : ' $text';
    input.value = TextEditingValue(
        text: before + spaced + value.text.substring(end),
        selection: TextSelection.collapsed(offset: at + spaced.length));
    _typed(input.text);
  }

  Widget _composerAction(
          IconData icon, String tooltip, void Function(BuildContext)? onTap) =>
      Builder(
          builder: (ctx) => IconButton(
              tooltip: tooltip,
              style: _composerIconStyle(),
              onPressed: onTap == null ? null : () => onTap(ctx),
              icon: Icon(icon, size: 20)));

  // Resolves a sender id to a display name: the agents in the workspace are
  // known by name, other members fall back to a short id.
  ({String name, bool agent}) _sender(String id) {
    for (final b in widget.mentionable) {
      if (b.id == id || b.accountId == id) {
        return (name: b.name, agent: true);
      }
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
    // Microtool replies (kind tool) are for the desk / command path —
    // never list them in chat (they are not conversation).
    if (m.kind == 'tool') {
      return const SizedBox.shrink();
    }
    // Agentic-flow content (aseman's plans, dispatches, tool/sandbox outputs)
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
    final sender = _senderOf(m);
    final seen = mine &&
        widget.receipts &&
        widget.peerSeenAt != null &&
        !m.createdAt.isAfter(widget.peerSeenAt!);
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    final bubble = Container(
        padding: ThemeChrome.chatBubblePadding(context),
        decoration: ThemeChrome.chatBubble(
          context,
          mine: mine,
          continued: continued,
        ),
        child: DefaultTextStyle.merge(
            style: TextStyle(color: fg, fontSize: 14, height: 1.4),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (m.replyTo.isNotEmpty) _quote(m, fg),
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
              if (m.body.trim().isNotEmpty) ..._agUiBody(context, m, deps, fg),
              // A gateway proxy message gets an "open in webview" button
              // so the room's users can view the page served from the
              // sandbox behind it.
              if (deps != null && _proxyPathIn(m.body) != null)
                Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _ProxyOpenButton(
                        title: _proxyTitle(m.body) ?? 'Sandbox service',
                        service: deps.service,
                        page: _proxyPathIn(m.body) ?? '')),
              _reactionChips(m, fg),
              const SizedBox(height: 2),
              Row(mainAxisSize: MainAxisSize.min, children: [
                if (m.edited)
                  _EditedLabel(
                    time: time,
                    color: fg.withValues(alpha: .65),
                    onTap: deps == null
                        ? null
                        : () => showMessageEditHistory(context,
                            service: deps.service, message: m),
                  )
                else
                  Text(time,
                      style: TextStyle(
                          fontSize: 10, color: fg.withValues(alpha: .65))),
                // In a direct chat, the caller's messages show whether the
                // other side has read them.
                if (mine && widget.receipts) ...[
                  const SizedBox(width: 3),
                  Icon(seen ? Icons.done_all_rounded : Icons.done_rounded,
                      size: 13,
                      semanticLabel: seen ? 'Seen' : 'Sent',
                      color: seen ? scheme.primary : fg.withValues(alpha: .65)),
                ],
              ]),
            ])));
    final avatar = SizedBox(
        width: 36,
        child: continued
            ? null
            : sender.agent
                ? BotAvatar(
                    bot: _agentBotOf(m) ??
                        Bot(
                          id: _agentPrefsId(m),
                          ownerId: '',
                          accountId: m.senderId,
                          name: sender.name,
                          vmType: '',
                          status: '',
                          avatar: _avatarOf(m),
                          humanoid: _agentHumanoidOf(m),
                        ),
                    radius: 15,
                    userId: widget.me,
                  )
                : Builder(builder: (context) {
                    const radius = 15.0;
                    final faceSize = radius * 2;
                    final corners = context.avatarBorderRadius(faceSize);
                    final picture = Avatars.of(_avatarOf(m));
                    return HaloRing(
                      identity: HaloRingCache.person(m.senderId),
                      accent: scheme.secondary,
                      borderRadius: corners,
                      child: AvatarFace(
                        size: faceSize,
                        borderRadius: corners,
                        foregroundImage: picture,
                        onImageError:
                            picture == null ? null : (_, __) {},
                        backgroundColor: ThemeRoles.wellFill(context),
                        child: Icon(Icons.person_rounded,
                            size: 17, color: ThemeRoles.wellInk(context)),
                      ),
                    );
                  }));
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
                            Builder(
                                builder: (bubbleCtx) => GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onLongPressStart: (d) => _messageMenu(m,
                                        at: d.globalPosition, anchor: bubbleCtx),
                                    onSecondaryTapDown: (d) => _messageMenu(m,
                                        at: d.globalPosition, anchor: bubbleCtx),
                                    child: bubble)),
                          ]))),
              SizedBox(width: mine ? 4 : 12),
            ]));
  }

  static String _msgTime(DateTime t) =>
      '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

  /// Caption markdown + AG-UI surface (if the body carries an `agui` fence).
  List<Widget> _agUiBody(
      BuildContext context, RoomMessage m, AppDependencies? deps, Color fg) {
    try {
      final offered = parseReplies(m.body);
      final parsed = parseAgUiBody(offered.text);
      final out = <Widget>[];
      if (parsed.caption.trim().isNotEmpty) {
        out.add(RichPostContent(parsed.caption,
            headers: deps?.service.authHeaders() ?? const {},
            resolveUrl: deps?.service.resolveContentUrl,
            onLinkTap: deps == null
                ? null
                : (link) => openWorkspaceLink(context, deps.service, link)));
      }
      final surface = parsed.surface;
      if (surface != null && surface.root != null) {
        out.add(Padding(
          padding: EdgeInsets.only(top: parsed.caption.trim().isEmpty ? 0 : 8),
          child: _withActions(
            deps,
            AgUiSurfaceView(
              surface: surface,
              onReply: widget.onSend == null
                  ? null
                  : (value, {meta}) {
                      widget.onSend!(value, const [], const [], replyTo: m.id);
                    },
            ),
          ),
        ));
      } else if (parsed.caption.trim().isEmpty &&
          offered.text.trim().isNotEmpty) {
        // No fence — original markdown body.
        out.add(RichPostContent(offered.text,
            headers: deps?.service.authHeaders() ?? const {},
            resolveUrl: deps?.service.resolveContentUrl,
            onLinkTap: deps == null
                ? null
                : (link) => openWorkspaceLink(context, deps.service, link)));
      }
      if (offered.replies.isNotEmpty &&
          m.id == _repliesFor &&
          widget.onSend != null) {
        out.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final reply in offered.replies)
              ActionChip(
                label: Text(reply),
                onPressed: () =>
                    widget.onSend!(reply, const [], const [], replyTo: m.id),
              ),
          ]),
        ));
      }
      return out;
    } catch (_) {
      // Never let one bad body grey out the whole message list.
      final plain = m.body.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (plain.isEmpty) return const [];
      return [Text(plain, style: TextStyle(color: fg, fontSize: 14, height: 1.4))];
    }
  }

  /// Gives governance cards (approvals, secrets, take-over, suggestions)
  /// the node and this conversation's project.
  Widget _withActions(AppDependencies? deps, Widget child) {
    if (deps == null) return child;
    return AgUiActions(
      invoke: (namespace, action, body) =>
          deps.service.invokeAction(namespace, action, body: body),
      spaceId: widget.spaceId,
      roomId: widget.roomId,
      onOpenTasks: () => showTasksPanel(context, deps),
      child: child,
    );
  }
}

/// A file picked for an in-flight room message. It is uploaded to the space's
/// room as soon as it is picked so the message only references the file id.
class _DraftAttachment {
  _DraftAttachment({
    required this.name,
    required this.mime,
    required this.bytes,
    this.voice = false,
    this.durationMs = 0,
    this.waveform = const [],
  });

  final String name;
  final String mime;
  final Uint8List bytes;

  /// Direct voice note → `users.dm_file_upload` voice metadata.
  final bool voice;
  final int durationMs;
  final List<int> waveform;
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
  const _ProxyOpenButton(
      {required this.title, required this.service, required this.page});

  final String title;
  final AsemanService service;
  final String page;

  Future<void> _open(BuildContext context) async {
    try {
      await openWorkspacePage(context, service, page, title: title);
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
    final target = workspacePageTarget(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Material(
        color: scheme.primary,
        borderRadius: AppShape.borderRadius(context, 12),
        child: InkWell(
          borderRadius: AppShape.borderRadius(context, 12),
          onTap: () => _open(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                  switch (target) {
                    WorkspacePageTarget.desk => Icons.dashboard_rounded,
                    WorkspacePageTarget.screen => Icons.open_in_browser_rounded,
                    WorkspacePageTarget.browser => Icons.open_in_new_rounded,
                  },
                  size: 16,
                  color: scheme.onPrimary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                    switch (target) {
                      WorkspacePageTarget.desk => 'Open on the desk',
                      WorkspacePageTarget.screen => 'Open page',
                      WorkspacePageTarget.browser => 'Open in browser',
                    },
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
                color: ThemeRoles.wellFill(context),
                borderRadius: BorderRadius.circular(AppShape.innerOf(context))),
            child: Icon(Icons.forum_rounded,
                size: 30, color: ThemeRoles.wellInk(context)),
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

/// Compact "edited · time" affordance; opens the message's earlier wording.
class _EditedLabel extends StatelessWidget {
  const _EditedLabel({required this.time, required this.color, this.onTap});

  final String time;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text.rich(
      TextSpan(children: [
        TextSpan(
            text: 'edited',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
                decoration: onTap == null ? null : TextDecoration.underline,
                decorationColor: color.withValues(alpha: .5))),
        TextSpan(
            text: ' · $time',
            style: TextStyle(fontSize: 10, color: color)),
      ]),
    );
    if (onTap == null) return label;
    return Tooltip(
      message: 'View edit history',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: label,
        ),
      ),
    );
  }
}

// _WorkingIndicator shows, below the last message, which agent is working:
// a live sentence of what it is doing ("running in the sandbox…") or the
// answer it is writing as it comes, with how many requests wait after it.
class _WorkingIndicator extends StatefulWidget {
  const _WorkingIndicator(
      {required this.agent,
      this.detail = '',
      this.draft = '',
      this.waiting = 0});
  final String agent;
  final String detail;

  /// The answer being written, shown as it comes.
  final String draft;

  /// Requests waiting after this one.
  final int waiting;

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
    final draft = widget.draft.trim();
    final detail = draft.isNotEmpty
        ? 'writing'
        : widget.detail.trim().isEmpty
            ? 'working'
            : widget.detail.trim();
    final muted = TextStyle(
        fontSize: 12,
        fontStyle: FontStyle.italic,
        color: scheme.onSurfaceVariant);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(top: 10, left: 38),
        padding: ThemeChrome.chatBubblePadding(context),
        decoration: ThemeChrome.chatBubble(
          context,
          mine: false,
          agent: true,
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.agent,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary)),
                const SizedBox(width: 6),
                Flexible(
                    child: Text(detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted)),
                const SizedBox(width: 8),
                _WorkingDots(controller: _controller, color: scheme.primary),
                if (widget.waiting > 0) ...[
                  const SizedBox(width: 8),
                  Text('+${widget.waiting} waiting', style: muted),
                ],
              ]),
              if (draft.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(draft,
                    key: const ValueKey('live-draft'),
                    style: const TextStyle(fontSize: 14, height: 1.35)),
              ],
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
        borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: .4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(AppShape.controlOf(context)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 10, 8),
            child: Row(children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                    color: ThemeRoles.wellFill(context),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.terminal_rounded,
                    size: 15, color: ThemeRoles.wellInk(context)),
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
                    headers: dependencies?.service.authHeaders() ?? const {},
                    resolveUrl: dependencies?.service.resolveContentUrl),
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
