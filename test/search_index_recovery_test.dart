import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/storage_probe.dart';

class _OfflineVector implements Embedder {
  @override
  Future<List<double>> embed(String text, {required bool query}) async => [
    1,
    0,
  ];
}

void main() {
  final corruptions = <String, String>{
    'object in place of layers': "UPDATE nodes SET neighbors='{}'",
    'non-list layer': "UPDATE nodes SET neighbors='[1]'",
    'non-string link': "UPDATE nodes SET neighbors='[[1]]'",
    'zero vector': 'UPDATE vector_blocks SET payload=zeroblob(length(payload))',
    'missing entry node': 'DELETE FROM nodes WHERE id IN (SELECT CAST(substr(key,2) AS INTEGER) FROM entries)',
    'missing entry pointer': 'DELETE FROM entries',
  };
  for (final fault in corruptions.entries) {
    test('damaged derived graph recovers: ${fault.key}', () async {
      final home = await Directory.systemTemp.createTemp(
        'nianxia-graph-fault-',
      );
      var book = await Notebook.open(home);
      try {
        final record = await book.saveText('本地原始正文');
        await book.index(record.id, _OfflineVector());
        expect(
          await book.search('另一种说法', embedder: _OfflineVector()),
          hasLength(1),
        );
        await book.repository.waitForSearchIndex();
        final raw = StorageProbe(book).select('SELECT * FROM records');
        final vectors = StorageProbe(book).select(
          'SELECT record_id,source_revision,hex(payload) FROM record_embeddings',
        );
        await book.close();
        final cache = sqlite3.open('${home.path}/search-index.sqlite');
        cache.execute(fault.value);
        cache.close();
        book = await Notebook.open(home);
        final fallback = await book.search('本地', embedder: _OfflineVector());
        expect(fallback.single.record.id, record.id);
        await book.repository.waitForSearchIndex();
        // First query may use a verified source fallback; the next one must
        // actually return to indexed search, not silently scan forever.
        final recovered = await book.search(
          '另一种说法',
          embedder: _OfflineVector(),
        );
        expect(recovered.single.record.id, record.id);
        expect(recovered.fallbackReason, isNull);
        expect(recovered.semanticApproximate, isTrue);
        expect(StorageProbe(book).select('SELECT * FROM records'), raw);
        expect(
          StorageProbe(book).select(
            'SELECT record_id,source_revision,hex(payload) FROM record_embeddings',
          ),
          vectors,
        );
      } finally {
        await book.close();
        await home.delete(recursive: true);
      }
    });
  }
  for (final version in [999, 2]) {
    test(
      'unknown or future sidecar v$version is preserved and source remains searchable offline',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'nianxia-future-search-',
        );
        var book = await Notebook.open(home);
        try {
          final record = await book.saveText('离线中文关键词');
          await book.close();
          final path = '${home.path}/search-index.sqlite';
          final cache = sqlite3.open(path);
          cache.execute(
            'PRAGMA application_id=1314411337;PRAGMA user_version=$version;CREATE TABLE future_data(value TEXT);INSERT INTO future_data VALUES (\'preserve\')',
          );
          cache.close();
          final before = await File(path).readAsBytes();
          book = await Notebook.open(home);
          var attempts = 0;
          final found = await HttpOverrides.runZoned(
            () => book.search('中文'),
            createHttpClient: (_) {
              attempts++;
              throw StateError('Network forbidden');
            },
          );
          expect(found.single.record.id, record.id);
          expect(found.fallbackReason, isNotNull);
          expect(attempts, 0);
          expect(await File(path).readAsBytes(), before);
        } finally {
          await book.close();
          await home.delete(recursive: true);
        }
      },
    );
  }
  test(
    'offline semantic path makes no HTTP requests and respects narrow dates',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'nianxia-date-search-',
      );
      final book = await Notebook.open(home);
      try {
        final source = RecordRepository(home);
        try {
          source.transaction(() {
            for (var i = 0; i < 300; i++) {
              source.insert(
                Record(
                  id: 'fixture-$i',
                  body: '另一种描述 $i',
                  createdAt: DateTime.utc(i == 299 ? 2020 : 2026),
                  timezone: 'UTC',
                  offsetMinutes: 0,
                ),
              );
              source.embedding('fixture-$i', 1, i == 299 ? [.8, .6] : [1, 0]);
            }
          });
        } finally {
          source.close();
        }
        var attempts = 0;
        final found = await HttpOverrides.runZoned(
          () => book.search(
            '未出现的语句',
            from: DateTime(2020),
            to: DateTime(2020, 12, 31),
            embedder: _OfflineVector(),
          ),
          createHttpClient: (_) {
            attempts++;
            throw StateError('Network forbidden');
          },
        );
        expect(found.single.record.id, 'fixture-299');
        expect(found.semanticApproximate, isFalse);
        expect(attempts, 0);
      } finally {
        await book.close();
        await home.delete(recursive: true);
      }
    },
  );
}
