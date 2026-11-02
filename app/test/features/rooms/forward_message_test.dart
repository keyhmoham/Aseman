import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/data/models/uploaded_file.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/forward_message_sheet.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/room_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_aseman_service.dart';

class _Service extends FakeAsemanService {
  final sent = <({String space, String room, String body, List<String> files})>[];

  @override
  Future<RoomMessage> sendRoomMessage(
      String spaceId, String roomId, String body,
      {List<String> mentions = const [],
      List<String> attachments = const [],
      String replyTo = ''}) {
    sent.add((space: spaceId, room: roomId, body: body, files: attachments));
    return super.sendRoomMessage(spaceId, roomId, body,
        mentions: mentions, attachments: attachments, replyTo: replyTo);
  }
}

RoomMessage _msg({
  String body = 'Ship the charts',
  List<UploadedFile> attachments = const [],
}) =>
    RoomMessage(
      id: 'm1',
      spaceId: FakeAsemanService.atlasId,
      roomId: 'a1',
      senderId: '00000000000000010000000000000042',
      senderName: 'Maya Chen',
      body: body,
      attachments: attachments,
      createdAt: DateTime.utc(2026, 3, 4, 9),
    );

void main() {
  test('forwardedMessageBody attributes the sender and keeps a note', () {
    expect(
      forwardedMessageBody(_msg(), fromName: 'Maya Chen', note: 'FYI'),
      'FYI\n\n_Forwarded from **Maya Chen**_\n\nShip the charts',
    );
    expect(
      forwardedMessageBody(_msg(body: ''), fromName: ''),
      '_Forwarded message_',
    );
  });

  testWidgets('Forward in the menu sends the message to chosen chats',
      (tester) async {
    final service = _Service();
    final message = _msg(
      attachments: const [
        UploadedFile(id: 'f1', name: 'chart.png', mime: 'image/png', size: 12),
      ],
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomChat(
          room: 'general',
          messages: [message],
          me: '00000000000000010000000000000001',
          dependencies: AppDependencies.withService(service),
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          bare: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Ship the charts'));
    await tester.pumpAndSettle();
    expect(find.text('Forward'), findsOneWidget);
    await tester.tap(find.text('Forward'));
    await tester.pumpAndSettle();

    expect(find.text('Forward to…'), findsOneWidget);
    // Source Atlas room is excluded; Maya's direct chat is available.
    expect(find.text('Maya Chen'), findsWidgets);
    await tester.tap(find.text('Maya Chen').last);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Add a message (optional)'), 'Look');
    await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
    await tester.pumpAndSettle();

    expect(service.sent, hasLength(1));
    expect(service.sent.single.space, FakeAsemanService.directId);
    expect(service.sent.single.files, ['f1']);
    expect(service.sent.single.body, contains('Look'));
    expect(service.sent.single.body, contains('Forwarded from'));
    expect(service.sent.single.body, contains('Ship the charts'));
    expect(find.text('Forwarded'), findsOneWidget);
  });

  testWidgets('forward sheet can target a project room', (tester) async {
    final service = _Service();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showForwardMessageSheet(context,
                dependencies: AppDependencies.withService(service),
                message: _msg(),
                fromName: 'Sam',
                excludeSpaceId: FakeAsemanService.directId,
                excludeRoomId: 'd1'),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    // Atlas Collective's general room from the fake chat list.
    expect(find.text('general'), findsOneWidget);
    await tester.tap(find.text('general'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forward'));
    await tester.pumpAndSettle();

    expect(service.sent.single.space, FakeAsemanService.atlasId);
    expect(service.sent.single.room, 'a1');
    expect(service.sent.single.body, contains('Forwarded from **Sam**'));
  });
}
