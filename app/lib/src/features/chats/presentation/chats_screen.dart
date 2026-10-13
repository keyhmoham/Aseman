import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/bot.dart';
import '../../../data/models/space.dart';
import '../../../data/services/tradera_service.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/app_inputs.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/segmented_tab_bar.dart';

/// Server-backed messages: the packet inbox (message namespace). Shows pending
/// asks that need an answer and the message history, with send + reply flows.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, required this.dependencies});

  final AppDependencies dependencies;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  static const _pageSize = 50;
  List<Packet> _packets = [];
  List<Packet> _requests = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || !_hasMore || _loading) return;
      setState(() => _loadingMore = true);
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final offset = more ? _offset : 0;
      final results = await Future.wait([
        widget.dependencies.service
            .fetchPackets(limit: _pageSize, offset: offset),
        if (!more) widget.dependencies.service.fetchPendingRequests(),
      ]);
      if (!mounted) return;
      final packets = results[0];
      setState(() {
        if (more) {
          _packets.addAll(packets);
          _offset += packets.length;
        } else {
          _packets = packets;
          _requests = (results[1] as List).cast<Packet>();
          _offset = packets.length;
        }
        _hasMore = packets.length >= _pageSize;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _newMessage() async {
    final result = await showAppForm<_NewMessageResult>(
        context, _NewMessageForm(service: widget.dependencies.service));
    if (result == null || !mounted) return;
    try {
      await widget.dependencies.service.sendPacket(result.toId, result.body);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Message sent')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Send failed: $e')));
    }
  }

  Future<void> _answerAsk(Packet ask) async {
    final body = await showAppForm<String>(context, _ReplyForm(ask: ask));
    if (body == null || !mounted) return;
    try {
      await widget.dependencies.service.respondToAsk(ask.id, body);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Answered')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    final pending = _requests.isNotEmpty
        ? _requests
        : _packets
            .where((p) => p.isAsk && p.isRequested && p.toId == me)
            .toList();
    final received = _packets.where((p) => p.toId == me).toList();
    final sent = _packets.where((p) => p.fromId == me).toList();
    final shown = switch (_filter) {
      1 => pending,
      2 => received,
      3 => sent,
      _ => _packets,
    };
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final gutter = wide ? 32.0 : 16.0;
    return Scaffold(
      backgroundColor: scheme.surface,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newMessage,
        icon: const Icon(Icons.edit_rounded),
        label: const Text('New message'),
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_hasMore && !_loadingMore && n.metrics.extentAfter < 250) {
            unawaited(_load(more: true));
          }
          return false;
        },
        child: RefreshIndicator(
          onRefresh: _load,
          child: CustomScrollView(slivers: [
            SliverAppBar.large(
              backgroundColor: scheme.surface,
              surfaceTintColor: Colors.transparent,
              title: const Text('Messages'),
              actions: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 0),
              sliver: SliverToBoxAdapter(
                child: SegmentedTabBar(
                  alignment: Alignment.centerLeft,
                  selectedIndex: _filter,
                  onTap: (i) => setState(() => _filter = i),
                  labels: [
                    'All',
                    pending.isEmpty
                        ? 'Requests'
                        : 'Requests · ${pending.length}',
                    'Received',
                    'Sent',
                  ],
                  icons: const [
                    Icons.all_inbox_rounded,
                    Icons.help_outline_rounded,
                    Icons.call_received_rounded,
                    Icons.call_made_rounded,
                  ],
                ),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CircularProgressIndicator()))
            else if (_error != null)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(
                      icon: Icons.cloud_off_rounded,
                      title: 'Could not load messages',
                      body: _error!))
            else if (shown.isEmpty)
              SliverFillRemaining(
                  hasScrollBody: false,
                  child: _Empty(
                      icon: _filter == 1
                          ? Icons.mark_chat_read_outlined
                          : Icons.forum_outlined,
                      title:
                          _filter == 1 ? 'No open requests' : 'No messages yet',
                      body: _filter == 1
                          ? 'Questions people and agents ask you show up here.'
                          : 'Send one to a person or an agent to start.'))
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 96),
                sliver: SliverList.separated(
                  itemCount: shown.length + (_loadingMore ? 1 : 0),
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    if (i >= shown.length) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Center(
                            child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5))),
                      );
                    }
                    final p = shown[i];
                    final open = pending.contains(p);
                    return _PacketCard(
                      packet: p,
                      incoming: p.toId == me,
                      needsAnswer: open,
                      onAnswer: open ? () => _answerAsk(p) : null,
                    );
                  },
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: ShapeDecoration(
                color: scheme.secondaryContainer,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24))),
            child: Icon(icon, size: 34, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(height: 16),
          Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(body,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}

class _PacketCard extends StatelessWidget {
  const _PacketCard({
    required this.packet,
    required this.incoming,
    required this.needsAnswer,
    this.onAnswer,
  });

  final Packet packet;
  final bool incoming;
  final bool needsAnswer;
  final VoidCallback? onAnswer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final peer = incoming ? packet.fromId : packet.toId;
    final (label, color, icon) = packet.isAsk
        ? ('Question', AppColors.primary, Icons.help_outline_rounded)
        : packet.isAnswered
            ? ('Answered', AppColors.success, Icons.check_circle_outline)
            : packet.isRequested
                ? ('Requested', AppColors.warning, Icons.hourglass_top_rounded)
                : (
                    'Message',
                    scheme.onSurfaceVariant,
                    Icons.chat_bubble_outline
                  );
    final time = packet.repliedAt?.toLocal();
    final name = peer.isEmpty
        ? 'unknown'
        : peer.length > 12
            ? peer.substring(0, 12)
            : peer;
    return Material(
      color: needsAnswer
          ? scheme.primaryContainer.withValues(alpha: .55)
          : scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppShape.inner + 2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onAnswer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Stack(clipBehavior: Clip.none, children: [
              AppAvatar(peer.isEmpty ? '?' : peer.substring(0, 2).toUpperCase(),
                  color: color, radius: 22),
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                      color: scheme.surface, shape: BoxShape.circle),
                  child: Icon(
                      incoming
                          ? Icons.call_received_rounded
                          : Icons.call_made_rounded,
                      size: 12,
                      color: incoming ? AppColors.cyan : scheme.primary),
                ),
              ),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text('${incoming ? 'From' : 'To'} @$name',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: color.withValues(alpha: .15),
                            borderRadius: BorderRadius.circular(999)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(icon, size: 12, color: color),
                          const SizedBox(width: 4),
                          Text(label,
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: color)),
                        ]),
                      ),
                      const Spacer(),
                      if (time != null)
                        Text(
                            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                            style: TextStyle(
                                fontSize: 12, color: scheme.onSurfaceVariant)),
                    ]),
                    const SizedBox(height: 6),
                    Text(packet.body.isEmpty ? '(no text)' : packet.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: scheme.onSurfaceVariant)),
                    if (onAnswer != null) ...[
                      const SizedBox(height: 10),
                      FilledButton.tonalIcon(
                          onPressed: onAnswer,
                          icon: const Icon(Icons.reply_rounded, size: 18),
                          label: const Text('Answer')),
                    ],
                  ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _NewMessageResult {
  const _NewMessageResult(this.toId, this.body);
  final String toId;
  final String body;
}

/// Writes a message to someone found by @handle (a pasted account id also
/// works).
class _NewMessageForm extends StatefulWidget {
  const _NewMessageForm({required this.service});
  final TraderaService service;
  @override
  State<_NewMessageForm> createState() => _NewMessageFormState();
}

class _NewMessageFormState extends State<_NewMessageForm> {
  final query = TextEditingController();
  final body = TextEditingController();
  List<AccountSummary> results = const [];
  AccountSummary? recipient;
  Timer? debounce;

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    body.dispose();
    super.dispose();
  }

  void _search(String text) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () async {
      final q = text.trim().replaceFirst(RegExp(r'^@+'), '');
      if (q.isEmpty) {
        if (mounted) setState(() => results = const []);
        return;
      }
      try {
        final found = await widget.service.searchUsers(q, limit: 6);
        if (mounted) setState(() => results = found);
      } catch (_) {
        if (mounted) setState(() => results = const []);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final raw = query.text.trim();
    final pastedId = RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(raw);
    final to = recipient?.id ?? (pastedId ? raw : null);
    return AppFormFrame(
      icon: Icons.edit_rounded,
      title: 'New message',
      subtitle: 'To a person or an agent. Agents reply in this inbox.',
      submit: 'Send',
      onSubmit: to == null || body.text.trim().isEmpty
          ? null
          : () =>
              Navigator.pop(context, _NewMessageResult(to, body.text.trim())),
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const AppFieldLabel('To'),
          if (recipient != null)
            InputChip(
              avatar: CircleAvatar(
                  child: Text(recipient!.handle.isEmpty
                      ? '?'
                      : recipient!.handle[0].toUpperCase())),
              label: Text('@${recipient!.handle}'),
              onDeleted: () => setState(() => recipient = null),
            )
          else ...[
            TextField(
              controller: query,
              autofocus: true,
              onChanged: (v) {
                setState(() {});
                _search(v);
              },
              decoration: const InputDecoration(
                hintText: 'Search by @handle',
                prefixIcon: Icon(Icons.person_search_rounded),
              ),
            ),
            for (final r in results)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppShape.control)),
                leading: CircleAvatar(
                    child: Icon(r.kind == 'user'
                        ? Icons.person_outline_rounded
                        : Icons.smart_toy_outlined)),
                title: Text('@${r.handle}'),
                subtitle: Text(r.kind == 'user' ? 'Person' : 'Agent'),
                onTap: () => setState(() => recipient = r),
              ),
          ],
        ]),
        TextField(
          controller: body,
          minLines: 3,
          maxLines: 8,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: 'Message', alignLabelWithHint: true),
        ),
      ],
    );
  }
}

class _ReplyForm extends StatefulWidget {
  const _ReplyForm({required this.ask});
  final Packet ask;
  @override
  State<_ReplyForm> createState() => _ReplyFormState();
}

class _ReplyFormState extends State<_ReplyForm> {
  final controller = TextEditingController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppFormFrame(
      icon: Icons.reply_rounded,
      title: 'Answer the question',
      submit: 'Reply',
      onSubmit: controller.text.trim().isEmpty
          ? null
          : () => Navigator.pop(context, controller.text.trim()),
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppShape.control),
            border: Border(left: BorderSide(color: scheme.primary, width: 4)),
          ),
          child: Text(widget.ask.body,
              style: const TextStyle(fontSize: 14, height: 1.4)),
        ),
        TextField(
          controller: controller,
          minLines: 3,
          maxLines: 8,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
              labelText: 'Your answer', alignLabelWithHint: true),
        ),
      ],
    );
  }
}
