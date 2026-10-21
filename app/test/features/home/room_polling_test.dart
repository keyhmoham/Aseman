import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tradera/src/app.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/features/rooms/domain/room_work.dart';

import '../../fake_tradera_service.dart';

typedef _Page = ({
  List<RoomMessage> messages,
  String working,
  String workingDetail
});

class _Service extends FakeTraderaService {
  Completer<_Page>? pending;
  int pendingCalls = 0;
  bool failSending = false;
  List<WorkEntry> entries = [];

  @override
  Future<({List<WorkRun> live, List<WorkRun> queued, List<WorkEntry> entries})>
      roomWork(String spaceId, {int limit = 40}) async =>
          (live: <WorkRun>[], queued: <WorkRun>[], entries: entries);

  @override
  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) {
    if (failSending)
      throw const ApiException('UNAVAILABLE', 'Test send failure');
    return super.sendRoomMessage(spaceId, roomId, body,
        mentions: mentions, attachments: attachments, replyTo: replyTo);
  }

  @override
  Future<_Page> fetchRoomMessages(String spaceId, String roomId,
      {int limit = 50, int offset = 0}) {
    if (pending != null && roomId == 'a1') {
      pendingCalls++;
      return pending!.future;
    }
    return super
        .fetchRoomMessages(spaceId, roomId, limit: limit, offset: offset);
  }
}

RoomMessage _message(String id, String room, String body) => RoomMessage(
      id: id,
      spaceId: FakeTraderaService.atlasId,
      roomId: room,
      senderId: '00000000000000010000000000000099',
      body: body,
      createdAt: DateTime.utc(2026),
    );

void main() {
  tearDown(() => TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .clearAllTestValues());
  Future<void> open(WidgetTester tester, _Service service) async {
    SharedPreferences.setMockInitialValues({
      'tradera.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}'
    });
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
        TraderaApp(dependencies: AppDependencies.withService(service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TRADERA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Atlas Capital').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
  }

  testWidgets('the room\'s Work button shows what its agents did',
      (tester) async {
    final service = _Service()
      ..entries = [
        WorkEntry(
            at: DateTime.now(),
            kind: 'done',
            runId: 't1:bot',
            turnId: 't1',
            roomId: 'a1',
            botId: 'bot',
            botName: 'SignalBot',
            prompt: 'Summarise the market',
            durationMs: 4000),
        WorkEntry(
            at: DateTime.now(),
            kind: 'done',
            runId: 't2:bot',
            turnId: 't2',
            roomId: 'a2',
            botId: 'bot',
            botName: 'OtherRoomBot'),
      ];
    await open(tester, service);
    await tester.tap(find.byTooltip('Work'));
    await tester.pumpAndSettle();
    expect(find.text('SignalBot'), findsOneWidget);
    expect(find.textContaining('Summarise the market'), findsOneWidget);
    expect(find.text('OtherRoomBot'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed send preserves the room composer draft', (tester) async {
    final service = _Service()..failSending = true;
    await open(tester, service);
    final composer = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == 'Message room…');
    await tester.enterText(composer, 'Keep my instruction');
    await tester.tap(find.widgetWithIcon(IconButton, Icons.send_rounded).last);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text,
        'Keep my instruction');
    expect(find.textContaining('Send failed:'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'same-size message page rotation updates the visible conversation',
      (tester) async {
    final service = _Service();
    service.roomMessages['${FakeTraderaService.atlasId}/a1'] = [
      _message('old', 'a1', 'Old delivery')
    ];
    await open(tester, service);
    expect(find.text('Old delivery'), findsOneWidget);
    service.roomMessages['${FakeTraderaService.atlasId}/a1'] = [
      _message('new', 'a1', 'Corrected delivery')
    ];
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Corrected delivery'), findsOneWidget);
    expect(find.text('Old delivery'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'late room response cannot replace a different room or its composer',
      (tester) async {
    final service = _Service();
    service.roomMessages['${FakeTraderaService.atlasId}/a2'] = [
      _message('macro', 'a2', 'Macro room content')
    ];
    await open(tester, service);
    final composer = find.byWidgetPredicate((widget) =>
        widget is TextField && widget.decoration?.hintText == 'Message room…');
    await tester.enterText(composer, 'Draft for general');
    final pending = Completer<_Page>();
    service.pending = pending;
    await tester.pump(const Duration(seconds: 4));
    expect(service.pendingCalls, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(service.pendingCalls, 1,
        reason: 'Do not overlap polls for one room');
    await tester.tap(find.text('Global Macro'));
    await tester.pumpAndSettle();
    expect(find.text('Macro room content'), findsOneWidget);
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    pending.complete((
      messages: [_message('late', 'a1', 'Late general response')],
      working: 'old-worker',
      workingDetail: 'Old task'
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Macro room content'), findsOneWidget);
    expect(find.text('Late general response'), findsNothing);
    expect(find.text('old-worker'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
