import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'hnsw.dart';

/// Worker-owned SQLite adapter. Mutations, flush and entry updates must share a
/// transaction. Discard this adapter after rollback; cached nodes are tentative.
/// Immutable Float32 vectors are packed separately from mutable adjacency.
class CompactGraphStore implements HnswStore {
  CompactGraphStore(this.db, this.dimensions) {
    if (dimensions < 1 || dimensions > 4096) {
      throw ArgumentError.value(dimensions, 'dimensions');
    }
    _read = db.prepare('''SELECT n.neighbors,n.deleted,
      substr(v.payload,(n.slot % $_blockSlots)*?+1,?) AS vector
      FROM nodes n LEFT JOIN vector_blocks v
      ON v.dimension=n.dimension AND v.block=n.slot/$_blockSlots
      WHERE n.id=? AND n.dimension=?''');
    _update = db.prepare(
      'UPDATE nodes SET neighbors=?,deleted=? WHERE id=? AND dimension=?',
    );
    _insert = db.prepare('INSERT INTO nodes VALUES (?,?,?,?,?)');
    _entry = db.prepare('SELECT key FROM entries WHERE dimension=?');
    _setEntry = db.prepare('INSERT OR REPLACE INTO entries VALUES (?,?)');
  }
  final Database db;
  @override
  final int dimensions;
  late final PreparedStatement _read, _update, _insert, _entry, _setEntry;
  final _cache = <String, HnswNode>{};
  final _pending = <String, HnswNode>{};
  bool _closed = false;
  int? _nextSlot;
  int get _bytes => dimensions * 4;
  // Aim for one 4KiB payload instead of copying 16KiB on each 512D read.
  int get _blockSlots => math.min(64, math.max(1, 4096 ~/ _bytes));
  int get _capacity => math.min(2048, math.max(64, 4 * 1024 * 1024 ~/ _bytes));
  void _check() {
    if (_closed) throw StateError('Graph store is closed');
  }

  static int _id(String key) {
    final id = key.startsWith('n') ? int.tryParse(key.substring(1)) : null;
    if (id == null || id < 1 || id > 0x1fffffffffffff || key != 'n$id') {
      throw const FormatException('Invalid graph key');
    }
    return id;
  }

  @override
  String? get entryPoint {
    _check();
    final rows = _entry.select([dimensions]);
    final key = rows.isEmpty ? null : rows.single['key'];
    if (key == null &&
        db.select(
          'SELECT 1 FROM docs WHERE dimension=? AND vector_key IS NOT NULL LIMIT 1',
          [dimensions],
        ).isNotEmpty) {
      throw const FormatException('Missing graph entry pointer');
    }
    if (key != null && (key is! String || read(key) == null)) {
      throw const FormatException('Missing graph entry');
    }
    return key as String?;
  }

  @override
  set entryPoint(String? key) {
    _check();
    if (key != null) _id(key);
    _setEntry.execute([dimensions, key]);
  }

  void _remember(HnswNode node) {
    _cache.remove(node.key);
    _cache[node.key] = node;
    if (_cache.length > _capacity) _cache.remove(_cache.keys.first);
  }

  @override
  HnswNode? read(String key) {
    _check();
    final pending = _pending[key];
    if (pending != null) return pending;
    var node = _cache.remove(key);
    if (node == null) {
      final rows = _read.select([_bytes, _bytes, _id(key), dimensions]);
      if (rows.isEmpty) return null;
      final row = rows.single;
      final bytes = row['vector'];
      if (bytes is! Uint8List || bytes.length != _bytes) {
        throw const FormatException('Invalid graph vector block');
      }
      final Float32List vector;
      if (Endian.host == Endian.little && bytes.offsetInBytes % 4 == 0) {
        vector = bytes.buffer.asFloat32List(bytes.offsetInBytes, dimensions);
      } else {
        final data = ByteData.sublistView(bytes);
        vector = Float32List(dimensions);
        for (var i = 0; i < dimensions; i++) {
          vector[i] = data.getFloat32(i * 4, Endian.little);
        }
      }
      var norm = 0.0;
      for (var i = 0; i < vector.length; i++) {
        norm += vector[i] * vector[i];
      }
      if (!norm.isFinite ||
          (norm - 1).abs() > 1e-4 ||
          (row['deleted'] != 0 && row['deleted'] != 1)) {
        throw const FormatException('Invalid graph vector');
      }
      node = HnswNode(
        key: key,
        vector: vector,
        neighbors: _decode(row['neighbors']),
        deleted: row['deleted'] == 1,
      );
    }
    _remember(node);
    return node;
  }

  @override
  void write(HnswNode node) {
    _check();
    _id(node.key);
    if (node.vector.length != dimensions) {
      throw ArgumentError('Invalid graph dimensions');
    }
    _pending[node.key] = node;
    _remember(node);
  }

  void flush() {
    _check();
    if (_pending.isEmpty) return;
    // Recover allocation from committed rows, not a separately mutable cursor.
    // nodes_slot makes this a single index seek, once per adapter lifetime.
    var slot = _nextSlot ?? -1;
    if (slot < 0) {
      final rows = db.select(
        'SELECT slot FROM nodes WHERE dimension=? ORDER BY slot DESC LIMIT 1',
        [dimensions],
      );
      final last = rows.isEmpty ? -1 : rows.single['slot'];
      if (last is! int || last < -1 || last >= 0x1fffffffffffff) {
        throw const FormatException('Invalid graph slot');
      }
      slot = last + 1;
    }
    final blocks = <int, Uint8List>{};
    for (final node in _pending.values) {
      final links = _encode(node.neighbors);
      _update.execute([links, node.deleted ? 1 : 0, _id(node.key), dimensions]);
      if (db.updatedRows != 0) continue;
      final block = slot ~/ _blockSlots;
      final bytes = blocks.putIfAbsent(block, () {
        final rows = db.select(
          'SELECT payload FROM vector_blocks WHERE dimension=? AND block=?',
          [dimensions, block],
        );
        if (rows.isEmpty) return Uint8List(_bytes * _blockSlots);
        final payload = rows.single['payload'];
        if (payload is! Uint8List || payload.length != _bytes * _blockSlots) {
          throw const FormatException('Invalid graph vector block');
        }
        return Uint8List.fromList(payload);
      });
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < dimensions; i++) {
        data.setFloat32(
          (slot % _blockSlots) * _bytes + i * 4,
          node.vector[i],
          Endian.little,
        );
      }
      _insert.execute([
        _id(node.key),
        dimensions,
        slot,
        links,
        node.deleted ? 1 : 0,
      ]);
      slot++;
    }
    for (final entry in blocks.entries) {
      db.execute('INSERT OR REPLACE INTO vector_blocks VALUES (?,?,?)', [
        dimensions,
        entry.key,
        entry.value,
      ]);
    }
    _nextSlot = slot;
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final statement in [_read, _update, _insert, _entry, _setEntry]) {
      statement.close();
    }
    _cache.clear();
    _pending.clear();
  }

  static Uint8List _encode(List<List<String>> layers) {
    if (layers.isEmpty ||
        layers.length > 33 ||
        layers.any((layer) => layer.length > 256)) {
      throw const FormatException('Invalid graph links');
    }
    final out = BytesBuilder(copy: false);
    void put(int value) {
      while (value >= 128) {
        out.addByte((value & 127) | 128);
        value >>= 7;
      }
      out.addByte(value);
    }

    put(layers.length);
    for (final layer in layers) {
      put(layer.length);
      for (final key in layer) {
        put(_id(key));
      }
    }
    return out.takeBytes();
  }

  static List<List<String>> _decode(Object? payload) {
    if (payload is! Uint8List || payload.isEmpty || payload.length > 65536) {
      throw const FormatException('Invalid graph links');
    }
    var at = 0;
    int get() {
      var value = 0, shift = 0;
      while (at < payload.length && shift <= 49) {
        final byte = payload[at++];
        value |= (byte & 127) << shift;
        if (byte < 128) {
          if (shift > 0 && byte == 0 || value > 0x1fffffffffffff) {
            throw const FormatException('Invalid graph integer');
          }
          return value;
        }
        shift += 7;
      }
      throw const FormatException('Truncated graph links');
    }

    final count = get();
    if (count < 1 || count > 33) {
      throw const FormatException('Invalid graph layers');
    }
    final layers = <List<String>>[];
    for (var layer = 0; layer < count; layer++) {
      final size = get();
      if (size > 256) throw const FormatException('Invalid graph links');
      final keys = <String>[];
      for (var i = 0; i < size; i++) {
        final id = get();
        if (id < 1) throw const FormatException('Invalid graph key');
        keys.add('n$id');
      }
      layers.add(keys);
    }
    if (at != payload.length) {
      throw const FormatException('Trailing graph links');
    }
    return layers;
  }
}
