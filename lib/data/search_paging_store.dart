import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';
import '../domain/search_page.dart';
import 'record_repository.dart';
import 'record_search_store.dart';
import 'search_index.dart';

class _RankedQuery {
  _RankedQuery(
    this.id,
    this.identity,
    this.sourceVersion,
    this.generation,
    this.model,
  );
  final String id, identity, model;
  final Object sourceVersion;
  final int generation;
  final Stopwatch idle = Stopwatch()..start();
  bool cancelled = false, ready = false, approximate = false;
  int total = 0;
  String? fallback;
}

/// Only IDs/scores/times survive candidate visitation. Source bodies, transcripts,
/// organization and vectors are never accumulated as an all-results collection.
class SearchPagingStore {
  SearchPagingStore(this.source, this.index, this.home);
  final RecordRepository source;
  final SearchIndex index;
  final Directory home;
  final Map<String, _RankedQuery> _queries = {};
  final Set<Completer<void>> _builders = {};
  final Set<String> _cancelledRequests = {};
  Database? _db;
  Future<void>? _opening;
  Directory? _work;
  RandomAccessFile? _ownerLock;
  PreparedStatement? _insert;
  bool _closed = false;
  Object _sourceVersion() => (
    source.contentGeneration,
    source.indexModelVersion,
    source.db.select('PRAGMA data_version').single.values.first,
  );

  Future<void> _open() async {
    if (_db != null) return;
    await (_opening ??= _createScratch().whenComplete(() => _opening = null));
  }

  Future<void> _createScratch() async {
    final root = Directory(p.join(home.path, 'search-pages'))
      ..createSync(recursive: true);
    // Only an identified, versioned scratch owner may be removed after a crash.
    // Unknown future directories are preserved. Startup never waits for this scan.
    await for (final entry in root.list(followLinks: false).take(16)) {
      if (entry is! Directory) continue;
      final marker = File(p.join(entry.path, 'owner.json'));
      try {
        if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
                FileSystemEntityType.file ||
            marker.lengthSync() > 1024) {
          continue;
        }
        final data = jsonDecode(marker.readAsStringSync());
        if (data is Map &&
            data['format'] == 'nianxia-search-pages' &&
            data['version'] == 1 &&
            data['pid'] is int &&
            data['pid'] != pid) {
          final owner = File(p.join(entry.path, 'owner.lock'));
          if (FileSystemEntity.typeSync(owner.path, followLinks: false) !=
              FileSystemEntityType.file) {
            continue;
          }
          final lock = owner.openSync(mode: FileMode.append);
          try {
            lock.lockSync(FileLock.exclusive);
            entry.deleteSync(recursive: true);
          } finally {
            lock.closeSync();
          }
        }
      } catch (_) {
        /* Disposable leftovers cannot fail source access. */
      }
    }
    _work = root.createTempSync('session-');
    Database? opening;
    try {
      _ownerLock = File(p.join(_work!.path, 'owner.lock'))
          .openSync(mode: FileMode.write);
      _ownerLock!.lockSync(FileLock.exclusive);
      File(p.join(_work!.path, 'owner.json')).writeAsStringSync(
        jsonEncode({
          'format': 'nianxia-search-pages',
          'version': 1,
          'pid': pid,
        }),
        flush: true,
      );
      final db = sqlite3.open(p.join(_work!.path, 'ranks.sqlite'));
      opening = db;
      db.execute('PRAGMA cache_size=-2048');
      db.execute('PRAGMA journal_mode=OFF'); // Identified scratch data only.
      db.execute('PRAGMA synchronous=OFF');
      final size = db.select('PRAGMA page_size').first.values.first as int;
      db.execute('PRAGMA max_page_count=${256 * 1024 * 1024 ~/ size}');
      db.execute(
        'CREATE TABLE ranked(query_id TEXT NOT NULL,id TEXT NOT NULL,score_key REAL NOT NULL,time_key INTEGER NOT NULL,PRIMARY KEY(query_id,id)) WITHOUT ROWID',
      );
      db.execute(
        'CREATE INDEX ranked_page ON ranked(query_id,score_key,time_key,id)',
      );
      _insert = db.prepare('INSERT OR REPLACE INTO ranked VALUES(?,?,?,?)');
      _db = db;
    } catch (_) {
      try {
        opening?.close();
      } finally {
        _releaseScratch();
      }
      rethrow;
    }
  }

  void _releaseScratch() {
    try {
      _ownerLock?.closeSync();
    } catch (_) {
      /* Retry cleanup on a later process. */
    }
    _ownerLock = null;
    try {
      _work?.deleteSync(recursive: true);
    } catch (_) {
      /* Identified leftovers only. */
    }
    _work = null;
  }

  void cancel(String id) {
    final query = _queries[id];
    if (query != null) {
      query.cancelled = true;
    } else {
      _cancelledRequests.add(id);
      if (_cancelledRequests.length > 256) {
        _cancelledRequests.remove(_cancelledRequests.first);
      }
    }
  }

  void _drop(String id) {
    _queries.remove(id)?.cancelled = true;
    _db?.execute('DELETE FROM ranked WHERE query_id=?', [id]);
  }

  bool _invalid(_RankedQuery query) =>
      _closed || query.cancelled || query.sourceVersion != _sourceVersion();

  Future<SearchPage> page(
    SearchQuery query, {
    required String requestId,
    SearchCursor? after,
    List<double>? vector,
    String? model,
    String? fallback,
    bool semanticRequested = false,
    int limit = 40,
  }) async {
    try {
      return await _page(
        query,
        requestId: requestId,
        after: after,
        vector: vector,
        model: model,
        fallback: fallback,
        semanticRequested: semanticRequested,
        limit: limit,
      );
    } on SqliteException catch (error) {
      throw NotebookException(
        error.resultCode == 13
            ? '查找临时空间不足，请缩小范围或释放空间后重试。原始资料未被更改。'
            : '查找暂不可用，请重试。原始资料未被更改。',
      );
    } on FileSystemException {
      throw const NotebookException('查找暂不可用，请检查可用空间后重试。原始资料未被更改。');
    }
  }

  Future<SearchPage> _page(
    SearchQuery query, {
    required String requestId,
    SearchCursor? after,
    List<double>? vector,
    String? model,
    String? fallback,
    bool semanticRequested = false,
    int limit = 40,
  }) async {
    if (_closed) throw const NotebookException('本地资料库已关闭。');
    if (limit < 1 || limit > 40) throw const NotebookException('查找分页大小无效。');
    if (RecordSearchStore.normalize(query.text).isEmpty) return SearchPage([]);
    await _open();
    for (final old in _queries.values.toList()) {
      if (old.idle.elapsed > const Duration(minutes: 5) || old.cancelled) {
        _drop(old.id);
      }
    }
    _RankedQuery? state;
    if (after != null) {
      state = _queries[after.queryId];
      if (state == null ||
          !state.ready ||
          state.identity != query.identity ||
          _invalid(state) ||
          after.generation != state.generation ||
          after.model != state.model ||
          !after.score.isFinite ||
          after.id.length > 36 ||
          after.createdAt < -8640000000000000000 ||
          after.createdAt > 8640000000000000000) {
        if (state != null) _drop(state.id);
        return SearchPage([], reset: true);
      }
    } else {
      while (_queries.length >= 2) {
        _drop(_queries.keys.first);
      }
      while (_builders.length >= 2) {
        await Future.any(_builders.map((builder) => builder.future));
      }
      if (_closed || _cancelledRequests.remove(requestId)) {
        throw const NotebookException('查找已取消。');
      }
      // Recheck the context bound after yielding for a builder slot.
      while (_queries.length >= 2) {
        _drop(_queries.keys.first);
      }
      state = _RankedQuery(
        requestId,
        query.identity,
        _sourceVersion(),
        source.contentGeneration,
        source.indexModelVersion,
      );
      _queries[state.id] = state;
      final active = state;
      final completion = Completer<void>();
      _builders.add(completion);
      final pendingRows = <List<Object>>[];
      void flush() {
        if (pendingRows.isEmpty) return;
        final db = _db!;
        db.execute('BEGIN');
        try {
          for (final row in pendingRows) {
            _insert!.execute(row);
          }
          db.execute('COMMIT');
          pendingRows.clear();
        } catch (_) {
          try {
            db.execute('ROLLBACK');
          } catch (_) {}
          rethrow;
        }
      }

      void record(SearchHit hit) {
        if (active.cancelled || _closed) {
          throw const NotebookException('查找已取消。');
        }
        pendingRows.add([
          active.id,
          hit.record.id,
          -hit.score,
          -hit.record.createdAt.microsecondsSinceEpoch,
        ]);
        if (pendingRows.length >= 64) flush();
      }

      try {
        final result = await index.search(
          RecordSearchStore.normalize(query.text),
          query.from,
          query.to,
          vector,
          model ?? state.model,
          fallback,
          semanticRequested,
          onKeywordHit: record,
          summariesOnly: true,
          cancelled: () => active.cancelled || _closed,
        );
        for (final hit in result) {
          record(hit);
        }
        if (_invalid(active)) {
          final stopped = active.cancelled || _closed;
          _drop(active.id);
          if (stopped) throw const NotebookException('查找已取消。');
          return SearchPage([], reset: true);
        }
        flush();
        state.ready = true;
        state.approximate = result.semanticApproximate;
        state.fallback = result.fallbackReason;
        state.total =
            _db!.select('SELECT count(*) n FROM ranked WHERE query_id=?', [
                  state.id,
                ]).single['n']
                as int;
      } catch (_) {
        _drop(active.id);
        rethrow;
      } finally {
        _builders.remove(completion);
        completion.complete();
        _cancelledRequests.remove(active.id);
      }
    }
    if (state.cancelled) throw const NotebookException('查找已取消。');
    state.idle.reset();
    final rows = _db!.select(
      "SELECT id,score_key,time_key FROM ranked WHERE query_id=? ${after == null ? '' : 'AND (score_key,time_key,id)>(?,?,?)'} ORDER BY score_key,time_key,id LIMIT ?",
      [
        state.id,
        if (after != null) ...[-after.score, -after.createdAt, after.id],
        limit + 1,
      ],
    );
    final selected = rows.take(limit).toList();
    final byId = <String, SearchHitSummary>{};
    if (selected.isNotEmpty) {
      final records = source.db.select(
        '''SELECT id,body,created_at,timezone,offset_minutes,parent_id,audio,duration_ms
        FROM records WHERE id IN (${List.filled(selected.length, '?').join(',')})''',
        selected.map((r) => r['id']).toList(),
      );
      final q = RecordSearchStore.normalize(query.text);
      for (final row in records) {
        final body = row['body'] as String;
        final normalized = RecordSearchStore.normalize(body);
        final at = normalized.indexOf(q);
        final offset = at < 0 ? 0 : normalized.substring(0, at).runes.length;
        final trimmed = body.trim();
        final firstNewline = trimmed.indexOf('\n');
        final firstLine = firstNewline < 0
            ? trimmed
            : trimmed.substring(0, firstNewline);
        final title = String.fromCharCodes(firstLine.runes.take(120));
        final snippet = String.fromCharCodes(
          body.runes.skip(math.max(0, offset - 30)).take(150),
        );
        byId[row['id'] as String] = SearchHitSummary(
          id: row['id'] as String,
          title: title,
          snippet: snippet,
          createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
          timezone: row['timezone'] as String,
          offsetMinutes: row['offset_minutes'] as int,
          parentId: row['parent_id'] as String?,
          hasAudio: row['audio'] != null,
          durationMs: row['duration_ms'] as int,
          kind: at < 0 ? MatchKind.semantic : MatchKind.keyword,
        );
      }
    }
    if (_invalid(state)) {
      _drop(state.id);
      return SearchPage([], reset: true);
    }
    final entries = selected
        .map((r) => byId[r['id']])
        .whereType<SearchHitSummary>()
        .toList();
    final tail = selected.lastOrNull;
    final next = rows.length > limit && tail != null
        ? SearchCursor(
            queryId: state.id,
            score: -(tail['score_key'] as num).toDouble(),
            createdAt: -(tail['time_key'] as int),
            id: tail['id'] as String,
            generation: state.generation,
            model: state.model,
          )
        : null;
    return SearchPage(
      entries,
      next: next,
      semanticApproximate: state.approximate,
      fallbackReason: state.fallback,
      knownTotal: state.total,
    );
  }

  void close() {
    _closed = true;
    for (final state in _queries.values) {
      state.cancelled = true;
    }
    try {
      _insert?.close();
    } finally {
      _insert = null;
      try {
        _db?.close();
      } finally {
        _db = null;
        _releaseScratch();
      }
    }
  }
}
