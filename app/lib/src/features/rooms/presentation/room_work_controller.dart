import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/services/aseman_service.dart';
import '../domain/room_work.dart';

/// Follows the agent work of one room: what runs now and what waits, the
/// answers being written (a long poll while agents work), the questions the
/// agents wait on and the last run that did not finish. Stops, retries and
/// answers go through it too.
class RoomWorkController extends ChangeNotifier {
  RoomWorkController(this.service,
      {required this.spaceId,
      required this.roomId,
      this.busyEvery = const Duration(seconds: 2),
      this.idleEvery = const Duration(seconds: 6)});

  final AsemanService service;
  final String spaceId, roomId;
  final Duration busyEvery, idleEvery;

  List<WorkRun> live = const [];
  List<WorkRun> queued = const [];
  List<WorkEntry> history = const [];
  List<AgentQuestion> questions = const [];
  List<LiveActivity> activity = const [];

  /// The newest run of this room that failed or was interrupted, unless
  /// something ran after it or it was dismissed.
  WorkEntry? failure;
  WorkRun? interrupted;

  bool stopping = false;
  final Set<String> _dismissed = {};
  Timer? _timer;
  bool _started = false, _disposed = false, _fetching = false;
  bool _following = false;
  int _seq = 0;

  /// Agents are on it: something runs or waits to run.
  bool get busy => live.isNotEmpty || queued.isNotEmpty;

  /// Agents running now (not interrupted ones).
  List<WorkRun> get running => [
        for (final r in live)
          if (!r.blocked) r
      ];

  /// The answer an agent is writing right now, if any.
  LiveActivity? get drafting {
    for (final a in activity) {
      if (a.draft.trim().isNotEmpty) return a;
    }
    return null;
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    unawaited(refresh());
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_started) return;
    _timer = Timer(busy ? busyEvery : idleEvery, () => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (_disposed || _fetching) return;
    _fetching = true;
    try {
      final results = await Future.wait<Object>([
        service.roomWork(spaceId),
        service.agentQuestions(spaceId).catchError((_) => <AgentQuestion>[]),
      ]);
      if (_disposed) return;
      final work = results[0] as ({
        List<WorkRun> live,
        List<WorkRun> queued,
        List<WorkEntry> entries
      });
      live = [
        for (final r in work.live)
          if (r.roomId == roomId) r
      ];
      queued = [
        for (final r in work.queued)
          if (r.roomId == roomId) r
      ];
      history = [
        for (final e in work.entries)
          if (e.roomId == roomId) e
      ];
      questions = [
        for (final q in results[1] as List<AgentQuestion>)
          if (q.roomId == roomId) q
      ];
      _findFailure();
      if (busy && !_following) unawaited(_follow());
      if (!busy) activity = const [];
      notifyListeners();
    } catch (_) {
      // Best-effort: the chat still works without the work view.
    } finally {
      _fetching = false;
      _schedule();
    }
  }

  void _findFailure() {
    interrupted = null;
    for (final r in live) {
      if (r.blocked && !_dismissed.contains(r.runId)) interrupted = r;
    }
    failure = null;
    if (busy) return;
    // history is newest first: the room's last finished run decides.
    for (final e in history) {
      if (e.kind == 'accepted') continue;
      if (e.failed && !_dismissed.contains(e.runId)) failure = e;
      break;
    }
  }

  /// Long-polls what the agents write while they work.
  Future<void> _follow() async {
    _following = true;
    try {
      while (!_disposed && busy) {
        final next = await service.roomLive(spaceId, roomId, seq: _seq);
        if (_disposed) return;
        _seq = next.seq;
        final ended = activity.isNotEmpty && next.activity.isEmpty;
        activity = next.activity;
        notifyListeners();
        // An agent finished: fetch now so its reply lands before the draft
        // goes away.
        if (ended) await refresh();
      }
    } catch (_) {
      // The regular refresh starts following again.
    } finally {
      _following = false;
    }
  }

  /// Stops every run of this room, queued ones included. Returns the error
  /// of the first stop that failed, if any.
  Future<Object?> stopAll() async {
    if (stopping) return null;
    stopping = true;
    notifyListeners();
    Object? error;
    final turns = {
      for (final r in [...live, ...queued]) r.turnId
    };
    for (final id in turns) {
      try {
        await service.cancelTurn(id);
      } catch (e) {
        error ??= e;
      }
    }
    stopping = false;
    activity = const [];
    await refresh();
    return error;
  }

  /// Stops one run's turn.
  Future<void> stop(WorkRun run) async {
    await service.cancelTurn(run.turnId);
    await refresh();
  }

  /// Runs an interrupted turn again.
  Future<void> resume(WorkRun run) async {
    await service.resumeTurn(run.turnId);
    _dismissed.add(run.runId);
    await refresh();
  }

  void dismiss(String runId) {
    _dismissed.add(runId);
    _findFailure();
    notifyListeners();
  }

  Future<void> answer(AgentQuestion question, String answer) async {
    await service.answerAgent(spaceId, question, answer);
    questions = [
      for (final q in questions)
        if (q.id != question.id) q
    ];
    notifyListeners();
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
