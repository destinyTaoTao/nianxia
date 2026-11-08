import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';

class RecordRepository {
  RecordRepository(Directory home)
    : db = sqlite3.open(p.join(home.path, 'records.sqlite')) {
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = FULL');
    final version = db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      db.close();
      throw const NotebookException('数据版本高于当前应用，请先更新应用。');
    }
    db.execute('''CREATE TABLE IF NOT EXISTS records (
      id TEXT PRIMARY KEY, parent_id TEXT REFERENCES records(id) ON DELETE CASCADE,
      body TEXT NOT NULL, created_at TEXT NOT NULL, timezone TEXT NOT NULL,
      offset_minutes INTEGER NOT NULL, revision INTEGER NOT NULL,
      favorite INTEGER NOT NULL, audio TEXT, duration_ms INTEGER NOT NULL,
      transcript TEXT, transcription TEXT NOT NULL, organization TEXT,
      organization_revision INTEGER, vector TEXT, vector_revision INTEGER)''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS records_parent ON records(parent_id)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS restored (fingerprint TEXT PRIMARY KEY, record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE)',
    );
    db.execute(
      'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)',
    );
    db.execute('PRAGMA user_version = 1');
    // A killed process cannot still be transcribing. No paid work is replayed.
    db.execute(
      "UPDATE records SET transcription = 'pending' WHERE transcription = 'running'",
    );
  }
  final Database db;
  List<Record> all() => db
      .select('SELECT * FROM records ORDER BY created_at DESC, id')
      .map(_record)
      .toList();
  Record? get(String id) {
    final rows = db.select('SELECT * FROM records WHERE id = ?', [id]);
    return rows.isEmpty ? null : _record(rows.first);
  }

  static Record _record(Row r) => Record(
    id: r['id'] as String,
    parentId: r['parent_id'] as String?,
    body: r['body'] as String,
    createdAt: DateTime.parse(r['created_at'] as String),
    timezone: r['timezone'] as String,
    offsetMinutes: r['offset_minutes'] as int,
    revision: r['revision'] as int,
    favorite: r['favorite'] == 1,
    audio: r['audio'] as String?,
    durationMs: r['duration_ms'] as int,
    transcript: r['transcript'] as String?,
    transcription: r['transcription'] as String,
    organization: r['organization'] == null
        ? null
        : jsonDecode(r['organization'] as String) as Map<String, dynamic>,
    organizationRevision: r['organization_revision'] as int?,
    vector: r['vector'] == null
        ? null
        : (jsonDecode(r['vector'] as String) as List)
              .cast<num>()
              .map((v) => v.toDouble())
              .toList(),
    vectorRevision: r['vector_revision'] as int?,
  );
  void insert(Record r) => db.execute(
    'INSERT INTO records VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    [
      r.id,
      r.parentId,
      r.body,
      r.createdAt.toUtc().toIso8601String(),
      r.timezone,
      r.offsetMinutes,
      r.revision,
      r.favorite ? 1 : 0,
      r.audio,
      r.durationMs,
      r.transcript,
      r.transcription,
      r.organization == null ? null : jsonEncode(r.organization),
      r.organizationRevision,
      null,
      null,
    ],
  );
  void edit(String id, String text, int expectedRevision) {
    db.execute(
      'UPDATE records SET body = ?, revision = revision + 1, vector = NULL, vector_revision = NULL WHERE id = ? AND revision = ?',
      [text, id, expectedRevision],
    );
    if (db.updatedRows != 1) {
      throw const NotebookException('记录已修改或删除，请重新打开后再编辑。');
    }
  }

  void favorite(String id, bool value) => db.execute(
    'UPDATE records SET favorite = ? WHERE id = ?',
    [value ? 1 : 0, id],
  );
  void delete(String id) =>
      db.execute('DELETE FROM records WHERE id = ?', [id]);
  bool transcript(String id, int revision, String text) {
    db.execute(
      "UPDATE records SET transcript = ?, body = CASE WHEN body = '' THEN ? ELSE body END, revision = revision + 1, transcription = 'done', vector = NULL, vector_revision = NULL WHERE id = ? AND revision = ?",
      [text, text, id, revision],
    );
    return db.updatedRows == 1;
  }

  void transcriptionState(String id, String state) => db.execute(
    'UPDATE records SET transcription = ? WHERE id = ?',
    [state, id],
  );
  bool derived(String id, int revision, Map<String, dynamic> result) {
    db.execute(
      'UPDATE records SET organization = ?, organization_revision = ? WHERE id = ? AND revision = ?',
      [jsonEncode(result), revision, id, revision],
    );
    return db.updatedRows == 1;
  }

  bool embedding(String id, int revision, List<double> vector) {
    db.execute(
      'UPDATE records SET vector = ?, vector_revision = ? WHERE id = ? AND revision = ?',
      [jsonEncode(vector), revision, id, revision],
    );
    return db.updatedRows == 1;
  }

  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? restoredId(String hash) {
    final rows = db.select(
      'SELECT record_id FROM restored WHERE fingerprint = ?',
      [hash],
    );
    return rows.isEmpty ? null : rows.first['record_id'] as String;
  }

  void markRestored(String hash, String id) =>
      db.execute('INSERT OR REPLACE INTO restored VALUES (?,?)', [hash, id]);
  void ensureIndexVersion(String version) => transaction(() {
    final rows = db.select(
      "SELECT value FROM metadata WHERE key='search_model'",
    );
    if (rows.isNotEmpty && rows.first['value'] == version) {
      return;
    }
    db.execute('UPDATE records SET vector = NULL, vector_revision = NULL');
    db.execute("INSERT OR REPLACE INTO metadata VALUES ('search_model',?)", [
      version,
    ]);
  });
  void close() => db.close();
}
