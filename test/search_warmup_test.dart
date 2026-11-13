import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/search_index.dart';

import 'dart:typed_data';

import 'package:nianxia/data/compact_graph_store.dart';
import 'package:nianxia/data/hnsw.dart';
import 'package:nianxia/domain/record.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'continuous same-model embedding writes do not starve cold semantic query',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'nianxia-derived-query-',
      );
      final source = RecordRepository(home);
      final index = SearchIndex(source, home);
      Timer? writes;
      try {
        source.transaction(() {
          for (var n = 0; n < 5000; n++) {
            source.insert(
              Record(
                id: n.toString().padLeft(5, '0'),
                body: '已有原始资料 $n',
                createdAt: DateTime.utc(2026),
                timezone: 'UTC',
                offsetMinutes: 0,
              ),
            );
            source.embedding(n.toString().padLeft(5, '0'), 1, [1, 0]);
          }
        });
        writes = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => source.embedding('00000', 1, [1, 0]),
        );
        final found = await index
            .search('另一种表达', null, null, [1, 0], 'unversioned', null, true)
            .timeout(const Duration(seconds: 1));
        expect(found, hasLength(128));
        expect(found.semanticUsed, isTrue);
      } finally {
        writes?.cancel();
        await index.close();
        source.close();
        await home.delete(recursive: true);
      }
    },
  );
  test('background compaction cannot clear graph under a paged semantic query', () async {
    final home = await Directory.systemTemp.createTemp(
      'nianxia-compaction-query-',
    );
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    Future<void>? maintenance;
    try {
      source.transaction(() {
        for (var n = 0; n < 200; n++) {
          source.insert(
            Record(
              id: n.toString().padLeft(5, '0'),
              body: '共同关键词 $n',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
        }
        source.insert(
          Record(
            id: 'semantic-only',
            body: '另一种表述',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
        source.embedding('semantic-only', 1, [1, 0]);
      });
      await index.waitForIndexing();
      final cache = sqlite3.open('${home.path}/search-index.sqlite');
      cache.execute('BEGIN');
      final store = CompactGraphStore(cache, 2);
      for (var n = 0; n < 1025; n++) {
        store.write(
          HnswNode(
            key: 'n${10000 + n}',
            vector: Float32List.fromList([1, 0]),
            neighbors: [[]],
            deleted: true,
          ),
        );
      }
      store.flush();
      store.close();
      cache.execute('COMMIT');
      cache.close();
      final finding = Completer<SearchResults>();
      var armed = true;
      source.db.trace = SqliteTraceCallback(
        (event) {
          if (armed &&
              event is SqliteTraceStatement &&
              (event.sql ?? '').startsWith('SELECT r.rowid AS source_rowid')) {
            armed = false;
            // Observe the real background dirty batch without reentering SQLite
            // from its callback. This microtask precedes the batch's timer yield.
            scheduleMicrotask(() async {
              try {
                finding.complete(
                  await index.search(
                    '共同关键词',
                    null,
                    null,
                    [1, 0],
                    'unversioned',
                    null,
                    true,
                  ),
                );
              } catch (error, stack) {
                finding.completeError(error, stack);
              }
            });
          }
          return 0;
        },
        row: false,
        profile: false,
      );
      source.favorite('00000', true);
      maintenance = index.waitForIndexing().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      final found = await finding.future.timeout(const Duration(seconds: 3));
      expect(found.any((hit) => hit.record.id == 'semantic-only'), isTrue);
      expect(found, hasLength(201));
      await maintenance;
      final checked = sqlite3.open(
        '${home.path}/search-index.sqlite',
        mode: OpenMode.readOnly,
      );
      try {
        expect(
          checked
              .select('SELECT count(*) AS n FROM nodes WHERE deleted=1')
              .single['n'],
          0,
        );
      } finally {
        checked.close();
      }
      expect(source.all(), hasLength(201));
    } finally {
      source.db.trace = null;
      await index.close();
      await maintenance;
      source.close();
      await home.delete(recursive: true);
    }
  });
  for (final oldVersion in [1, 2]) {
    test(
      'recognized v$oldVersion sidecar shrinks and rebuilds without changing source',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'nianxia-cache-upgrade-',
        );
        final source = RecordRepository(home);
        final index = SearchIndex(source, home);
        try {
          source.insert(
            Record(
              id: 'original',
              body: '保留中文原文',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
          final before = source.db
              .select('SELECT * FROM records')
              .map((r) => Map<String, Object?>.from(r))
              .toList();
          final cache = sqlite3.open('${home.path}/search-index.sqlite');
          // Frozen cache-v1 table names/layout. Cache-only upgrade never opens a
          // source migration and may discard these old derived rows.
          cache.execute('''
        CREATE TABLE docs(id TEXT PRIMARY KEY,source_rowid INTEGER UNIQUE,embedding_rowid INTEGER,signature TEXT NOT NULL,body TEXT NOT NULL,day TEXT NOT NULL,vector_key TEXT,dimension INTEGER);
        CREATE TABLE postings(term TEXT,doc ${oldVersion == 1 ? 'TEXT' : 'INTEGER'},PRIMARY KEY(term,doc)) WITHOUT ROWID;
        CREATE TABLE terms(term TEXT PRIMARY KEY,count INTEGER) WITHOUT ROWID;
        CREATE TABLE nodes(key TEXT PRIMARY KEY,dimension INTEGER,vector BLOB,neighbors TEXT,deleted INTEGER);
        CREATE TABLE entries(dimension INTEGER PRIMARY KEY,key TEXT);
        CREATE TABLE pending_vectors(id TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
        INSERT INTO postings VALUES ('2:旧词',${oldVersion == 1 ? "'old-cache-id'" : '123456'});
        PRAGMA user_version=1;
      ''');
          if (oldVersion == 2) {
            cache.execute(
              'PRAGMA user_version=2; PRAGMA application_id=1314411337',
            );
          }
          cache.execute(
            "INSERT INTO nodes VALUES ('old',512,zeroblob(33554432),'[[]]',0)",
          );
          cache.close();
          expect(
            File('${home.path}/search-index.sqlite').lengthSync(),
            greaterThan(32 * 1024 * 1024),
          );
          expect(
            (await index.search(
              '中文',
              null,
              null,
              null,
              'unversioned',
              null,
              false,
            )).single.record.id,
            'original',
          );
          await index.waitForIndexing();
          final upgraded = sqlite3.open(
            '${home.path}/search-index.sqlite',
            mode: OpenMode.readOnly,
          );
          try {
            expect(upgraded.userVersion, 3);
            expect(
              upgraded
                  .select(
                    'EXPLAIN QUERY PLAN SELECT slot FROM nodes WHERE dimension=? ORDER BY slot DESC LIMIT 1',
                    [512],
                  )
                  .map((r) => r['detail'])
                  .join(' '),
              contains('nodes_slot'),
            );
            expect(
              File('${home.path}/search-index.sqlite').lengthSync(),
              lessThan(1024 * 1024),
            );
            expect(
              upgraded
                  .select('SELECT DISTINCT typeof(term) AS kind FROM postings')
                  .single['kind'],
              'integer',
            );
            expect(
              upgraded
                  .select('SELECT DISTINCT typeof(doc) AS kind FROM postings')
                  .single['kind'],
              'integer',
            );
            expect(
              upgraded.select(
                "SELECT * FROM postings WHERE doc='old-cache-id'",
              ),
              isEmpty,
            );
          } finally {
            upgraded.close();
          }
          expect(
            source.db
                .select('SELECT * FROM records')
                .map((r) => Map<String, Object?>.from(r))
                .toList(),
            before,
          );
          expect(source.db.userVersion, 2);
        } finally {
          await index.close();
          source.close();
          await home.delete(recursive: true);
        }
      },
    );
  }
  test('cache symlink cannot write into original DB when both format numbers equal two', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-cache-alias-');
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    try {
      source.insert(
        Record(
          id: 'original',
          body: '原始资料不改写',
          createdAt: DateTime.utc(2026),
          timezone: 'UTC',
          offsetMinutes: 0,
        ),
      );
      await Link('${home.path}/search-index.sqlite')
          .create('${home.path}/records.sqlite');
      expect(
        (await index.search(
          '原始',
          null,
          null,
          null,
          'unversioned',
          null,
          false,
        )).single.record.id,
        'original',
      );
      expect(source.db.userVersion, 2);
      expect(
        source.db.select(
          "SELECT name FROM sqlite_master WHERE name='postings'",
        ),
        isEmpty,
      );
      expect(source.get('original')!.body, '原始资料不改写');
      expect(await Link('${home.path}/search-index.sqlite').exists(), isTrue);
    } finally {
      await index.close();
      source.close();
      await home.delete(recursive: true);
    }
  });
  test('external mutation during paged query cannot deadlock behind background priority', () async {
    final home = await Directory.systemTemp.createTemp(
      'nianxia-query-mutation-',
    );
    final source = RecordRepository(home);
    final index = SearchIndex(source, home);
    try {
      source.transaction(() {
        for (var n = 0; n < 2000; n++) {
          source.insert(
            Record(
              id: n.toString().padLeft(5, '0'),
              body: '共同关键词 $n',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
        }
      });
      await index.waitForIndexing();
      final finding = index.search(
        '共同关键词',
        null,
        null,
        null,
        'unversioned',
        null,
        false,
      );
      await Future<void>.delayed(Duration.zero);
      final external = sqlite3.open('${home.path}/records.sqlite');
      external.execute(
        "UPDATE records SET body='外部修订',revision=revision+1 WHERE id='01999'",
      );
      external.close();
      final found = await finding.timeout(const Duration(seconds: 2));
      expect(found, hasLength(1999));
      expect(found.any((h) => h.record.id == '01999'), isFalse);
    } finally {
      await index.close();
      source.close();
      await home.delete(recursive: true);
    }
  });
  test(
    'close drains an error fallback and its semantic workspace stays bounded',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'nianxia-fallback-close-',
      );
      final source = RecordRepository(home);
      final index = SearchIndex(source, home);
      var closedSource = false;
      try {
        source.transaction(() {
          for (var n = 0; n < 500; n++) {
            source.insert(
              Record(
                id: '$n',
                body: '原始资料 $n',
                createdAt: DateTime.utc(2026),
                timezone: 'UTC',
                offsetMinutes: 0,
              ),
            );
            source.embedding('$n', 1, [1, 0]);
          }
        });
        final futureCache = sqlite3.open('${home.path}/search-index.sqlite');
        futureCache.execute('PRAGMA user_version=999');
        futureCache.close();
        final finding = index.search(
          '其他表达',
          null,
          null,
          [1, 0],
          'unversioned',
          null,
          true,
        );
        await Future<void>.delayed(Duration.zero);
        await index.close();
        source.close();
        closedSource = true;
        expect(await finding, hasLength(128));
      } finally {
        await index.close();
        if (!closedSource) source.close();
        await home.delete(recursive: true);
      }
    },
  );
  test(
    'first semantic result includes pending vectors without draining the graph',
    () async {
      final home = await Directory.systemTemp.createTemp('nianxia-warmup-');
      final source = RecordRepository(home);
      var index = SearchIndex(source, home);
      try {
        source.transaction(() {
          for (var n = 0; n < 1000; n++) {
            final id = n.toString().padLeft(5, '0');
            source.insert(
              Record(
                id: id,
                body: '无公共词语 $n',
                createdAt: DateTime.utc(2026),
                timezone: 'UTC',
                offsetMinutes: 0,
              ),
            );
            source.embedding(id, 1, n == 999 ? [1, 0] : [0, 1]);
          }
        });
        final found = await index.search(
          '另一种含义',
          null,
          null,
          [1, 0],
          'unversioned',
          null,
          true,
        );
        expect(found.single.record.id, '00999');
        expect(found.pendingSemanticRecords, 1000);
        final cache = sqlite3.open(
          '${home.path}/search-index.sqlite',
          mode: OpenMode.readOnly,
        );
        try {
          expect(
            cache.select('SELECT count(*) AS n FROM docs').single['n'],
            lessThan(1000),
            reason:
                'first result must not wait for the text sidecar build either',
          );
        } finally {
          cache.close();
        }
        await index.close();
        index = SearchIndex(source, home);
        expect(
          (await index.search(
            '另一种含义',
            null,
            null,
            [1, 0],
            'unversioned',
            null,
            true,
          )).single.record.id,
          '00999',
        );
        source.db.execute('DELETE FROM records WHERE id=?', ['00999']);
        expect(
          await index.search(
            '另一种含义',
            null,
            null,
            [1, 0],
            'unversioned',
            null,
            true,
          ),
          isEmpty,
        );
        expect(source.all(), hasLength(999));
      } finally {
        await index.close();
        source.close();
        await home.delete(recursive: true);
      }
    },
  );
}
