import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/uploaded_file.dart';
import '../data/workflow_repository.dart';
import '../domain/workflow.dart';

class WorkflowViewModel extends ChangeNotifier {
  WorkflowViewModel(this.repository,
      {required this.spaceId, required this.roomId});
  final WorkflowRepository repository;
  final String spaceId, roomId;
  List<WorkflowRun> runs = const [];
  bool loading = true;
  String? loadError, actionError;
  final Set<String> _commands = {};
  final Map<String, Future<UploadedFile>> _files = {};
  Timer? _timer;
  bool _fetching = false, _disposed = false;

  void setPollingEnabled(bool enabled) {
    _timer?.cancel();
    _timer = null;
    if (!enabled || _disposed) return;
    unawaited(refresh());
    _timer =
        Timer.periodic(const Duration(seconds: 4), (_) => unawaited(refresh()));
  }

  Future<void> refresh() async {
    if (_fetching || _disposed) return;
    _fetching = true;
    try {
      final result = await repository.list(spaceId, roomId);
      if (_disposed) return;
      runs = List.unmodifiable(result);
      loadError = null;
    } catch (error) {
      if (_disposed) return;
      loadError = error.toString();
    } finally {
      _fetching = false;
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  bool busy(String id, String command) => _commands.contains('$id:$command');

  Future<UploadedFile> file(String id, {bool retry = false}) {
    if (retry) _files.remove(id);
    return _files.putIfAbsent(id, () => repository.file(id));
  }

  Future<List<Map<String, dynamic>>> execution(String id) =>
      repository.execution(id);

  Future<bool> cancel(WorkflowRun run) =>
      _command(run.id, 'cancel', () => repository.cancel(run.id));

  Future<bool> resume(WorkflowRun run, {String answer = ''}) async {
    if (!run.canResume && !run.canAnswer) return false;
    if (run.canAnswer && answer.trim().isEmpty) return false;
    return _command(
        run.id,
        'resume',
        () => repository.resume(run.id,
            questionId: run.canAnswer ? run.questionId : '',
            answer: answer.trim()));
  }

  Future<bool> reconcile(
          WorkflowRun run, String event, String verdict, String result) =>
      _command(run.id, 'reconcile',
          () => repository.reconcile(run.id, event, verdict, result));

  Future<bool> _command(
      String id, String name, Future<void> Function() action) async {
    final key = '$id:$name';
    if (_disposed || !_commands.add(key)) return false;
    actionError = null;
    notifyListeners();
    var completed = false;
    try {
      await action();
      completed = true;
    } catch (error) {
      if (!_disposed)
        actionError = '$error\nRefresh task status before trying again.';
    } finally {
      _commands.remove(key);
      if (!_disposed) {
        notifyListeners();
        await refresh();
      }
    }
    return completed;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
