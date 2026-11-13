import 'dart:math';
import 'dart:typed_data';

/// Synchronous graph storage, owned by the storage isolate. Callers wrap graph
/// mutations and entry-point updates in the same storage transaction.
abstract interface class HnswStore {
  HnswNode? read(String key);
  void write(HnswNode node);
  String? get entryPoint;
  set entryPoint(String? key);
  int get dimensions;
}

class HnswNode {
  const HnswNode({
    required this.key,
    required this.vector,
    required this.neighbors,
    this.deleted = false,
  });

  final String key;
  final Float32List vector;
  final List<List<String>> neighbors;
  final bool deleted;
  int get level => neighbors.length - 1;
}

class HnswMatch {
  const HnswMatch(this.key, this.cosine);
  final String key;
  final double cosine;
}

class HnswResult {
  const HnswResult(this.matches, this.distanceEvaluations);
  final List<HnswMatch> matches;
  final int distanceEvaluations;
}

/// Hierarchical navigable small-world graph for normalized cosine search.
///
/// Follows algorithms 1, 2, 4 and 5 of Malkov and Yashunin,
/// https://arxiv.org/abs/1603.09320. Layer zero allows 2M neighbors; other
/// layers allow M. Neighbor selection keeps diverse directions, then fills
/// remaining slots with the rejected nearest candidates.
///
/// Keys identify immutable revisions: repeating the same normalized vector is
/// idempotent, while replacing a vector or reusing a tombstone is rejected.
/// Removal preserves all routing links. Search is approximate, and its ef
/// parameter trades more distance evaluations for higher recall.
class HnswIndex {
  HnswIndex(
    this.store, {
    int maxNeighbors = 12,
    int constructionEf = 80,
    int searchEf = 160,
    int seed = 20261112,
  }) : _maxNeighbors = maxNeighbors,
       _constructionEf = constructionEf,
       _searchEf = searchEf,
       // Keep the public configuration name independent of private state.
       // ignore: prefer_initializing_formals
       _seed = seed {
    if (store.dimensions < 1) {
      throw ArgumentError.value(store.dimensions, 'dimensions');
    }
    if (maxNeighbors < 2 || maxNeighbors > 128) {
      throw RangeError.range(maxNeighbors, 2, 128, 'maxNeighbors');
    }
    if (constructionEf < maxNeighbors) {
      throw ArgumentError.value(
        constructionEf,
        'constructionEf',
        'Must be >= maxNeighbors',
      );
    }
    if (searchEf < 1) throw ArgumentError.value(searchEf, 'searchEf');
  }

  final HnswStore store;
  final int _maxNeighbors;
  final int _constructionEf;
  final int _searchEf;
  final int _seed;

  void add(String key, List<double> vector) {
    if (key.isEmpty) throw ArgumentError.value(key, 'key');
    final normalized = _normalize(vector);
    final existing = store.read(key);
    if (existing != null) {
      if (existing.deleted || !_sameVector(existing.vector, normalized)) {
        throw StateError('HNSW keys identify immutable vector revisions');
      }
      return;
    }
    final entryKey = store.entryPoint;
    final entry = entryKey == null ? null : store.read(entryKey);
    if (entryKey != null && entry == null) {
      throw StateError('HNSW entry point is missing');
    }
    final level = _level(key);
    var node = HnswNode(
      key: key,
      vector: normalized,
      neighbors: List.generate(level + 1, (_) => const <String>[]),
    );
    store.write(node);
    if (entry == null) {
      store.entryPoint = key;
      return;
    }

    final distances = _Distances(normalized);
    var entries = <String>[entry.key];
    for (var layer = entry.level; layer > level; layer--) {
      final nearest = _searchLayer(distances, entries, 1, layer);
      if (nearest.isNotEmpty) entries = [nearest.first.key];
    }
    for (var layer = min(level, entry.level); layer >= 0; layer--) {
      final candidates = _searchLayer(
        distances,
        entries,
        _constructionEf,
        layer,
      );
      final selected = _selectNeighbors(node, candidates, _maxNeighbors);
      node = _withNeighbors(node, layer, selected);
      store.write(node);
      for (final neighborKey in selected) {
        final neighbor = store.read(neighborKey);
        if (neighbor == null || neighbor.level < layer) continue;
        final links = {...neighbor.neighbors[layer], key}.toList();
        final maximum = layer == 0 ? _maxNeighbors * 2 : _maxNeighbors;
        final List<String> retained;
        if (links.length > maximum) {
          final fromNeighbor = _Distances(neighbor.vector);
          final choices = <_Scored>[];
          for (final link in links) {
            final target = store.read(link);
            if (target != null &&
                target.level >= layer &&
                link != neighbor.key) {
              choices.add(_Scored(link, fromNeighbor.to(target)));
            }
          }
          retained = _selectNeighbors(neighbor, choices, maximum);
        } else {
          retained = links;
        }
        store.write(_withNeighbors(neighbor, layer, retained));
      }
      // Algorithm 1 carries all ef candidates down to the next layer.
      if (candidates.isNotEmpty) {
        entries = candidates.map((candidate) => candidate.key).toList();
      }
    }
    if (level > entry.level) store.entryPoint = key;
  }

  void remove(String key) {
    final node = store.read(key);
    if (node == null || node.deleted) return;
    store.write(
      HnswNode(
        key: node.key,
        vector: node.vector,
        neighbors: node.neighbors,
        deleted: true,
      ),
    );
  }

  HnswResult search(
    List<double> query, {
    int limit = 128,
    int? ef,
    int upperEf = 8,
  }) {
    final normalized = _normalize(query);
    if (limit < 0) throw ArgumentError.value(limit, 'limit');
    if (ef != null && ef < 1) throw ArgumentError.value(ef, 'ef');
    if (upperEf < 1) throw ArgumentError.value(upperEf, 'upperEf');
    if (limit == 0) return const HnswResult([], 0);
    final entryKey = store.entryPoint;
    final entry = entryKey == null ? null : store.read(entryKey);
    if (entry == null) return const HnswResult([], 0);
    final distances = _Distances(normalized);
    var entries = <String>[entry.key];
    for (var layer = entry.level; layer > 0; layer--) {
      // A single greedy upper route can enter the wrong dense cluster even
      // when the lower layer has ample ef. Carry a small beam between layers.
      final nearest = _searchLayer(distances, entries, upperEf, layer);
      if (nearest.isNotEmpty) {
        entries = nearest.map((match) => match.key).toList();
      }
    }
    final found = _searchLayer(
      distances,
      entries,
      max(limit, ef ?? _searchEf),
      0,
      liveOnly: true,
    );
    return HnswResult(
      List.unmodifiable(
        found
            .take(limit)
            .map((match) => HnswMatch(match.key, 1 - match.distance)),
      ),
      distances.evaluations,
    );
  }

  List<_Scored> _searchLayer(
    _Distances distances,
    List<String> entryKeys,
    int ef,
    int layer, {
    bool liveOnly = false,
  }) {
    final visited = <String>{};
    final candidates = _Heap(nearestFirst: true);
    final nearest = _Heap(nearestFirst: false);
    for (final key in entryKeys) {
      if (!visited.add(key)) continue;
      final node = store.read(key);
      if (node == null || node.level < layer) continue;
      final scored = _Scored(key, distances.to(node));
      candidates.add(scored);
      if (!liveOnly || !node.deleted) {
        nearest.add(scored);
        if (nearest.length > ef) nearest.removeFirst();
      }
    }
    while (candidates.isNotEmpty) {
      final candidate = candidates.removeFirst();
      if (nearest.length >= ef && _compare(candidate, nearest.first) > 0) break;
      final node = store.read(candidate.key);
      if (node == null || node.level < layer) continue;
      for (final key in node.neighbors[layer]) {
        if (!visited.add(key)) continue;
        final neighbor = store.read(key);
        if (neighbor == null || neighbor.level < layer) continue;
        final scored = _Scored(key, distances.to(neighbor));
        if (nearest.length < ef || _compare(scored, nearest.first) < 0) {
          candidates.add(scored);
          // Tombstones remain routing candidates, but cannot displace a live
          // result or end the search before enough live candidates are found.
          if (!liveOnly || !neighbor.deleted) {
            nearest.add(scored);
            if (nearest.length > ef) nearest.removeFirst();
          }
        }
      }
    }
    return nearest.sorted();
  }

  List<String> _selectNeighbors(
    HnswNode center,
    List<_Scored> candidates,
    int maximum,
  ) {
    // Stable pair-specific ties avoid systematically stripping incoming edges
    // from late insertions when many distinct keys have identical vectors.
    candidates.sort((a, b) {
      final compared = a.distance.compareTo(b.distance);
      if (compared != 0) return compared;
      final tied = _pairHash(
        center.key,
        a.key,
      ).compareTo(_pairHash(center.key, b.key));
      return tied == 0 ? a.key.compareTo(b.key) : tied;
    });
    final selected = <HnswNode>[];
    final rejected = <String>[];
    final seen = <String>{center.key};
    for (final candidate in candidates) {
      if (!seen.add(candidate.key)) continue;
      final node = store.read(candidate.key);
      if (node == null) continue;
      var diverse = true;
      for (final accepted in selected) {
        if (_distance(node.vector, accepted.vector) <= candidate.distance) {
          diverse = false;
          break;
        }
      }
      if (diverse) {
        selected.add(node);
        if (selected.length == maximum) break;
      } else {
        rejected.add(node.key);
      }
    }
    final result = selected.map((node) => node.key).toList();
    result.addAll(rejected.take(maximum - result.length));
    return result;
  }

  HnswNode _withNeighbors(HnswNode node, int layer, List<String> neighbors) =>
      HnswNode(
        key: node.key,
        vector: node.vector,
        deleted: node.deleted,
        neighbors: List.unmodifiable([
          for (var i = 0; i <= node.level; i++)
            List<String>.unmodifiable(
              i == layer ? neighbors : node.neighbors[i],
            ),
        ]),
      );

  int _level(String key) {
    // No PRNG state needs persistence: reopening before each insertion still
    // produces independent exponential layer heights for immutable keys.
    final sample = 1 - Random(_hash(key) ^ _seed).nextDouble();
    return min(32, (-log(sample) / log(_maxNeighbors)).floor());
  }

  Float32List _normalize(List<double> vector) {
    if (vector.length != store.dimensions) {
      throw ArgumentError('Vector dimensions must equal ${store.dimensions}');
    }
    var scale = 0.0;
    for (final coordinate in vector) {
      if (!coordinate.isFinite) throw ArgumentError('Vector must be finite');
      scale = max(scale, coordinate.abs());
    }
    if (scale == 0) throw ArgumentError('Vector must be nonzero');
    // Scaling first handles both very large and subnormal finite inputs.
    var squaredNorm = 0.0;
    for (final coordinate in vector) {
      final scaled = coordinate / scale;
      squaredNorm += scaled * scaled;
    }
    final norm = sqrt(squaredNorm);
    return Float32List.fromList([
      for (final coordinate in vector) (coordinate / scale) / norm,
    ]);
  }

  bool _sameVector(Float32List a, Float32List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > 1e-7) return false;
    }
    return true;
  }
}

double _distance(Float32List a, Float32List b) {
  // Independent double accumulators reduce the serial dependency chain.
  // Keep Float32 inputs and double products/sums; no vector quantization.
  var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0;
  var i = 0;
  for (; i + 3 < a.length; i += 4) {
    s0 += a[i] * b[i];
    s1 += a[i + 1] * b[i + 1];
    s2 += a[i + 2] * b[i + 2];
    s3 += a[i + 3] * b[i + 3];
  }
  for (; i < a.length; i++) {
    s0 += a[i] * b[i];
  }
  return (1 - ((s0 + s1) + (s2 + s3))).clamp(0.0, 2.0);
}

int _hash(String key) {
  var hash = 2166136261;
  for (final unit in key.codeUnits) {
    hash = ((hash ^ unit) * 16777619) & 0xffffffff;
  }
  hash ^= hash >>> 16;
  hash = (hash * 0x45d9f3b) & 0xffffffff;
  hash ^= hash >>> 16;
  return hash;
}

int _pairHash(String a, String b) =>
    _hash(a.compareTo(b) < 0 ? '$a\u0000$b' : '$b\u0000$a');

class _Distances {
  _Distances(this.query);
  final Float32List query;
  final Map<String, double> _cache = {};
  int get evaluations => _cache.length;
  double to(HnswNode node) =>
      _cache.putIfAbsent(node.key, () => _distance(query, node.vector));
}

class _Scored {
  const _Scored(this.key, this.distance);
  final String key;
  final double distance;
}

int _compare(_Scored a, _Scored b) {
  final order = a.distance.compareTo(b.distance);
  return order == 0 ? a.key.compareTo(b.key) : order;
}

/// Binary heap: layer search sorts only the final ef-sized result pool.
class _Heap {
  _Heap({required this.nearestFirst});
  final bool nearestFirst;
  final List<_Scored> _items = [];
  int get length => _items.length;
  bool get isNotEmpty => _items.isNotEmpty;
  _Scored get first => _items.first;
  bool _before(_Scored a, _Scored b) =>
      nearestFirst ? _compare(a, b) < 0 : _compare(a, b) > 0;

  void add(_Scored item) {
    _items.add(item);
    var child = _items.length - 1;
    while (child > 0) {
      final parent = (child - 1) ~/ 2;
      if (!_before(item, _items[parent])) break;
      _items[child] = _items[parent];
      child = parent;
    }
    _items[child] = item;
  }

  _Scored removeFirst() {
    final result = _items.first;
    final last = _items.removeLast();
    if (_items.isEmpty) return result;
    var parent = 0;
    while (parent * 2 + 1 < _items.length) {
      var child = parent * 2 + 1;
      if (child + 1 < _items.length &&
          _before(_items[child + 1], _items[child])) {
        child++;
      }
      if (!_before(_items[child], last)) break;
      _items[parent] = _items[child];
      parent = child;
    }
    _items[parent] = last;
    return result;
  }

  List<_Scored> sorted() => _items.toList()..sort(_compare);
}
