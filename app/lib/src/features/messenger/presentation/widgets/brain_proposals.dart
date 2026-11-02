import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../app_dependencies.dart';

/// Compact brain UX for the personal Aseman chat: pending proposal cards + thinking.
class BrainProposalsBar extends StatefulWidget {
  const BrainProposalsBar({
    super.key,
    required this.dependencies,
    this.enabled = true,
  });

  final AppDependencies dependencies;
  final bool enabled;

  @override
  State<BrainProposalsBar> createState() => _BrainProposalsBarState();
}

class _BrainProposalsBarState extends State<BrainProposalsBar> {
  Timer? _poll;
  bool _thinking = false;
  List<_Proposal> _pending = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      _poll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
      unawaited(_refresh());
    }
  }

  @override
  void didUpdateWidget(covariant BrainProposalsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _poll ??=
          Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
      unawaited(_refresh());
    }
    if (!widget.enabled && oldWidget.enabled) {
      _poll?.cancel();
      _poll = null;
      setState(() {
        _thinking = false;
        _pending = const [];
      });
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!widget.enabled) return;
    try {
      final res = await widget.dependencies.service.dmListSelf();
      if (!mounted) return;
      final working = res['agents_working'];
      final thinking = working is List && working.isNotEmpty;
      final messages = res['messages'];
      final pending = <_Proposal>[];
      if (messages is List) {
        for (final raw in messages) {
          if (raw is! Map) continue;
          final proposal = raw['proposal'];
          if (proposal is! Map) continue;
          if ('${proposal['status']}' != 'pending') continue;
          final steps = proposal['steps'];
          pending.add(_Proposal(
            id: '${raw['id'] ?? ''}',
            steps: steps is List
                ? [for (final s in steps) '$s']
                : const <String>[],
            body: '${raw['body'] ?? ''}',
          ));
        }
      }
      setState(() {
        _thinking = thinking;
        _pending = pending.where((p) => p.id.isNotEmpty).toList();
      });
    } catch (_) {}
  }

  Future<void> _confirm(_Proposal p, bool approve) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.dependencies.service
          .brainConfirm(p.id, approve: approve);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || (!_thinking && _pending.isEmpty)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_thinking)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Aseman is thinking…',
                    style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        for (final p in _pending)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Aseman proposes',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  if (p.body.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(p.body,
                        maxLines: 3, overflow: TextOverflow.ellipsis),
                  ],
                  if (p.steps.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final step in p.steps)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text('· $step',
                            style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant)),
                      ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _busy ? null : () => _confirm(p, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : () => _confirm(p, true),
                        child: const Text('Confirm'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Proposal {
  const _Proposal({
    required this.id,
    required this.steps,
    required this.body,
  });
  final String id;
  final List<String> steps;
  final String body;
}
