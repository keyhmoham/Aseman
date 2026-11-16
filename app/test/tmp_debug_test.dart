import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aseman/src/app.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/features/search_feed/presentation/search_feed_screen.dart';
import 'package:aseman/src/features/home/presentation/workspace_screen.dart';

import 'fake_aseman_service.dart';

void main() {
  testWidgets('debug working agent', (tester) async {
    SharedPreferences.setMockInitialValues({
      'aseman.session':
          '{"account_id":"00000000000000010000000000000001","handle":"test",'
              '"token":"x","private_key":"","public_key":"",'
              '"home_space_id":"00000000000000010000000000000002"}',
    });
    final service = FakeAsemanService();
    service.workingAgent = 'dev';
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      AsemanApp(dependencies: AppDependencies.withService(service)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Atlas Collective').first);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    for (final e in find.text('general').evaluate()) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        debugPrint('general at ${ro.localToGlobal(Offset.zero)} ${ro.size}');
      }
    }
    for (final e in find.text('Atlas Collective').evaluate()) {
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize) {
        debugPrint('atlas at ${ro.localToGlobal(Offset.zero)} ${ro.size}');
      }
    }
    await tester.tap(find.text('general').first);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 1));
    debugPrint(
      'feeds ${find.byType(SearchFeedScreen).evaluate().length} '
      'workspaces ${find.byType(WorkspaceScreen).evaluate().length}',
    );
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .toList();
    debugPrint('texts: ${texts.where((t) => t.length < 40).toList()}');
  });
}
