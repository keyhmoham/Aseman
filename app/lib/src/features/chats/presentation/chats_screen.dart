import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/page_scaffold.dart';
import '../../../shared/widgets/status_tag.dart';

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
    final result = await showDialog<_NewMessageResult>(
      context: context,
      builder: (context) => const _NewMessageDialog(),
    );
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
    final body = await showDialog<String>(
      context: context,
      builder: (context) => _ReplyDialog(ask: ask),
    );
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

  @override
  Widget build(BuildContext context) {
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    final pending = _requests.isNotEmpty
        ? _requests
        : _packets
            .where((p) => p.isAsk && p.isRequested && p.toId == me)
            .toList();
    return FeaturePage(
      title: 'Messages',
      subtitle:
          '${_packets.length} packets · ${pending.length} pending requests',
      onBack: () => Navigator.of(context).pop(),
      actions: [
        FilledButton.icon(
          onPressed: _newMessage,
          icon: const Icon(Icons.edit_rounded),
          label: const Text('New message'),
        ),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (_hasMore &&
                        !_loadingMore &&
                        n.metrics.extentAfter < 250) {
                      unawaited(_load(more: true));
                    }
                    return false;
                  },
                  child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                      children: [
                        if (pending.isNotEmpty) ...[
                          Text('REQUESTS',
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.primary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800)),
                          const SizedBox(height: 8),
                          ...pending.map((p) => _PacketCard(
                                packet: p,
                                incoming: p.toId == me,
                                onTap: () => _answerAsk(p),
                              )),
                          const SizedBox(height: 14),
                        ],
                        Text('INBOX',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                fontSize: 11,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 8),
                        if (_packets.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 50),
                            child: Center(
                              child: Text(
                                  'No messages yet — send one to a user or bot.',
                                  style: TextStyle(
                                      color: AppColors.muted, fontSize: 12)),
                            ),
                          )
                        else
                          ..._packets.map((p) => _PacketCard(
                                packet: p,
                                incoming: p.toId == me,
                                onTap: null,
                              )),
                        if (_loadingMore)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 14),
                            child: Center(
                                child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.5))),
                          ),
                      ]),
                ),
    );
  }
}

class _PacketCard extends StatelessWidget {
  const _PacketCard({
    required this.packet,
    required this.incoming,
    this.onTap,
  });

  final Packet packet;
  final bool incoming;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final peer = incoming ? packet.fromId : packet.toId;
    final color = packet.isAsk
        ? AppColors.primary
        : packet.isAnswered
            ? AppColors.success
            : AppColors.muted;
    final label = packet.isAsk
        ? 'ASK'
        : packet.isAnswered
            ? 'ANSWER'
            : packet.isRequested
                ? 'REQ'
                : 'MSG';
    final time = packet.repliedAt ?? DateTime.now();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Row(children: [
          AppAvatar(peer.isEmpty ? '?' : peer.substring(0, 2).toUpperCase(),
              color: color, radius: 19),
          const SizedBox(width: 12),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(
                      '@${peer.isEmpty ? 'unknown' : peer.substring(0, 10)}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                StatusTag(label, color),
              ]),
              const SizedBox(height: 3),
              Text(packet.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.muted, fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Text(
            '${time.hour}:${time.minute.toString().padLeft(2, '0')}',
            style: const TextStyle(color: AppColors.muted, fontSize: 10),
          ),
        ]),
      ),
    );
  }
}

class _NewMessageResult {
  const _NewMessageResult(this.toId, this.body);
  final String toId;
  final String body;
}

class _NewMessageDialog extends StatefulWidget {
  const _NewMessageDialog();
  @override
  State<_NewMessageDialog> createState() => _NewMessageDialogState();
}

class _NewMessageDialogState extends State<_NewMessageDialog> {
  final toController = TextEditingController();
  final bodyController = TextEditingController();

  @override
  void dispose() {
    toController.dispose();
    bodyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('New message'),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: toController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Recipient id (user or bot)',
              hintText: '32-char account id',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: bodyController,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Message'),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (toController.text.trim().isEmpty) return;
            Navigator.pop(
                context,
                _NewMessageResult(
                  toController.text.trim(),
                  bodyController.text.trim(),
                ));
          },
          child: const Text('Send'),
        ),
      ],
    );
  }
}

class _ReplyDialog extends StatelessWidget {
  const _ReplyDialog({required this.ask});

  final Packet ask;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Answer request'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(ask.body),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              maxLines: 3,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Your answer'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Reply'),
        ),
      ],
    );
  }
}
