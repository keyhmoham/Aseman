import 'dart:async';

import 'package:aseman/src/core/deferred/deferred_libraries.dart';

/// Runs before every test file: the app's deferred libraries are loaded
/// once, in the real zone. Loaded inside a test's fake-async zone instead,
/// the runtime's cached load would never complete for the tests after it.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await loadDeferredLibraries();
  await testMain();
}
