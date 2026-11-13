import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/platform/local_models.dart';

void main() {
  test('关闭队列拒绝等待及新任务，不执行已排队的副作用', () async {
    final queue = InferenceQueue()..paused = true;
    var executed = false;
    final pending = queue.run(() async => executed = true);
    final rejected = expectLater(pending, throwsA(isA<NotebookException>()));
    queue.dispose();
    queue.paused = false;
    await rejected;
    await expectLater(
      queue.run(() async => 1),
      throwsA(isA<NotebookException>()),
    );
    expect(executed, isFalse);
  });

  test('关闭后在途任务可释放原生资源但不能交付迟到结果', () async {
    final queue = InferenceQueue();
    final native = Completer<int>();
    final pending = queue.run(() => native.future);
    final rejected = expectLater(pending, throwsA(isA<NotebookException>()));
    queue.dispose();
    native.complete(42);
    await rejected;
    queue.dispose();
  });

  test('暂停推理仍有背压，不允许无限积压任务', () async {
    final queue = InferenceQueue()..paused = true;
    final results = <Future<Object>>[];
    for (var i = 0; i < 200; i++) {
      results.add(
        queue
            .run(() async => i)
            .then<Object>((value) => value, onError: (Object error) => error),
      );
    }
    queue.paused = false;
    final completed = await Future.wait(results);
    expect(completed.whereType<NotebookException>(), isNotEmpty);
    expect(completed.whereType<int>(), isNotEmpty);
  });

  test('前台优先且失败不阻塞下一个任务', () async {
    final queue = InferenceQueue()..paused = true;
    final order = <String>[];
    final background = queue.run(
      () async => order.add('background'),
      foreground: false,
    );
    final failed = queue.run<void>(
      () async => throw const NotebookException('失败'),
    );
    final rejection = expectLater(failed, throwsA(isA<NotebookException>()));
    final foreground = queue.run(() async => order.add('foreground'));
    queue.paused = false;
    await Future.wait([background, foreground, rejection]);
    expect(order, ['foreground', 'background']);
  });
}
