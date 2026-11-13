import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/search_index.dart';
import 'package:nianxia/domain/record.dart';

void main() {
  test(
    'ANN reranking bounds source SQL while preserving complete result records',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'nianxia-candidate-batch-',
      );
      final source = RecordRepository(home);
      final index = SearchIndex(source, home);
      try {
        source.ensureIndexVersion('batch-fixture');
        source.transaction(() {
          for (var i = 0; i < 160; i++) {
            final id = 'r${i.toString().padLeft(3, '0')}';
            source.insert(
              Record(
                id: id,
                body: '已归档记录$i',
                createdAt: DateTime.utc(2026),
                timezone: 'UTC',
                offsetMinutes: 0,
                favorite: i.isEven,
                transcript: '原始转写$i',
              ),
            );
            source.embedding(id, 1, [1, 0]);
            source.derived(id, 1, {'title': '标题$i', 'points': [], 'tasks': []});
          }
        });
        await index.waitForIndexing();
        var statements = 0;
        source.db.trace = SqliteTraceCallback(
          (event) {
            if (event is SqliteTraceStatement &&
                event.sql?.trimLeft().startsWith('SELECT') == true) {
              statements++;
            }
            return 0;
          },
          row: false,
          profile: false,
        );
        final found = await index.search(
          '完全不同表达',
          null,
          null,
          [1, 0],
          'batch-fixture',
          null,
          true,
        );
        source.db.trace = null;
        expect(found, hasLength(128));
        expect(found.semanticApproximate, isTrue);
        // Frozen pre-batch result order: all scores and creation times tie.
        expect(
          sha256
              .convert(utf8.encode(found.map((hit) => hit.record.id).join('|')))
              .toString(),
          '066d8338711cab8b599349c531d745bbca06e1fab537c045477404fb60f01bb3',
        );
        for (final hit in found) {
          final expected = source.get(hit.record.id)!;
          expect(hit.record.toJson(), expected.toJson());
          expect(hit.record.vectorRevision, expected.vectorRevision);
          expect(hit.record.vector, isNull);
          expect(hit.score, 1.0);
        }
        expect(statements, greaterThan(0));
        expect(
          statements,
          lessThanOrEqualTo(40),
          reason: '128 ANN candidates must use bounded source batches instead of per-record model lookups',
        );
      } finally {
        source.db.trace = null;
        await index.close();
        source.close();
        home.deleteSync(recursive: true);
      }
    },
  );
  test(
    'full record batches preserve metadata and isolate vector mutations',
    () {
      final home = Directory.systemTemp.createTempSync('nianxia-full-batch-');
      final source = RecordRepository(home);
      try {
        source.insert(
          Record(
            id: 'a',
            body: '正文',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
            transcript: '原始转写',
            favorite: true,
          ),
        );
        source.embedding('a', 1, [1, 0]);
        source.derived('a', 1, {'title': '标题', 'points': [], 'tasks': []});
        expect(source.getBatch([]), isEmpty);
        expect(
          () => source.getBatch(List.filled(65, 'a')),
          throwsArgumentError,
        );
        final batch = source.getBatch(['missing', 'a']);
        expect(batch, hasLength(1));
        expect(batch.single.toJson(), source.get('a')!.toJson());
        expect(batch.single.vector, orderedEquals([1, 0]));
        batch.single.vector![0] = 0;
        expect(source.get('a')!.vector, orderedEquals([1, 0]));
      } finally {
        source.close();
        home.deleteSync(recursive: true);
      }
    },
  );

  test('ambiguous cached candidate keys fall back and rebuild without hiding source', () async {
    final home = Directory.systemTemp.createTempSync('nianxia-batch-corrupt-');
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    try {
      source.ensureIndexVersion('batch-fixture');
      for (final id in ['a', 'b']) {
        source.insert(
          Record(
            id: id,
            body: '原文$id',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
        source.embedding(id, 1, id == 'a' ? [1, 0] : [0, 1]);
      }
      await index.waitForIndexing();
      final cache = sqlite3.open('${home.path}/search-index.sqlite');
      cache.execute(
        "UPDATE docs SET vector_key=(SELECT vector_key FROM docs WHERE id='a') WHERE id='b'",
      );
      cache.close();
      final fallback = await index.search(
        '完全不同表达',
        null,
        null,
        [1, 0],
        'batch-fixture',
        null,
        true,
      );
      expect(fallback.single.record.id, 'a');
      expect(fallback.fallbackReason, contains('重建'));
      expect(source.get('b')!.body, '原文b');
      await index.waitForIndexing();
      final rebuilt = await index.search(
        '完全不同表达',
        null,
        null,
        [1, 0],
        'batch-fixture',
        null,
        true,
      );
      expect(rebuilt.single.record.id, 'a');
      expect(rebuilt.fallbackReason, isNull);
    } finally {
      await index.close();
      source.close();
      home.deleteSync(recursive: true);
    }
  });
}
