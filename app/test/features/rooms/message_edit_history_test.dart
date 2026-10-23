import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/message_edit_history.dart';
import 'package:aseman/src/features/rooms/presentation/widgets/room_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_aseman_service.dart';

RoomMessage _msg(String id, String body, {DateTime? editedAt}) => RoomMessage(
      id: id,
      spaceId: FakeAsemanService.atlasId,
      roomId: 'a1',
      senderId: '00000000000000010000000000000001',
      body: body,
      createdAt: DateTime.utc(2026, 3, 4, 9),
      editedAt: editedAt,
    );

void main() {
  testWidgets('edited label opens the history of earlier wording',
      (tester) async {
    final service = FakeAsemanService();
    final key = '${FakeAsemanService.atlasId}/a1';
    service.roomMessages[key] = [
      _msg('m1', 'Final text', editedAt: DateTime.utc(2026, 3, 4, 9, 5)),
    ];
    service.messageEdits['m1'] = [
      MessageEditVersion(
          body: 'Second draft', at: DateTime.utc(2026, 3, 4, 9, 4)),
      MessageEditVersion(
          body: 'First draft', at: DateTime.utc(2026, 3, 4, 9, 2)),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomChat(
          room: 'general',
          messages: service.roomMessages[key]!,
          me: '00000000000000010000000000000001',
          dependencies: AppDependencies.withService(service),
          spaceId: FakeAsemanService.atlasId,
          roomId: 'a1',
          bare: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('edited'), findsOneWidget);
    await tester.tap(find.textContaining('edited'));
    await tester.pumpAndSettle();

    expect(find.text('Edit history'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Final text'), findsWidgets);
    expect(find.text('Second draft'), findsOneWidget);
    expect(find.text('First draft'), findsOneWidget);
    expect(find.text('Original'), findsOneWidget);
  });

  testWidgets('showMessageEditHistory loads versions from the service',
      (tester) async {
    final service = FakeAsemanService();
    final message =
        _msg('m2', 'Now', editedAt: DateTime.utc(2026, 3, 4, 10));
    service.roomMessages['${FakeAsemanService.atlasId}/a1'] = [message];
    service.messageEdits['m2'] = [
      MessageEditVersion(body: 'Before', at: DateTime.utc(2026, 3, 4, 9)),
    ];

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showMessageEditHistory(context,
                service: service, message: message),
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Before'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget);
  });
}
