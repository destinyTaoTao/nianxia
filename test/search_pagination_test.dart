import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/search_page.dart';
import 'package:nianxia/domain/ports.dart';

import 'support/storage_probe.dart';

class PagingEmbedder implements Embedder {
  int calls = 0;
  @override
  Future<List<double>> embed(String text, {required bool query}) async {
    calls++;
    return [1, 0];
  }
}

Future<void> seedPaging(Notebook book, int count, {bool long = false}) async {
  withFixtureRepository(book, (repository) {
    final probe = repository.db;
    probe.execute('BEGIN');
    try {
      for (var i = 0; i < count; i++) {
        final id = '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
        final body = 'marker $i ${long ? List.filled(600, '长🔒').join() : ''}';
        probe.execute(
          'INSERT INTO records(id,parent_id,body,created_at,timezone,offset_minutes,revision,favorite,audio,duration_ms,transcript,transcription) VALUES(?,NULL,?,?,\'UTC\',0,1,0,NULL,0,NULL,\'none\')',
          [id, body, '2026-11-14T00:00:00.000Z'],
        );
      }
      probe.execute('COMMIT');
    } catch (_) {
      probe.execute('ROLLBACK');
      rethrow;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-search-paging-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });
  test(
    'tiePagesNoDuplicates and wideMatchesStayBounded for 10001 real rows',
    () async {
      await seedPaging(book, 10001, long: true);
      final query = SearchQuery(text: 'marker');
      SearchCursor? cursor;
      final ids = <String>[];
      var pages = 0;
      do {
        final page = await book.searchPage(query, after: cursor);
        expect(page.reset, isFalse);
        expect(page.entries.length, lessThanOrEqualTo(40));
        expect(utf8.encode(jsonEncode(page.toMap())).length, lessThan(70000));
        ids.addAll(page.entries.map((e) => e.id));
        cursor = page.next;
        pages++;
      } while (cursor != null);
      expect(ids.length, 10001);
      expect(ids.toSet().length, ids.length);
      expect(ids, [...ids]..sort());
      expect(pages, 251);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'editDeleteModelChangeResetsCursor and inference runs once per query',
    () async {
      await seedPaging(book, 90);
      final embedder = PagingEmbedder();
      final query = SearchQuery(text: 'marker');
      final first = await book.searchPage(query, embedder: embedder);
      expect(first.next, isNotNull);
      final second = await book.searchPage(
        query,
        after: first.next,
        embedder: embedder,
      );
      expect(second.entries, isNotEmpty);
      expect(embedder.calls, 1);
      await book.edit(
        first.entries.first.id,
        'edited marker',
        expectedRevision: 1,
      );
      expect(
        (await book.searchPage(
          query,
          after: second.next,
          embedder: embedder,
        )).reset,
        isTrue,
      );
      final again = await book.searchPage(query);
      await book.setSearchModelVersion('test-model-v2');
      expect((await book.searchPage(query, after: again.next)).reset, isTrue);
    },
  );
  test('cancelStopsFurtherPages without invoking inference again', () async {
    await seedPaging(book, 90);
    final token = SearchCancellation();
    final query = SearchQuery(text: 'marker');
    final first = await book.searchPage(query, cancellation: token);
    token.cancel();
    await expectLater(
      book.searchPage(query, after: first.next, cancellation: token),
      throwsA(isA<NotebookException>()),
    );
  });
  test(
    'cursor sorts mixed millisecond and microsecond timestamps chronologically',
    () async {
      await seedPaging(book, 3);
      final probe = StorageProbe(book);
      final times = [
        '2026-11-14T00:00:00.123Z',
        '2026-11-14T00:00:00.123001Z',
        '2026-11-14T00:00:00.122999Z',
      ];
      for (var i = 0; i < 3; i++) {
        probe.execute('UPDATE records SET created_at=? WHERE id=?', [
          times[i],
          '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
        ]);
      }
      final first = await book.searchPage(
        SearchQuery(text: 'marker'),
        limit: 1,
      );
      expect(first.entries.single.id, endsWith('000000000001'));
      final second = await book.searchPage(
        SearchQuery(text: 'marker'),
        after: first.next,
        limit: 1,
      );
      expect(second.entries.single.id, endsWith('000000000000'));
    },
  );
  test(
    'another notebook cannot delete an active search scratch owner',
    () async {
      await seedPaging(book, 90);
      await book.searchPage(SearchQuery(text: 'marker'));
      final active = (await Directory(
        '${home.path}/search-pages',
      ).list().toList()).whereType<Directory>().single;
      final second = await Notebook.open(home);
      try {
        await second.searchPage(SearchQuery(text: 'marker'));
        expect(await active.exists(), isTrue);
      } finally {
        await second.close();
      }
    },
  );
  test(
    'cancellation interrupts an in-flight worker and releases ranked rows',
    () async {
      await seedPaging(book, 5000, long: true);
      final token = SearchCancellation();
      final operation = book.searchPage(
        SearchQuery(text: 'marker'),
        cancellation: token,
      );
      final assertion = expectLater(
        operation,
        throwsA(isA<NotebookException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      await assertion;
      final retry = await book.searchPage(
        SearchQuery(text: 'marker'),
        limit: 1,
      );
      expect(retry.entries.length, 1);
    },
  );
  test('delete and changed query identity invalidate a prior cursor', () async {
    await seedPaging(book, 90);
    final query = SearchQuery(text: 'marker');
    final first = await book.searchPage(query);
    expect(
      (await book.searchPage(
        SearchQuery(text: 'other'),
        after: first.next,
      )).reset,
      isTrue,
    );
    final again = await book.searchPage(query);
    await book.delete(again.entries.first.id);
    expect((await book.searchPage(query, after: again.next)).reset, isTrue);
  });
  test(
    'semantic and keyword scoring reuse the legacy matching rules',
    () async {
      final keyword = await book.saveText('marker keyword');
      final semantic = await book.saveText('unrelated synthetic');
      final embedder = PagingEmbedder();
      await book.index(keyword.id, embedder);
      await book.index(semantic.id, embedder);
      final legacy = await book.search('marker', embedder: embedder);
      expect(legacy.map((e) => e.score), [3.0, 1.0]);
      final first = await book.searchPage(
        SearchQuery(text: 'marker'),
        embedder: embedder,
        limit: 1,
      );
      final calls = embedder.calls;
      final second = await book.searchPage(
        SearchQuery(text: 'marker'),
        embedder: embedder,
        after: first.next,
        limit: 1,
      );
      expect(first.entries.single.id, keyword.id);
      expect(first.entries.single.kind, MatchKind.keyword);
      expect(second.entries.single.id, semantic.id);
      expect(second.entries.single.kind, MatchKind.semantic);
      expect(embedder.calls, calls);
    },
  );
  test(
    'damaged rebuildable index still serves bounded source summaries',
    () async {
      await seedPaging(book, 90);
      await book.repository.waitForSearchIndex();
      await book.close();
      await File('${home.path}/search-index.sqlite')
          .writeAsString('synthetic damaged index');
      book = await Notebook.open(home);
      final page = await book.searchPage(SearchQuery(text: 'marker'));
      expect(page.entries.length, 40);
      expect(page.fallbackReason, isNotNull);
      expect((await book.records).length, 90);
    },
  );
  test('unavailable paging scratch is an understandable error and source remains readable', () async {
    await seedPaging(book, 10);
    await File('${home.path}/search-pages')
        .writeAsString('synthetic blocked scratch');
    await expectLater(
      book.searchPage(SearchQuery(text: 'marker')),
      throwsA(
        isA<NotebookException>().having(
          (e) => e.message,
          'safe query message',
          contains('查找暂不可用'),
        ),
      ),
    );
    expect((await book.records).length, 10);
    expect((await book.search('marker')).length, 10);
  });
}
