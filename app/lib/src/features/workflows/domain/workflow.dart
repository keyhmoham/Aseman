import '../../../data/models/uploaded_file.dart';

enum WorkflowStatus {
  queued,
  planned,
  running,
  done,
  failed,
  partial,
  blocked,
  budgetExhausted,
  cancelled,
  awaitingInput,
  unknown;

  static WorkflowStatus parse(String value) => switch (value) {
        'budget_exhausted' => budgetExhausted,
        'awaiting_input' => awaitingInput,
        _ => values.firstWhere((status) => status.name == value,
            orElse: () => unknown),
      };

  String get label => switch (this) {
        queued => 'Queued',
        planned => 'Planned',
        running => 'Running',
        done => 'Completed',
        failed => 'Failed',
        partial => 'Partially completed',
        blocked => 'Interrupted',
        budgetExhausted => 'Budget exhausted',
        cancelled => 'Cancelled',
        awaitingInput => 'Needs your answer',
        unknown => 'Unknown status',
      };

  bool get isExecuting => this == queued || this == planned || this == running;
  bool get canCancel => isExecuting || this == awaitingInput || this == blocked;
}

/// Only public API fields needed by the client. Runtime prompts, private
/// checkpoints and capabilities remain owned by the workflow plugin.
class WorkflowRun {
  WorkflowRun.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String? ?? json['workflow_id'] as String? ?? '',
        spaceId = json['space_id'] as String? ?? '',
        roomId = json['room_id'] as String? ?? '',
        ownerId = json['owner_id'] as String? ?? '',
        task = json['task'] as String? ?? '',
        rawStatus = json['status'] as String? ?? '',
        result = json['result'] as String? ?? '',
        question = json['pending_question'] as String? ?? '',
        questionId = json['pending_question_id'] as String? ?? '',
        steps =
            List.unmodifiable(_maps(json['steps']).map(WorkflowStep.fromJson)),
        outcome = WorkflowOutcome.fromJson(_map(json['outcome'])),
        updatedAt = DateTime.tryParse(json['updated_at'] as String? ?? '');

  final String id, spaceId, roomId, ownerId, task, rawStatus, result;
  final String question, questionId;
  final List<WorkflowStep> steps;
  final WorkflowOutcome outcome;
  final DateTime? updatedAt;

  WorkflowStatus get status => WorkflowStatus.parse(rawStatus);
  String get statusLabel => status == WorkflowStatus.unknown
      ? 'Unknown status ($rawStatus)'
      : status.label;
  int get completedSteps => steps.where((step) => step.status == 'done').length;
  bool get canAnswer =>
      status == WorkflowStatus.awaitingInput && questionId.isNotEmpty;
  bool get canResume => status == WorkflowStatus.blocked;

  List<String> get artifactIds => List.unmodifiable({
        ...outcome.artifacts,
        for (final step in steps) ...step.artifacts.map((file) => file.id),
      }.where((id) => id.isNotEmpty));
}

class WorkflowOutcome {
  WorkflowOutcome.fromJson(Map<String, dynamic> json)
      : finalized = json['finalized'] == true,
        errorCode = json['error_code'] as String? ?? '',
        error = json['error'] as String? ?? '',
        tokensIn = _integer(json['tokens_in']),
        tokensOut = _integer(json['tokens_out']),
        artifacts = List.unmodifiable(_strings(json['artifacts']));

  final bool finalized;
  final String errorCode, error;
  final int tokensIn, tokensOut;
  final List<String> artifacts;
  int get totalTokens => tokensIn + tokensOut;
}

class WorkflowStep {
  WorkflowStep.fromJson(Map<String, dynamic> json)
      : index = _integer(json['index']),
        name = json['name'] as String? ?? '',
        status = json['status'] as String? ?? 'pending',
        scope = json['scope'] as String? ?? '',
        attempt = _integer(json['attempt']),
        retries = _integer(json['retries']),
        continuations = _integer(json['budget_continuations']),
        tokensIn = _integer(json['tokens_in']),
        tokensOut = _integer(json['tokens_out']),
        dispatchCode = json['dispatch_code'] as String? ?? '',
        verificationStatus = json['verification_status'] as String? ?? '',
        verificationFeedback = json['verification_feedback'] as String? ?? '',
        acceptance = List.unmodifiable(_strings(json['acceptance'])),
        skills = List.unmodifiable(_strings(json['skill_names'])),
        dependencies = List.unmodifiable(
            (json['depends_on'] as List? ?? const [])
                .whereType<num>()
                .map((number) => number.toInt())),
        artifacts = List.unmodifiable(
            _maps(json['artifacts']).map(UploadedFile.fromJson));

  final int index, attempt, retries, continuations, tokensIn, tokensOut;
  final String name, status, scope, dispatchCode;
  final String verificationStatus, verificationFeedback;
  final List<String> acceptance, skills;
  final List<int> dependencies;
  final List<UploadedFile> artifacts;

  // Inspection may accept completed work even when the worker stopped before
  // narrating it. The persisted step status is the authoritative verdict.
  bool get completedAfterStop => status == 'done' && dispatchCode.isNotEmpty;
  String get statusLabel => switch (status) {
        'done' =>
          completedAfterStop ? 'Completed after inspection' : 'Completed',
        'running' => 'Running',
        'failed' => 'Failed',
        'pending' => 'Pending',
        _ => 'Unknown status ($status)',
      };
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map<String, dynamic> ? value : const {};
Iterable<Map<String, dynamic>> _maps(dynamic value) =>
    (value is List ? value : const <dynamic>[])
        .whereType<Map<String, dynamic>>();
Iterable<String> _strings(dynamic value) =>
    (value is List ? value : const <dynamic>[]).whereType<String>();
int _integer(dynamic value) => value is num ? value.toInt() : 0;
