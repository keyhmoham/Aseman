import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/features/talent/presentation/talent_requests_panel.dart';

import '../../fake_tradera_service.dart';

class _Service extends FakeTraderaService {
  final requests = <Map<String, dynamic>>[
    {
      'id': 'r1',
      'title': 'Quant researcher for a BTC desk',
      'category': 'Research',
      'description': 'Backtest and size momentum strategies.',
      'budget_type': 'monthly',
      'budget_amount': 6000,
      'company': 'Atlas',
      'skills': ['Python', 'Statistics'],
      'status': 'open',
    }
  ];
  final created = <Map<String, dynamic>>[];
  final statuses = <String>[];

  @override
  Future<List<Map<String, dynamic>>> fetchTalentRequests() async =>
      List.of(requests);

  @override
  Future<Map<String, dynamic>> createTalentRequest(
      Map<String, dynamic> input) async {
    created.add(input);
    requests.insert(0, {...input, 'id': 'r2', 'status': 'open'});
    return requests.first;
  }

  @override
  Future<void> setTalentRequestStatus(String id, String status) async {
    statuses.add('$id:$status');
    for (final r in requests) {
      if (r['id'] == id) r['status'] = status;
    }
  }
}

void main() {
  Future<_Service> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    await tester.pumpWidget(
        MaterialApp(home: TalentRequestsPanel(service: service)));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('lists the requests a person posted and closes one',
      (tester) async {
    final service = await open(tester);
    expect(find.text('Quant researcher for a BTC desk'), findsOneWidget);
    expect(find.textContaining(r'$6000 / month'), findsOneWidget);
    await tester.tap(find.byTooltip('Request options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(service.statuses, ['r1:closed']);
    expect(find.text('Closed'), findsOneWidget);
  });

  testWidgets('posting checks the form and tells what is shared',
      (tester) async {
    final service = await open(tester);
    await tester.tap(find.text('New request'));
    await tester.pumpAndSettle();
    expect(find.textContaining('name and email are shared'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Title'), 'Flutter developer');
    await tester.ensureVisible(find.text('Post request'));
    await tester.tap(find.text('Post request'));
    await tester.pump();
    expect(find.textContaining('50 to 5,000 characters'), findsOneWidget);
    expect(service.created, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, 'What you need'),
        'Build the trading desk screens of a Flutter app with charts and live quotes.');
    await tester.enterText(find.widgetWithText(TextField, 'Amount'), '2500');
    await tester.enterText(
        find.widgetWithText(TextField, 'Company or project'), 'Atlas');
    await tester.enterText(
        find.widgetWithText(TextField, 'Skills (optional)'), 'Flutter, Dart');
    await tester.ensureVisible(find.text('Post request'));
    await tester.tap(find.text('Post request'));
    await tester.pumpAndSettle();
    expect(service.created.single['budget_amount'], 2500);
    expect(service.created.single['skills'], ['Flutter', 'Dart']);
    expect(service.created.single['category'], 'Development');
    expect(find.text('Flutter developer'), findsOneWidget);
  });
}
