import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';
import '../domain/deletion_scope.dart';
import '../domain/record_page.dart';
import 'derived_store.dart';
import 'schema_migrations.dart';

class RecordRepository {
  RecordRepository(Directory home, {MigrationHook? migrationHook})
    : db = _open(home, migrationHook);

  static Database _open(Directory home, MigrationHook? hook) {
    final path = p.join(home.path, 'records.sqlite');
    if (File(path).existsSync() && File(path).lengthSync() > 0) {
      Database? probe;
      try {
        probe = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          SchemaMigrations.checkSupported(probe);
        } on SqliteException catch (error) {
          // Some system SQLite builds cannot create missing WAL auxiliary
          // files through a read-only handle. Allow SQLite's own recovery, not
          // application DML or a journal/schema change, before version checking.
          if (error.resultCode != 14) rethrow;
          probe.close();
          probe = sqlite3.open(path, mode: OpenMode.readWrite);
          SchemaMigrations.checkSupported(probe);
        }
      } finally {
        probe?.close();
      }
    }
    final db = sqlite3.open(path);
    try {
      // Connection-local KiB budget: system SQLite may default to 2000 pages
      // (~8 MiB at 4 KiB/page). This does not change the source file format.
      db.execute('PRAGMA cache_size=-2048');
      SchemaMigrations.open(db, path, hook: hook);
      // Rebuildable access paths; no original fields or schema version change.
      db.execute(
        'CREATE INDEX IF NOT EXISTS records_timeline ON records(parent_id,created_at DESC,id)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS records_favorite_timeline ON records(favorite,created_at DESC,id)',
      );
      db.execute(
        'CREATE INDEX IF NOT EXISTS records_transcription ON records(transcription,id)',
      );
      // A killed process cannot still be transcribing. No paid work is replayed.
      db.execute(
        "UPDATE records SET transcription = 'pending' WHERE transcription = 'running'",
      );
      return db;
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  final Database db;
  // Invalidates an asynchronous paged search after raw content changes.
  // Extra increments after a rolled-back transaction are harmless.
  int _contentGeneration = 0;
  int get contentGeneration => _contentGeneration;

  RecordPage page({
    RecordCursor? after,
    RecordCursor? before,
    int? generation,
    bool favorites = false,
    String? parentId,
    int limit = 40,
  }) {
    if (limit < 1 || limit > 100) throw ArgumentError.value(limit, 'limit');
    if (before != null && (after != null || parentId == null)) {
      throw ArgumentError('Previous windows require a parent and one cursor.');
    }
    final reset =
        (after != null || before != null) &&
        generation != null &&
        generation != contentGeneration;
    if (reset) {
      after = null;
      before = null;
    }
    final where = <String>[];
    final args = <Object?>[];
    if (parentId != null) {
      where.add('r.parent_id=?');
      args.add(parentId);
    } else if (!favorites) {
      where.add('r.parent_id IS NULL');
    }
    if (favorites) where.add('r.favorite=1');
    final ascending = parentId != null;
    final cursor = before ?? after;
    if (cursor != null) {
      final comparison = before != null || !ascending ? '<' : '>';
      where.add(
        '(r.created_at $comparison ? OR (r.created_at=? AND r.id${before != null ? '<' : '>'}?))',
      );
      args.addAll([cursor.createdAt, cursor.createdAt, cursor.id]);
    }
    final columns = SchemaMigrations.rawColumns
        .split(',')
        .map(
          (c) => c == 'body'
              ? 'substr(r.body,1,600) AS body'
              : c == 'transcript'
              ? 'NULL AS transcript'
              : 'r.$c',
        )
        .join(',');
    final rows = db.select(
      '''SELECT $columns,
      (SELECT count(*) FROM records c WHERE c.parent_id=r.id) AS append_count
      FROM records r ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ORDER BY r.created_at ${ascending && before == null ? 'ASC' : 'DESC'},r.id ${before != null ? 'DESC' : 'ASC'} LIMIT ?''',
      [...args, limit + 1],
    );
    final visible = before == null
        ? rows.take(limit).toList()
        : rows.take(limit).toList().reversed.toList();
    final entries = visible
        .map(
          (row) => RecordListEntry(_rawRecord(row), row['append_count'] as int),
        )
        .toList();
    final last = visible.lastOrNull;
    final first = visible.firstOrNull;
    bool exists(String direction, Row row) => db.select(
      'SELECT 1 FROM records WHERE parent_id=? AND (created_at $direction ? OR (created_at=? AND id $direction ?)) LIMIT 1',
      [parentId, row['created_at'], row['created_at'], row['id']],
    ).isNotEmpty;
    final hasNext =
        last != null &&
        (before != null ? exists('>', last) : rows.length > limit);
    return RecordPage(
      entries,
      hasNext
          ? RecordCursor(last['created_at'] as String, last['id'] as String)
          : null,
      contentGeneration,
      reset: reset,
      previous: parentId != null && first != null && exists('<', first)
          ? RecordCursor(first['created_at'] as String, first['id'] as String)
          : null,
    );
  }

  Record _rawRecord(Row r) => Record(
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
  );

  int childCount(String id) =>
      db.select('SELECT count(*) n FROM records WHERE parent_id=?', [
            id,
          ]).single['n']
          as int;
  RecordDetail? detail(
    String id, {
    RecordCursor? after,
    RecordCursor? before,
    String? aroundId,
    int? generation,
  }) {
    final record = get(id);
    if (aroundId != null) {
      if (after != null || before != null) {
        throw ArgumentError('One window selector is allowed.');
      }
      final anchor = db.select(
        'SELECT created_at,id FROM records WHERE id=? AND parent_id=? LIMIT 1',
        [aroundId, id],
      );
      if (anchor.isNotEmpty) {
        final row = anchor.single;
        final earlier = db.select(
          'SELECT created_at,id FROM records WHERE parent_id=? AND (created_at<? OR (created_at=? AND id<=?)) ORDER BY created_at DESC,id DESC LIMIT 21',
          [id, row['created_at'], row['created_at'], row['id']],
        );
        if (earlier.length == 21) {
          final start = earlier.last;
          after = RecordCursor(
            start['created_at'] as String,
            start['id'] as String,
          );
        }
      }
    }
    return record == null
        ? null
        : RecordDetail(
            record,
            page(
              parentId: id,
              after: after,
              before: before,
              generation: generation,
            ),
            childCount(id),
          );
  }

  List<Record> children(String id) {
    final orgModel = organizationModelVersion, vectorModel = indexModelVersion;
    return db
        .select(
          '${_query(true)} WHERE r.parent_id=? ORDER BY r.created_at,r.id',
          [id],
        )
        .map(
          (row) => _record(
            row,
            includeVectors: true,
            orgModel: orgModel,
            vectorModel: vectorModel,
          ),
        )
        .toList();
  }

  List<String> audioReferences() => db
      .select('SELECT DISTINCT audio FROM records WHERE audio IS NOT NULL')
      .map((r) => r['audio'] as String)
      .toList();

  List<Record> pendingJobs({required bool transcription, String after = ''}) {
    final condition = transcription
        ? "r.transcription='pending'"
        : '''r.body<>'' AND NOT EXISTS (
      SELECT 1 FROM record_embeddings e WHERE e.record_id=r.id AND e.source_revision=r.revision
      AND e.model_version=? AND e.format_version=1 AND e.dimension BETWEEN 1 AND 4096
      AND typeof(e.payload)='blob' AND length(e.payload)=e.dimension*4)''';
    return db
        .select(
          '''SELECT ${SchemaMigrations.rawColumns.split(',').map((c) => 'r.$c').join(',')}
      FROM records r WHERE r.id>? AND $condition ORDER BY r.id LIMIT 32''',
          [after, if (!transcription) indexModelVersion],
        )
        .map(_rawRecord)
        .toList();
  }

  String? get themeMode {
    final rows = db.select("SELECT value FROM metadata WHERE key='theme_mode'");
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void saveThemeMode(String mode) => db.execute(
    "INSERT OR REPLACE INTO metadata (key,value) VALUES ('theme_mode',?)",
    [mode],
  );

  String _model(String key, String fallback) {
    final rows = db.select('SELECT value FROM metadata WHERE key=?', [key]);
    return rows.isEmpty || rows.single['value'] is! String
        ? fallback
        : rows.single['value'] as String;
  }

  String get indexModelVersion => _model('search_model', 'unversioned');
  String get organizationModelVersion =>
      _model('organization_model', 'organization-v1');

  String _query(bool vectors, {bool organization = true}) =>
      '''SELECT
    ${SchemaMigrations.rawColumns.split(',').map((c) => 'r.$c').join(',')},
    o.source_revision AS org_revision,o.format_version AS org_format,
    o.model_version AS org_model,
    ${organization ? 'CASE WHEN length(CAST(o.payload AS BLOB)) <= ${DerivedCodec.maxOrganizationBytes} THEN o.payload END' : 'NULL'} AS org_payload,
    e.source_revision AS vector_revision,e.format_version AS vector_format,
    e.model_version AS vector_model,e.dimension AS vector_dimension,
    length(e.payload) AS vector_bytes,typeof(e.payload) AS vector_type
    ${vectors ? ', CASE WHEN length(e.payload) <= ${DerivedCodec.maxDimensions * 4} THEN e.payload END AS vector_payload' : ''}
    FROM records r
    LEFT JOIN record_organizations o ON o.record_id=r.id
    LEFT JOIN record_embeddings e ON e.record_id=r.id''';

  List<Record> all({bool includeVectors = false}) {
    final orgModel = _model('organization_model', 'organization-v1');
    final vectorModel = indexModelVersion;
    return db
        .select('${_query(includeVectors)} ORDER BY r.created_at DESC, r.id')
        .map(
          (r) => _record(
            r,
            includeVectors: includeVectors,
            orgModel: orgModel,
            vectorModel: vectorModel,
          ),
        )
        .toList();
  }

  /// Keyset pages bound decoded vector memory. Search does not need cloud
  /// organization payloads; do not decode them just to discard most records.
  List<Record> searchPage({String? after, required bool includeVectors}) {
    final vectorModel = indexModelVersion;
    final query = _query(includeVectors, organization: false);
    return db
        .select(
          '$query ${after == null ? '' : 'WHERE r.id > ?'} ORDER BY r.id LIMIT 64',
          [?after],
        )
        .map(
          (r) => _record(
            r,
            includeVectors: includeVectors,
            orgModel: '',
            vectorModel: vectorModel,
          ),
        )
        .toList();
  }

  /// Bounded source materialization for the pending-vector retrieval path.
  List<Record> searchRecords(List<String> ids) {
    if (ids.isEmpty) return [];
    if (ids.length > 64) throw ArgumentError.value(ids.length, 'ids');
    final model = indexModelVersion;
    return db
        .select(
          '${_query(true, organization: false)} WHERE r.id IN (${List.filled(ids.length, '?').join(',')})',
          ids,
        )
        .map(
          (row) => _record(
            row,
            includeVectors: true,
            orgModel: '',
            vectorModel: model,
          ),
        )
        .toList();
  }

  Record? get(String id) {
    final rows = db.select('${_query(true)} WHERE r.id = ?', [id]);
    return rows.isEmpty
        ? null
        : _record(
            rows.first,
            includeVectors: true,
            orgModel: _model('organization_model', 'organization-v1'),
            vectorModel: indexModelVersion,
          );
  }

  /// Complete records for bounded candidate hydration. Missing IDs are omitted;
  /// callers retain their own ranking order instead of relying on SQL order.
  List<Record> getBatch(List<String> ids) {
    if (ids.isEmpty) return [];
    if (ids.length > 64) throw ArgumentError.value(ids.length, 'ids');
    final rows = db.select(
      '${_query(true)} WHERE r.id IN (${List.filled(ids.length, '?').join(',')})',
      ids,
    );
    if (rows.isEmpty) return [];
    final orgModel = _model('organization_model', 'organization-v1');
    final vectorModel = indexModelVersion;
    return rows
        .map(
          (row) => _record(
            row,
            includeVectors: true,
            orgModel: orgModel,
            vectorModel: vectorModel,
          ),
        )
        .toList();
  }

  Record _record(
    Row r, {
    required bool includeVectors,
    required String orgModel,
    required String vectorModel,
  }) {
    final org =
        r['org_format'] == DerivedCodec.formatVersion &&
            r['org_model'] == orgModel &&
            r['org_revision'] is int
        ? DerivedCodec.organization(r['org_payload'])
        : null;
    final dimension = r['vector_dimension'];
    var vectorValid =
        r['vector_format'] == DerivedCodec.formatVersion &&
        r['vector_model'] == vectorModel &&
        r['vector_revision'] == r['revision'] &&
        dimension is int &&
        dimension > 0 &&
        dimension <= DerivedCodec.maxDimensions &&
        r['vector_bytes'] == dimension * 4 &&
        r['vector_type'] == 'blob';
    final vector = vectorValid && includeVectors
        ? DerivedCodec.vector(r['vector_payload'], dimension)
        : null;
    if (includeVectors && vector == null) vectorValid = false;
    return Record(
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
      organization: org,
      organizationRevision: org == null ? null : r['org_revision'] as int,
      vector: vector,
      vectorRevision: vectorValid ? r['vector_revision'] as int : null,
    );
  }

  void insert(Record r) {
    db.execute(
      'INSERT INTO records (${SchemaMigrations.rawColumns}) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
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
      ],
    );
    _contentGeneration++;
    if (r.organization != null && r.organizationRevision != null) {
      _writeOrganization(r.id, r.organizationRevision!, r.organization!);
    }
  }

  Record insertText(Record value, {bool standalone = false}) {
    db.execute('SAVEPOINT submit_text');
    try {
      final existing = get(value.id);
      if (existing != null) {
        db.execute('RELEASE submit_text');
        return existing;
      }
      final parentId = standalone ? null : value.parentId;
      if (parentId != null) {
        final parents = db.select(
          'SELECT parent_id FROM records WHERE id=? LIMIT 1',
          [parentId],
        );
        if (parents.isEmpty) throw const NotebookException('原记录已删除，追加内容仍保留。');
        if (parents.single['parent_id'] != null) {
          throw const NotebookException('请追加到原记录。');
        }
      }
      final saved = Record(
        id: value.id,
        body: value.body,
        parentId: parentId,
        createdAt: value.createdAt,
        timezone: value.timezone,
        offsetMinutes: value.offsetMinutes,
      );
      insert(saved);
      db.execute('RELEASE submit_text');
      return saved;
    } catch (_) {
      db.execute('ROLLBACK TO submit_text');
      db.execute('RELEASE submit_text');
      rethrow;
    }
  }

  void edit(String id, String text, int expectedRevision) {
    db.execute(
      'UPDATE records SET body = ?, revision = revision + 1 WHERE id = ? AND revision = ?',
      [text, id, expectedRevision],
    );
    if (db.updatedRows != 1) {
      throw const NotebookException('记录已修改或删除，请重新打开后再编辑。');
    }
    _contentGeneration++;
    // The source revision invalidates the old cache without coupling a saved
    // user edit to a second cache write. Reindexing replaces the stale payload.
  }

  void favorite(String id, bool value) {
    db.execute('UPDATE records SET favorite = ? WHERE id = ?', [
      value ? 1 : 0,
      id,
    ]);
    _contentGeneration++;
  }

  DeletionScope deletionScope(String id) {
    final statement = db.prepare('''WITH RECURSIVE doomed(id) AS (
      SELECT id FROM records WHERE id=?
      UNION SELECT r.id FROM records r JOIN doomed d ON r.parent_id=d.id
    ) SELECT r.* FROM records r WHERE r.id IN doomed ORDER BY r.id''');
    final digest = _ScopeDigest();
    final hash = sha256.startChunkedConversion(digest);
    var count = 0;
    String? parent;
    try {
      final rows = statement.selectCursor([id]);
      while (rows.moveNext()) {
        final row = rows.current;
        if (row['id'] == id) parent = row['parent_id'] as String?;
        // One source row at a time; IDs, raw text and source versions participate
        // so equal counts or an imported same-ID replacement cannot reuse consent.
        hash.add(utf8.encode(jsonEncode(row.values.toList())));
        count++;
      }
      hash.close();
      if (count == 0) throw const NotebookException('这条记录已删除，请返回查找。');
      return DeletionScope(
        id: id,
        parentId: parent,
        count: count,
        digest: digest.value!,
      );
    } finally {
      statement.close();
    }
  }

  void delete(String id, {DeletionScope? scope}) {
    // A savepoint also keeps deletion atomic when called inside restore/test
    // transactions. Queue only audio whose last owning record is being removed.
    db.execute('SAVEPOINT delete_records');
    try {
      if (scope != null) {
        final current = deletionScope(id);
        if (scope.id != id ||
            scope.count != current.count ||
            scope.parentId != current.parentId ||
            scope.digest != current.digest) {
          throw const NotebookException('记录或追加已变化，请重新确认删除范围。');
        }
      }
      db.execute(
        '''WITH RECURSIVE doomed(id) AS (
        SELECT id FROM records WHERE id=?
        UNION SELECT r.id FROM records r JOIN doomed d ON r.parent_id=d.id
      ) INSERT OR IGNORE INTO pending_media_deletions (audio)
        SELECT DISTINCT r.audio FROM records r WHERE r.id IN doomed
        AND r.audio IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM records kept WHERE kept.audio=r.audio
          AND kept.id NOT IN doomed)''',
        [id],
      );
      db.execute('DELETE FROM records WHERE id = ?', [id]);
      db.execute('RELEASE delete_records');
      _contentGeneration++;
    } catch (_) {
      db.execute('ROLLBACK TO delete_records');
      db.execute('RELEASE delete_records');
      rethrow;
    }
  }

  List<String> pendingMediaDeletions() => db
      .select('''
    SELECT audio FROM pending_media_deletions p
    WHERE NOT EXISTS (SELECT 1 FROM records r WHERE r.audio=p.audio)
    ORDER BY audio''')
      .map((r) => r['audio'] as String)
      .toList();

  void completeMediaDeletion(String audio) =>
      db.execute('DELETE FROM pending_media_deletions WHERE audio=?', [audio]);

  void reserveMediaForCleanup(String audio) => db.execute(
    'INSERT OR IGNORE INTO pending_media_deletions (audio) SELECT ? WHERE NOT EXISTS (SELECT 1 FROM records WHERE audio=?)',
    [audio, audio],
  );

  bool completeReferencedMediaDeletions() {
    try {
      db.execute(
        'DELETE FROM pending_media_deletions WHERE EXISTS (SELECT 1 FROM records r WHERE r.audio=pending_media_deletions.audio)',
      );
      return true;
    } on SqliteException {
      return false;
    }
  }

  bool transcript(String id, int revision, String text) {
    db.execute(
      "UPDATE records SET transcript = ?, body = CASE WHEN body = '' THEN ? ELSE body END, revision = revision + 1, transcription = 'done' WHERE id = ? AND revision = ?",
      [text, text, id, revision],
    );
    if (db.updatedRows != 1) return false;
    _contentGeneration++;
    return true;
  }

  void transcriptionState(String id, String state) => db.execute(
    'UPDATE records SET transcription = ? WHERE id = ?',
    [state, id],
  );

  void _writeOrganization(
    String id,
    int revision,
    Map<String, dynamic> result,
  ) {
    final encoded = DerivedCodec.encodeOrganization(result);
    if (encoded == null) return;
    db.execute(
      'INSERT OR REPLACE INTO record_organizations (record_id,source_revision,format_version,model_version,payload) VALUES (?,?,1,?,?)',
      [id, revision, _model('organization_model', 'organization-v1'), encoded],
    );
  }

  bool derived(
    String id,
    int revision,
    Map<String, dynamic> result, {
    String? modelVersion,
  }) {
    final encoded = DerivedCodec.encodeOrganization(result);
    final model = _model('organization_model', 'organization-v1');
    if (encoded == null || modelVersion != null && modelVersion != model) {
      return false;
    }
    db.execute(
      'INSERT OR REPLACE INTO record_organizations (record_id,source_revision,format_version,model_version,payload) SELECT id,revision,1,?,? FROM records WHERE id=? AND revision=?',
      [model, encoded, id, revision],
    );
    return db.updatedRows == 1;
  }

  bool embedding(
    String id,
    int revision,
    List<double> vector, {
    String? modelVersion,
  }) {
    final bytes = DerivedCodec.encodeVector(vector);
    final model = _model('search_model', 'unversioned');
    if (bytes == null || modelVersion != null && modelVersion != model) {
      return false;
    }
    db.execute(
      'INSERT OR REPLACE INTO record_embeddings (record_id,source_revision,format_version,model_version,dimension,payload) SELECT id,revision,1,?,?,? FROM records WHERE id=? AND revision=?',
      [model, vector.length, bytes, id, revision],
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

  void markRestored(String hash, String id) => db.execute(
    'INSERT OR REPLACE INTO restored (fingerprint,record_id) VALUES (?,?)',
    [hash, id],
  );

  void _ensureModel(String key, String version, String table) =>
      transaction(() {
        final rows = db.select('SELECT value FROM metadata WHERE key=?', [key]);
        if (rows.isNotEmpty && rows.first['value'] == version) return;
        db.execute('DELETE FROM $table');
        db.execute('INSERT OR REPLACE INTO metadata (key,value) VALUES (?,?)', [
          key,
          version,
        ]);
      });
  void ensureIndexVersion(String version) =>
      _ensureModel('search_model', version, 'record_embeddings');
  void ensureOrganizationVersion(String version) =>
      _ensureModel('organization_model', version, 'record_organizations');

  /// SQLite reads a single consistent source, including committed WAL pages.
  void snapshotTo(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const NotebookException('快照目标已存在，不能覆盖。');
    }
    db.execute('VACUUM INTO ?', [path]);
  }

  void close() => db.close();
}

class _ScopeDigest implements Sink<Digest> {
  String? value;
  @override
  void add(Digest data) => value = data.toString();
  @override
  void close() {}
}
