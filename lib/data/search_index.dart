import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';
import '../domain/semantic_vector.dart';
import 'derived_store.dart';
import 'compact_graph_store.dart';
import 'hnsw.dart';
import 'record_repository.dart';
import 'record_search_store.dart';

/// Disposable, worker-owned access paths. Source commits never depend on this
/// database. Update hooks only enqueue row IDs: SQLite forbids reentry there.
class SearchIndex {
  SearchIndex(this.source, this.home, {this.searchEf = 200}) {
    if (searchEf < 128) throw ArgumentError.value(searchEf, 'searchEf');
    _updates = source.db.updatesSync.listen((event) {
      if (event.tableName == 'records' ||
          event.tableName == 'record_embeddings' ||
          event.tableName == 'metadata') {
        _generation++;
        if (!_fullReconcile) {
          _dirty.add((event.tableName, event.rowId));
          if (_dirty.length > 4096) {
            _dirty.clear();
            _fullReconcile = true;
          }
        }
        if (_buildRequested && !_wakeScheduled) {
          _wakeScheduled = true;
          scheduleMicrotask(() {
            _wakeScheduled = false;
            _startBuild();
          });
        }
      }
    });
  }
  final RecordRepository source;
  final Directory home;
  final int searchEf;
  late final StreamSubscription<SqliteUpdate> _updates;
  final _dirty = <(String, int)>{};
  final _stores = <int, CompactGraphStore>{};
  final _termIds = <String, int>{};
  final _termDeltas = <int, int>{};
  PreparedStatement? _findTerm,
      _insertTerm,
      _insertPosting,
      _countTerm,
      _deleteTerm;
  Database? _db;
  int _generation = 0, _externalVersion = -1;
  String? _model;
  Future<void>? _preparing;
  Future<void>? _background, _closeFuture;
  Completer<void>? _idle;
  Object? _buildError;
  int _activeQueries = 0;
  bool _closed = false, _buildRequested = false, _wakeScheduled = false;
  bool _ready = false;
  bool _entriesVerified = false;
  bool _fullReconcile = false, _rebuild = false;
  int _vectorSequence = 0;

  // Counts contain no record content. Tests/benchmarks observe actual work.
  int keywordCandidates = 0, sourceRecordsRead = 0, reconciledRecords = 0;
  int distanceEvaluations = 0;
  Object _sourceVersion() => (
    source.contentGeneration,
    source.indexModelVersion,
    source.db.select('PRAGMA data_version').single.values.first,
  );

  Future<void> close() => _closeFuture ??= _finishClose();
  Future<void> _finishClose() async {
    _closed = true;
    await _updates.cancel();
    await _idle?.future;
    await _background;
    _clearStores();
    for (final statement in [
      _findTerm,
      _insertTerm,
      _insertPosting,
      _countTerm,
      _deleteTerm,
    ]) {
      statement?.close();
    }
    _db?.close();
    _db = null;
  }

  Database _open() {
    final path = p.join(home.path, 'search-index.sqlite');
    // Cache schema numbers are independent of the source schema. Never follow
    // a cache path/auxiliary link into original data, even if versions match.
    for (final tail in ['', '-wal', '-shm']) {
      final target = '$path$tail';
      final type = FileSystemEntity.typeSync(target, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FormatException('Unsafe search cache path');
      }
      if (type == FileSystemEntityType.file) {
        for (final rawTail in ['', '-wal', '-shm']) {
          final raw = p.join(home.path, 'records.sqlite$rawTail');
          if (File(raw).existsSync() &&
              FileSystemEntity.identicalSync(raw, target)) {
            throw const FormatException('Search cache aliases source data');
          }
        }
      }
    }
    Database open() {
      final db = sqlite3.open(path);
      var closed = false;
      try {
        final version = db.userVersion;
        if (version > 3) throw const FormatException('Future search index');
        const tables = {
          'docs',
          'postings',
          'terms',
          'nodes',
          'entries',
          'pending_vectors',
          'metadata',
        };
        final actual = db
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toSet();
        final appId = db.select('PRAGMA application_id').single.values.first;
        final expected = {...tables, if (version == 3) 'vector_blocks'};
        if (version == 0 && (actual.isNotEmpty || appId != 0) ||
            version > 0 &&
                (actual.length != expected.length ||
                    !actual.containsAll(expected)) ||
            version >= 2 && appId != 0x4e585349 ||
            version == 1 && appId != 0 && appId != 0x4e585349) {
          throw const FormatException('Unknown search cache');
        }
        if (version == 1 || version == 2) {
          // Only an identified disposable cache may be physically replaced.
          // Dropping tables would retain hundreds of MiB of allocated pages.
          db.close();
          closed = true;
          for (final tail in ['-wal', '-shm', '']) {
            final file = File('$path$tail');
            if (file.existsSync()) file.deleteSync();
          }
          return open();
        }
        // Bound native page memory as well as the Dart graph working set.
        // Negative values are KiB, independent of this SQLite build's defaults.
        db.execute('PRAGMA cache_size=-2048');
        final check = db.select('PRAGMA quick_check');
        if (check.length != 1 || check.first.values.first != 'ok') {
          throw const _IndexCorruption('Damaged search index');
        }
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA synchronous=NORMAL');
        db.execute('BEGIN');
        db.execute('''
          CREATE TABLE IF NOT EXISTS docs (
            id TEXT PRIMARY KEY, source_rowid INTEGER UNIQUE,
            embedding_rowid INTEGER, signature TEXT NOT NULL,
            body TEXT NOT NULL, day TEXT NOT NULL, vector_key TEXT,
            dimension INTEGER);
          CREATE INDEX IF NOT EXISTS docs_embedding ON docs(embedding_rowid);
          CREATE INDEX IF NOT EXISTS docs_vector_key ON docs(vector_key);
          CREATE INDEX IF NOT EXISTS docs_keyword_date ON docs(day,id);
          CREATE INDEX IF NOT EXISTS docs_vector_date ON docs(dimension,day,vector_key);
          CREATE INDEX IF NOT EXISTS docs_dimension ON docs(dimension,vector_key);
          CREATE TABLE IF NOT EXISTS postings (
            term INTEGER NOT NULL, doc INTEGER NOT NULL,
            PRIMARY KEY(term,doc)) WITHOUT ROWID;
          CREATE INDEX IF NOT EXISTS postings_doc ON postings(doc);
          CREATE TABLE IF NOT EXISTS terms (
            id INTEGER PRIMARY KEY, term TEXT UNIQUE NOT NULL, count INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS nodes (
            id INTEGER PRIMARY KEY, dimension INTEGER NOT NULL,
            slot INTEGER NOT NULL, neighbors BLOB NOT NULL,
            deleted INTEGER NOT NULL);
          CREATE INDEX IF NOT EXISTS nodes_dimension ON nodes(dimension,deleted);
          CREATE INDEX IF NOT EXISTS nodes_deleted ON nodes(deleted);
          CREATE UNIQUE INDEX IF NOT EXISTS nodes_slot ON nodes(dimension,slot);
          -- Keep large vector payloads in a rowid table. WITHOUT ROWID puts
          -- them inside the index records and amplifies random B-tree reads.
          CREATE TABLE IF NOT EXISTS vector_blocks (
            dimension INTEGER NOT NULL, block INTEGER NOT NULL, payload BLOB NOT NULL,
            PRIMARY KEY(dimension,block));
          CREATE TABLE IF NOT EXISTS entries (
            dimension INTEGER PRIMARY KEY, key TEXT);
          CREATE TABLE IF NOT EXISTS pending_vectors (
            id TEXT PRIMARY KEY) WITHOUT ROWID;
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT);
          PRAGMA application_id=1314411337;
          PRAGMA user_version=3;
          COMMIT;
        ''');
        return db;
      } catch (_) {
        if (!closed) db.close();
        rethrow;
      }
    }

    void quarantine() {
      final suffix = '.corrupt-${DateTime.now().microsecondsSinceEpoch}';
      for (final tail in ['', '-wal', '-shm']) {
        final file = File('$path$tail');
        if (file.existsSync()) file.renameSync('$path$suffix$tail');
      }
    }

    try {
      return open();
    } on _IndexCorruption {
      quarantine();
      return open();
    } on SqliteException catch (error) {
      // Only corruption is rebuilt here. Full disk, permissions, and future
      // versions use the source-only fallback; never touch records.sqlite.
      if (error.resultCode != 11 && error.resultCode != 26) rethrow;
      quarantine();
      return open();
    }
  }

  T _transaction<T>(T Function() action) {
    final db = _db!;
    db.execute('BEGIN');
    try {
      final value = action();
      for (final store in _stores.values) {
        store.flush();
      }
      _countTerm ??= db.prepare('UPDATE terms SET count=count+? WHERE id=?');
      for (final delta in _termDeltas.entries) {
        _countTerm!.execute([delta.value, delta.key]);
      }
      for (final delta in _termDeltas.entries) {
        if (delta.value >= 0) continue;
        _deleteTerm ??= db.prepare('DELETE FROM terms WHERE id=? AND count<=0');
        _deleteTerm!.execute([delta.key]);
        if (db.updatedRows > 0) _termIds.clear();
      }
      db.execute('COMMIT');
      _termDeltas.clear();
      return value;
    } catch (_) {
      // RAISE(ROLLBACK), full disk and some I/O failures can have already
      // ended the transaction. Always discard tentative in-memory state.
      if (!db.autocommit) db.execute('ROLLBACK');
      _clearStores(); // Never retain graph nodes from a rolled-back write.
      _termIds.clear();
      _termDeltas.clear();
      rethrow;
    }
  }

  static Set<String> _grams(String text) {
    final runes = text.runes.toList();
    final terms = <String>{};
    for (var at = 0; at < runes.length; at++) {
      for (var n = 1; n <= 3 && at + n <= runes.length; n++) {
        // A length prefix distinguishes grams even when text contains NUL.
        terms.add('$n:${String.fromCharCodes(runes.sublist(at, at + n))}');
      }
    }
    return terms;
  }

  CompactGraphStore _store(int dimension) {
    final store =
        _stores.remove(dimension) ?? CompactGraphStore(_db!, dimension);
    _stores[dimension] = store;
    if (_stores.length > 4) {
      final evicted = _stores.remove(_stores.keys.first)!;
      try {
        evicted.flush();
      } finally {
        evicted.close();
      }
    }
    return store;
  }

  void _clearStores() {
    for (final store in _stores.values) {
      store.close();
    }
    _stores.clear();
  }

  int _termId(String term) {
    final cached = _termIds.remove(term);
    if (cached != null) {
      _termIds[term] = cached;
      return cached;
    }
    _findTerm ??= _db!.prepare('SELECT id FROM terms WHERE term=?');
    var rows = _findTerm!.select([term]);
    if (rows.isEmpty) {
      _insertTerm ??= _db!.prepare(
        'INSERT INTO terms(term,count) VALUES (?,0)',
      );
      _insertTerm!.execute([term]);
      rows = _findTerm!.select([term]);
    }
    final id = rows.single['id'] as int;
    _termIds[term] = id;
    if (_termIds.length > 4096) _termIds.remove(_termIds.keys.first);
    return id;
  }

  void _termDelta(int term, int change) => _termDeltas.update(
    term,
    (value) => value + change,
    ifAbsent: () => change,
  );

  void _removeTerms(String id) {
    final db = _db!;
    final rows = db.select('SELECT source_rowid FROM docs WHERE id=?', [id]);
    if (rows.isEmpty) return;
    final key = rows.single['source_rowid'];
    for (final row in db.select('SELECT term FROM postings WHERE doc=?', [
      key,
    ])) {
      _termDelta(row['term'] as int, -1);
    }
    db.execute('DELETE FROM postings WHERE doc=?', [key]);
  }

  void _removeVector(Row old) {
    final key = old['vector_key'];
    if (key is String) HnswIndex(_store(old['dimension'] as int)).remove(key);
  }

  void _remove(String id) {
    final rows = _db!.select('SELECT * FROM docs WHERE id=?', [id]);
    if (rows.isEmpty) return;
    _removeVector(rows.single);
    _removeTerms(id);
    _db!.execute('DELETE FROM pending_vectors WHERE id=?', [id]);
    _db!.execute('DELETE FROM docs WHERE id=?', [id]);
  }

  void _sync(String id) {
    reconciledRecords++;
    final rows = source.db.select(
      '''SELECT r.rowid AS source_rowid,r.id,
      r.revision,r.body,r.created_at,r.offset_minutes,
      e.rowid AS embedding_rowid,e.source_revision,e.format_version,
      e.model_version,e.dimension,length(e.payload) AS payload_bytes,
      typeof(e.payload) AS payload_type,
      CASE WHEN length(e.payload)<=16384 THEN e.payload END AS payload
      FROM records r LEFT JOIN record_embeddings e ON e.record_id=r.id
      WHERE r.id=?''',
      [id],
    );
    if (rows.isEmpty) {
      _remove(id);
      return;
    }
    final row = rows.single;
    // SQLite may reuse rowids after deletes, including between process starts.
    // Remove the former owner explicitly so its postings/graph are cleaned.
    for (final previous in _db!.select(
      'SELECT id FROM docs WHERE source_rowid=? AND id<>?',
      [row['source_rowid'], id],
    )) {
      _remove(previous['id'] as String);
    }
    final payload = row['payload'];
    final fields = Map<String, Object?>.from(row)..remove('payload');
    // Include payload bytes to detect external UPDATEs that retain revision or
    // rowid. Do not decode vectors until the source fingerprint has changed.
    final header = utf8.encode(jsonEncode(fields));
    final tail = payload is List<int> ? payload : utf8.encode('$payload');
    // Preserve the exact fingerprint bytes without expanding each byte into
    // a generic list slot during whole-library startup reconciliation.
    final signatureBytes = Uint8List(header.length + tail.length)
      ..setRange(0, header.length, header)
      ..setRange(header.length, header.length + tail.length, tail);
    final signature = sha256.convert(signatureBytes).toString();
    final oldRows = _db!.select('SELECT * FROM docs WHERE id=?', [id]);
    final old = oldRows.isEmpty ? null : oldRows.single;
    if (old?['signature'] == signature) return;
    final body = RecordSearchStore.normalize(row['body'] as String);
    if (old?['body'] != body || old?['source_rowid'] != row['source_rowid']) {
      _removeTerms(id);
      _insertPosting ??= _db!.prepare(
        'INSERT INTO postings(term,doc) VALUES (?,?)',
      );
      for (final term in _grams(body)) {
        final termId = _termId(term);
        _insertPosting!.execute([termId, row['source_rowid']]);
        _termDelta(termId, 1);
      }
    }
    if (old != null) _removeVector(old);
    final dimension = row['dimension'];
    final eligible =
        row['source_revision'] == row['revision'] &&
        row['format_version'] == DerivedCodec.formatVersion &&
        row['model_version'] == _model &&
        dimension is int &&
        dimension > 0 &&
        dimension <= DerivedCodec.maxDimensions &&
        row['payload_type'] == 'blob' &&
        row['payload_bytes'] == dimension * 4;
    if (eligible) {
      _db!.execute('INSERT OR IGNORE INTO pending_vectors VALUES (?)', [id]);
    } else {
      _db!.execute('DELETE FROM pending_vectors WHERE id=?', [id]);
    }
    final local = DateTime.parse(row['created_at'] as String)
        .toUtc()
        .add(Duration(minutes: row['offset_minutes'] as int));
    final day =
        '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    _db!.execute(
      '''INSERT OR REPLACE INTO docs
      (id,source_rowid,embedding_rowid,signature,body,day,vector_key,dimension)
      VALUES (?,?,?,?,?,?,?,?)''',
      [
        id,
        row['source_rowid'],
        row['embedding_rowid'],
        signature,
        body,
        day,
        null,
        null,
      ],
    );
  }

  Future<void> _prepareVectors() async {
    // Text postings are usable without waiting for the initial graph build.
    // A durable queue resumes interrupted graph work on the next semantic query.
    {
      final rows = _db!.select(
        'SELECT id FROM pending_vectors ORDER BY id LIMIT 8',
      );
      if (rows.isEmpty) return;
      _transaction(() {
        for (final row in rows) {
          final id = row['id'] as String;
          final r = source.get(id);
          if (r?.vector != null) {
            try {
              final vector = unitVector(r!.vector!);
              // Each incarnation gets its own key, even if the vector returns
              // to an earlier value after deletion. Keys do not retain text.
              final saved = _db!.select(
                "SELECT value FROM metadata WHERE key='graph_sequence'",
              );
              final sequence = saved.isEmpty
                  ? 0
                  : int.parse(saved.single['value'] as String);
              _vectorSequence = math.max(_vectorSequence, sequence) + 1;
              final key = 'n$_vectorSequence';
              _db!.execute(
                "INSERT OR REPLACE INTO metadata VALUES ('graph_sequence',?)",
                ['$_vectorSequence'],
              );
              HnswIndex(_store(vector.length)).add(key, vector);
              _db!.execute(
                'UPDATE docs SET vector_key=?,dimension=? WHERE id=?',
                [key, vector.length, id],
              );
            } on NotebookException {
              /* Invalid derived data remains a miss. */
            }
          }
          _db!.execute('DELETE FROM pending_vectors WHERE id=?', [id]);
        }
      });
      await Future<void>.delayed(Duration.zero);
      // Reconcile intervening edits/model switches before consuming more work.
      if (_dirty.isNotEmpty ||
          _fullReconcile ||
          _model != source.indexModelVersion ||
          _externalVersion !=
              source.db.select('PRAGMA data_version').single.values.first) {
        return;
      }
    }
  }

  Future<void> _reconcile() async {
    // Keyset batches avoid retaining the library or vectors in worker memory.
    String? after;
    while (true) {
      while (_activeQueries > 0 && !_closed) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (_closed) return;
      if (_closed && _activeQueries == 0) return;
      final rows = source.db.select(
        'SELECT id FROM records ${after == null ? '' : 'WHERE id>?'} ORDER BY id LIMIT 64',
        [?after],
      );
      if (rows.isEmpty) break;
      _transaction(() {
        for (final row in rows) {
          _sync(row['id'] as String);
        }
      });
      after = rows.last['id'] as String;
      await Future<void>.delayed(Duration.zero);
    }
    after = null;
    while (true) {
      while (_activeQueries > 0 && !_closed) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      if (_closed) return;
      if (_closed && _activeQueries == 0) return;
      final rows = _db!.select(
        'SELECT id FROM docs ${after == null ? '' : 'WHERE id>?'} ORDER BY id LIMIT 64',
        [?after],
      );
      if (rows.isEmpty) break;
      _transaction(() {
        for (final row in rows) {
          final id = row['id'] as String;
          if (source.db.select('SELECT 1 FROM records WHERE id=?', [
            id,
          ]).isEmpty) {
            _remove(id);
          }
        }
      });
      after = rows.last['id'] as String;
      await Future<void>.delayed(Duration.zero);
    }
  }

  void _syncDirtyBatch() {
    if (_dirty.isEmpty) return;
    final batch = _dirty.take(64).toList();
    _dirty.removeAll(batch);
    final ids = <String>{};
    for (final (table, rowid) in batch) {
      if (table == 'metadata') continue; // Model checked on every prepare.
      final column = table == 'records' ? 'source_rowid' : 'embedding_rowid';
      ids.addAll(
        _db!
            .select('SELECT id FROM docs WHERE $column=?', [rowid])
            .map((r) => r['id'] as String),
      );
      ids.addAll(
        source.db
            .select(
              'SELECT ${table == 'records' ? 'id' : 'record_id'} AS id FROM $table WHERE rowid=?',
              [rowid],
            )
            .map((r) => r['id'] as String),
      );
    }
    _transaction(() {
      for (final id in ids) {
        _sync(id);
      }
    });
  }

  Future<void> _prepare() async {
    _db ??= _open();
    final db = _db!;
    if (_rebuild) {
      _clearStores();
      _termIds.clear();
      _transaction(() {
        db.execute(
          'DELETE FROM docs; DELETE FROM postings; DELETE FROM terms; DELETE FROM nodes; DELETE FROM vector_blocks; DELETE FROM entries; DELETE FROM metadata; DELETE FROM pending_vectors;',
        );
      });
      _clearStores();
      _ready = false;
      _entriesVerified = false;
      _rebuild = false;
    }
    final model = source.indexModelVersion;
    final saved = db.select("SELECT value FROM metadata WHERE key='model'");
    if (_model != model || saved.isEmpty || saved.single['value'] != model) {
      if (saved.isEmpty || saved.single['value'] != model) {
        _clearStores();
        _transaction(() {
          db.execute(
            'DELETE FROM nodes; DELETE FROM vector_blocks; DELETE FROM entries; DELETE FROM pending_vectors;',
          );
          db.execute(
            "UPDATE docs SET signature='',vector_key=NULL,dimension=NULL",
          );
          db.execute("INSERT OR REPLACE INTO metadata VALUES ('model',?)", [
            model,
          ]);
        });
        _clearStores();
      }
      _model = model;
      _ready = false;
    }
    final version =
        source.db.select('PRAGMA data_version').single.values.first as int;
    if (!_ready || _fullReconcile || _externalVersion != version) {
      _entriesVerified = false;
      _ready = false;
      _fullReconcile = false;
      await _reconcile();
      _externalVersion = version;
      _ready = true;
    }
    while (_dirty.isNotEmpty) {
      _syncDirtyBatch();
      await Future<void>.delayed(Duration.zero);
    }
    if (!_entriesVerified) {
      final dimensions = db.select(
        'SELECT dimension FROM entries UNION SELECT dimension FROM docs WHERE vector_key IS NOT NULL',
      );
      for (final row in dimensions) {
        _store(row['dimension'] as int).entryPoint;
      }
      _entriesVerified = true;
    }
    // Rebuild a deletion-heavy graph rather than accumulate routing tombstones
    // forever. Raw embeddings are authoritative and stay untouched.
    if (_activeQueries > 0) return;
    if (db.select('SELECT id FROM nodes WHERE deleted=1 LIMIT 1025').length >
        1024) {
      _ready = false;
      _entriesVerified = false;
      _clearStores();
      _transaction(() {
        db.execute(
          'DELETE FROM nodes; DELETE FROM vector_blocks; DELETE FROM entries; DELETE FROM pending_vectors;',
        );
        db.execute(
          "UPDATE docs SET signature='',vector_key=NULL,dimension=NULL",
        );
      });
      _clearStores();
      await _reconcile();
      _ready = true;
    }
  }

  Future<void> _ensure() async {
    // Concurrent queries share maintenance; raw edits can run between batches.
    final pending = _preparing;
    if (pending != null) {
      if (_ready &&
          !_fullReconcile &&
          _dirty.isEmpty &&
          _model == source.indexModelVersion &&
          _externalVersion ==
              source.db.select('PRAGMA data_version').single.values.first) {
        // Graph construction yields between durable batches. A concurrent
        // keyword query can already use the reconciled text access path.
        return;
      }
      await pending;
      return _ensure();
    }
    final work = _prepare();
    _preparing = work;
    try {
      await work;
    } finally {
      _preparing = null;
    }
    if (_model != source.indexModelVersion ||
        _dirty.isNotEmpty ||
        _fullReconcile ||
        _externalVersion !=
            source.db.select('PRAGMA data_version').single.values.first) {
      await _ensure();
    }
  }

  void _startBuild() {
    if (_closed || !_buildRequested || _background != null || _db == null) {
      return;
    }
    _background = Future<void>(() async {
      var repaired = false;
      while (!_closed) {
        try {
          if (_activeQueries > 0) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            continue;
          }
          await _ensure();
          if (_closed) return;
          if (_activeQueries > 0) continue;
          if (_db!.select('SELECT id FROM pending_vectors LIMIT 1').isEmpty) {
            return;
          }
          await _prepareVectors();
        } catch (error) {
          final corrupt =
              error is FormatException ||
              error is SqliteException &&
                  (error.resultCode == 11 || error.resultCode == 26);
          _ready = false;
          _entriesVerified = false;
          _clearStores();
          if (corrupt && !repaired) {
            _rebuild = true;
            repaired = true;
            continue;
          }
          _buildError = error;
          return;
        }
      }
    }).whenComplete(() => _background = null);
  }

  /// Maintenance/benchmark barrier; interactive search never waits on this.
  Future<void> waitForIndexing() async {
    if (_closed) throw const NotebookException('存储已关闭。');
    _buildRequested = true;
    _db ??= _open();
    if (_background == null) _buildError = null;
    _startBuild();
    await _background;
    if (_closed) throw const NotebookException('存储已关闭。');
    if (_buildError != null) throw const NotebookException('语义索引构建失败，原始资料已保留。');
  }

  Future<SearchResults> search(
    String q,
    DateTime? from,
    DateTime? to,
    List<double>? vector,
    String model,
    String? fallback,
    bool semanticRequested, {
    void Function(SearchHit)? onKeywordHit,
    bool summariesOnly = false,
    bool Function()? cancelled,
  }) async {
    if (_closed) throw const NotebookException('存储已关闭。');
    if (_activeQueries++ == 0) _idle = Completer<void>();
    keywordCandidates = sourceRecordsRead = reconciledRecords =
        distanceEvaluations = 0;
    try {
      _db ??= _open();
      if (_ready &&
          !_fullReconcile &&
          !_rebuild &&
          _dirty.length <= 64 &&
          _model == source.indexModelVersion &&
          _externalVersion ==
              source.db.select('PRAGMA data_version').single.values.first) {
        _syncDirtyBatch();
      }
      if (!_ready ||
          _dirty.isNotEmpty ||
          _fullReconcile ||
          _rebuild ||
          _model != source.indexModelVersion ||
          _externalVersion !=
              source.db.select('PRAGMA data_version').single.values.first) {
        _buildRequested = true;
        return await RecordSearchStore(source).scan(
          q,
          from,
          to,
          vector,
          model,
          fallback ?? '本次直接查找原记录；索引就绪后，后续查找会加速。',
          semanticRequested,
          semanticLimit: from == null && to == null ? 128 : 1024,
          indexingPending: true,
          sourceGeneration: _sourceVersion,
          onKeywordHit: onKeywordHit,
          cancelled: cancelled,
        );
      }
      if (vector != null && model == source.indexModelVersion) {
        _buildRequested = true;
      }
      return await _query(
        q,
        from,
        to,
        vector,
        model,
        fallback,
        semanticRequested,
        onKeywordHit: onKeywordHit,
        summariesOnly: summariesOnly,
        cancelled: cancelled,
      );
    } on SqliteException catch (error) {
      _ready = false;
      _clearStores();
      if (error.resultCode == 11 || error.resultCode == 26) _rebuild = true;
      return await RecordSearchStore(source).scan(
        q,
        from,
        to,
        vector,
        model,
        fallback ?? '检索索引暂不可用，已从本地原记录查找。',
        semanticRequested,
        semanticLimit: from == null && to == null ? 128 : 1024,
        sourceGeneration: _sourceVersion,
        onKeywordHit: onKeywordHit,
        cancelled: cancelled,
      );
    } on FormatException {
      _ready = false;
      _clearStores();
      _rebuild = true;
      return await RecordSearchStore(source).scan(
        q,
        from,
        to,
        vector,
        model,
        fallback ?? '检索索引需重建，已从本地原记录查找。',
        semanticRequested,
        semanticLimit: from == null && to == null ? 128 : 1024,
        sourceGeneration: _sourceVersion,
        onKeywordHit: onKeywordHit,
        cancelled: cancelled,
      );
    } on FileSystemException {
      _ready = false;
      _clearStores();
      return await RecordSearchStore(source).scan(
        q,
        from,
        to,
        vector,
        model,
        fallback ?? '检索索引暂不可用，已从本地原记录查找。',
        semanticRequested,
        semanticLimit: from == null && to == null ? 128 : 1024,
        sourceGeneration: _sourceVersion,
        onKeywordHit: onKeywordHit,
        cancelled: cancelled,
      );
    } finally {
      if (--_activeQueries == 0) {
        _idle?.complete();
        _idle = null;
      }
      _startBuild();
    }
  }

  Future<SearchResults> _query(
    String q,
    DateTime? from,
    DateTime? to,
    List<double>? vector,
    String model,
    String? fallback,
    bool requested, {
    void Function(SearchHit)? onKeywordHit,
    bool summariesOnly = false,
    bool Function()? cancelled,
  }) async {
    final generation = _generation;
    if (vector != null && model != source.indexModelVersion) {
      vector = null;
      fallback = '语义模型已切换，已使用关键词查找。';
    }
    final terms = <(int, int)>[];
    var missing = false;
    for (final gram in _grams(q)) {
      final count = _db!.select('SELECT id,count FROM terms WHERE term=?', [
        gram,
      ]);
      if (count.isEmpty || (count.single['count'] as int) <= 0) {
        missing = true;
        break;
      }
      terms.add((count.single['id'] as int, count.single['count'] as int));
    }
    terms.sort((a, b) => a.$2.compareTo(b.$2));
    final hits = <String, SearchHit>{};
    String day(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final dateWhere =
        '${from == null ? '' : 'AND d.day>=?'} ${to == null ? '' : 'AND d.day<=?'}';
    final dateArgs = <Object?>[
      if (from != null) day(from),
      if (to != null) day(to),
    ];
    bool inDate(Record r) {
      final local = r.recordedLocal;
      final date = DateTime(local.year, local.month, local.day);
      return (from == null ||
              !date.isBefore(DateTime(from.year, from.month, from.day))) &&
          (to == null || !date.isAfter(DateTime(to.year, to.month, to.day)));
    }

    var semanticUsed = false;
    final semanticHits = <SearchHit>[];
    final semanticLimit = from == null && to == null ? 128 : 1024;
    int compareHits(SearchHit a, SearchHit b) => a.score != b.score
        ? b.score.compareTo(a.score)
        : b.record.createdAt.compareTo(a.record.createdAt);
    void considerRecord(Record r, {required bool keyword}) {
      if (!inDate(r)) return;
      final text = RecordSearchStore.normalize(r.body);
      final exact = text.contains(q);
      if (keyword && !exact) return;
      var score = exact ? 2.0 : 0.0;
      if (vector != null &&
          r.vectorRevision == r.revision &&
          r.vector?.length == vector.length) {
        try {
          final document = unitVector(r.vector!);
          semanticUsed = true;
          var cosine = 0.0;
          for (var i = 0; i < document.length; i++) {
            cosine += document[i] * vector[i];
          }
          if (cosine >= .60) score += cosine.clamp(-1.0, 1.0);
        } on NotebookException {
          /* Invalid derived data is a cache miss. */
        }
      }
      if (score <= 0) return;
      final at = math.min(r.body.length, math.max(0, text.indexOf(q) - 30));
      final hit = SearchHit(
        r.withoutVector,
        r.body.substring(at, math.min(r.body.length, at + 150)),
        score,
      );
      if (exact) {
        if (onKeywordHit != null) {
          onKeywordHit(hit);
        } else {
          hits[r.id] = hit;
        }
      } else if (semanticHits.length < semanticLimit ||
          compareHits(hit, semanticHits.last) < 0) {
        if (semanticHits.length == semanticLimit) semanticHits.removeLast();
        semanticHits.add(hit);
        semanticHits.sort(compareHits);
      }
    }

    void consider(String id, {required bool keyword}) {
      sourceRecordsRead++;
      final record = summariesOnly
          ? source.searchRecords([id]).firstOrNull
          : source.get(id);
      if (record != null) considerRecord(record, keyword: keyword);
    }

    if (!missing && terms.isNotEmpty) {
      final selected = terms.take(8).toList();
      // Probe at most the rarest posting's size through a covering date index.
      // This chooses the smaller access path without COUNTing the whole library
      // or scanning a common character's postings for an empty date window.
      final dateCount = from == null && to == null
          ? null
          : _db!.select(
                  'SELECT count(*) AS n FROM (SELECT 1 FROM docs d INDEXED BY docs_keyword_date WHERE 1=1 $dateWhere LIMIT ?)',
                  [...dateArgs, selected.first.$2 + 1],
                ).single['n']
                as int;
      final byDate = dateCount != null && dateCount <= selected.first.$2;
      Object? after;
      String? afterDay;
      while (true) {
        if (cancelled?.call() == true) throw const NotebookException('查找已取消。');
        // The tuple already implies the original lower date bound. Keeping
        // both makes SQLite repeatedly start at `from` on some versions.
        final pageDateWhere = after == null
            ? dateWhere
            : (to == null ? '' : 'AND d.day<=?');
        final rows = _db!.select(
          byDate
              ? '''SELECT d.id,d.body,d.day FROM docs d INDEXED BY docs_keyword_date
          WHERE 1=1 $pageDateWhere ${after == null ? '' : 'AND (d.day,d.id)>(?,?)'}
          ORDER BY d.day,d.id LIMIT 64'''
              : '''SELECT d.id,d.body,p.doc AS cursor FROM postings p JOIN docs d ON d.source_rowid=p.doc
          WHERE p.term=? ${after == null ? '' : 'AND p.doc>?'}
          $dateWhere
          ${List.generate(selected.length - 1, (_) => 'AND EXISTS(SELECT 1 FROM postings x WHERE x.term=? AND x.doc=p.doc)').join(' ')}
          ORDER BY p.doc LIMIT 64''',
          byDate
              ? [
                  if (after == null) ...dateArgs else if (to != null) day(to),
                  if (after != null) ...[afterDay, after],
                ]
              : [
                  selected.first.$1,
                  ?after,
                  ...dateArgs,
                  ...selected.skip(1).map((t) => t.$1),
                ],
        );
        if (rows.isEmpty) break;
        keywordCandidates += rows.length;
        final matching = rows.where(
          (row) => (row['body'] as String).contains(q),
        );
        if (summariesOnly) {
          final records = source.searchRecords(
            matching.map((row) => row['id'] as String).toList(),
          );
          sourceRecordsRead += records.length;
          for (final record in records) {
            considerRecord(record, keyword: true);
          }
        } else {
          for (final row in matching) {
            consider(row['id'] as String, keyword: true);
          }
        }
        after = byDate ? rows.last['id'] as String : rows.last['cursor'] as int;
        if (byDate) afterDay = rows.last['day'] as String;
        await Future<void>.delayed(Duration.zero);
      }
    }
    var approximate = false;
    var pendingCount = 0;
    if (vector != null) {
      String? afterPending;
      while (true) {
        if (cancelled?.call() == true) throw const NotebookException('查找已取消。');
        final rows = _db!.select(
          'SELECT id FROM pending_vectors ${afterPending == null ? '' : 'WHERE id>?'} ORDER BY id LIMIT 64',
          [?afterPending],
        );
        if (rows.isEmpty) break;
        pendingCount += rows.length;
        final records = source.searchRecords(
          rows.map((r) => r['id'] as String).toList(),
        );
        sourceRecordsRead += records.length;
        for (final record in records) {
          considerRecord(record, keyword: false);
        }
        afterPending = rows.last['id'] as String;
        await Future<void>.delayed(Duration.zero);
      }
      final store = _store(vector.length);
      if (store.entryPoint != null) {
        // Availability is independent of similarity cutoff or date window.
        final graphAvailable = _db!.select(
          'SELECT 1 FROM docs WHERE dimension=? AND vector_key IS NOT NULL LIMIT 1',
          [vector.length],
        ).isNotEmpty;
        semanticUsed = semanticUsed || graphAvailable;
        // A narrow date window must not lose every result behind newer global
        // neighbors. Small filtered sets are exact; broad ones use a larger
        // approximate candidate budget and remain explicitly approximate.
        final filtered = from == null && to == null
            ? null
            : _db!.select(
                'SELECT d.id FROM docs d WHERE d.dimension=? AND d.vector_key IS NOT NULL $dateWhere LIMIT 1025',
                [vector.length, ...dateArgs],
              );
        if (filtered != null && filtered.length <= 1024) {
          for (final row in filtered) {
            consider(row['id'] as String, keyword: false);
          }
        } else {
          approximate = graphAvailable;
          final limit = filtered == null ? 128 : 1024;
          final candidates = HnswIndex(store).search(
            vector,
            limit: limit,
            ef: filtered == null ? searchEf : 1400,
          );
          distanceEvaluations = candidates.distanceEvaluations;
          // Bound full-record/organization materialization while amortizing
          // SQLite read transactions, statement setup and model metadata reads.
          // Hydrate in SQL batches, but score in the original ANN order.
          for (var at = 0; at < candidates.matches.length; at += 16) {
            if (cancelled?.call() == true) {
              throw const NotebookException('查找已取消。');
            }
            final batch = candidates.matches.sublist(
              at,
              math.min(at + 16, candidates.matches.length),
            );
            final rows = _db!.select(
              'SELECT id,vector_key FROM docs WHERE vector_key IN (${List.filled(batch.length, '?').join(',')})',
              batch.map((match) => match.key).toList(),
            );
            final ids = <String, String>{};
            for (final row in rows) {
              final key = row['vector_key'] as String;
              if (ids.containsKey(key)) {
                throw const FormatException('Ambiguous graph candidate');
              }
              ids[key] = row['id'] as String;
            }
            final records = {
              for (final record
                  in (summariesOnly
                      ? source.searchRecords(ids.values.toList())
                      : source.getBatch(ids.values.toList())))
                record.id: record,
            };
            for (final match in batch) {
              final id = ids[match.key];
              if (id == null) continue;
              sourceRecordsRead++;
              final record = records[id];
              if (record != null) considerRecord(record, keyword: false);
            }
          }
        }
      }
    }
    if (!_ready ||
        _rebuild ||
        _fullReconcile ||
        generation != _generation ||
        _model != source.indexModelVersion ||
        _externalVersion !=
            source.db.select('PRAGMA data_version').single.values.first) {
      // Revalidate raw data, but do not require a quiet period in derived
      // embedding jobs: same-model vectors may legitimately keep arriving.
      return RecordSearchStore(source).scan(
        q,
        from,
        to,
        vector,
        model,
        fallback ?? '本次直接查找原记录；索引就绪后，后续查找会加速。',
        requested,
        semanticLimit: semanticLimit,
        indexingPending: true,
        sourceGeneration: _sourceVersion,
        onKeywordHit: onKeywordHit,
        cancelled: cancelled,
      );
    }
    final sorted = [...hits.values, ...semanticHits]..sort(compareHits);
    return SearchResults(
      sorted,
      semanticUsed: semanticUsed,
      semanticApproximate: approximate && semanticUsed,
      pendingSemanticRecords: pendingCount,
      fallbackReason:
          fallback ??
          (pendingCount > 0
              ? '本地语义索引正在准备，本次已同时查找尚未建图的记录。'
              : (requested && !semanticUsed ? '语义索引尚未就绪，显示关键词结果。' : null)),
    );
  }
}

class _IndexCorruption extends FormatException {
  const _IndexCorruption(super.message);
}
