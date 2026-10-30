import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/data/models/post.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_view_model.dart';

import '../../fake_aseman_service.dart';

/// Follows people too, so the Following feed has both of its sources.
class _FollowingFake extends FakeAsemanService {
  final DateTime now = DateTime.now();

  @override
  Future<List<SocialPost>> fetchFeed(
          {bool following = false,
          String? spaceId,
          int limit = 50,
          int offset = 0}) async =>
      following && offset == 0
          ? [
              SocialPost(
                  id: 'f1',
                  authorId: FakeAsemanService.atlasId,
                  body: 'Newest from someone I follow.',
                  createdAt: now.subtract(const Duration(minutes: 1))),
              SocialPost(
                  id: 'f2',
                  authorId: FakeAsemanService.atlasId,
                  body: 'Older from someone I follow.',
                  createdAt: now.subtract(const Duration(minutes: 9))),
            ]
          : const [];
}

void main() {
  test('the Following feed mixes followed and space posts, newest first',
      () async {
    final model = SearchFeedViewModel(
        dependencies: AppDependencies.withService(_FollowingFake()));
    await model.load();

    final posts = model.followingPosts;
    expect(posts.map((p) => p.serverId), ['f1', 'ws1', 'f2']);
    // The space post carries its space's name; the others carry none.
    expect(posts[1].workspace, isNotNull);
    expect(posts[0].workspace, isNull);
    model.dispose();
  });
}
