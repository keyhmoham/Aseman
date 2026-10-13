import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tradera/src/core/theme/app_theme.dart';
import 'package:tradera/src/shared/widgets/segmented_tab_bar.dart';

void main() {
  Future<void> pump(WidgetTester tester, double screen, List<String> labels,
      {double? width}) async {
    tester.view.physicalSize = Size(screen, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkWith(const Color(0xFF8B7BFF)),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SegmentedTabBar(
            width: width,
            labels: labels,
            icons: [for (final _ in labels) Icons.star_outline_rounded],
            selectedIndex: 0,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  double pillWidth(WidgetTester tester) => tester
      .getSize(find
          .descendant(
              of: find.byType(SegmentedTabBar),
              matching: find.byType(Container))
          .first)
      .width;

  double overflow(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(
          of: find.byType(TabBar), matching: find.byType(Scrollable)))
      .position
      .maxScrollExtent;

  testWidgets('a few tabs shrink the bar to fit them, with nothing to scroll',
      (tester) async {
    await pump(tester, 1200, ['Overview', 'Transactions'], width: 900);
    expect(pillWidth(tester), lessThan(900));
    expect(overflow(tester), 0);
    // Every tab is fully inside the pill.
    final pill = tester.getRect(find
        .descendant(
            of: find.byType(SegmentedTabBar), matching: find.byType(Container))
        .first);
    for (final label in ['Overview', 'Transactions']) {
      final tab = tester.getRect(find.text(label));
      expect(
          pill.contains(tab.topLeft) && pill.contains(tab.bottomRight), isTrue,
          reason: label);
    }
  });

  testWidgets('tabs that do not fit fill the width and scroll', (tester) async {
    const labels = [
      'Invitations',
      'Messages',
      'Billing',
      'Payout',
      'Usage',
      'Profile',
      'Account',
    ];
    await pump(tester, 390, labels, width: 1000);
    expect(pillWidth(tester), 390 - 32);
    expect(overflow(tester), greaterThan(0));
  });
}
