import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/features/admin/presentation/admin_screen.dart';
import 'package:aseman/src/features/admin/presentation/admin_widgets.dart';

import 'admin_fixtures.dart';

const pages = [
  'Overview',
  'Users',
  'Projects',
  'Agents',
  'Apps',
  'Talent',
  'Finance · Overview',
  'Finance · Purchases',
  'Finance · Payouts',
  'Providers',
  'Models',
  'Decision model',
  'Memory models',
  'Agentic engine',
  'OpenCode',
  'Health',
  'Node · Host',
  'Node · Modules',
  'Node · Logs',
  'Sandboxes',
  'Storage',
  'Settings · Pricing',
  'Settings · Machine',
  'Settings · Agent instructions',
  'Settings · Categories',
];

const sizes = {
  'phone': Size(390, 844),
  'tablet': Size(820, 1180),
  'desktop': Size(1440, 900),
};

/// Writes screenshots when ADMIN_SHOTS names a directory.
final shots = Platform.environment['ADMIN_SHOTS'];

void main() {
  setUpAll(() async {
    if (shots != null) await loadFonts();
  });

  Future<List<String>> pumpPage(
      WidgetTester tester, Size size, String page, Map<String, dynamic> data,
      {String? shot, Future<void> Function()? interact}) async {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final culprit =
          RegExp(r'The relevant error-causing widget was:\s*\n\s*(.*)\n\s*(.*)')
              .firstMatch(text);
      errors.add('${details.exceptionAsString().split('\n').first}'
          '${culprit == null ? '' : ' @ ${culprit.group(1)} ${culprit.group(2)}'}');
    };
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
        home: AdminScreen(
            dependencies: AppDependencies.withService(AdminFakeService(data))),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      if (page != 'Overview') {
        final state = tester.state(find.byType(AdminScreen)) as dynamic;
        state.navigateToLabel(page);
      }
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (interact != null) await interact();
      if (shot != null && shots != null) {
        await expectLater(find.byType(MaterialApp),
            matchesGoldenFile(Uri.file('$shots/$shot.png')));
      }
    } finally {
      await tester.pumpWidget(const SizedBox());
      FlutterError.onError = previous;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
    return errors;
  }

  for (final size in sizes.entries) {
    for (final page in pages) {
      testWidgets('${size.key} · $page renders without errors', (tester) async {
        final slug = page.replaceAll(RegExp(r'[^A-Za-z]+'), '_');
        final errors = await pumpPage(tester, size.value, page, adminFixtures(),
            shot: '${size.key}_$slug');
        expect(errors, isEmpty);
        final empty = await pumpPage(tester, size.value, page, const {});
        expect(empty, isEmpty, reason: 'empty backend responses');
      });
    }
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final size in sizes.entries) {
    final dialogs = <String, (String, Future<void> Function(WidgetTester))>{
      'user dialog': (
        'Users',
        (t) async {
          final row = find.descendant(
              of: find.byType(AdminDataTable),
              matching: find.text('Ada Lovelace'));
          await t.ensureVisible(row.first);
          await t.pump();
          await t.tap(row.first);
          await settle(t);
        }
      ),
      'project dialog': (
        'Projects',
        (t) async {
          final row = find.descendant(
              of: find.byType(AdminDataTable),
              matching: find.textContaining('A project with'));
          await t.ensureVisible(row.first);
          await t.pump();
          await t.tap(row.first);
          await settle(t);
        }
      ),
      'model editor': (
        'Models',
        (t) async {
          await t.tap(find.text('Add model'));
          await settle(t);
          expect(find.text('What this model is for'), findsOneWidget);
        }
      ),
      'provider editor': (
        'Providers',
        (t) async {
          await t.tap(find.text('Add provider'));
          await settle(t);
          expect(find.text('Add LLM provider'), findsOneWidget);
        }
      ),
    };
    for (final entry in dialogs.entries) {
      testWidgets('${size.key} · ${entry.key} renders without errors',
          (tester) async {
        final (page, open) = entry.value;
        if (entry.key == 'user dialog' || entry.key == 'project dialog') {
          final tabs = entry.key == 'user dialog'
              ? ['Summary', 'Purchases', 'Wallet', 'Profile & access']
              : ['Overview', 'Machine', 'Cost', 'Storage', 'Logs', 'People'];
          for (final tab in tabs) {
            final errors =
                await pumpPage(tester, size.value, page, adminFixtures(),
                    shot: '${size.key}_dialog_${entry.key.split(' ').first}_'
                        '${tab.replaceAll(RegExp(r'[^A-Za-z]+'), '_')}',
                    interact: () async {
              await open(tester);
              final segment = find.descendant(
                  of: find.byType(Dialog), matching: find.text(tab));
              await tester.ensureVisible(segment.last);
              await tester.tap(segment.last);
              await settle(tester);
            });
            expect(errors, isEmpty, reason: tab);
          }
        } else {
          final errors = await pumpPage(
              tester, size.value, page, adminFixtures(),
              shot: '${size.key}_dialog_${entry.key.replaceAll(' ', '_')}',
              interact: () => open(tester));
          expect(errors, isEmpty);
        }
      });
    }
  }

  testWidgets('settings pointing at a removed provider or model still render',
      (tester) async {
    final data = adminFixtures();
    data['llm.llm_decision_get'] = {
      ...data['llm.llm_decision_get'] as Map<String, dynamic>,
      'provider_id': 'prov-disabled',
      'model_id': 'gone-model',
      'providers': const <Map<String, dynamic>>[],
    };
    data['llm.llm_memory_get'] = {
      ...data['llm.llm_memory_get'] as Map<String, dynamic>,
      'chat_provider_id': 'prov-disabled',
      'chat_model_id': 'gone-model',
      'providers': const <Map<String, dynamic>>[],
    };
    data['finance.payouts_list'] = {
      'payouts': [
        {'id': 'p1', 'handle': '', 'amount': 1, 'status': 'pending'}
      ]
    };
    for (final page in [
      'Decision model',
      'Memory models',
      'Finance · Payouts'
    ]) {
      for (final size in sizes.values) {
        expect(await pumpPage(tester, size, page, data), isEmpty, reason: page);
      }
    }
  });

  testWidgets('leaving page search keeps the current page', (tester) async {
    await pumpPage(tester, sizes['desktop']!, 'Health', adminFixtures(),
        interact: () async {
      await tester.tap(find.byTooltip('Search'));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await settle(tester);
      expect(find.text('Deployment checklist'), findsOneWidget);
    });
  });
}
