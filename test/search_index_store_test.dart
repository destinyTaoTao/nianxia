import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/search_index.dart';
import 'package:nianxia/domain/record.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'concurrent keywords cannot bypass an unfinished overflow reconciliation',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'nianxia-overflow-index-',
      );
      final source = RecordRepository(home);
      final index = SearchIndex(source, home);
      Record record(String id, String body) => Record(
        id: id,
        body: body,
        createdAt: DateTime.utc(2026),
        timezone: 'UTC',
        offsetMinutes: 0,
      );
      try {
        source.insert(record('initial', '已有索引'));
        await index.search('索引', null, null, null, 'unversioned', null, false);
        await index.waitForIndexing();
        source.transaction(() {
          for (var i = 0; i < 4500; i++) {
            source.insert(
              record('new-${i.toString().padLeft(5, '0')}', '批量导入 $i'),
            );
          }
          source.insert(record('zz-tail', '尾部独特目标'));
        });
        final rebuilding = index.search(
          '批量',
          null,
          null,
          null,
          'unversioned',
          null,
          false,
        );
        await Future<void>.delayed(Duration.zero);
        final concurrent = index.search(
          '独特目标',
          null,
          null,
          null,
          'unversioned',
          null,
          false,
        );
        expect((await concurrent).single.record.id, 'zz-tail');
        expect(await rebuilding, hasLength(4500));
        await index.waitForIndexing();
        final cache = sqlite3.open(
          '${home.path}/search-index.sqlite',
          mode: OpenMode.readOnly,
        );
        try {
          final plan = cache
              .select(
                'EXPLAIN QUERY PLAN SELECT d.id FROM docs d WHERE d.dimension=? AND d.vector_key IS NOT NULL AND d.day>=? AND d.day<=? LIMIT 1025',
                [64, '2020-01-01', '2020-12-31'],
              )
              .map((r) => r['detail'])
              .join(' ');
          expect(
            plan,
            contains('day>?'),
            reason: 'narrow/empty date windows must seek by date instead of scanning a whole embedding dimension',
          );
          final paging = cache
              .select(
                'EXPLAIN QUERY PLAN SELECT d.id,d.body,d.day FROM docs d INDEXED BY docs_keyword_date WHERE d.day<=? AND (d.day,d.id)>(?,?) ORDER BY d.day,d.id LIMIT 64',
                ['2026-01-01', '2026-01-01', 'new-04000'],
              )
              .map((r) => r['detail'])
              .join(' ');
          expect(
            paging,
            contains('(day,id)>'),
            reason: 'later pages seek past the tuple cursor instead of rescanning earlier rows of the same day',
          );
        } finally {
          cache.close();
        }
      } finally {
        await index.close();
        source.close();
        await home.delete(recursive: true);
      }
    },
  );
  for (final failure in ['ABORT', 'ROLLBACK']) {
    test(
      '$failure cache maintenance retries from source without losing dirty edits',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'nianxia-index-fault-',
        );
        final source = RecordRepository(home);
        final index = SearchIndex(source, home);
        try {
          source.insert(
            Record(
              id: 'r',
              body: '旧正文',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
          await index.search('旧', null, null, null, 'unversioned', null, false);
          await index.waitForIndexing();
          final cache = sqlite3.open('${home.path}/search-index.sqlite');
          cache.execute(
            "CREATE TRIGGER fail_posting BEFORE INSERT ON postings BEGIN SELECT RAISE($failure,'fixture'); END",
          );
          source.edit('r', '新的正文', 1);
          final fallback = await index.search(
            '新的',
            null,
            null,
            null,
            'unversioned',
            null,
            false,
          );
          expect(fallback.single.record.body, '新的正文');
          expect(fallback.fallbackReason, isNotNull);
          cache.execute('DROP TRIGGER fail_posting');
          await index.waitForIndexing();
          expect(
            cache.select(
              'SELECT t.id FROM terms t LEFT JOIN postings p ON p.term=t.id GROUP BY t.id HAVING t.count<>count(p.doc)',
            ),
            isEmpty,
          );
          expect(cache.select('SELECT id FROM terms WHERE count<=0'), isEmpty);
          cache.close();
          expect(
            (await index.search(
              '新的',
              null,
              null,
              null,
              'unversioned',
              null,
              false,
            )).single.record.id,
            'r',
          );
          expect(
            await index.search(
              '旧',
              null,
              null,
              null,
              'unversioned',
              null,
              false,
            ),
            isEmpty,
          );
        } finally {
          await index.close();
          source.close();
          await home.delete(recursive: true);
        }
      },
    );
  }
  test('a removed embedding can return to the same value without reusing a tombstone', () async {
    final home = await Directory.systemTemp.createTemp(
      'nianxia-index-replace-',
    );
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    try {
      source.insert(
        Record(
          id: 'r',
          body: '记录',
          createdAt: DateTime.utc(2026),
          timezone: 'UTC',
          offsetMinutes: 0,
        ),
      );
      source.embedding('r', 1, [1, 0]);
      expect(
        await index.search(
          '不同表述',
          null,
          null,
          [1, 0],
          'unversioned',
          null,
          true,
        ),
        hasLength(1),
      );
      await index.waitForIndexing();
      source.db.execute('DELETE FROM record_embeddings WHERE record_id=?', [
        'r',
      ]);
      expect(
        await index.search(
          '不同表述',
          null,
          null,
          [1, 0],
          'unversioned',
          null,
          true,
        ),
        isEmpty,
      );
      source.embedding('r', 1, [1, 0]);
      expect(
        await index.search(
          '不同表述',
          null,
          null,
          [1, 0],
          'unversioned',
          null,
          true,
        ),
        hasLength(1),
      );
    } finally {
      await index.close();
      source.close();
      await home.delete(recursive: true);
    }
  });
  test('selective keyword lookup visits postings, not the entire library', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-index-');
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    try {
      source.transaction(() {
        for (var i = 0; i < 3000; i++) {
          source.insert(
            Record(
              id: '$i',
              body: i == 17 ? '独特检索：中文，ＡＢＣ！' : '普通想法 $i',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
        }
      });
      var hits = await index.search(
        '中文',
        null,
        null,
        null,
        'unversioned',
        null,
        false,
      );
      expect(hits.map((h) => h.record.id), ['17']);
      await index.waitForIndexing();
      hits = await index.search(
        '中文',
        null,
        null,
        null,
        'unversioned',
        null,
        false,
      );
      expect(index.keywordCandidates, lessThan(30));
      expect(index.sourceRecordsRead, lessThan(30));
      final dated = await index.search(
        '普',
        DateTime(2026),
        DateTime(2026, 1, 1),
        null,
        'unversioned',
        null,
        false,
      );
      expect(
        dated.length,
        2999,
        reason:
            'date-priority keyset paging preserves every exact keyword result',
      );
      expect(
        await index.search(
          '普',
          DateTime(2020),
          DateTime(2020, 12, 31),
          null,
          'unversioned',
          null,
          false,
        ),
        isEmpty,
      );
      expect(
        index.keywordCandidates,
        0,
        reason:
            'an empty date range should not read common-character candidates',
      );
      hits = await index.search(
        'abc',
        null,
        null,
        null,
        'unversioned',
        null,
        false,
      );
      expect(hits.single.record.id, '17');
      expect(
        index.reconciledRecords,
        0,
        reason: 'warm query must not rescan source',
      );
      source.edit('17', '改成全新内容', 1);
      expect(
        await index.search('中文', null, null, null, 'unversioned', null, false),
        isEmpty,
      );
      expect(
        (await index.search(
          '全新',
          null,
          null,
          null,
          'unversioned',
          null,
          false,
        )).single.record.id,
        '17',
      );
      expect(index.reconciledRecords, lessThan(5));
    } finally {
      await index.close();
      source.close();
      await home.delete(recursive: true);
    }
  });
}
