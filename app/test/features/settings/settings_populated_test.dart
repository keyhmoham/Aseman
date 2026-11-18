import 'dart:io';

import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/network/session_store.dart';
import 'package:aseman/src/core/settings/app_settings.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/settings/presentation/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../fake_aseman_service.dart';
import '../admin/admin_fixtures.dart' show loadFonts;

final _shots = Platform.environment['UI_SHOTS'];

/// A service whose account, wallet, approvals, channels and sessions hold
/// real-looking rows, so the settings pages render with content.
class _RichService extends FakeAsemanService {
  @override
  Future<dynamic> invokeAction(
    String namespace,
    String action, {
    Map<String, dynamic> body = const {},
    Duration? timeout,
    bool anonymous = false,
  }) async {
    switch ('$namespace.$action') {
      case 'auth.me':
        return {
          'id': 'me',
          'handle': 'test',
          'email': 'someone.with.a.long.address@example-company.com',
          'email_verified': true,
          'is_admin': true,
        };
      case 'auth.config':
        return {
          'providers': ['password', 'google'],
        };
      case 'finance.account':
        return {
          'balance': 12480,
          'locked': 320,
          'bought': 20000,
          'spent': 7200,
          'transactions': [
            for (var i = 0; i < 5; i++)
              {
                'created_at': '2026-11-0${i + 1}T10:00:00Z',
                'description': i.isEven
                    ? 'Agent run: quarterly report research for Atlas'
                    : 'Credit pack top-up',
                'amount': i.isEven ? -420 - i : 5000,
                'type': i.isEven ? 'spend' : 'purchase',
              },
            {
              'created_at': '2026-10-01T10:00:00Z',
              'description': 'Welcome credits',
              'amount': 1000,
              'expires_at': '2027-01-01T00:00:00Z',
              'grant_status': 'active',
            },
          ],
        };
      case 'finance.wallet_get':
        return {'balance': 12480, 'locked': 320};
      case 'finance.purchases_mine':
        return {
          'purchases': [
            {
              'product_id': 'Starter pack',
              'created_at': '2026-11-02T10:00:00Z',
              'amount': 5000,
              'status': 'credited',
            },
          ],
        };
      case 'finance.credit_requests_mine':
        return {'requests': <Object>[]};
      case 'usage.projects':
        return {
          'projects': [
            {
              'space_name': 'Atlas Collective',
              'agent_time': 1200,
              'llm': 3400,
              'spent': 5200,
            },
            {
              'space_name': 'Personal',
              'agent_time': 300,
              'llm': 700,
              'spent': 1000,
            },
          ],
        };
      case 'governance.approval_list':
        return {
          'approvals': [
            {
              'id': 'a1',
              'summary': 'Send the Q4 summary email to the board',
              'agent_name': 'Researcher',
              'tool': 'gmail.send',
              'effect': 'sends email',
              'recipients': ['board@example.com', 'cfo@example.com'],
              'text': 'Hi all, attached is the Q4 summary. Highlights: …',
            },
          ],
        };
      case 'governance.grant_list':
        return {
          'grants': [
            {
              'id': 'g1',
              'summary': 'Read calendar',
              'agent_name': 'Scheduler',
              'tool': 'calendar.read',
              'effect': 'reads',
              'target': 'primary',
            },
          ],
        };
      case 'channels.status':
        return {
          'offered': {'telegram': true, 'slack': true},
          'bindings': [
            {
              'id': 'b1',
              'provider': 'telegram',
              'name': '@someone',
              'notify': true,
            },
          ],
        };
      case 'google.status':
        return {};
      case 'proactive.settings_get':
        return {
          'settings': {
            'research': true,
            'interval_hours': 6,
            'last_result': 'Found 2 things worth doing',
          },
        };
      case 'proactive.setup_check':
        return {
          'items': [
            {'label': 'Home project', 'status': 'ready', 'detail': 'Created'},
            {
              'label': 'Email account',
              'status': 'needs_setup',
              'detail': 'No account connected',
              'fix': 'Connect Google in Apps',
            },
            {
              'label': 'Notifications',
              'status': 'unknown',
              'detail': 'Not checked on this device',
            },
            {
              'label': 'Calendar',
              'status': 'ready',
              'optional': true,
              'detail': 'Connected',
            },
          ],
        };
    }
    return super.invokeAction(
      namespace,
      action,
      body: body,
      timeout: timeout,
      anonymous: anonymous,
    );
  }

  @override
  Future<({List<DeviceSession> sessions, String sessionId})>
  sessionsList() async => (
    sessions: const [
      DeviceSession(
        id: 's1',
        kind: 'session',
        createdAt: '2026-11-01T10:00:00Z',
        expiresAt: '2027-11-01T10:00:00Z',
        lastSeenAt: '2026-11-18T09:00:00Z',
        current: true,
        meta: {'name': 'Pixel 9', 'platform': 'android'},
      ),
      DeviceSession(
        id: 's2',
        kind: 'session',
        createdAt: '2026-10-01T10:00:00Z',
        expiresAt: '2027-10-01T10:00:00Z',
        lastSeenAt: '2026-11-10T09:00:00Z',
        meta: {'name': 'Chrome on Linux', 'platform': 'web'},
      ),
    ],
    sessionId: 's1',
  );
}

void main() {
  setUpAll(() async {
    if (_shots != null) await loadFonts();
  });

  testWidgets('pages render populated data without layout errors', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final d = AppDependencies.withService(_RichService());
    d.sessionController.setSession(
      const Session(
        accountId: '00000000000000010000000000000001',
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: '',
        homeSpaceId: FakeAsemanService.homeId,
      ),
    );
    await tester.pumpWidget(
      AppSettingsScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightWith(const Color(0xFF6750A4)),
          home: SettingsScreen(dependencies: d),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in [
      'Account & sign-in',
      'Wallet',
      'Approvals',
      'Connections',
      'Setup',
      'Devices',
    ]) {
      final row = find.text(label);
      await tester.scrollUntilVisible(
        row,
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
      if (_shots != null) {
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            Uri.file(
              '$_shots/rich_${label.split(' ').first.toLowerCase()}.png',
            ),
          ),
        );
      }
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
    }
  });

  Future<void> pumpSettings(WidgetTester tester, Size size) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final d = AppDependencies.withService(_RichService());
    d.sessionController.setSession(
      const Session(
        accountId: '00000000000000010000000000000001',
        handle: 'test',
        token: 'x',
        privateKey: '',
        publicKey: '',
        homeSpaceId: FakeAsemanService.homeId,
      ),
    );
    await tester.pumpWidget(
      AppSettingsScope(
        controller: AppSettingsController(),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightWith(const Color(0xFF6750A4)),
          home: SettingsScreen(dependencies: d),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Dismisses the open overlay by tapping its scrim.
  Future<void> dismiss(WidgetTester tester) async {
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
  }

  // Every overlay settings can open, as (pane to open, what to tap).
  final overlays = <(String, String)>[
    ('Notifications', 'Quiet hours'),
    ('Privacy', 'Who may message you'),
    ('Agents', 'Currency'),
    ('Storage', 'Upload quality'),
    ('Storage', 'Clear local cache'),
    ('Account', 'Edit identity'),
    ('Account', 'Change password'),
    ('Account', 'Delete account'),
    ('Wallet', 'Add credits'),
    ('Devices', 'Sign out other devices'),
    ('Appearance', 'Browse themes in Store'),
  ];

  testWidgets('desktop never opens a bottom sheet from settings', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1440, 900));
    for (final (pane, trigger) in overlays) {
      await tester.tap(find.widgetWithText(ListTile, pane));
      await tester.pumpAndSettle();
      final target = find.text(trigger).first;
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      await tester.tap(target);
      await tester.pumpAndSettle();
      expect(
        find.byType(BottomSheet),
        findsNothing,
        reason: '$pane · $trigger opened a bottom sheet on desktop',
      );
      // Something did open: the screen has more than the settings page.
      expect(
        find.byType(ModalBarrier).evaluate().length,
        greaterThan(1),
        reason: '$pane · $trigger opened nothing',
      );
      await dismiss(tester);
      expect(find.byType(BottomSheet), findsNothing);
    }
  });

  testWidgets('a picker on desktop is anchored to its row, not a sheet', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(1440, 900));
    await tester.tap(find.widgetWithText(ListTile, 'Notifications'));
    await tester.pumpAndSettle();
    final row = tester.getRect(find.text('Quiet hours'));
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    final option = tester.getRect(find.text('22:00 – 08:00'));
    // Next to the row that opened it, not pinned to the bottom edge.
    expect(option.bottom, lessThan(900 - 40));
    expect((option.center.dy - row.center.dy).abs(), lessThan(400));
    await tester.tap(find.text('22:00 – 08:00'));
    await tester.pumpAndSettle();
    expect(find.text('22:00 – 08:00'), findsOneWidget);
  });

  testWidgets('a phone opens the same overlays as bottom sheets', (
    tester,
  ) async {
    await pumpSettings(tester, const Size(390, 844));
    await tester.tap(find.text('Notifications'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
  });
}
