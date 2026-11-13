import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';
import 'derived_store.dart';

/// Optional deterministic fault injection, only used by migration tests.
typedef MigrationHook = void Function(String stage);

class SchemaMigrations {
  static const version = 2;
  static const rawColumns =
      'id,parent_id,body,created_at,timezone,offset_minutes,'
      'revision,favorite,audio,duration_ms,transcript,transcription';

  static void _records(Database db, String table, {String? reference}) =>
      db.execute('''
    CREATE TABLE $table (
      id TEXT PRIMARY KEY, parent_id TEXT REFERENCES ${reference ?? table}(id) ON DELETE CASCADE,
      body TEXT NOT NULL, created_at TEXT NOT NULL, timezone TEXT NOT NULL,
      offset_minutes INTEGER NOT NULL, revision INTEGER NOT NULL,
      favorite INTEGER NOT NULL, audio TEXT, duration_ms INTEGER NOT NULL,
      transcript TEXT, transcription TEXT NOT NULL)''');

  static void _caches(Database db) {
    db.execute('CREATE TABLE pending_media_deletions (audio TEXT PRIMARY KEY)');
    db.execute('''CREATE TABLE record_organizations (
      record_id TEXT PRIMARY KEY REFERENCES records(id) ON DELETE CASCADE,
      source_revision INTEGER NOT NULL, format_version INTEGER NOT NULL,
      model_version TEXT NOT NULL, payload TEXT NOT NULL)''');
    db.execute('''CREATE TABLE record_embeddings (
      record_id TEXT PRIMARY KEY REFERENCES records(id) ON DELETE CASCADE,
      source_revision INTEGER NOT NULL, format_version INTEGER NOT NULL,
      model_version TEXT NOT NULL, dimension INTEGER NOT NULL,
      payload BLOB NOT NULL)''');
  }

  static void open(Database db, String path, {MigrationHook? hook}) {
    final current = checkSupported(db);
    db.execute('PRAGMA foreign_keys = ON');
    if (current == 0) {
      _transaction(db, () {
        _records(db, 'records');
        db.execute('CREATE INDEX records_parent ON records(parent_id)');
        db.execute(
          'CREATE TABLE restored (fingerprint TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE)',
        );
        db.execute(
          'CREATE TABLE metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
        );
        _caches(db);
        db.execute('PRAGMA user_version = 2');
        _validate(db);
      });
    } else if (current == 1) {
      final snapshot = File('$path.migration-v1.snapshot');
      // Refresh on every attempt: the older app might have changed v1 after
      // a failed upgrade. Atomically replace only our reserved snapshot file.
      final pending = File('${snapshot.path}.pending');
      if (pending.existsSync()) pending.deleteSync();
      try {
        db.execute('VACUUM INTO ?', [pending.path]);
        pending.renameSync(snapshot.path);
      } catch (_) {
        if (pending.existsSync()) pending.deleteSync();
        rethrow;
      }
      hook?.call('snapshot');
      // Rebuild both referencing tables with foreign keys disabled OUTSIDE the
      // transaction. Otherwise DROP records cascades into restored mappings.
      db.execute('PRAGMA foreign_keys = OFF');
      try {
        _transaction(db, () {
          _records(db, 'records_next', reference: 'records');
          db.execute(
            'INSERT INTO records_next ($rawColumns) SELECT $rawColumns FROM records',
          );
          db.execute(
            'CREATE TABLE restored_next (fingerprint TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE)',
          );
          db.execute(
            'INSERT INTO restored_next (fingerprint,record_id) SELECT fingerprint,record_id FROM restored',
          );
          hook?.call('copied');
          // Compare raw SQLite values before destroying the old table.
          if (db
                  .select(
                    'SELECT $rawColumns FROM records EXCEPT SELECT $rawColumns FROM records_next',
                  )
                  .isNotEmpty ||
              db
                  .select(
                    'SELECT $rawColumns FROM records_next EXCEPT SELECT $rawColumns FROM records',
                  )
                  .isNotEmpty) {
            throw const NotebookException('升级原始记录校验失败。');
          }
          _caches(db);
          final models = db.select(
            "SELECT value FROM metadata WHERE key='search_model'",
          );
          final model = models.isEmpty ? 'unversioned' : models.single['value'];
          // Keyset pages keep migration memory independent of notebook size.
          String? after;
          while (true) {
            final rows = db.select(
              'SELECT id,CASE WHEN length(CAST(organization AS BLOB)) <= 1048576 THEN organization END AS organization,organization_revision,CASE WHEN length(vector) <= 131072 THEN vector END AS vector,vector_revision FROM records WHERE (? IS NULL OR id > ?) ORDER BY id LIMIT 128',
              [after, after],
            );
            if (rows.isEmpty) break;
            for (final r in rows) {
              final org = DerivedCodec.organization(r['organization']);
              if (org != null && r['organization_revision'] is int) {
                db.execute(
                  'INSERT INTO record_organizations (record_id,source_revision,format_version,model_version,payload) VALUES (?,?,1,?,?)',
                  [
                    r['id'],
                    r['organization_revision'],
                    'organization-v1',
                    r['organization'],
                  ],
                );
              }
              final vector = DerivedCodec.legacyVector(r['vector']);
              if (vector != null && r['vector_revision'] is int) {
                db.execute(
                  'INSERT INTO record_embeddings (record_id,source_revision,format_version,model_version,dimension,payload) VALUES (?,?,1,?,?,?)',
                  [
                    r['id'],
                    r['vector_revision'],
                    model,
                    vector.length ~/ 4,
                    vector,
                  ],
                );
              }
            }
            after = rows.last['id'] as String;
          }
          db.execute('DROP TABLE restored');
          db.execute('DROP TABLE records');
          db.execute('ALTER TABLE records_next RENAME TO records');
          db.execute('ALTER TABLE restored_next RENAME TO restored');
          db.execute('CREATE INDEX records_parent ON records(parent_id)');
          hook?.call('switched');
          db.execute('PRAGMA user_version = 2');
          hook?.call('versioned');
          _validate(db);
          hook?.call('validated');
          hook?.call('beforeCommit');
        });
      } finally {
        db.execute('PRAGMA foreign_keys = ON');
      }
      // Commit and first validation finished; never use this for later rollback.
      _removeCompletedSnapshot(snapshot);
    } else {
      _validate(db);
      final staleSnapshot = File('$path.migration-v1.snapshot');
      _removeCompletedSnapshot(staleSnapshot);
    }
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
  }

  /// Safe for a read-only connection; never switches journal mode or schema.
  static int checkSupported(Database db) {
    final current =
        db.select('PRAGMA user_version').single.values.single as int;
    final nonempty = db
        .select(
          "SELECT name FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' LIMIT 1",
        )
        .isNotEmpty;
    if (current > version || current < 0 || current == 0 && nonempty) {
      throw const NotebookException('无法识别数据版本，请保留数据并更新应用。');
    }
    if (current == 1) {
      // A version number alone does not grant permission to drop unknown
      // columns or tables. The v1 transform is defined for this frozen shape.
      final expected = {
        'records': {
          ...rawColumns.split(','),
          'organization',
          'organization_revision',
          'vector',
          'vector_revision',
        },
        'restored': {'fingerprint', 'record_id'},
        'metadata': {'key', 'value'},
      };
      final tables = db.select(
        "SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'",
      );
      if (tables.length != expected.length ||
          tables.any((r) => !expected.containsKey(r['name']))) {
        throw const NotebookException('旧版数据结构不受支持，原始资料未改动。');
      }
      for (final entry in expected.entries) {
        final columns = db.select('PRAGMA table_info(${entry.key})');
        if (columns.length != entry.value.length ||
            columns.any((r) => !entry.value.contains(r['name']))) {
          throw const NotebookException('旧版数据结构不受支持，原始资料未改动。');
        }
      }
    }
    return current;
  }

  static void _removeCompletedSnapshot(File snapshot) {
    try {
      if (snapshot.existsSync()) snapshot.deleteSync();
    } on FileSystemException {
      // Cleanup is not part of the commit boundary. A retained private snapshot
      // must not make a verified, committed notebook appear to have failed.
    }
  }

  static void _validate(Database db) {
    if (db.select('PRAGMA foreign_key_check').isNotEmpty ||
        db.select('PRAGMA quick_check').single.values.single != 'ok') {
      throw const NotebookException('数据库完整性校验失败，请保留原数据。');
    }
  }

  static void _transaction(Database db, void Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      action();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}
