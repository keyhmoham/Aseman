import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/app_dependencies.dart';
import 'package:tradera/src/features/admin/presentation/admin_screen.dart';

import '../../fake_tradera_service.dart';

/// Serves admin calls from [responses] and lets a test hold one action's
/// reply open to observe the page while that panel is still refreshing.
class _LiveService extends FakeTraderaService {
  final responses = <String, dynamic>{};
  final held = <String, Completer<void>>{};

  @override
  Future<dynamic> invokeAction(String namespace, String action,
      {Map<String, dynamic> body = const {}, Duration? timeout}) async {
    final label = '$namespace.$action';
    final gate = held[label];
    if (gate != null) await gate.future;
    return responses[label] ?? const <String, dynamic>{};
  }
}

Map<String, dynamic> _nodeStats(int plugins) => {
      'node': {'id': 'node-a', 'plugins': plugins, 'goroutines': 12},
      'resources': {
        'cpu_cores': 4,
        'load_avg': [1.0],
        'mem_used_percent': 40
      },
    };

Map<String, dynamic> _telemetry(String message) => {
      'plugins': [
        {'name': 'gateway', 'ok': true, 'message': message}
      ]
    };

void main() {
  testWidgets('live node page updates each panel in place without a spinner',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _LiveService()
      ..responses['admin.node_stats'] = _nodeStats(3)
      ..responses['admin.telemetry'] = _telemetry('first reading');
    await tester.pumpWidget(MaterialApp(
        home: AdminScreen(dependencies: AppDependencies.withService(service))));
    await tester.pump();
    (tester.state(find.byType(AdminScreen)) as dynamic)
        .navigateToLabel('Node · Host');
    await tester.pump();
    await tester.pump();
    expect(find.text('3'), findsOneWidget);
    expect(find.text('first reading'), findsOneWidget);

    // Next tick: node stats answer right away, telemetry is still pending.
    service.responses['admin.node_stats'] = _nodeStats(5);
    service.responses['admin.telemetry'] = _telemetry('second reading');
    final telemetry = service.held['admin.telemetry'] = Completer<void>();
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('first reading'), findsOneWidget);

    telemetry.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('second reading'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed background tick keeps the last good data',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _FailingService()
      ..responses['admin.node_stats'] = _nodeStats(3);
    await tester.pumpWidget(MaterialApp(
        home: AdminScreen(dependencies: AppDependencies.withService(service))));
    await tester.pump();
    (tester.state(find.byType(AdminScreen)) as dynamic)
        .navigateToLabel('Node · Host');
    await tester.pump();
    await tester.pump();
    expect(find.text('3'), findsOneWidget);

    service.failing = true;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3'), findsOneWidget);
    expect(find.textContaining('admin.node_stats:'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}

class _FailingService extends _LiveService {
  bool failing = false;

  @override
  Future<dynamic> invokeAction(String namespace, String action,
      {Map<String, dynamic> body = const {}, Duration? timeout}) async {
    if (failing) throw Exception('offline');
    return super.invokeAction(namespace, action, body: body, timeout: timeout);
  }
}
