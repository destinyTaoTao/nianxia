import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/hnsw.dart';

void main() {
  test(
    'cosine keeps double accumulation accuracy for odd and dense dimensions',
    () {
      for (final dimensions in [1, 3, 7, 511, 512]) {
        final random = Random(618 + dimensions);
        final store = _MemoryStore(dimensions);
        final index = HnswIndex(store);
        final query = _randomVector(random, dimensions);
        index.add('query', query);
        final normalized = store.read('query')!.vector;
        for (var n = 0; n < 12; n++) {
          index.add('v$n', _randomVector(random, dimensions));
        }
        final hits = index.search(query, limit: 13, ef: 20).matches;
        expect(hits, hasLength(13));
        for (final hit in hits) {
          final vector = store.read(hit.key)!.vector;
          var dot = 0.0;
          for (var i = 0; i < dimensions; i++) {
            dot += normalized[i] * vector[i];
          }
          expect(hit.cosine, closeTo(dot.clamp(-1.0, 1.0), 1e-12));
        }
      }
    },
  );
  test(
    'upper-layer beam escapes a greedy local minimum before lower routing',
    () {
      final store = _MemoryStore(3);
      void add(String key, List<double> vector, List<List<String>> links) =>
          store.write(
            HnswNode(
              key: key,
              vector: Float32List.fromList(vector),
              neighbors: links,
            ),
          );
      add(
        'entry',
        [.5, sqrt(.75), 0],
        [
          ['local'],
          ['local', 'bridge'],
        ],
      );
      add(
        'local',
        [.8, .6, 0],
        [
          ['entry'],
          ['entry'],
        ],
      );
      add(
        'bridge',
        [.6, 0, .8],
        [
          ['target'],
          ['entry', 'target'],
        ],
      );
      add(
        'target',
        [1, 0, 0],
        [
          ['bridge'],
          ['bridge'],
        ],
      );
      store.entryPoint = 'entry';
      expect(
        HnswIndex(store).search([1, 0, 0], limit: 1).matches.single.key,
        'target',
      );
    },
  );
  test('validates vectors and preserves cosine similarity through Float32', () {
    final store = _MemoryStore(3);
    final index = HnswIndex(store);
    expect(index.search([1, 0, 0]).matches, isEmpty);
    for (final bad in <List<double>>[
      [0, 0, 0],
      [double.nan, 0, 1],
      [double.infinity, 0, 1],
      [1, 0],
    ]) {
      expect(() => index.add('bad', bad), throwsArgumentError);
      expect(() => index.search(bad), throwsArgumentError);
    }
    index.add('east', [3, 0, 0]);
    index.add('north', [0, 4, 0]);
    index.add('west', [-1, 0, 0]);
    index.add('tiny', [1e-300, 1e-300, 0]);
    index.add('huge', [1e300, 1e300, 0]);
    index.add('east', [6, 0, 0]);
    expect(() => index.add('east', [0, 1, 0]), throwsStateError);
    final result = index.search([10, 0, 0], limit: 5).matches;
    expect(result.first.key, 'east');
    expect(result.first.cosine, closeTo(1, 1e-6));
    expect(result.last.key, 'west');
    expect(result.last.cosine, closeTo(-1, 1e-6));
    expect(index.search([1, 0, 0], limit: 0).matches, isEmpty);
  });

  test('duplicate vectors remain reachable and old nodes are not mutated', () {
    final store = _MemoryStore(3);
    final index = HnswIndex(store, maxNeighbors: 8);
    index.add('0', [1, 0, 0]);
    final first = store.read('0')!;
    final original = first.neighbors.map((n) => n.toList()).toList();
    for (var i = 1; i < 100; i++) {
      index.add('$i', [1, 0, 0]);
    }
    expect(first.neighbors, original);
    expect(index.search([1, 0, 0], limit: 100).matches, hasLength(100));
    for (final node in store.nodes.values) {
      for (var level = 0; level <= node.level; level++) {
        expect(
          node.neighbors[level].length,
          lessThanOrEqualTo(level == 0 ? 16 : 8),
        );
        expect(node.neighbors[level], isNot(contains(node.key)));
      }
    }
  });

  test('deletion retains routing through entry point and ordinary nodes', () {
    final store = _MemoryStore(3);
    final index = HnswIndex(store);
    for (var i = 0; i < 180; i++) {
      index.add('$i', [cos(i / 20), sin(i / 20), 0.1]);
    }
    final entry = store.entryPoint!;
    final ordinary = entry == '40' ? '41' : '40';
    final beforeRemoval = store.read(entry)!;
    index.remove(entry);
    index.remove(ordinary);
    index.remove('absent');
    expect(beforeRemoval.deleted, isFalse);
    expect(store.entryPoint, entry);
    expect(store.read(entry)!.deleted, isTrue);
    final matches = index.search([cos(2), sin(2), 0.1], limit: 180).matches;
    expect(matches, hasLength(178));
    expect(matches.map((m) => m.key), isNot(contains(entry)));
    expect(matches.map((m) => m.key), isNot(contains(ordinary)));
    index.add('replacement', [cos(2), sin(2), 0.1]);
    expect(
      index.search([cos(2), sin(2), 0.1], limit: 1).matches.single.key,
      'replacement',
    );
    expect(() => index.add(entry, [1, 0, 0]), throwsStateError);
  });

  test(
    'reopening a detached store preserves query results and permits inserts',
    () {
      final random = Random(219);
      final store = _MemoryStore(64);
      final index = HnswIndex(store);
      for (var i = 0; i < 400; i++) {
        index.add('$i', _randomVector(random, 64));
      }
      final query = _randomVector(random, 64);
      final before = index.search(query, limit: 20);
      final reopened = store.detached();
      final reopenedIndex = HnswIndex(reopened);
      final after = reopenedIndex.search(query, limit: 20);
      expect(after.matches.map((m) => m.key), before.matches.map((m) => m.key));
      expect(
        after.matches.map((m) => m.cosine),
        before.matches.map((m) => m.cosine),
      );
      expect(after.distanceEvaluations, before.distanceEvaluations);
      reopenedIndex.add('new', query);
      expect(reopenedIndex.search(query, limit: 1).matches.single.key, 'new');
    },
  );

  test('64D random and separated cluster queries reach Recall@10 >= 0.95', () {
    for (final clustered in [false, true]) {
      final random = Random(clustered ? 812 : 411);
      final vectors = <String, List<double>>{};
      final centers = List.generate(12, (_) => _randomVector(random, 64));
      final index = HnswIndex(
        _MemoryStore(64),
        maxNeighbors: 16,
        constructionEf: 160,
        searchEf: 180,
      );
      for (var i = 0; i < 1500; i++) {
        final vector = clustered
            ? _around(random, centers[i ~/ 125], 0.12)
            : _randomVector(random, 64);
        vectors['$i'] = vector;
        index.add('$i', vector);
      }
      var hits = 0;
      for (var i = 0; i < 24; i++) {
        final query = clustered
            ? _around(random, centers[i % centers.length], 0.12)
            : _randomVector(random, 64);
        final exact = _exhaustive(vectors, query, 10).toSet();
        final approximate = index.search(query, limit: 10).matches;
        hits += approximate.where((m) => exact.contains(m.key)).length;
      }
      expect(
        hits / 240,
        greaterThanOrEqualTo(0.95),
        reason: 'clustered=$clustered',
      );
    }
  });

  test('10k clustered vectors query visits less than 30 percent of vectors', () {
    final random = Random(711);
    final centers = List.generate(40, (_) => _randomVector(random, 64));
    final index = HnswIndex(
      _MemoryStore(64),
      maxNeighbors: 12,
      constructionEf: 100,
      searchEf: 100,
    );
    final vectors = <String, List<double>>{};
    for (var i = 0; i < 10000; i++) {
      final vector = _around(random, centers[i ~/ 250], 0.08);
      vectors['$i'] = vector;
      index.add('$i', vector);
    }
    var hits = 0;
    var evaluations = 0;
    for (var i = 0; i < 12; i++) {
      final query = _around(random, centers[i * 3], 0.08);
      final exact = _exhaustive(vectors, query, 10).toSet();
      final result = index.search(query, limit: 10);
      hits += result.matches.where((m) => exact.contains(m.key)).length;
      evaluations += result.distanceEvaluations;
      expect(result.distanceEvaluations, lessThan(3000));
    }
    expect(hits / 120, greaterThanOrEqualTo(0.95));
    // Host synthetic work count, independent of machine speed or mobile latency.
    // ignore: avoid_print
    print(
      'HNSW 10k/64D: recall=${hits / 120}, mean distances=${evaluations / 12}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('512D vectors retain useful recall without a corpus scan', () {
    final random = Random(913);
    final centers = List.generate(10, (_) => _randomVector(random, 512));
    final vectors = <String, List<double>>{};
    final index = HnswIndex(_MemoryStore(512), constructionEf: 100);
    for (var i = 0; i < 500; i++) {
      final vector = _around(random, centers[i ~/ 50], 0.06);
      vectors['$i'] = vector;
      index.add('$i', vector);
    }
    for (var i = 0; i < 10; i++) {
      final query = _around(random, centers[i], 0.06);
      final exact = _exhaustive(vectors, query, 10).toSet();
      final result = index.search(query, limit: 10, ef: 64);
      expect(
        result.matches.where((m) => exact.contains(m.key)).length,
        greaterThanOrEqualTo(9),
      );
      expect(result.distanceEvaluations, lessThan(500));
    }
  });

  test(
    'missing neighbors and cycles terminate without returning missing keys',
    () {
      final store = _MemoryStore(2);
      store.write(
        HnswNode(
          key: 'a',
          vector: Float32List.fromList([1, 0]),
          neighbors: [
            ['a', 'missing', 'b'],
          ],
        ),
      );
      store.write(
        HnswNode(
          key: 'b',
          vector: Float32List.fromList([0, 1]),
          neighbors: [
            ['a', 'b'],
          ],
        ),
      );
      store.entryPoint = 'a';
      final result = HnswIndex(store).search([0, 1], limit: 10);
      expect(result.matches.map((m) => m.key), ['b', 'a']);
      expect(result.distanceEvaluations, lessThanOrEqualTo(2));
    },
  );
}

class _MemoryStore implements HnswStore {
  _MemoryStore(this.dimensions);
  final Map<String, HnswNode> nodes = {};
  @override
  final int dimensions;
  @override
  String? entryPoint;
  @override
  HnswNode? read(String key) => nodes[key];
  @override
  void write(HnswNode node) => nodes[node.key] = node;

  _MemoryStore detached() {
    final result = _MemoryStore(dimensions)..entryPoint = entryPoint;
    for (final node in nodes.values) {
      result.write(
        HnswNode(
          key: node.key,
          vector: Float32List.fromList(node.vector),
          neighbors: node.neighbors.map((n) => n.toList()).toList(),
          deleted: node.deleted,
        ),
      );
    }
    return result;
  }
}

List<double> _randomVector(Random random, int dimensions) =>
    List.generate(dimensions, (_) => random.nextDouble() * 2 - 1);

List<double> _around(Random random, List<double> center, double noise) => [
  for (final coordinate in center)
    coordinate + (random.nextDouble() * 2 - 1) * noise,
];

List<String> _exhaustive(
  Map<String, List<double>> vectors,
  List<double> query,
  int limit,
) {
  final queryNorm = sqrt(
    query.fold<double>(0, (sum, value) => sum + value * value),
  );
  final scored = vectors.entries.map((entry) {
    var dot = 0.0;
    var squaredNorm = 0.0;
    for (var i = 0; i < query.length; i++) {
      dot += query[i] * entry.value[i];
      squaredNorm += entry.value[i] * entry.value[i];
    }
    return (entry.key, dot / (queryNorm * sqrt(squaredNorm)));
  }).toList()..sort((a, b) => b.$2.compareTo(a.$2));
  return scored.take(limit).map((entry) => entry.$1).toList();
}
