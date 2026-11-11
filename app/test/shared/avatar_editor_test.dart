import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/network/api_client.dart';
import 'package:aseman/src/data/models/bot.dart';
import 'package:aseman/src/data/models/post.dart';
import 'package:aseman/src/data/models/profile.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/data/services/aseman_service.dart';
import 'package:aseman/src/shared/widgets/avatar.dart';
import 'package:aseman/src/shared/widgets/avatar_editor.dart';
import 'package:aseman/src/shared/widgets/avatar_face.dart';

const fileId = '00000000000000010000000000000001';

AsemanService _service() =>
    AsemanService(AsemanApiClient(baseUrl: 'https://node.example'));

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

  test('a zero id is no picture', () {
    expect(_service().avatarImage('0' * 32), isNull);
  });

  test('posts, chats, messages and listings carry their pictures', () {
    final post = SocialPost.fromJson({
      'id': 'p',
      'author_id': 'a',
      'author': {'display_name': 'Ada', 'handle': 'ada', 'avatar': fileId},
    });
    expect([post.authorName, post.authorHandle, post.authorAvatar],
        ['Ada', 'ada', fileId]);
    expect(post.withLike(likes: 1, likedByMe: true).authorAvatar, fileId);
    expect(
        ChatSummary.fromJson({'space_id': 's', 'space_avatar': fileId})
            .copyWith(blocked: true)
            .spaceAvatar,
        fileId);
    expect(
        RoomMessage.fromJson({
          'id': 'm',
          'sender': {'avatar': fileId},
        }).senderAvatar,
        fileId);
    expect(MarketListing.fromJson({'id': 'l', 'avatar': fileId}).avatar,
        fileId);
    expect(AccountSummary.fromJson({'id': 'u', 'avatar': fileId}).avatar,
        fileId);
  });

  testWidgets('an avatar shows its picture over its fallback', (tester) async {
    final service = _service();
    Avatars.resolve = service.avatarImage;
    addTearDown(() => Avatars.resolve = (_) => null);
    await tester.pumpWidget(const MaterialApp(
        home: Column(children: [
      AvatarPicture(avatar: fileId, size: 30, fallback: Text('F1')),
      AvatarPicture(avatar: '', size: 30, fallback: Text('F2')),
      AppAvatar('A', color: Colors.blue, avatar: fileId),
    ])));
    // The fallback stays under the picture (which cannot load in tests).
    expect(find.text('F1'), findsOneWidget);
    expect(find.text('F2'), findsOneWidget);
    // A picture for each avatar that has one (F1 and the AppAvatar's face),
    // none for F2.
    expect(find.byType(Image), findsNWidgets(2));
    final face = tester.widget<AvatarFace>(find.byType(AvatarFace));
    expect(
      (face.foregroundImage as NetworkImage).url,
      'https://node.example/v1/files/$fileId/content',
    );
  });
}
