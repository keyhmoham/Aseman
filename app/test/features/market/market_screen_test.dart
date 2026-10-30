import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/app_dependencies.dart';
import 'package:aseman/src/features/market/presentation/market_screen.dart';

import '../../fake_aseman_service.dart';

void main() {
  testWidgets('the Apps tab has no install button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarketScreen(
            dependencies: AppDependencies.withService(FakeAsemanService()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'a');
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pumpAndSettle();

    expect(find.text('AlphaBot'), findsWidgets);
    expect(find.text('Install'), findsOneWidget);

    await tester.tap(find.text('Apps'));
    await tester.pumpAndSettle();

    expect(find.text('Chart Studio'), findsWidgets);
    expect(find.text('Install'), findsNothing);
  });
}
