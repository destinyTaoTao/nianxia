import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/data/record_repository.dart';

import 'fixtures/schema_v1.dart';

void main() {
  late Directory home;
  setUp(() {
    home = Directory.systemTemp.createTempSync('nianxia-migration-');
  });
  tearDown(() {
    home.deleteSync(recursive: true);
  });

  void fixture() {
    final db = sqlite3.open('${home.path}/records.sqlite');
    db.execute(File('test/fixtures/schema_v1.sql').readAsStringSync());
    db.close();
    File('${home.path}/original.wav').writeAsBytesSync([0, 1, 255, 42]);
  }

  test('native and host frozen v1 fixtures stay identical', () {
    expect(
      schemaV1Fixture.trim(),
      File('test/fixtures/schema_v1.sql').readAsStringSync().trim(),
    );
  });

  test('v1 migrates raw fields, mappings, metadata and audio without loss', () {
    fixture();
    final r = RecordRepository(home);
    try {
      expect(r.db.select('PRAGMA user_version').single.values.single, 2);
      expect(r.db.select('PRAGMA table_info(records)').length, 12);
      expect(r.get('parent')!.body, '原文不改写');
      expect(r.get('parent')!.revision, 7);
      expect(r.get('parent')!.transcript, '原始转写');
      expect(r.get('parent')!.favorite, isTrue);
      expect(r.get('child')!.parentId, 'parent');
      expect(r.restoredId('frozen-hash'), 'parent');
      expect(r.themeMode, 'dark');
      expect(r.db.select('PRAGMA foreign_key_check'), isEmpty);
      expect(File('${home.path}/original.wav').readAsBytesSync(), [
        0,
        1,
        255,
        42,
      ]);
      r.delete('parent');
      expect(r.all(), isEmpty);
      expect(r.restoredId('frozen-hash'), isNull);
    } finally {
      r.close();
    }
  });

  test('unknown nonempty version zero is rejected without journal change', () {
    final db = sqlite3.open('${home.path}/records.sqlite');
    db.execute('CREATE TABLE unknown (value TEXT)');
    db.execute("INSERT INTO unknown VALUES ('keep')");
    final journal = db.select('PRAGMA journal_mode').single.values.single;
    db.close();
    expect(() => RecordRepository(home), throwsA(anything));
    final check = sqlite3.open('${home.path}/records.sqlite');
    expect(check.select('PRAGMA journal_mode').single.values.single, journal);
    expect(check.select('SELECT value FROM unknown').single['value'], 'keep');
    expect(check.select('PRAGMA user_version').single.values.single, 0);
    check.close();
  });

  test('higher schema is rejected without modifying journal mode', () {
    final db = sqlite3.open('${home.path}/records.sqlite');
    db.execute('PRAGMA user_version = 99');
    db.close();
    expect(() => RecordRepository(home), throwsA(anything));
    final check = sqlite3.open('${home.path}/records.sqlite');
    expect(check.select('PRAGMA journal_mode').single.values.single, 'delete');
    expect(check.select('PRAGMA user_version').single.values.single, 99);
    check.close();
  });

  test(
    'v1 with unknown raw columns is refused instead of discarding values',
    () {
      fixture();
      final db = sqlite3.open('${home.path}/records.sqlite');
      db.execute('ALTER TABLE records ADD COLUMN unknown_user_data TEXT');
      db.execute("UPDATE records SET unknown_user_data='must survive'");
      db.close();
      expect(() => RecordRepository(home), throwsA(anything));
      final check = sqlite3.open('${home.path}/records.sqlite');
      try {
        expect(check.select('PRAGMA user_version').single.values.single, 1);
        expect(
          check
              .select('SELECT unknown_user_data FROM records')
              .first['unknown_user_data'],
          'must survive',
        );
      } finally {
        check.close();
      }
    },
  );

  test(
    'retry refreshes its snapshot if the old app edited v1 after failure',
    () {
      fixture();
      expect(
        () => RecordRepository(
          home,
          migrationHook: (stage) {
            if (stage == 'copied') throw StateError('stop');
          },
        ),
        throwsStateError,
      );
      final old = sqlite3.open('${home.path}/records.sqlite');
      old.execute(
        "UPDATE records SET body='new edit before retry' WHERE id='parent'",
      );
      old.close();
      final retry = RecordRepository(
        home,
        migrationHook: (stage) {
          if (stage != 'snapshot') return;
          final snapshot = sqlite3.open(
            '${home.path}/records.sqlite.migration-v1.snapshot',
            mode: OpenMode.readOnly,
          );
          try {
            expect(
              snapshot
                  .select("SELECT body FROM records WHERE id='parent'")
                  .single['body'],
              'new edit before retry',
            );
          } finally {
            snapshot.close();
          }
        },
      );
      retry.close();
    },
  );
  test('fresh and migrated databases have equivalent constraints', () {
    fixture();
    final migrated = RecordRepository(home);
    final freshHome = Directory.systemTemp.createTempSync('nianxia-fresh-');
    final fresh = RecordRepository(freshHome);
    try {
      for (final table in [
        'records',
        'restored',
        'metadata',
        'record_organizations',
        'record_embeddings',
        'pending_media_deletions',
      ]) {
        for (final pragma in ['table_info', 'foreign_key_list', 'index_list']) {
          List<List<Object?>> shape(RecordRepository r) => r.db
              .select('PRAGMA $pragma($table)')
              .map((row) => row.values.toList())
              .toList();
          expect(shape(migrated), shape(fresh), reason: '$pragma($table)');
        }
      }
    } finally {
      migrated.close();
      fresh.close();
      freshHome.deleteSync(recursive: true);
    }
  });

  for (final stage in [
    'snapshot',
    'copied',
    'switched',
    'versioned',
    'validated',
    'beforeCommit',
  ]) {
    test(
      'migration failure at $stage leaves v1 retryable and audio untouched',
      () {
        fixture();
        expect(
          () => RecordRepository(
            home,
            migrationHook: (at) {
              if (at == stage) throw StateError('injected $stage');
            },
          ),
          throwsStateError,
        );
        final check = sqlite3.open('${home.path}/records.sqlite');
        expect(check.select('PRAGMA user_version').single.values.single, 1);
        expect(
          check
              .select('SELECT body,revision FROM records WHERE id=?', [
                'parent',
              ])
              .single
              .values
              .toList(),
          ['原文不改写', 7],
        );
        expect(
          check.select('SELECT record_id FROM restored').single['record_id'],
          'parent',
        );
        expect(check.select('PRAGMA foreign_key_check'), isEmpty);
        check.close();
        expect(File('${home.path}/original.wav').readAsBytesSync(), [
          0,
          1,
          255,
          42,
        ]);
        final retry = RecordRepository(home);
        expect(retry.get('child')!.parentId, 'parent');
        retry.close();
        expect(
          File('${home.path}/records.sqlite.migration-v1.snapshot')
              .existsSync(),
          isFalse,
        );
      },
    );
  }

  test('snapshot includes committed WAL and does not overwrite targets', () {
    fixture();
    final r = RecordRepository(home);
    final target = '${home.path}/snapshot-quote\'.sqlite';
    try {
      r.edit('parent', '快照正文', 7);
      r.snapshotTo(target);
      r.edit('parent', '后续编辑', 8);
      expect(() => r.snapshotTo(target), throwsA(anything));
      final snapshot = sqlite3.open(target, mode: OpenMode.readOnly);
      expect(
        snapshot.select('SELECT body FROM records WHERE id=?', [
          'parent',
        ]).single['body'],
        '快照正文',
      );
      expect(snapshot.select('PRAGMA quick_check').single.values.single, 'ok');
      snapshot.close();
    } finally {
      r.close();
    }
  });

  test('deleting a group atomically journals only its unreferenced audio', () {
    fixture();
    final r = RecordRepository(home);
    try {
      expect(
        r.db.select(
          "SELECT name FROM sqlite_schema WHERE name='pending_media_deletions'",
        ),
        hasLength(1),
      );
      r.db.execute("UPDATE records SET audio='original.wav' WHERE id='child'");
      r.db.execute(
        "CREATE TRIGGER refuse_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      );
      expect(() => r.delete('parent'), throwsA(anything));
      expect(r.db.select('SELECT audio FROM pending_media_deletions'), isEmpty);
      expect(r.all(), hasLength(2));
      r.db.execute('DROP TRIGGER refuse_delete');
      r.transaction(() => r.delete('parent'));
      expect(r.pendingMediaDeletions(), ['original.wav']);
      expect(File('${home.path}/original.wav').readAsBytesSync(), [
        0,
        1,
        255,
        42,
      ]);
      r.completeMediaDeletion('original.wav');
      expect(r.pendingMediaDeletions(), isEmpty);
    } finally {
      r.close();
    }
  });
}
