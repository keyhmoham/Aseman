import 'package:flutter/material.dart';

import '../../../app_dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shape.dart';
import '../../../data/models/space.dart';
import '../../../shared/widgets/app_form.dart';
import '../../../shared/widgets/avatar.dart';
import '../../../shared/widgets/overlay_panels.dart';
import '../../../shared/widgets/panel_header.dart';
import '../../../shared/widgets/skeleton.dart';

/// Opens the questions people and agents asked the caller and are waiting on
/// (the message namespace's asks), to answer them one by one.
Future<void> showRequestsPanel(
        BuildContext context, AppDependencies dependencies) =>
    showFloatingPanel(context, RequestsPanel(dependencies: dependencies),
        maxWidth: 720);

class RequestsPanel extends StatefulWidget {
  const RequestsPanel({super.key, required this.dependencies});
  final AppDependencies dependencies;

  @override
  State<RequestsPanel> createState() => _RequestsPanelState();
}

class _RequestsPanelState extends State<RequestsPanel> {
  List<Packet> _requests = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final requests = await widget.dependencies.service.fetchPendingRequests();
      if (mounted) {
        setState(() {
          _requests = requests;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _answer(Packet ask) async {
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 560;
    final me = widget.dependencies.sessionController.session?.accountId ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(
          compact ? 16 : 26, compact ? 16 : 22, compact ? 16 : 26, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PanelHeader(
          icon: Icons.help_outline_rounded,
          title: 'Requests',
          subtitle: 'Questions people and agents are waiting on you for',
          onClose: () => Navigator.pop(context),
          actions: [
            IconButton(
                tooltip: 'Refresh',
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded)),
          ],
        ),
        const SizedBox(height: 14),
        Expanded(
          child: _loading
              ? const SkeletonList()
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant)))
                  : _requests.isEmpty
                      ? Center(
                          child: Text('No open requests.',
                              style: TextStyle(color: scheme.onSurfaceVariant)))
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 28),
                          itemCount: _requests.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (context, i) => _PacketCard(
                            packet: _requests[i],
                            incoming: _requests[i].toId == me,
                            needsAnswer: true,
                            onAnswer: () => _answer(_requests[i]),
                          ),
                        ),
        ),
      ]),
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
