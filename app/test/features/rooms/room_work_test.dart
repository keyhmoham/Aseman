import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/features/rooms/domain/room_work.dart';
import 'package:aseman/src/features/rooms/presentation/room_work_controller.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/room_chat.dart';

import '../../fake_aseman_service.dart';

WorkRun _run(String turn, String status,
        {String room = 'room-1', String bot = 'bot-a', String name = 'Ada'}) =>
    WorkRun(
        runId: '$turn:$bot',
        turnId: turn,
        roomId: room,
        botId: bot,
        botName: name,
        status: status,
        prompt: 'Draft the launch post');

/// A node whose room has whatever work, drafts and questions a test sets.
class _Node extends FakeAsemanService {
  List<WorkRun> live = [];
  List<WorkRun> queued = [];
  List<WorkEntry> entries = [];
  List<AgentQuestion> asked = [];
  List<LiveActivity> activity = [];
  final cancelled = <String>[];
  final resumed = <String>[];
  final answers = <String>[];

  @override
  Future<({List<WorkRun> live, List<WorkRun> queued, List<WorkEntry> entries})>
      roomWork(String spaceId, {int limit = 40}) async =>
          (live: live, queued: queued, entries: entries);

  @override
  Future<({int seq, List<LiveActivity> activity})> roomLive(
      String spaceId, String roomId,
      {int seq = 0}) async {
    // A long poll: hold a little, as the node does.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (seq: seq + 1, activity: activity);
  }

  @override
  Future<List<AgentQuestion>> agentQuestions(String spaceId) async => asked;

  @override
  Future<void> cancelTurn(String turnId) async {
    cancelled.add(turnId);
    live = [];
    queued = [];
    activity = [];
  }

  @override
  Future<void> resumeTurn(String turnId) async => resumed.add(turnId);

  @override
  Future<void> answerAgent(
      String spaceId, AgentQuestion question, String answer) async {
    answers.add('${question.id}:$answer');
    asked = [];
  }
}

Future<List<String>> _pumpChat(WidgetTester tester, _Node node) async {
  final sent = <String>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RoomChat(
        room: 'Launch',
        messages: const [],
        dependencies: AppDependencies.withService(node),
        spaceId: 'space-1',
        roomId: 'room-1',
        onSend: (body, mentions, attachments, {replyTo = ''}) async =>
            sent.add('$body|${mentions.join(',')}'),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return sent;
}

/// Disposes the chat so its polling stops before the test ends.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('agent work shows once in the thread, with one Stop',
      (tester) async {
    final node = _Node()
      ..live = [_run('t1', 'running')]
      ..queued = [_run('t2', 'queued', name: 'Bo', bot: 'bot-b')]
      ..activity = const [LiveActivity(agent: 'Ada', detail: 'searching')];
    await _pumpChat(tester, node);
    await tester.pump(const Duration(milliseconds: 100));

    // What the agent does is said once, below the messages, with the queue.
    expect(find.text('searching'), findsOneWidget);
    expect(find.text('+1 waiting'), findsOneWidget);
    expect(find.textContaining('is working'), findsNothing);
    // One Stop: the composer's.
    expect(find.byTooltip('Stop the work in progress'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

    // Typing turns it back into Send.
    await tester.enterText(find.byType(TextField), 'also add a picture');
    await tester.pump();
    expect(find.byTooltip('Stop the work in progress'), findsNothing);
    expect(find.byTooltip('Send'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    await tester.tap(find.byTooltip('Stop the work in progress'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.cancelled, unorderedEquals(['t1', 't2']));
    expect(find.text('searching'), findsNothing);
    expect(find.byTooltip('Send'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('the answer shows as the agent writes it', (tester) async {
    final node = _Node()
      ..live = [_run('t1', 'running')]
      ..activity = const [
        LiveActivity(agent: 'Ada', draft: 'Here is a first take on the post')
      ];
    await _pumpChat(tester, node);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Here is a first take on the post'), findsOneWidget);
    expect(find.text('writing'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('an agent\'s question is answered with a tap, not repeated',
      (tester) async {
    final node = _Node()
      ..asked = const [
        AgentQuestion(
            id: 'q1',
            botId: 'bot-a',
            agent: 'Ada',
            roomId: 'room-1',
            question: 'Which audience?',
            options: ['Builders', 'Traders']),
        // Another room's question stays there.
        AgentQuestion(
            id: 'q2',
            botId: 'bot-a',
            agent: 'Ada',
            roomId: 'room-2',
            question: 'Elsewhere?',
            options: ['Somewhere']),
      ];
    await _pumpChat(tester, node);
    expect(find.text('Answer Ada'), findsOneWidget);
    // The question is the agent's message in the thread, not shown again.
    expect(find.text('Which audience?'), findsNothing);
    expect(find.text('Somewhere'), findsNothing);
    expect(find.widgetWithText(TextField, 'Answer Ada…'), findsOneWidget);
    await tester.tap(find.text('Traders'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.answers, ['q1:Traders']);
    expect(find.text('Answer Ada'), findsNothing);
    await _close(tester);
  });

  testWidgets('an approval offers go-ahead and refusal', (tester) async {
    final node = _Node()
      ..asked = const [
        AgentQuestion(
            id: 'q1',
            botId: 'bot-a',
            agent: 'Ada',
            roomId: 'room-1',
            question: 'Send the email to 40 people?',
            kind: 'approval'),
      ];
    await _pumpChat(tester, node);
    expect(find.text('Ada needs your go-ahead'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    await tester.tap(find.text('Yes, go ahead'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.answers, ['q1:Yes, go ahead']);
    await _close(tester);
  });

  testWidgets('a failed run can be sent to its agent again', (tester) async {
    final node = _Node()
      ..entries = [
        WorkEntry(
            at: DateTime.now(),
            kind: 'failed',
            runId: 't1:bot-a',
            turnId: 't1',
            roomId: 'room-1',
            botId: 'bot-a',
            botName: 'Ada',
            error: 'the model provider timed out',
            prompt: 'Draft the launch post'),
      ];
    final sent = await _pumpChat(tester, node);
    expect(find.text('Ada couldn’t finish: the model provider timed out'),
        findsOneWidget);
    await tester.tap(find.text('Run again'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(sent, ['Draft the launch post|bot-a']);
    expect(find.textContaining('couldn’t finish'), findsNothing);
    await _close(tester);
  });

  testWidgets('interrupted work is retried as it was', (tester) async {
    final node = _Node()..live = [_run('t1', 'blocked')];
    await _pumpChat(tester, node);
    expect(find.text('Ada was interrupted'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.resumed, ['t1']);
    await _close(tester);
  });

  testWidgets('Work lists what runs, what waits and what ran', (tester) async {
    final node = _Node()
      ..live = [_run('t1', 'running')]
      ..queued = [_run('t2', 'queued', name: 'Bo', bot: 'bot-b')]
      ..entries = [
        WorkEntry(
            at: DateTime.now(),
            kind: 'done',
            runId: 't0:bot-a',
            turnId: 't0',
            roomId: 'room-1',
            botId: 'bot-a',
            botName: 'Cy',
            prompt: 'Find three competitors',
            durationMs: 65000),
      ];
    await _pumpChat(tester, node);
    await tester.tap(find.byTooltip('Work'));
    // The working dots keep animating: pump through the sheet's opening.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);
    expect(find.textContaining('1 min 5 s'), findsOneWidget);
    // Running work is stopped from the composer; a waiting request is
    // dropped here.
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.text('Remove'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(node.cancelled, ['t2']);
    await _close(tester);
  });

  testWidgets('a leading slash offers the prompt commands', (tester) async {
    await _pumpChat(tester, _Node());
    await tester.enterText(find.byType(TextField), '/');
    await tester.pump();
    expect(find.text('/btw'), findsOneWidget);
    expect(find.text('/ask'), findsOneWidget);
    expect(find.text('/fresh'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '/f');
    await tester.pump();
    expect(find.text('/btw'), findsNothing);
    await tester.tap(find.text('Fresh start'));
    await tester.pump();
    expect(find.widgetWithText(TextField, '/fresh '), findsOneWidget);
    expect(find.text('Fresh start'), findsNothing);
    await _close(tester);
  });

  test('the controller keeps only its room\'s work', () async {
    final node = _Node()
      ..live = [_run('t1', 'running'), _run('t9', 'running', room: 'room-2')]
      ..queued = [_run('t3', 'queued', room: 'room-2')];
    final work = RoomWorkController(node, spaceId: 'space-1', roomId: 'room-1');
    await work.refresh();
    expect(work.live.map((r) => r.turnId), ['t1']);
    expect(work.queued, isEmpty);
    await work.stopAll();
    expect(node.cancelled, ['t1']);
    work.dispose();
  });
}
