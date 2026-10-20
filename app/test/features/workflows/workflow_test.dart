import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/services/tradera_service.dart';
import 'package:tradera/src/features/workflows/data/workflow_repository.dart';
import 'package:tradera/src/features/workflows/domain/workflow.dart';
import 'package:tradera/src/features/workflows/presentation/workflow_view_model.dart';

Map<String, dynamic> runJson(
        {String status = 'running',
        String id = 'run',
        String room = 'room',
        String owner = 'owner',
        String question = 'q1'}) =>
    {
      'id': id,
      'space_id': 'space',
      'room_id': room,
      'owner_id': owner,
      'task': 'Build a website',
      'status': status,
      'pending_question_id': question,
      'pending_question': 'Which audience?',
      'outcome': {
        'tokens_in': 100,
        'tokens_out': 20,
        'artifacts': ['file'],
        'finalized': true
      },
      'steps': [
        {
          'index': 0,
          'name': 'Delivery',
          'status': 'done',
          'dispatch_code': 'BUDGET_EXHAUSTED',
          'budget_continuations': 2,
          'retries': 0,
          'attempt': 3,
          'depends_on': [1],
          'skill_names': ['web-design'],
          'verification_status': 'failed',
          'verification_feedback': 'Artifact bytes inspected.',
          'artifacts': [
            {
              'id': 'file',
              'name': 'index.html',
              'mime': 'text/html',
              'size': 123
            }
          ]
        }
      ],
    };

class WorkflowClient extends TraderaApiClient {
  WorkflowClient() : super(baseUrl: 'http://localhost:8080');
  final calls =
      <({String action, Map<String, dynamic> body, Duration? timeout})>[];
  List<Map<String, dynamic>> rows = [runJson()];
  List<Map<String, dynamic>> questions = const [];
  Completer<ApiResponse>? listPending, resumePending;
  bool failList = false, failCancel = false;
  @override
  Future<ApiResponse> call(String namespace, String action,
      {Map<String, dynamic> body = const {}, Duration? requestTimeout}) async {
    expect(namespace, 'spaces');
    calls.add((action: action, body: body, timeout: requestTimeout));
    if (action == 'turn_list') {
      if (failList)
        throw const ApiException('UNAVAILABLE', 'Plugin unavailable');
      if (listPending != null) return listPending!.future;
      return ApiResponse(200, {'turns': rows});
    }
    if (action == 'agent_questions') {
      return ApiResponse(200, {'questions': questions});
    }
    if (action == 'turn_cancel' && failCancel)
      throw const ApiException('TIMEOUT', 'Unknown request outcome');
    if ((action == 'agent_answer' || action == 'turn_resume') &&
        resumePending != null) return resumePending!.future;
    if (action == 'turn_log')
      return const ApiResponse(200, {
        'entries': [
          {
            'at': '2026-01-01T00:00:00Z',
            'run_id': 'run:bot',
            'bot_name': 'Builder',
            'kind': 'tool_result',
            'text': 'File sent'
          }
        ],
      });
    return const ApiResponse(200, {'ok': true});
  }
}

void main() {
  test(
      'parses the completed live backend evaluation without losing delivery or verdicts',
      () {
    final json = jsonDecode(
        File('test/features/workflows/fixtures/website_completed.json')
            .readAsStringSync()) as Map<String, dynamic>;
    final run = WorkflowRun.fromJson(json);
    expect(run.status, WorkflowStatus.done);
    expect(run.completedSteps, 4);
    expect(run.outcome.totalTokens, 188676);
    expect(run.artifactIds, hasLength(2));
    expect(run.steps.first.statusLabel, 'Completed after inspection');
    expect(run.steps[2].artifacts.first.name, 'index.html');
    expect(run.steps[2].artifacts.first.size, 39748);
  });

  test(
      'completion uses persisted verdict and resource continuations remain separate',
      () {
    final run = WorkflowRun.fromJson(runJson(status: 'partial'));
    expect(run.status, WorkflowStatus.partial);
    expect(run.status.canCancel, false);
    expect(run.artifactIds, ['file']);
    expect(run.steps.single.statusLabel, 'Completed after inspection');
    expect(run.steps.single.continuations, 2);
    expect(run.steps.single.retries, 0);
    expect(run.steps.single.skills, ['web-design']);
    expect(run.outcome.totalTokens, 120);
  });

  test('unknown and older payloads never imply success', () {
    final run = WorkflowRun.fromJson({
      'id': 'old',
      'status': 'future_state',
      'steps': null,
      'outcome': null
    });
    expect(run.status, WorkflowStatus.unknown);
    expect(run.statusLabel, contains('future_state'));
    expect(run.completedSteps, 0);
    expect(run.canResume, false);
    expect(run.canAnswer, false);
    expect(run.outcome.finalized, false);
    expect(run.artifactIds, isEmpty);
    for (final status in [
      'done',
      'failed',
      'partial',
      'budget_exhausted',
      'cancelled'
    ]) {
      expect(WorkflowRun.fromJson(runJson(status: status)).status.canCancel,
          false);
    }
    expect(
        WorkflowRun.fromJson(runJson(status: 'awaiting_input', question: ''))
            .canAnswer,
        false);
  });

  test('repository scopes runs to the exact room and uses correlated resume',
      () async {
    final client = WorkflowClient()
      ..rows = [
        runJson(),
        runJson(room: 'another'),
        {...runJson(), 'space_id': 'another'}
      ]
      ..questions = [
        {
          'id': 'q-current',
          'space_id': 'space',
          'room_id': 'room',
          'bot_id': 'bot',
          'question': 'Which audience?',
          'asked_at': '2026-01-01T00:00:00Z'
        }
      ];
    final repository = WorkflowRepository(TraderaService(client));
    expect(await repository.list('space', 'room'), hasLength(2));
    await repository.resume('run', questionId: 'q-current', answer: 'Builders');
    expect(client.calls.last.body, {
      'space': 'space',
      'room': 'room',
      'bot': 'bot',
      'question_id': 'q-current',
      'answer': 'Builders'
    });
    expect(client.calls.last.timeout, const Duration(minutes: 10));
    expect((await repository.execution('space', 'run')).single['result'],
        'File sent');
    expect(client.calls.last.body,
        {'space': 'space', 'turn': 'run', 'limit': 200});
    await repository.reconcile(
        'run', 'event', 'not_executed', 'No attachment exists');
    expect(client.calls.last.body, {
      'turn': 'run',
      'verdict': 'not_executed',
    });
  });

  test(
      'refresh serializes polls, retains prior state on failure, ignores disposed replies',
      () async {
    final client = WorkflowClient();
    final model = WorkflowViewModel(WorkflowRepository(TraderaService(client)),
        spaceId: 'space', roomId: 'room');
    await model.refresh();
    client.failList = true;
    await model.refresh();
    expect(model.runs, hasLength(1));
    expect(model.loadError, contains('Plugin unavailable'));
    client.failList = false;
    client.listPending = Completer<ApiResponse>();
    final pending = model.refresh();
    final count = client.calls.length;
    await model.refresh();
    expect(client.calls.length, count);
    var notifications = 0;
    model.addListener(() => notifications++);
    model.dispose();
    client.listPending!
        .complete(const ApiResponse(200, {'turns': <dynamic>[]}));
    await pending;
    expect(notifications, 0);
  });

  test(
      'resume prevents duplicate answers while allowing a separate cancellation',
      () async {
    final client = WorkflowClient()
      ..questions = [
        {
          'id': 'q1',
          'space_id': 'space',
          'room_id': 'room',
          'bot_id': 'bot',
          'question': 'Which audience?',
          'asked_at': '2026-01-01T00:00:00Z'
        }
      ];
    final repository = WorkflowRepository(TraderaService(client));
    await repository.list('space', 'room');
    client.resumePending = Completer<ApiResponse>();
    final model =
        WorkflowViewModel(repository, spaceId: 'space', roomId: 'room');
    final awaiting = WorkflowRun.fromJson(runJson(status: 'awaiting_input'));
    expect(await model.resume(awaiting, answer: '  '), false);
    final pending = model.resume(awaiting, answer: 'Builders');
    expect(model.busy('run', 'resume'), true);
    expect(await model.resume(awaiting, answer: 'Duplicated'), false);
    expect(await model.cancel(WorkflowRun.fromJson(runJson())), true);
    expect(client.calls.where((call) => call.action == 'agent_answer'),
        hasLength(1));
    client.resumePending!.complete(const ApiResponse(200, {'ok': true}));
    expect(await pending, true);
    model.dispose();
  });

  test('uncertain mutation outcomes are not automatically retried', () async {
    final client = WorkflowClient()..failCancel = true;
    final model = WorkflowViewModel(WorkflowRepository(TraderaService(client)),
        spaceId: 'space', roomId: 'room');
    expect(await model.cancel(WorkflowRun.fromJson(runJson())), false);
    expect(model.actionError, contains('Refresh task status'));
    expect(client.calls.where((call) => call.action == 'turn_cancel'),
        hasLength(1));
    expect(model.runs, hasLength(1));
    model.dispose();
  });
}
