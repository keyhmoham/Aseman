import 'package:flutter/material.dart';

import '../../../../core/theme/app_shape.dart';
import '../../../../core/theme/theme_roles.dart';
import '../../../../data/models/space.dart';
import '../../../../data/services/aseman_service.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../../search_feed/presentation/rich_post_content.dart';

/// Opens a sheet of the current body and every earlier wording of [message].
Future<void> showMessageEditHistory(
  BuildContext context, {
  required AsemanService service,
  required RoomMessage message,
}) =>
    showAdaptivePanel<void>(
      context,
      _MessageEditHistorySheet(
        service: service,
        message: message,
      ),
      breakpoint: 720,
      maxWidth: 520,
      maxHeight: 720,
      heightFactor: .72,
    );

class _MessageEditHistorySheet extends StatefulWidget {
  const _MessageEditHistorySheet({
    required this.service,
    required this.message,
  });

  final AsemanService service;
  final RoomMessage message;

  @override
  State<_MessageEditHistorySheet> createState() =>
      _MessageEditHistorySheetState();
}

class _MessageEditHistorySheetState extends State<_MessageEditHistorySheet> {
  MessageEditHistory? _history;
  Object? _error;
  bool _loading = true;

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
      final history =
          await widget.service.fetchMessageEdits(widget.message.id);
      if (!mounted) return;
      setState(() {
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Edit history',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface)),
              const SizedBox(height: 4),
              Text('Earlier wording of this message, newest change first.',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              Expanded(child: _body(scheme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2.5)));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.history_toggle_off_rounded,
              size: 36, color: scheme.onSurfaceVariant),
          const SizedBox(height: 10),
          Text('Could not load edit history',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface)),
          const SizedBox(height: 6),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ]),
      );
    }
    final history = _history!;
    final headers = widget.service.authHeaders();
    return ListView(
      children: [
        _versionCard(
          scheme: scheme,
          label: 'Current',
          body: history.current.body.isEmpty
              ? widget.message.body
              : history.current.body,
          at: history.current.at.isAtSameMomentAs(
                  DateTime.fromMillisecondsSinceEpoch(0))
              ? (widget.message.editedAt ?? widget.message.createdAt)
              : history.current.at,
          current: true,
          headers: headers,
        ),
        for (var i = 0; i < history.previous.length; i++) ...[
          const SizedBox(height: 10),
          _versionCard(
            scheme: scheme,
            label: i == history.previous.length - 1 ? 'Original' : 'Earlier',
            body: history.previous[i].body,
            at: history.previous[i].at,
            current: false,
            headers: headers,
          ),
        ],
        if (history.previous.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 18),
            child: Text(
              'No earlier wording is kept for this message yet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }

  Widget _versionCard({
    required ColorScheme scheme,
    required String label,
    required String body,
    required DateTime at,
    required bool current,
    required Map<String, String> headers,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: current
            ? ThemeRoles.selectedFill(context)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(AppShape.innerOf(context)),
        border: Border.all(
          color: current
              ? scheme.primary.withValues(alpha: 0.28)
              : scheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: current
                      ? scheme.primary.withValues(alpha: 0.14)
                      : scheme.onSurface.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                    color: current ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const Spacer(),
              Text(_formatWhen(at),
                  style: TextStyle(
                      fontSize: 11, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 10),
          if (body.trim().isEmpty)
            Text('(empty)',
                style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: scheme.onSurfaceVariant))
          else
            DefaultTextStyle.merge(
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: scheme.onSurface,
              ),
              child: RichPostContent(body,
                  headers: headers,
                  resolveUrl: widget.service.resolveContentUrl),
            ),
        ],
      ),
    );
  }

  static String _formatWhen(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (sameDay) return time;
    return '${local.day}/${local.month}/${local.year} · $time';
  }
}
