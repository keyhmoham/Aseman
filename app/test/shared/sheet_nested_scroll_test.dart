import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aseman/src/core/theme/app_theme.dart';
import 'package:aseman/src/shared/widgets/glass_surface.dart';
import 'package:aseman/src/shared/widgets/overlay_panels.dart';

void main() {
  testWidgets('a nested vertical scrollbar inside a mobile sheet scrolls', (
    tester,
  ) async {
    final inner = ScrollController();
    final outer = ScrollController();
    addTearDown(inner.dispose);
    addTearDown(outer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        // A phone-width layout still uses the desktop scrollbar when the
        // browser is on Linux, macOS, or Windows.
        theme: AppTheme.dark.copyWith(platform: TargetPlatform.linux),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  showAppSheet<void>(
                    context,
                    Column(
                      children: [
                        const Text('Sheet title'),
                        Expanded(
                          child: ListView(
                            controller: outer,
                            children: [
                              const SizedBox(height: 40, child: Text('Above')),
                              SizedBox(
                                height: 180,
                                child: ListView(
                                  controller: inner,
                                  children: [
                                    for (var i = 0; i < 40; i++)
                                      SizedBox(
                                        height: 36,
                                        child: Text('Inner $i'),
                                      ),
                                  ],
                                ),
                              ),
                              for (var i = 0; i < 30; i++)
                                SizedBox(height: 48, child: Text('Outer $i')),
                            ],
                          ),
                        ),
                      ],
                    ),
                    heightFactor: .85,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(inner.offset, 0);
    final bars = find.byType(Scrollbar);
    expect(bars, findsWidgets);
    Rect? innerBar;
    for (final element in bars.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (innerBar == null || rect.height < innerBar.height) {
        innerBar = rect;
      }
    }
    // Thumb is the trailing edge of the shorter (nested) scrollbar.
    final thumb = Offset(innerBar!.right - 3, innerBar.top + 12);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: thumb);
    await gesture.moveTo(thumb);
    await tester.pumpAndSettle();
    await gesture.down(thumb);
    await gesture.moveBy(const Offset(0, 70));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(inner.offset, greaterThan(20));
    expect(outer.offset, 0);
  });

  testWidgets('a short sheet stays as tall as its content', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  showAppSheet<void>(
                    context,
                    const SizedBox(height: 48, child: Text('Only row')),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Only row'), findsOneWidget);
    final sheet = tester.getSize(find.byType(GlassSurface));
    expect(sheet.height, lessThan(200));
  });

  testWidgets('a sheet taller than the screen scrolls its body', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  showAppSheet<void>(
                    context,
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 40; i++)
                          SizedBox(
                            height: 48,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text('Row $i'),
                            ),
                          ),
                      ],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Row 0'), findsOneWidget);
    expect(find.text('Row 39').hitTestable(), findsNothing);
    final sheet = tester.getSize(find.byType(GlassSurface));
    // Grows up to the screen, rather than stopping at the default 9/16 cap.
    expect(sheet.height, greaterThan(500));
    expect(sheet.height, lessThanOrEqualTo(600));

    final before = tester.getTopLeft(find.text('Row 0')).dy;
    await tester.drag(find.text('Row 0'), const Offset(0, -1600));
    await tester.pump();
    expect(tester.getTopLeft(find.text('Row 0')).dy, lessThan(before - 200));
    final last = tester.getTopLeft(find.text('Row 39'));
    expect(last.dy, inInclusiveRange(0, 600));
  });
}
