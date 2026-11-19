import 'dart:async';

import 'package:aseman/src/features/voice/live/transcribe_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folds chunks into one note in the order they were spoken', () async {
    final queue = TranscribeQueue();
    final first = Completer<String>();
    final second = Completer<String>();
    queue.enqueue(first.future);
    queue.enqueue(second.future);
    expect(queue.drained, isFalse);

    second.complete('world'); // comes back first, is used second
    await Future<void>.delayed(Duration.zero);
    expect(queue.accumulated, '');
    first.complete('hello');
    await Future<void>.delayed(Duration.zero);

    expect(queue.accumulated, 'hello world');
    expect(queue.drained, isTrue);
  });

  test('a failed or silent chunk contributes nothing', () async {
    final queue = TranscribeQueue();
    queue.enqueue(Future<String>.error(StateError('network')));
    queue.enqueue(Future.value(''));
    queue.enqueue(Future.value('still here'));
    await Future<void>.delayed(Duration.zero);
    expect(queue.accumulated, 'still here');
    expect(queue.drained, isTrue);
  });

  test('cancel drops what is queued and in flight', () async {
    final queue = TranscribeQueue();
    final slow = Completer<String>();
    queue.enqueue(slow.future);
    queue.cancel();
    expect(queue.drained, isTrue);

    queue.enqueue(Future.value('new turn'));
    slow.complete('stale');
    await Future<void>.delayed(Duration.zero);
    expect(queue.accumulated, 'new turn');
  });

  test('reset starts a new turn', () async {
    final queue = TranscribeQueue();
    queue.enqueue(Future.value('one'));
    await Future<void>.delayed(Duration.zero);
    queue.reset();
    expect(queue.accumulated, '');
  });
}
