import '../../../data/models/uploaded_file.dart';
import '../../../data/services/tradera_service.dart';
import '../domain/workflow.dart';

/// Workflow-specific transport stays inside this feature; the shared service
/// supplies the signed client and existing authorized file operations.
class WorkflowRepository {
  WorkflowRepository(this.service);
  final TraderaService service;
  final Map<String, ({String bot, String room, String space})> _questions = {};

  Future<UploadedFile> file(String id) => service.fetchFile(id);

  Future<List<WorkflowRun>> list(String spaceId, String roomId) async {
    final responses = await Future.wait([
      service.client.call('spaces', 'turn_list', body: {
        'space': spaceId,
        'room': roomId,
        'limit': 100,
      }),
      service.client
          .call('spaces', 'agent_questions', body: {'space': spaceId}),
    ]);
    final turns = (responses[0].body as Map?)?['turns'] as List? ?? const [];
    final questions =
        (responses[1].body as Map?)?['questions'] as List? ?? const [];
    _questions.clear();
    final rows = <Map<String, dynamic>>[
      for (final value in turns.whereType<Map<Object?, Object?>>())
        if (value['space_id'] == spaceId && value['room_id'] == roomId)
          _turnRow(Map<String, dynamic>.from(value)),
    ];
    for (final value in questions.whereType<Map<Object?, Object?>>()) {
      final question = Map<String, dynamic>.from(value);
      if (question['room_id'] != roomId) continue;
      final id = question['id']?.toString() ?? '';
      final bot = question['bot_id']?.toString() ?? '';
      if (id.isEmpty) continue;
      _questions[id] = (bot: bot, room: roomId, space: spaceId);
      rows.insert(0, {
        'id': id,
        'space_id': spaceId,
        'room_id': roomId,
        'owner_id': service.session?.accountId ?? '',
        'task': question['question']?.toString() ?? 'Agent question',
        'status': 'awaiting_input',
        'pending_question': question['question']?.toString() ?? '',
        'pending_question_id': id,
        'updated_at': question['asked_at'],
        'outcome': const <String, dynamic>{},
        'steps': const <dynamic>[],
      });
    }
    return rows.map(WorkflowRun.fromJson).toList(growable: false);
  }

  Map<String, dynamic> _turnRow(Map<String, dynamic> turn) => {
        ...turn,
        'owner_id': turn['owner_id'] ?? turn['actor_id'],
        'task': (turn['task']?.toString().isNotEmpty ?? false)
            ? turn['task']
            : (turn['prompt']?.toString().isNotEmpty ?? false)
                ? turn['prompt']
                : turn['submission'],
        'result': turn['result'] ?? '',
        'steps': turn['steps'] ?? const <dynamic>[],
        'outcome': turn['outcome'] ??
            {
              'finalized': turn['status'] == 'done',
              if ((turn['error']?.toString().isNotEmpty ?? false))
                'error': turn['error'],
            },
      };

  Future<void> cancel(String workflowId) async {
    await service.client
        .call('spaces', 'turn_cancel', body: {'turn': workflowId});
  }

  Future<void> resume(String workflowId,
      {String questionId = '', String answer = ''}) async {
    if (questionId.isNotEmpty) {
      final question = _questions[questionId];
      if (question == null) throw StateError('Question is no longer open');
      await service.client.call('spaces', 'agent_answer',
          body: {
            'space': question.space,
            'room': question.room,
            'bot': question.bot,
            'question_id': questionId,
            'answer': answer,
          },
          requestTimeout: const Duration(minutes: 10));
      return;
    }
    await service.client.call('spaces', 'turn_resume', body: {
      'turn': workflowId,
      'verdict': 'not_executed',
    });
  }

  Future<List<Map<String, dynamic>>> execution(
      String spaceId, String workflowId) async {
    final response = await service.client.call('spaces', 'turn_log',
        body: {'space': spaceId, 'turn': workflowId, 'limit': 200});
    final body = (response.body as Map<Object?, Object?>?) ?? const {};
    return (body['entries'] as List? ?? const [])
        .whereType<Map<Object?, Object?>>()
        .map((raw) {
      final event = Map<String, dynamic>.from(raw);
      return <String, dynamic>{
        ...event,
        'id': '${event['run_id'] ?? workflowId}:${event['at'] ?? ''}',
        'tool': event['bot_name'] ?? event['kind'] ?? 'Agent work',
        'result': event['text'] ?? event['error'] ?? '',
        'status': event['error'] == null ? 'completed' : 'failed',
      };
    }).toList(growable: false);
  }

  Future<void> reconcile(
      String workflowId, String eventId, String verdict, String result) async {
    if (verdict != 'not_executed') {
      throw StateError('Only work confirmed as not executed can be resumed');
    }
    await service.client.call('spaces', 'turn_resume', body: {
      'turn': workflowId,
      'verdict': verdict,
    });
  }
}
