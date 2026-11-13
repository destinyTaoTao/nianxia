import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/data/compact_graph_store.dart';
import 'package:nianxia/data/hnsw.dart';

void main() {
  test(
    'packed vectors persist exactly while adjacency changes independently',
    () {
      final db = sqlite3.openInMemory();
      db.execute('''CREATE TABLE nodes(id INTEGER PRIMARY KEY,dimension INTEGER NOT NULL,slot INTEGER NOT NULL,neighbors BLOB NOT NULL,deleted INTEGER NOT NULL);
      CREATE TABLE vector_blocks(dimension INTEGER,block INTEGER,payload BLOB NOT NULL,PRIMARY KEY(dimension,block));
      CREATE TABLE entries(dimension INTEGER PRIMARY KEY,key TEXT);
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
      CREATE TABLE docs(dimension INTEGER,vector_key TEXT);''');
      var store = CompactGraphStore(db, 512);
      final vector = Float32List(512)..[0] = 1;
      try {
        db.execute('BEGIN');
        for (var n = 1; n <= 17; n++) {
          store.write(
            HnswNode(
              key: 'n$n',
              vector: vector,
              neighbors: [
                [if (n > 1) 'n${n - 1}'],
              ],
            ),
          );
        }
        store.entryPoint = 'n1';
        store.flush();
        db.execute('COMMIT');
        final blocks = db
            .select(
              'SELECT dimension,block,hex(payload) AS bytes FROM vector_blocks ORDER BY block',
            )
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        expect(blocks, hasLength(9));
        expect(store.read('n17')!.vector, vector);
        db.execute('BEGIN');
        store.write(
          HnswNode(
            key: 'n17',
            vector: vector,
            neighbors: [
              ['n1', 'n100000'],
            ],
            deleted: true,
          ),
        );
        store.flush();
        db.execute('COMMIT');
        expect(
          db
              .select(
                'SELECT dimension,block,hex(payload) AS bytes FROM vector_blocks ORDER BY block',
              )
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
          blocks,
        );
        store.close();
        store = CompactGraphStore(db, 512);
        expect(store.read('n17')!.deleted, isTrue);
        expect(store.read('n17')!.neighbors, [
          ['n1', 'n100000'],
        ]);
        expect(store.read('n17')!.vector, vector);
        db.execute("UPDATE nodes SET neighbors=x'80' WHERE id=17");
        store.close();
        store = CompactGraphStore(db, 512);
        expect(() => store.read('n17'), throwsFormatException);
      } finally {
        store.close();
        db.close();
      }
    },
  );
  test(
    'dimension slots are independent and rollback leaves no published nodes',
    () {
      final db = sqlite3.openInMemory();
      db.execute('''CREATE TABLE nodes(id INTEGER PRIMARY KEY,dimension INTEGER NOT NULL,slot INTEGER NOT NULL,neighbors BLOB NOT NULL,deleted INTEGER NOT NULL);
      CREATE TABLE vector_blocks(dimension INTEGER,block INTEGER,payload BLOB NOT NULL,PRIMARY KEY(dimension,block));
      CREATE TABLE entries(dimension INTEGER PRIMARY KEY,key TEXT);
      CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
      CREATE TABLE docs(dimension INTEGER,vector_key TEXT);''');
      var small = CompactGraphStore(db, 3);
      final large = CompactGraphStore(db, 512);
      try {
        db.execute('BEGIN');
        small.write(
          HnswNode(
            key: 'n1',
            vector: Float32List.fromList([1, 0, 0]),
            neighbors: [[]],
          ),
        );
        large.write(
          HnswNode(
            key: 'n2',
            vector: Float32List(512)..[0] = 1,
            neighbors: [[]],
          ),
        );
        small.flush();
        large.flush();
        db.execute('COMMIT');
        expect(
          db.select('SELECT slot FROM nodes ORDER BY id').map((r) => r['slot']),
          [0, 0],
        );
        db.execute('BEGIN');
        small.write(
          HnswNode(
            key: 'n3',
            vector: Float32List.fromList([0, 1, 0]),
            neighbors: [
              ['n1'],
            ],
          ),
        );
        small.entryPoint = 'n3';
        small.flush();
        db.execute('ROLLBACK');
        small.close();
        small = CompactGraphStore(db, 3);
        expect(small.read('n3'), isNull);
        expect(small.entryPoint, isNull);
        expect(small.read('n1')!.vector, [1, 0, 0]);
        db.execute('BEGIN');
        small.write(
          HnswNode(
            key: 'n4',
            vector: Float32List.fromList([0, 0, 1]),
            neighbors: [
              ['n1'],
            ],
          ),
        );
        small.flush();
        db.execute('COMMIT');
        expect(
          db.select('SELECT slot FROM nodes WHERE id=4').single['slot'],
          1,
        );
        small.close();
        small = CompactGraphStore(db, 3);
        expect(small.read('n4')!.vector, [0, 0, 1]);
        expect(large.read('n2')!.vector.first, 1);
      } finally {
        small.close();
        large.close();
        db.close();
      }
    },
  );
  for (final fault in [
    "x'010000'",
    "x'810000'",
    "x'010100'",
    "x'22'",
    "'{}'",
  ]) {
    test('malformed compact links reject $fault', () {
      final db = sqlite3.openInMemory();
      db.execute('''CREATE TABLE nodes(id INTEGER PRIMARY KEY,dimension INTEGER,slot INTEGER,neighbors BLOB,deleted INTEGER);
        CREATE TABLE vector_blocks(dimension INTEGER,block INTEGER,payload BLOB,PRIMARY KEY(dimension,block));
        CREATE TABLE entries(dimension INTEGER PRIMARY KEY,key TEXT);
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE docs(dimension INTEGER,vector_key TEXT);''');
      var store = CompactGraphStore(db, 1);
      try {
        store.write(
          HnswNode(
            key: 'n1',
            vector: Float32List.fromList([1]),
            neighbors: [[]],
          ),
        );
        store.flush();
        store.close();
        db.execute('UPDATE nodes SET neighbors=$fault');
        store = CompactGraphStore(db, 1);
        expect(() => store.read('n1'), throwsFormatException);
      } finally {
        store.close();
        db.close();
      }
    });
  }
  for (final cursor in [null, '0']) {
    test(
      'missing or regressed slot cursor never overwrites existing vectors: $cursor',
      () {
        final db = sqlite3.openInMemory();
        db.execute('''CREATE TABLE nodes(id INTEGER PRIMARY KEY,dimension INTEGER,slot INTEGER,neighbors BLOB,deleted INTEGER);
        CREATE TABLE vector_blocks(dimension INTEGER,block INTEGER,payload BLOB,PRIMARY KEY(dimension,block));
        CREATE TABLE entries(dimension INTEGER PRIMARY KEY,key TEXT);
        CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE docs(dimension INTEGER,vector_key TEXT);''');
        var store = CompactGraphStore(db, 2);
        try {
          store.write(
            HnswNode(
              key: 'n1',
              vector: Float32List.fromList([1, 0]),
              neighbors: [[]],
            ),
          );
          store.flush();
          store.close();
          if (cursor == null) {
            db.execute('DELETE FROM metadata');
          } else {
            db.execute('UPDATE metadata SET value=?', [cursor]);
          }
          store = CompactGraphStore(db, 2);
          store.write(
            HnswNode(
              key: 'n2',
              vector: Float32List.fromList([0, 1]),
              neighbors: [
                ['n1'],
              ],
            ),
          );
          store.flush();
          store.close();
          store = CompactGraphStore(db, 2);
          expect(store.read('n1')!.vector, [1, 0]);
          expect(store.read('n2')!.vector, [0, 1]);
          expect(
            db
                .select('SELECT slot FROM nodes ORDER BY id')
                .map((r) => r['slot']),
            [0, 1],
          );
        } finally {
          store.close();
          db.close();
        }
      },
    );
  }
}
