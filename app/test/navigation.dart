import 'package:flutter_test/flutter_test.dart';

/// Opens a space's room from the feed's chat rail: the space's entry lists
/// its rooms, and a room opens the space's workspace (its rooms, apps, files,
/// computer… on the left, the room's chat in the middle).
Future<void> openSpaceRoom(
  WidgetTester tester, {
  String space = 'Atlas Collective',
  String room = 'general',
}) async {
  await tester.tap(find.text(space).last);
  await tester.pumpAndSettle();
  await tester.tap(find.text(room).first);
  await tester.pumpAndSettle();
}
