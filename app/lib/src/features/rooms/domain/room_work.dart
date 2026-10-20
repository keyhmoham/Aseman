/// The agent work of a room, as the node reports it: runs (one per agent a
/// turn was addressed to), what the agents are writing right now and the
/// questions they are waiting on.
library;

DateTime? _time(Object? v) =>
    v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// One agent's part of a turn (`spaces.turn_log` live / queued rows).
class WorkRun {
  const WorkRun({
    required this.runId,
    required this.turnId,
    required this.roomId,
    required this.botId,
    required this.botName,
    required this.status,
    this.prompt = '',
    this.startedAt,
    this.createdAt,
  });

  factory WorkRun.fromJson(Map<String, dynamic> j) => WorkRun(
        runId: '${j['run_id'] ?? ''}',
        turnId: '${j['turn_id'] ?? ''}',
        roomId: '${j['room_id'] ?? ''}',
        botId: '${j['bot_id'] ?? ''}',
        botName: '${j['bot_name'] ?? j['bot_id'] ?? 'Agent'}',
        status: '${j['status'] ?? ''}',
        prompt: '${j['prompt'] ?? ''}',
        startedAt: _time(j['started_at']),
        createdAt: _time(j['created_at']),
      );

  final String runId, turnId, roomId, botId, botName, status, prompt;
  final DateTime? startedAt, createdAt;

  /// Interrupted (its node stopped or lost it): it can be run again as is.
  bool get blocked => status == 'blocked';
}

/// A line of a room's work history (`spaces.turn_log` entries).
class WorkEntry {
  const WorkEntry({
    required this.at,
    required this.kind,
    required this.runId,
    required this.turnId,
    required this.roomId,
    required this.botId,
    required this.botName,
    this.error = '',
    this.prompt = '',
    this.durationMs = 0,
  });

  factory WorkEntry.fromJson(Map<String, dynamic> j) => WorkEntry(
        at: _time(j['at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        kind: '${j['kind'] ?? ''}',
        runId: '${j['run_id'] ?? ''}',
        turnId: '${j['turn_id'] ?? ''}',
        roomId: '${j['room_id'] ?? ''}',
        botId: '${j['bot_id'] ?? ''}',
        botName: '${j['bot_name'] ?? j['bot_id'] ?? 'Agent'}',
        error: '${j['error'] ?? ''}',
        prompt: '${j['prompt'] ?? ''}',
        durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
      );

  final DateTime at;

  /// accepted, done, failed or cancelled.
  final String kind;
  final String runId, turnId, roomId, botId, botName, error, prompt;
  final int durationMs;

  bool get failed => kind == 'failed';
}

/// What an agent is doing in a room right now, and the answer it is writing.
class LiveActivity {
  const LiveActivity({required this.agent, this.detail = '', this.draft = ''});

  factory LiveActivity.fromJson(Map<String, dynamic> j) => LiveActivity(
        agent: '${j['agent'] ?? ''}',
        detail: '${j['detail'] ?? ''}',
        draft: '${j['draft'] ?? ''}',
      );

  final String agent, detail, draft;
}

/// A question an agent is blocked on until someone answers it: asked with
/// ask_user, or a step waiting for a person's go-ahead (`kind: approval`).
class AgentQuestion {
  const AgentQuestion({
    required this.id,
    required this.botId,
    required this.agent,
    required this.roomId,
    required this.question,
    this.options = const [],
    this.kind = 'question',
  });

  factory AgentQuestion.fromJson(Map<String, dynamic> j) => AgentQuestion(
        id: '${j['id'] ?? ''}',
        botId: '${j['bot_id'] ?? ''}',
        agent: '${j['agent'] ?? 'Agent'}',
        roomId: '${j['room_id'] ?? ''}',
        question: '${j['question'] ?? ''}',
        options: [for (final o in (j['options'] as List? ?? const [])) '$o'],
        kind: '${j['kind'] ?? 'question'}',
      );

  final String id, botId, agent, roomId, question, kind;
  final List<String> options;

  bool get approval => kind == 'approval';
}

/// How a prompt runs, picked with a leading command the node reads.
class PromptCommand {
  const PromptCommand(this.command, this.title, this.description);
  final String command, title, description;
}

const promptCommands = [
  PromptCommand('/btw', 'By the way',
      'A quick side question: no computer, and the room’s memory is left out.'),
  PromptCommand('/ask', 'Just ask',
      'Answer from what it knows: no computer, memory kept.'),
  PromptCommand('/fresh', 'Fresh start',
      'Work without the room’s memory of earlier conversations.'),
];
