import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/data/models/space.dart';
import 'package:aseman/src/features/home/presentation/space_settings_panel.dart';

import '../../fake_aseman_service.dart';

void main() {
  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized()
        .platformDispatcher
        .clearAllTestValues();
  });

  AppDependencies app() {
    final deps = AppDependencies.withService(FakeAsemanService());
    deps.sessionController.setSession(const Session(
      accountId: 'me',
      handle: 'test',
      token: 'x',
      privateKey: '',
      publicKey: '',
      homeSpaceId: FakeAsemanService.homeId,
    ));
    return deps;
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    required Workspace space,
    VoidCallback? onExit,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SpaceSettingsPanel(
          dependencies: app(),
          space: space,
          onExit: onExit,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders all settings sections with the danger zone last',
      (tester) async {
    await pumpPanel(
      tester,
      space: const Workspace(
          id: FakeAsemanService.homeId,
          ownerId: 'me',
          name: 'Home',
          home: true),
    );

    expect(find.text('Workspace settings'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('At a glance'), findsOneWidget);
    expect(find.text('Rooms'), findsWidgets);
    expect(find.text('Members'), findsWidgets);
    expect(find.text('LLM usage'), findsOneWidget);
    expect(find.text('Danger zone'), findsOneWidget);
    // The one settings panel: the budget is set here, and nothing opens a
    // second panel for the space's facilities.
    expect(find.text('Set budget'), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_customize_outlined), findsNothing);

    // Token usage rollups render per room chat and per agent.
    expect(find.text('Per room chat'), findsOneWidget);
    expect(find.text('Per agent'), findsOneWidget);
    expect(find.text('SignalBot'), findsOneWidget);
    expect(find.text('aseman'), findsOneWidget);

    final dangerTop = tester.getTopLeft(find.text('Danger zone')).dy;
    final overviewTop = tester.getTopLeft(find.text('Overview')).dy;
    final glanceTop = tester.getTopLeft(find.text('At a glance')).dy;
    expect(dangerTop, greaterThan(overviewTop));
    expect(dangerTop, greaterThan(glanceTop));
    expect(
        dangerTop, greaterThan(tester.getTopLeft(find.text('LLM usage')).dy));

    expect(find.text('general'), findsWidgets);
    expect(find.text('Crypto Alpha'), findsWidgets);
    expect(find.text('@test'), findsOneWidget);
  });

  testWidgets('owner sees the delete workspace action, not leave',
      (tester) async {
    await pumpPanel(
      tester,
      space: const Workspace(
          id: FakeAsemanService.homeId,
          ownerId: 'me',
          name: 'Home',
          home: true),
    );

    expect(find.text('Delete workspace'), findsOneWidget);
    expect(find.text('Leave workspace'), findsNothing);
  });

  testWidgets('non-owner member sees the leave workspace action, not delete',
      (tester) async {
    await pumpPanel(
      tester,
      space: const Workspace(
          id: FakeAsemanService.sharedId, ownerId: 'u1', name: 'Shared Desk'),
    );

    expect(find.text('Leave workspace'), findsOneWidget);
    expect(find.text('Delete workspace'), findsNothing);
  });

  testWidgets('owner deleting a workspace confirms then exits', (tester) async {
    var exitCalled = false;
    await pumpPanel(
      tester,
      space: const Workspace(
          id: FakeAsemanService.homeId,
          ownerId: 'me',
          name: 'Home',
          home: true),
      onExit: () => exitCalled = true,
    );

    await tester.ensureVisible(find.text('Delete workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete workspace'));
    await tester.pumpAndSettle();
    expect(find.textContaining('permanently deletes'), findsOneWidget);

    // Destructive confirmations wait for the acknowledgement.
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Delete workspace').last);
    await tester.pumpAndSettle();
    expect(exitCalled, isTrue);
  });

  testWidgets('member leaving a workspace confirms then exits', (tester) async {
    var exitCalled = false;
    await pumpPanel(
      tester,
      space: const Workspace(
          id: FakeAsemanService.sharedId, ownerId: 'u1', name: 'Shared Desk'),
      onExit: () => exitCalled = true,
    );

    await tester.ensureVisible(find.text('Leave workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave workspace'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Leave Shared Desk?'), findsOneWidget);

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Leave workspace').last);
    await tester.pumpAndSettle();
    expect(exitCalled, isTrue);
  });
}
