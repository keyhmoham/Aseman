import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/data/models/post.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/search_feed/presentation/feed_post_card.dart';
import 'package:aseman/src/features/search_feed/presentation/rich_post_content.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fake_aseman_service.dart';

const _me = '00000000000000010000000000000001';
const _alice = '00000000000000010000000000000077';

/// Records what the card asks of the server.
class _PostsFake extends FakeAsemanService {
  final calls = <String>[];

  @override
  Future<void> updatePost(String postId, String body) async =>
      calls.add('update $postId $body');

  @override
  Future<void> deletePost(String postId) async => calls.add('delete $postId');

  @override
  Future<void> reportPost(
    String postId, {
    required String reason,
    String note = '',
  }) async => calls.add('report $postId $reason');

  @override
  Future<String> forwardPost(String postId, {String? spaceId}) async {
    calls.add('forward $postId ${spaceId ?? 'public'}');
    return 'new';
  }

  @override
  Future<RoomMessage> sendRoomMessage(
    String spaceId,
    String roomId,
    String body, {
    List<String> mentions = const [],
    List<String> attachments = const [],
    String replyTo = '',
  }) async {
    calls.add('send $spaceId/$roomId $body');
    return RoomMessage(
      id: 'm',
      spaceId: spaceId,
      roomId: roomId,
      senderId: _me,
      body: body,
      createdAt: DateTime.now(),
    );
  }
}

void main() {
  late _PostsFake service;
  late AppDependencies deps;
  final opened = <String>[];

  setUp(() {
    service = _PostsFake();
    deps = AppDependencies.withService(service);
    deps.sessionController.setSession(
      const Session(
        accountId: _me,
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: '',
      ),
    );
    opened.clear();
    PostLinks.openAccount = (_, id, __) => opened.add(id);
  });

  Future<void> show(
    WidgetTester tester,
    SocialPost post, {
    VoidCallback? onDeleted,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FeedPostCard(
              post: feedPostFromServer(post),
              dependencies: deps,
              onDeleted: onDeleted,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  SocialPost post({String author = _me, String forwardOf = ''}) => SocialPost(
    id: 'p1',
    authorId: author,
    authorHandle: author == _me ? 'test' : 'alice',
    body: 'Long **BTC**',
    createdAt: DateTime.now(),
    forwardOf: forwardOf,
    forwardAuthorId: forwardOf.isEmpty ? '' : _alice,
    forwardAuthorName: forwardOf.isEmpty ? '' : 'Alice',
  );

  testWidgets('the author edits and deletes their post from its menu', (
    tester,
  ) async {
    var deleted = false;
    await show(tester, post(), onDeleted: () => deleted = true);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Edit post'), findsOneWidget);
    expect(find.text('Report post'), findsNothing);

    await tester.tap(find.text('Delete post'));
    await tester.pumpAndSettle();
    expect(find.text('Delete this post?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(service.calls, ['delete p1']);
    expect(deleted, isTrue);
  });

  testWidgets("someone else's post is reported with a reason", (tester) async {
    await show(tester, post(author: _alice));
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Edit post'), findsNothing);
    await tester.tap(find.text('Report post'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scam or fraud'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();
    expect(service.calls, ['report p1 scam']);
  });

  testWidgets('a shared post names its original author, who opens', (
    tester,
  ) async {
    await show(tester, post(forwardOf: 'orig'));
    expect(
      find.textContaining('Forwarded from', findRichText: true),
      findsOneWidget,
    );
    await tester.tap(find.textContaining('Alice', findRichText: true));
    await tester.pumpAndSettle();
    expect(opened, [_alice]);
    // A shared post keeps its original's words: it cannot be edited.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Edit post'), findsNothing);
    expect(find.text('Delete post'), findsOneWidget);
  });

  testWidgets('the share modal reposts to feeds and forwards to chats', (
    tester,
  ) async {
    await show(tester, post(author: _alice));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Share post'), findsOneWidget);
    expect(find.text('Share via…'), findsOneWidget);

    await tester.tap(find.text('Public feed'));
    await tester.tap(find.text('Atlas Capital').first);
    final chat = (await service.fetchChats()).first;
    await tester.tap(find.text(chat.title).last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a message (optional)'),
      'look',
    );
    await tester.tap(find.text('Share to 3'));
    await tester.pumpAndSettle();

    expect(service.calls, contains('forward p1 public'));
    expect(service.calls, contains('forward p1 ${FakeAsemanService.atlasId}'));
    final sent = service.calls.singleWhere((c) => c.startsWith('send '));
    expect(
      sent,
      startsWith('send ${chat.spaceId}/${chat.roomId} look\n\n:::post '),
    );
    expect(sent, contains('"author_id":"$_alice"'));
    expect(find.text('Share post'), findsNothing);
  });
}
