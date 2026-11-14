import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/platform/local_models.dart';

void main() {
  test(
    'closeWaitsForNativeRelease even after pending caller is rejected',
    () async {
      final queue = InferenceQueue();
      final entered = Completer<void>();
      final release = Completer<void>();
      var freed = false;
      final active = queue.run(() async {
        entered.complete();
        try {
          await release.future;
          return 1;
        } finally {
          freed = true;
        }
      });
      final rejection = expectLater(active, throwsA(isA<NotebookException>()));
      await entered.future;
      var closed = false;
      final closing = queue.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(freed, isFalse);
      release.complete();
      await closing;
      await rejection;
      expect(freed, isTrue);
    },
  );
  test('capturePriorityPausesQueuedWork and preserves foreground ordering on resume', () async {
    final queue = InferenceQueue();
    queue.paused = true;
    final order = <int>[];
    final background = queue.run(() async => order.add(2), foreground: false);
    final foreground = queue.run(() async => order.add(1));
    await Future<void>.delayed(Duration.zero);
    expect(order, isEmpty);
    queue.paused = false;
    await Future.wait([foreground, background]);
    expect(order, [1, 2]);
    await queue.close();
  });
}
