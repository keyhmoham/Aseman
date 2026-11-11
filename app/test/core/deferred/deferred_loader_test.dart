import 'package:aseman/src/core/deferred/deferred_loader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a deferred library loads once, then opens without waiting', () async {
    var loads = 0;
    final loader = DeferredLoader(() async => loads++);
    expect(loader.isLoaded, isFalse);
    final first = loader.ensure();
    expect(loader.ensure(), same(first)); // one load in flight
    await first;
    expect(loader.isLoaded, isTrue);
    expect(loader.ensure(), isNull); // loaded: nothing to wait for
    expect(loads, 1);
  });

  test('a failed load is tried again', () async {
    var attempts = 0;
    final loader = DeferredLoader(() async {
      attempts++;
      if (attempts == 1) throw StateError('offline');
    });
    await expectLater(loader.ensure(), throwsStateError);
    expect(loader.isLoaded, isFalse);
    await loader.ensure();
    expect(loader.isLoaded, isTrue);
    expect(attempts, 2);
  });
}
