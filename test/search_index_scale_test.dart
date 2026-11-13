import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/record_search_store.dart';
import 'package:nianxia/data/search_index.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/domain/semantic_vector.dart';

void main() {
  test('10k persistent vectors: recall, selective postings, warm reopen', () async {
    const size = 10000, dimensions = 64;
    final home = await Directory.systemTemp.createTemp('nianxia-search-scale-');
    var source = RecordRepository(home);
    var index = SearchIndex(source, home);
    final random = Random(60261);
    List<double> noise() =>
        List.generate(dimensions, (_) => random.nextDouble() * 2 - 1);
    final centers = List.generate(40, (_) => unitVector(noise()));
    List<double> near(List<double> center) => unitVector([
      for (final v in center) v + (random.nextDouble() * 2 - 1) * .035,
    ]);
    final vectors = <List<double>>[];
    String id(int n) => n.toString().padLeft(6, '0');
    try {
      source.ensureIndexVersion('scale64-v1');
      source.transaction(() {
        for (var i = 0; i < size; i++) {
          final vector = near(centers[i % centers.length]);
          vectors.add(vector);
          source.insert(
            Record(
              id: id(i),
              body: i == 17 ? '特殊尾部灵感，中文关键词。' : '第$i条普通记录，保留本地灵感。',
              createdAt: DateTime.utc(2026, 1, 1),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
          expect(source.embedding(id(i), 1, vector), isTrue);
        }
      });
      final cold = Stopwatch()..start();
      expect(
        (await index.search(
          '尾部灵感',
          null,
          null,
          null,
          'scale64-v1',
          null,
          false,
        )).single.record.id,
        id(17),
      );
      cold.stop();
      final graphBuild = Stopwatch()..start();
      var graphDone = false;
      final building = index.waitForIndexing().then((_) {
        graphDone = true;
      });
      await Future<void>.delayed(Duration.zero);
      final concurrent = await index.search(
        '尾部',
        null,
        null,
        null,
        'scale64-v1',
        null,
        false,
      );
      expect(concurrent.single.record.id, id(17));
      expect(
        graphDone,
        isFalse,
        reason: 'keyword query must not wait for graph construction',
      );
      await building;
      await index.waitForIndexing();
      graphBuild.stop();
      final linear = <int>[], indexed = <int>[];
      for (var trial = 0; trial < 10; trial++) {
        final q = trial.isEven ? '尾部' : '尾部灵感';
        var watch = Stopwatch()..start();
        final exact = await RecordSearchStore(source)
            .scan(q, null, null, null, 'scale64-v1', null, false);
        linear.add(watch.elapsedMicroseconds);
        watch = Stopwatch()..start();
        final found = await index.search(
          q,
          null,
          null,
          null,
          'scale64-v1',
          null,
          false,
        );
        indexed.add(watch.elapsedMicroseconds);
        expect(found.map((h) => h.record.id), exact.map((h) => h.record.id));
        expect(index.keywordCandidates, lessThan(size * .01));
        expect(index.sourceRecordsRead, lessThan(size * .01));
        expect(index.reconciledRecords, 0);
      }
      var recalled = 0, distances = 0;
      final semanticTimes = <int>[];
      for (var trial = 0; trial < 12; trial++) {
        final q = near(centers[(trial * 7) % centers.length]);
        double cosine(List<double> vector) {
          var sum = 0.0;
          for (var n = 0; n < dimensions; n++) {
            sum += q[n] * vector[n];
          }
          return sum;
        }

        final exact = List.generate(size, (i) => (id(i), cosine(vectors[i])))
          ..sort((a, b) => b.$2.compareTo(a.$2));
        final gold = exact.take(10).map((v) => v.$1).toSet();
        final watch = Stopwatch()..start();
        final found = await index.search(
          '另外一种含义',
          null,
          null,
          q,
          'scale64-v1',
          null,
          true,
        );
        semanticTimes.add(watch.elapsedMicroseconds);
        recalled += found
            .take(10)
            .where((h) => gold.contains(h.record.id))
            .length;
        distances += index.distanceEvaluations;
        expect(found.semanticUsed, isTrue);
        expect(found.semanticApproximate, isTrue);
        expect(found.fallbackReason, isNull);
        expect(found.length, lessThanOrEqualTo(128));
        expect(found.every((h) => h.record.vector == null), isTrue);
        expect(index.reconciledRecords, 0);
        expect(index.sourceRecordsRead, lessThanOrEqualTo(128));
      }
      expect(recalled / 120, greaterThanOrEqualTo(.95));
      expect(distances / 12, lessThan(size * .35));
      await index.close();
      source.close();
      source = RecordRepository(home);
      index = SearchIndex(source, home);
      final reopen = Stopwatch()..start();
      expect(
        (await index.search(
          '尾部',
          null,
          null,
          null,
          'scale64-v1',
          null,
          false,
        )).single.record.id,
        id(17),
      );
      reopen.stop();
      source.insert(
        Record(
          id: 'new',
          body: '新向量',
          createdAt: DateTime.utc(2026),
          timezone: 'UTC',
          offsetMinutes: 0,
        ),
      );
      source.embedding('new', 1, centers.first);
      expect(
        (await index.search(
          '新含义',
          null,
          null,
          centers.first,
          'scale64-v1',
          null,
          true,
        )).first.record.id,
        'new',
      );
      expect(index.reconciledRecords, lessThan(5));
      await index.close();
      var bytes = 0;
      await for (final file in home.list()) {
        if (file is File && file.path.contains('search-index.sqlite')) {
          bytes += await file.length();
        }
      }
      linear.sort();
      indexed.sort();
      semanticTimes.sort();
      // Synthetic host fixtures; neither device latency nor language quality.
      // ignore: avoid_print
      print(
        'Indexed search host 10k/64D: keyword cold=${cold.elapsedMilliseconds}ms, graph first=${graphBuild.elapsedMilliseconds}ms, reopen=${reopen.elapsedMilliseconds}ms, cache=$bytes bytes, keyword scan/index p95=${linear[9] / 1000}/${indexed[9] / 1000}ms, semantic p95=${semanticTimes[11] / 1000}ms, Recall@10=${recalled / 120}, mean distances=${distances / 12}',
      );
    } finally {
      await index.close();
      source.close();
      await home.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
