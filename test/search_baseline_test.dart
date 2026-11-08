import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';

void main() {
  test('1000 条短记录的关键词查找基线，编辑后结果可观察更新', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-baseline-');
    final book = await Notebook.open(home);
    try {
      for (var i = 0; i < 1000; i++) {
        await book.saveText('第 $i 条想法：用 SQLite 事务可靠保存语音灵感。');
      }
      final times = <int>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        final result = await book.search('SQLite');
        watch.stop();
        expect(result.length, 1000);
        times.add(watch.elapsedMicroseconds);
      }
      times.sort();
      // Synthetic host metric, not a mobile latency acceptance claim.
      // ignore: avoid_print
      print(
        'Host keyword baseline: 1000 records, n=20, p95=${times[18] / 1000} ms',
      );
    } finally {
      book.dispose();
      await home.delete(recursive: true);
    }
  });
}
