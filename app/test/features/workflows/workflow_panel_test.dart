import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/session_store.dart';
import 'package:tradera/src/features/workflows/data/workflow_repository.dart';
import 'package:tradera/src/features/workflows/domain/workflow.dart';
import 'package:tradera/src/features/workflows/presentation/workflow_panel.dart';

import '../../fake_tradera_service.dart';
import 'workflow_test.dart' show runJson;

class _Repository extends WorkflowRepository {
  _Repository() : super(FakeTraderaService()) {
    service.client.session = const Session(
        accountId: 'owner',
        handle: 'me',
        token: 'test',
        privateKey: '',
        publicKey: '');
  }
  List<WorkflowRun> runs = [
    WorkflowRun.fromJson({
      ...runJson(status: 'partial'),
      'outcome': {'finalized': true}
    })
  ];
  String? submittedQuestion, submittedAnswer;
  @override
  Future<List<WorkflowRun>> list(String spaceId, String roomId) async => runs;
  @override
  Future<void> resume(String workflowId,
      {String questionId = '', String answer = ''}) async {
    submittedQuestion = questionId;
    submittedAnswer = answer;
    runs = [
      WorkflowRun.fromJson({...runJson(), 'steps': <dynamic>[]})
    ];
  }
}

void main() {
  tearDown(() => TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .clearAllTestValues());
  Future<void> pumpPanel(WidgetTester tester, _Repository repository,
      {double width = 390}) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WorkflowPanel(
                repository: repository,
                spaceId: 'space',
                roomId: 'room',
                roomName: 'General'))));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
      'partial task retains delivered files and inspection verdict on mobile',
      (tester) async {
    final repository = _Repository();
    await pumpPanel(tester, repository);
    expect(find.text('Partially completed'), findsOneWidget);
    expect(find.text('Delivered files (1)'), findsOneWidget);
    expect(find.text('Cancel task'), findsNothing);
    await tester.tap(find.text('Stages and verification'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Completed after inspection'), findsOneWidget);
    expect(find.textContaining('0 corrective retries'), findsOneWidget);
    expect(find.text('web-design'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'answer submits the pending question identity and polls into running',
      (tester) async {
    final repository = _Repository()
      ..runs = [
        WorkflowRun.fromJson({
          ...runJson(status: 'awaiting_input'),
          'steps': <dynamic>[],
          'outcome': <String, dynamic>{}
        })
      ];
    await pumpPanel(tester, repository, width: 900);
    expect(find.text('Needs your answer'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Developers');
    await tester.tap(find.text('Submit answer'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repository.submittedQuestion, 'q1');
    expect(repository.submittedAnswer, 'Developers');
    expect(find.text('Running'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new question clears a draft and unknown status stays explicit',
      (tester) async {
    final repository = _Repository()
      ..runs = [
        WorkflowRun.fromJson({
          ...runJson(status: 'awaiting_input'),
          'steps': <dynamic>[],
          'outcome': <String, dynamic>{}
        })
      ];
    await pumpPanel(tester, repository);
    await tester.enterText(find.byType(TextField), 'Old answer');
    repository.runs = [
      WorkflowRun.fromJson({
        ...runJson(status: 'awaiting_input', question: 'q2'),
        'steps': <dynamic>[],
        'outcome': <String, dynamic>{}
      })
    ];
    await tester.pump(const Duration(seconds: 4));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    repository.runs = [
      WorkflowRun.fromJson({
        ...runJson(status: 'new_status'),
        'steps': <dynamic>[],
        'outcome': <String, dynamic>{}
      })
    ];
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Unknown status (new_status)'), findsOneWidget);
    expect(find.text('Submit answer'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
