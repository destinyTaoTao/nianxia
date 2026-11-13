import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/storage.dart';
import 'package:nianxia/domain/record.dart';

void main() {
  late Directory home;
  setUp(
    () async => home = await Directory.systemTemp.createTemp('storage-actor-'),
  );
  tearDown(() async => home.delete(recursive: true));

  test('首页游标在相同时间下不重不漏，仅返回有界摘要和准确追加数', () async {
    final raw = RecordRepository(home);
    raw.transaction(() {
      for (var i = 0; i < 85; i++) {
        raw.insert(
          Record(
            id: 'note-${i.toString().padLeft(3, '0')}',
            body: '正文' * 1000,
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
            favorite: i == 0,
          ),
        );
      }
      raw.insert(
        Record(
          id: 'child',
          parentId: 'note-000',
          body: '追加',
          createdAt: DateTime.utc(2026),
          timezone: 'UTC',
          offsetMinutes: 0,
        ),
      );
    });
    raw.close();
    final storage = await Storage.open(home);
    try {
      var page = await storage.page();
      expect(page.entries.length, 40);
      expect(page.entries.first.record.id, 'note-000');
      expect(page.entries.first.appendCount, 1);
      expect(page.entries.first.record.body.length, lessThanOrEqualTo(600));
      expect((await storage.get('note-000'))!.body.length, 2000);
      final ids = page.entries.map((e) => e.record.id).toList();
      while (page.next != null) {
        page = await storage.page(
          after: page.next,
          generation: page.generation,
        );
        ids.addAll(page.entries.map((e) => e.record.id));
      }
      expect(ids.length, 85);
      expect(ids.toSet().length, 85);
      expect(
        (await storage.page(favorites: true)).entries.single.record.id,
        'note-000',
      );
    } finally {
      await storage.close();
    }
  });

  test('游标跨原文变更时返回重置页，不拼接两代列表', () async {
    final storage = await Storage.open(home);
    try {
      for (var i = 0; i < 41; i++) {
        await storage.insert(
          Record(
            id: '$i',
            body: '原文',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
      }
      final first = await storage.page();
      await storage.delete(first.entries.first.record.id);
      final next = await storage.page(
        after: first.next,
        generation: first.generation,
      );
      expect(next.reset, isTrue);
      expect(next.entries.length, 40);
      expect(
        next.entries.any((e) => e.record.id == first.entries.first.record.id),
        isFalse,
      );
    } finally {
      await storage.close();
    }
  });

  test('关闭排空已接收写入，幂等释放，并拒绝新请求', () async {
    final storage = await Storage.open(home);
    final write = storage.insert(
      Record(
        id: 'kept',
        body: '保留内容',
        createdAt: DateTime.utc(2026),
        timezone: 'UTC',
        offsetMinutes: 0,
      ),
    );
    final closing = storage.close();
    await write;
    await closing;
    await storage.close();
    await expectLater(storage.get('kept'), throwsA(isA<NotebookException>()));
    final reopened = await Storage.open(home);
    try {
      expect((await reopened.get('kept'))!.body, '保留内容');
    } finally {
      await reopened.close();
    }
  });

  test('数据库快照在专用isolate执行，调用方定时器可继续运行', () async {
    final raw = RecordRepository(home);
    raw.transaction(() {
      for (var i = 0; i < 20000; i++) {
        raw.insert(
          Record(
            id: '$i',
            body: '资料' * 100,
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
      }
    });
    raw.close();
    final storage = await Storage.open(home);
    var ticks = 0;
    final pulse = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    try {
      await storage.snapshotTo('${home.path}/snapshot.sqlite');
      expect(ticks, greaterThan(0));
      expect(
        await File('${home.path}/snapshot.sqlite').length(),
        greaterThan(1000000),
      );
    } finally {
      pulse.cancel();
      await storage.close();
    }
  });
}
