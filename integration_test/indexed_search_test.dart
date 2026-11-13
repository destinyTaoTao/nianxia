// Native SQLite + the installed offline BGE model. No recording or network.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/test_sandbox.dart';
import '../test/vector_bit_patterns_test.dart' as vector_bits;
import '../test/search_candidate_batch_test.dart' as candidate_batches;

void main() {
  requireModelTestSandbox();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  vector_bits.main();
  candidate_batches.main();
  testWidgets('原生同日日期关键词分页使用tuple索引，不漏记录', (tester) async {
    final home = await Directory.systemTemp.createTemp('native-search-date-');
    final book = await Notebook.open(home);
    try {
      final source = RecordRepository(home);
      try {
        source.transaction(() {
          for (var i = 0; i < 1000; i++) {
            source.insert(
              Record(
                id: 'fixture-${i.toString().padLeft(4, '0')}',
                body: '普遍日期记录 $i',
                createdAt: DateTime.utc(2026),
                timezone: 'UTC',
                offsetMinutes: 0,
              ),
            );
          }
        });
      } finally {
        source.close();
      }
      expect(
        await book.search('普', from: DateTime(2026), to: DateTime(2026, 1, 1)),
        hasLength(1000),
      );
      expect(
        await book.search('普', from: DateTime(2020), to: DateTime(2020, 1, 1)),
        isEmpty,
      );
      final cache = sqlite3.open(
        '${home.path}/search-index.sqlite',
        mode: OpenMode.readOnly,
      );
      try {
        final plan = cache
            .select(
              'EXPLAIN QUERY PLAN SELECT d.id,d.body,d.day FROM docs d INDEXED BY docs_keyword_date WHERE d.day<=? AND (d.day,d.id)>(?,?) ORDER BY d.day,d.id LIMIT 64',
              ['2026-01-01', '2026-01-01', 'fixture-0500'],
            )
            .map((r) => r['detail'])
            .join(' ');
        expect(plan, contains('(day,id)>'));
      } finally {
        cache.close();
      }
    } finally {
      await book.close();
      await home.delete(recursive: true);
    }
  });
  testWidgets('原生离线BGE通过持久化索引检索，损坏后可恢复', (tester) async {
    await tester.runAsync(() async {
      final home = await Directory.systemTemp.createTemp(
        'native-indexed-search-',
      );
      final store = ModelStore(
        Directory('/data/local/tmp/nianxia-models'),
        ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
      );
      final models = LocalModels(store);
      var book = await Notebook.open(home);
      try {
        expect(
          await store.ready('bge'),
          isTrue,
          reason: 'Stage trusted offline model fixtures first',
        );
        var networkAttempts = 0;
        await HttpOverrides.runZoned(
          () async {
            await book.setSearchModelVersion('native-bge-indexed-v1');
            final target = await book.saveText('给数据库建立索引，可以加快查询速度。');
            final other = await book.saveText('周末准备去公园散步。');
            final keyword = await book.saveText('中文检索：ＳＱＬｉｔｅ 与标点Ａ＋Ｂ。');
            await book.index(target.id, models);
            await book.index(other.id, models);
            final first = await book.search('怎样优化数据库的查询性能', embedder: models);
            expect(first.first.record.id, target.id);
            expect(first.semanticUsed, isTrue);
            expect(first.pendingSemanticRecords, greaterThan(0));
            await book.repository.waitForSearchIndex();
            expect(
              (await book.search(
                '怎样优化数据库的查询性能',
                embedder: models,
              )).semanticApproximate,
              isTrue,
            );
            expect(await book.search('月球上的火山如何喷发', embedder: models), isEmpty);
            for (final q in ['文', '中文', 'sqlite', 'a+b']) {
              final hits = await book.search(q);
              expect(hits.any((h) => h.record.id == keyword.id), isTrue);
            }
            await book.close();
            book = await Notebook.open(home);
            expect(
              (await book.search(
                '怎样优化数据库的查询性能',
                embedder: models,
              )).first.record.id,
              target.id,
            );
            await book.close();
            final cache = sqlite3.open('${home.path}/search-index.sqlite');
            cache.execute("UPDATE nodes SET neighbors='{}'");
            cache.close();
            book = await Notebook.open(home);
            expect(
              (await book.search('数据库', embedder: models)).first.record.id,
              target.id,
            );
            await book.repository.waitForSearchIndex();
            final rebuilt = await book.search('怎样优化数据库的查询性能', embedder: models);
            expect(rebuilt.first.record.id, target.id);
            expect(rebuilt.fallbackReason, isNull);
            expect((await book.records).length, 3);
          },
          createHttpClient: (_) {
            networkAttempts++;
            throw StateError('Offline test: HTTP forbidden');
          },
        );
        expect(networkAttempts, 0);
      } finally {
        await book.close();
        store.dispose();
        await home.delete(recursive: true);
      }
    });
  });
}
