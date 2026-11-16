import 'package:flutter/material.dart';

import '../../../../agui/agui.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/overlay_panels.dart';
import '../../domain/room_work.dart';
import '../room_work_controller.dart';

/// Above the composer, only when the room's agents need the person: the
/// answers to the question an agent asked (AG-UI Question — same HITL widgets
/// as in-chat surfaces), or the run that did not finish, to run again.
class RoomWorkNeeds extends StatelessWidget {
  const RoomWorkNeeds(
      {super.key,
      required this.work,
      required this.onAnswer,
      required this.onRunAgain});

  final RoomWorkController work;
  final void Function(AgentQuestion question, String answer) onAnswer;
  final void Function(WorkEntry failed) onRunAgain;

  @override
  Widget build(BuildContext context) {
    final q = work.questions.isEmpty ? null : work.questions.first;
    final row = q != null
        ? _answers(context, q)
        : work.interrupted != null
            ? _notice(context,
                icon: Icons.pause_circle_outline,
                color: AppColors.warningOf(context),
                text: '${work.interrupted!.botName} was interrupted',
                action: 'Retry',
                onAction: () => work.resume(work.interrupted!),
                onDismiss: () => work.dismiss(work.interrupted!.runId))
            : work.failure != null
                ? _notice(context,
                    icon: Icons.error_outline,
                    color: Theme.of(context).colorScheme.error,
                    text: work.failure!.error.isEmpty
                        ? '${work.failure!.botName} couldn’t finish'
                        : '${work.failure!.botName} couldn’t finish: ${work.failure!.error}',
                    action: work.failure!.prompt.trim().isEmpty
                        ? null
                        : 'Run again',
                    onAction: () => onRunAgain(work.failure!),
                    onDismiss: () => work.dismiss(work.failure!.runId))
                : null;
    if (row == null) return const SizedBox.shrink();
    return Padding(padding: const EdgeInsets.only(bottom: 6), child: row);
  }

  Widget _answers(BuildContext context, AgentQuestion q) {
    final scheme = Theme.of(context).colorScheme;
    final options = [
      ...q.options,
      if (q.options.isEmpty && q.approval) ...['Yes, go ahead', 'No'],
    ];
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Icon(
                  q.approval
                      ? Icons.verified_user_outlined
                      : Icons.reply_rounded,
                  size: 16,
                  color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    q.approval
                        ? '${q.agent} needs your go-ahead'
                        : 'Answer ${q.agent}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
              ),
            ]),
            const SizedBox(height: 8),
            // The question itself is the agent's message in the thread, and
            // a typed answer goes through the composer: only its choices
            // are offered here.
            if (options.isNotEmpty)
              AgUiChoices(
                options: options,
                onSelect: (value) => onAnswer(q, value),
              ),
            if (!q.approval)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero),
                  onPressed: () => onAnswer(q,
                      'Use reasonable placeholders for now and carry on; I will fill them in later.'),
                  child: const Text('Use placeholders for now',
                      style: TextStyle(fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _notice(BuildContext context,
      {required IconData icon,
      required Color color,
      required String text,
      String? action,
      required VoidCallback onAction,
      required VoidCallback onDismiss}) {
    return Row(children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: 6),
      Expanded(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12))),
      if (action != null)
        TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: onAction,
            child: Text(action)),
      IconButton(
          tooltip: 'Dismiss',
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded)),
    ]);
  }
}

/// The room's work: what is running and waiting now, then what ran. What an
/// agent is doing is shown in the thread and Stop is the composer's; here a
/// waiting request can be dropped and a failed one run again.
Future<void> showRoomWork(BuildContext context, RoomWorkController work,
        {void Function(WorkEntry failed)? onRunAgain}) =>
    showFloatingPanel(
      context,
      RoomWorkPanel(work: work, onRunAgain: onRunAgain),
      maxWidth: 520,
      barrierLabel: 'Close work',
    );

class RoomWorkPanel extends StatelessWidget {
  const RoomWorkPanel({super.key, required this.work, this.onRunAgain});
  final RoomWorkController work;
  final void Function(WorkEntry failed)? onRunAgain;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: work,
        builder: (context, _) {
          final scheme = Theme.of(context).colorScheme;
          final now = [...work.live, ...work.queued];
          final done = [
            for (final e in work.history)
              if (e.kind != 'accepted') e
          ];
          Widget heading(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
              child: Text(text,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurfaceVariant)));
          return ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
              children: [
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('Work',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w800))),
                if (now.isEmpty && done.isEmpty)
                  Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                          child: Text('No agent has worked in this room yet.',
                              style:
                                  TextStyle(color: scheme.onSurfaceVariant)))),
                if (now.isNotEmpty) heading('NOW'),
                for (final r in now) _run(context, r),
                if (done.isNotEmpty) heading('EARLIER'),
                for (final e in done) _entry(context, e),
              ]);
        },
      );

  Widget _run(BuildContext context, WorkRun r) {
    final (icon, label) = switch (r.status) {
      'queued' => (Icons.schedule_rounded, 'Waiting'),
      'blocked' => (Icons.pause_circle_outline, 'Interrupted'),
      _ => (Icons.autorenew_rounded, 'Working'),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(icon, color: r.blocked ? AppColors.warningOf(context) : null),
      title:
          Text(r.botName, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
          [
            label,
            if (r.startedAt != null)
              formatWorkDuration(DateTime.now().difference(r.startedAt!)),
            if (r.prompt.isNotEmpty) _clip(r.prompt),
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      trailing: switch (r.status) {
        'queued' => TextButton(
            onPressed: () => work.stop(r), child: const Text('Remove')),
        'blocked' => TextButton(
            onPressed: () => work.resume(r), child: const Text('Retry')),
        _ => null,
      },
    );
  }

  Widget _entry(BuildContext context, WorkEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (e.kind) {
      'done' => (Icons.check_circle_outline, AppColors.successOf(context), 'Done'),
      'failed' => (Icons.error_outline, scheme.error, 'Failed'),
      'cancelled' => (
          Icons.stop_circle_outlined,
          scheme.onSurfaceVariant,
          'Stopped'
        ),
      _ => (Icons.circle_outlined, scheme.onSurfaceVariant, e.kind),
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(icon, color: color),
      title:
          Text(e.botName, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(
          [
            label,
            if (e.durationMs > 0)
              formatWorkDuration(Duration(milliseconds: e.durationMs)),
            _when(e.at),
            if (e.prompt.isNotEmpty) _clip(e.prompt),
            if (e.error.isNotEmpty) e.error,
          ].join(' · '),
          maxLines: 3,
          overflow: TextOverflow.ellipsis),
      trailing: e.failed && onRunAgain != null && e.prompt.trim().isNotEmpty
          ? TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onRunAgain!(e);
              },
              child: const Text('Run again'))
          : null,
    );
  }

  static String _clip(String s) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return '“${t.length > 90 ? '${t.substring(0, 90)}…' : t}”';
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
