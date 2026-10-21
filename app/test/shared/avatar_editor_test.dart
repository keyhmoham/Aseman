import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/network/api_client.dart';
import 'package:tradera/src/data/models/bot.dart';
import 'package:tradera/src/data/models/profile.dart';
import 'package:tradera/src/data/models/space.dart';
import 'package:tradera/src/data/services/tradera_service.dart';
import 'package:tradera/src/shared/widgets/avatar_editor.dart';

const fileId = '00000000000000010000000000000001';

TraderaService _service() =>
    TraderaService(TraderaApiClient(baseUrl: 'https://node.example'));

void main() {
  test('an avatar reference resolves onto its stored picture', () {
    final service = _service();
    for (final ref in [fileId, '/v1/files/$fileId/content']) {
      final image = service.avatarImage(ref) as NetworkImage;
      expect(image.url, 'https://node.example/v1/files/$fileId/content');
    }
    expect(
      (service.avatarImage('https://cdn.example/a.png') as NetworkImage).url,
      'https://cdn.example/a.png',
    );
    expect(service.avatarImage(''), isNull);
    expect(service.avatarImage('not a file'), isNull);
  });

  test('workspaces, bots and profiles read their avatar', () {
    expect(
      Workspace.fromJson({
        'id': 's',
        'profile': {'avatar': fileId},
      }).avatar,
      fileId,
    );
    expect(Workspace.fromJson({'id': 's', 'avatar': fileId}).avatar, fileId);
    expect(Workspace.fromJson({'id': 's'}).avatar, '');
    expect(
      Workspace.fromJson({
        'id': 's',
        'role': 'admin',
      }).withAvatar(fileId).canManage,
      isTrue,
    );
    final bot = Bot.fromJson({'id': 'b', 'avatar': fileId});
    expect(bot.avatar, fileId);
    expect(bot.withAvatar('').avatar, '');
    expect(
      UserProfile.fromJson({
        'id': 'u',
        'profile': {'avatar': fileId},
      }).avatar,
      fileId,
    );
    expect(BotProfile.fromJson({'id': 'b', 'avatar': fileId}).avatar, fileId);
    expect(SpaceProfile.fromJson({'id': 's', 'avatar': fileId}).avatar, fileId);
  });

  testWidgets('removing an avatar saves it cleared', (tester) async {
    final saved = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AvatarEditor(
              service: _service(),
              avatar: fileId,
              initials: 'AI',
              subject: 'agent picture',
              onChanged: (id) async => saved.add(id),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('Upload a new picture'), findsOneWidget);
    await tester.tap(find.text('Remove the agent picture'));
    await tester.pumpAndSettle();
    expect(saved, ['']);
    expect(find.text('The agent picture was removed.'), findsOneWidget);

    // Without a picture there is nothing to remove.
    await tester.tap(find.text('AI'));
    await tester.pumpAndSettle();
    expect(find.text('Upload a picture'), findsOneWidget);
    expect(find.text('Remove the agent picture'), findsNothing);
  });

  testWidgets('an avatar its viewer may not change offers nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AvatarEditor(
            service: _service(),
            avatar: '',
            initials: 'W',
            enabled: false,
            onChanged: (_) async => fail('nothing may be saved'),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.photo_camera_outlined), findsNothing);
    await tester.tap(find.text('W'));
    await tester.pumpAndSettle();
    expect(find.text('Upload a picture'), findsNothing);
  });
}
