import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shape.dart';
import '../../domain/room_work.dart';
import '../room_work_controller.dart';

/// Above the composer: what the room's agents are doing, with Stop and the
/// details; the questions they wait on, answerable with a tap; and the last
/// run that did not finish, with Retry. Nothing when there is nothing to say.
class RoomWorkStrip extends StatelessWidget {
  const RoomWorkStrip(
      {super.key,
      required this.work,
      required this.onStop,
      required this.onAnswer,
      this.onRunAgain});

  final RoomWorkController work;
  final VoidCallback onStop;
  final void Function(AgentQuestion question, String answer) onAnswer;

  /// Sends a failed run's prompt to its agent again.
  final void Function(WorkEntry failed)? onRunAgain;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[
      for (final q in work.questions) _question(context, q),
      if (work.busy) _status(context),
      if (work.interrupted case final run?) _interrupted(context, run),
      if (work.failure case final failed?) _failed(context, failed),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final c in children)
          Padding(padding: const EdgeInsets.only(top: 4), child: c),
      ]),
    );
  }

  Widget _card(BuildContext context, {required Widget child, Color? tone}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: tone?.withValues(alpha: .10) ?? scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(AppShape.card),
      child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 6, 8), child: child),
    );
  }

  Widget _status(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = work.running;
    final names = {for (final r in running) r.botName}.toList();
    final waiting = work.queued.length;
    final detail = work.activity.isEmpty ? '' : work.activity.first.detail;
    final title = names.isEmpty
        ? 'Waiting to start'
        : names.length == 1
            ? '${names.first} is working'
            : '${names.take(2).join(' and ')}${names.length > 2 ? ' and others' : ''} are working';
    return _card(
      context,
      child: Row(children: [
        const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                if (detail.isNotEmpty || waiting > 0)
                  Text(
                      [
                        if (detail.isNotEmpty) detail,
                        if (waiting > 0)
                          waiting == 1
                              ? '1 more queued'
                              : '$waiting more queued',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
              ]),
        ),
        TextButton(
            onPressed: () => showRoomWorkSheet(context, work, onStop: onStop),
            child: const Text('Details')),
        FilledButton.tonalIcon(
            onPressed: work.stopping ? null : onStop,
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('Stop')),
      ]),
    );
  }

  Widget _question(BuildContext context, AgentQuestion q) {
    final scheme = Theme.of(context).colorScheme;
    final choices = q.options.isNotEmpty
        ? q.options
        : q.approval
            ? const ['Yes, go ahead', 'No, don’t do it']
            : const <String>[];
    return _card(
      context,
      tone: AppColors.warning,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(q.approval ? Icons.verified_user_outlined : Icons.help_outline,
              size: 16, color: AppColors.warning),
          const SizedBox(width: 6),
          Expanded(
              child: Text(
                  q.approval
                      ? '${q.agent} needs your go-ahead'
                      : '${q.agent} is asking you',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 4),
        Text(q.question, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final c in choices)
            ActionChip(
                visualDensity: VisualDensity.compact,
                label: Text(c, style: const TextStyle(fontSize: 12)),
                onPressed: () => onAnswer(q, c)),
          if (!q.approval)
            ActionChip(
                visualDensity: VisualDensity.compact,
                label: const Text('Use placeholders for now',
                    style: TextStyle(fontSize: 12)),
                onPressed: () => onAnswer(q,
                    'Use reasonable placeholders for now and carry on; I will fill them in later.')),
        ]),
        const SizedBox(height: 2),
        Text('Or type your answer below.',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _interrupted(BuildContext context, WorkRun run) => _card(
        context,
        tone: AppColors.warning,
        child: Row(children: [
          const Icon(Icons.pause_circle_outline,
              size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
              child: Text('${run.botName} was interrupted before finishing.',
                  style: const TextStyle(fontSize: 13))),
          TextButton(
              onPressed: () => work.dismiss(run.runId),
              child: const Text('Dismiss')),
          FilledButton.tonal(
              onPressed: () => work.resume(run), child: const Text('Retry')),
        ]),
      );

  Widget _failed(BuildContext context, WorkEntry e) {
    final scheme = Theme.of(context).colorScheme;
    return _card(
      context,
      tone: scheme.error,
      child: Row(children: [
        Icon(Icons.error_outline, size: 18, color: scheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${e.botName} couldn’t finish',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                if (e.error.isNotEmpty)
                  Text(e.error,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
              ]),
        ),
        TextButton(
            onPressed: () => work.dismiss(e.runId),
            child: const Text('Dismiss')),
        if (onRunAgain != null && e.prompt.trim().isNotEmpty)
          FilledButton.tonal(
              onPressed: () => onRunAgain!(e), child: const Text('Run again')),
      ]),
    );
  }
}

/// The room's work in full: each agent's run now (with its own Stop) and
/// what waits, then the history of finished runs.
Future<void> showRoomWorkSheet(BuildContext context, RoomWorkController work,
        {VoidCallback? onStop}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(
          heightFactor: .7, child: RoomWorkDetails(work: work, onStop: onStop)),
    );

class RoomWorkDetails extends StatelessWidget {
  const RoomWorkDetails({super.key, required this.work, this.onStop});
  final RoomWorkController work;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: ListenableBuilder(
          listenable: work,
          builder: (context, _) => Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
              child: Row(children: [
                const Expanded(
                    child: Text('Agent work',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800))),
                if (work.busy && onStop != null)
                  FilledButton.tonalIcon(
                      onPressed: work.stopping ? null : onStop,
                      icon: const Icon(Icons.stop_rounded, size: 18),
                      label: const Text('Stop all')),
              ]),
            ),
            const TabBar(tabs: [Tab(text: 'Live'), Tab(text: 'History')]),
            Expanded(
                child:
                    TabBarView(children: [_live(context), _history(context)])),
          ]),
        ),
      );

  Widget _empty(BuildContext context, String text) => Center(
      child: Text(text,
          style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant)));

  Widget _live(BuildContext context) {
    final rows = [...work.live, ...work.queued];
    if (rows.isEmpty) return _empty(context, 'No agent is working here now.');
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final r in rows)
        Card(
          child: ListTile(
            leading: Icon(
                r.blocked
                    ? Icons.pause_circle_outline
                    : r.status == 'queued'
                        ? Icons.schedule_rounded
                        : Icons.autorenew_rounded,
                color: r.blocked ? AppColors.warning : null),
            title: Text(r.botName,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
                [
                  switch (r.status) {
                    'queued' => 'Queued',
                    'blocked' => 'Interrupted',
                    _ => _activityFor(r) ?? 'Working',
                  },
                  if (r.startedAt != null)
                    formatWorkDuration(DateTime.now().difference(r.startedAt!)),
                  if (r.prompt.isNotEmpty) '“${_clip(r.prompt)}”',
                ].join(' · '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
            trailing: r.blocked
                ? TextButton(
                    onPressed: () => work.resume(r), child: const Text('Retry'))
                : TextButton(
                    onPressed: () => work.stop(r), child: const Text('Stop')),
          ),
        ),
    ]);
  }

  String? _activityFor(WorkRun r) {
    for (final a in work.activity) {
      if (a.agent == r.botName && a.detail.isNotEmpty) return a.detail;
    }
    return null;
  }

  Widget _history(BuildContext context) {
    final rows = [
      for (final e in work.history)
        if (e.kind != 'accepted') e
    ];
    if (rows.isEmpty) return _empty(context, 'Nothing has finished here yet.');
    final scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final e = rows[i];
        final (icon, color, label) = switch (e.kind) {
          'done' => (Icons.check_circle_outline, AppColors.success, 'Done'),
          'failed' => (Icons.error_outline, scheme.error, 'Failed'),
          'cancelled' => (
              Icons.stop_circle_outlined,
              scheme.onSurfaceVariant,
              'Stopped'
            ),
          _ => (Icons.circle_outlined, scheme.onSurfaceVariant, e.kind),
        };
        return ListTile(
          leading: Icon(icon, color: color),
          title: Text('${e.botName} · $label',
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(
              [
                if (e.durationMs > 0)
                  formatWorkDuration(Duration(milliseconds: e.durationMs)),
                _when(e.at),
                if (e.prompt.isNotEmpty) '“${_clip(e.prompt)}”',
                if (e.error.isNotEmpty) e.error,
              ].join(' · '),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        );
      },
    );
  }

  static String _clip(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > 90 ? '${t.substring(0, 90)}…' : t;
  }

  static String _when(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }
}

/// 4 s, 2 min 5 s, 1 h 3 min.
String formatWorkDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds.clamp(0, 59)} s';
  if (d.inMinutes < 60) {
    final s = d.inSeconds % 60;
    return s == 0 ? '${d.inMinutes} min' : '${d.inMinutes} min $s s';
  }
  return '${d.inHours} h ${d.inMinutes % 60} min';
}

/// The prompt commands that match what is being typed at the start of the
/// message (`/`, `/b`, …), to pick one with a tap.
class PromptCommandSuggestions extends StatelessWidget {
  const PromptCommandSuggestions(
      {super.key, required this.typed, required this.onPick});
  final String typed;
  final ValueChanged<PromptCommand> onPick;

  static bool matches(String text) => RegExp(r'^/[a-z]*$').hasMatch(text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = [
      for (final c in promptCommands)
        if (c.command.startsWith(typed)) c
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return Column(mainAxisSize: MainAxisSize.min, children: [
      for (final c in shown)
        ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Text(c.command,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  fontFamily: 'monospace')),
          title: Text(c.title,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(c.description, style: const TextStyle(fontSize: 11)),
          onTap: () => onPick(c),
        ),
    ]);
  }
}
