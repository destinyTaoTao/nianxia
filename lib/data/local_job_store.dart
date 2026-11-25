import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/local_job.dart';
import 'record_repository.dart';

/// Owned by the storage isolate. Failure of this optional cache must never
/// prevent reading or writing originals. No two-file transaction is assumed.
class LocalJobStore {
  LocalJobStore(this.source, this.home);
  final RecordRepository source;
  final Directory home;
  Database? _db, _owner;
  String _pruneAfter = '';
  bool _attempted = false, _failed = false, _spaceBlocked = false;
  bool get available => _open() != null && !_spaceBlocked;
  Database? _open() {
    if (_failed) return null;
    if (_attempted) return _db;
    _attempted = true;
    Database? db;
    try {
      final path = p.join(home.path, 'jobs.sqlite');
      if (File(path).existsSync()) {
        final probe = sqlite3.open(path, mode: OpenMode.readOnly);
        try {
          if (probe.userVersion != 1 ||
              probe.select('PRAGMA application_id').single.values.single !=
                  0x4e584a42) {
            return null;
          }
        } finally {
          probe.close();
        }
      }
      // SQLite's lock works between connections in the same process too;
      // POSIX file locks alone would not exclude another Dart isolate.
      final ownerPath = p.join(home.path, 'jobs-owner.sqlite');
      final exists = File(ownerPath).existsSync();
      _owner = sqlite3.open(ownerPath);
      _owner!.execute('PRAGMA busy_timeout=0');
      if (exists) {
        final id = _owner!.select('PRAGMA application_id').single.values.single;
        final version = _owner!.userVersion;
        final empty =
            version == 0 &&
            id == 0 &&
            _owner!.select("SELECT 1 FROM sqlite_master LIMIT 1").isEmpty;
        if (!empty && (version != 1 || id != 0x4e584a4f)) {
          _owner!.close();
          _owner = null;
          return null;
        }
      }
      _owner!.execute('PRAGMA application_id=${0x4e584a4f}');
      _owner!.execute('PRAGMA user_version=1');
      _owner!.execute('BEGIN IMMEDIATE');
      db = sqlite3.open(path);
      db.execute('PRAGMA application_id=${0x4e584a42}');
      db.execute('PRAGMA user_version=1');
      db.execute('PRAGMA cache_size=-512');
      db.execute('PRAGMA max_page_count=16384');
      db.execute('''CREATE TABLE IF NOT EXISTS jobs (
        key TEXT PRIMARY KEY, kind TEXT NOT NULL, source_id TEXT NOT NULL,
        source_revision INTEGER NOT NULL, model_generation TEXT NOT NULL,
        state TEXT NOT NULL, attempt INTEGER NOT NULL, next_attempt_at INTEGER NOT NULL,
        lease_token TEXT NOT NULL, error_code TEXT)''');
      db.execute(
        'CREATE INDEX IF NOT EXISTS jobs_ready ON jobs(state,next_attempt_at,key)',
      );
      // A process death loses the lease, never the already committed source.
      db.execute(
        "UPDATE jobs SET state=CASE WHEN attempt<3 THEN 'pending' ELSE 'failed' END,lease_token='' WHERE state='running'",
      );
      return _db = db;
    } catch (_) {
      db?.close();
      _owner?.close();
      _owner = null;
      return null;
    }
  }

  LocalJob _read(Row r) => LocalJob(
    key: r['key'] as String,
    kind: JobKind.values.byName(r['kind'] as String),
    sourceId: r['source_id'] as String,
    sourceRevision: r['source_revision'] as int,
    modelGeneration: r['model_generation'] as String,
    state: JobState.values.byName(r['state'] as String),
    attempt: r['attempt'] as int,
    nextAttemptAt: DateTime.fromMillisecondsSinceEpoch(
      r['next_attempt_at'] as int,
      isUtc: true,
    ),
    leaseToken: r['lease_token'] as String,
    errorCode: r['error_code'] as String?,
  );

  bool _needed(LocalJob job, String speech) {
    final r = source.get(job.sourceId);
    if (r == null || r.revision != job.sourceRevision) return false;
    if (job.kind == JobKind.transcription) {
      return job.modelGeneration == speech &&
          r.audio != null &&
          (r.transcription == 'pending' ||
              r.transcription == 'failed' ||
              r.transcription == 'running');
    }
    return job.modelGeneration == source.indexModelVersion &&
        r.body.isNotEmpty &&
        r.vectorRevision != r.revision;
  }

  // Reclaim completed and obsolete metadata, never a current failure marker
  // or a running lease. Only source identity/revision is read, not user bodies
  // or vectors. Each turn examines at most 256 rows and holds no transaction
  // while yielding to foreground storage requests.
  String _pruneBatch(Database db, String after, String? speech) {
    final rows = db.select(
      "SELECT key,kind,source_id,source_revision,model_generation,state FROM jobs WHERE key>? AND state!='running' ORDER BY key LIMIT 256",
      [after],
    );
    final generation = source.indexModelVersion;
    db.execute('SAVEPOINT prune_jobs');
    try {
      for (final row in rows) {
        final current = source.db.select(
          'SELECT revision FROM records WHERE id=?',
          [row['source_id']],
        );
        final obsolete =
            row['state'] == 'succeeded' ||
            current.isEmpty ||
            current.single['revision'] != row['source_revision'] ||
            (row['kind'] == 'embedding' &&
                row['model_generation'] != generation) ||
            (row['kind'] == 'transcription' &&
                speech != null &&
                row['model_generation'] != speech);
        if (obsolete) {
          db.execute("DELETE FROM jobs WHERE key=? AND state!='running'", [
            row['key'],
          ]);
        }
      }
      db.execute('RELEASE prune_jobs');
    } catch (_) {
      db.execute('ROLLBACK TO prune_jobs');
      db.execute('RELEASE prune_jobs');
      rethrow;
    }
    return rows.length < 256 ? '' : rows.last['key'] as String;
  }

  Future<void> _reclaimSpace(Database db, String? speech) async {
    var after = '';
    do {
      after = _pruneBatch(db, after, speech);
      await Future<void>.delayed(Duration.zero);
    } while (after.isNotEmpty);
  }

  Future<LocalJob?> claim(Set<JobKind> kinds, String speech) async {
    final db = _open();
    if (db == null || kinds.isEmpty || speech.length > 256) return null;
    final speechGeneration = kinds.contains(JobKind.transcription)
        ? speech
        : null;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        _pruneAfter = _pruneBatch(db, _pruneAfter, speechGeneration);
        final claimed = await _claim(db, kinds, speech);
        _spaceBlocked = false;
        return claimed;
      } on SqliteException catch (error) {
        if (error.resultCode != 13) {
          _failed = true;
          return null;
        }
        _spaceBlocked = true;
        // SQLITE_FULL is recoverable. Keep valid attempt limits and leases;
        // do not permanently disable this process or recreate the sidecar.
        if (attempt == 0) {
          try {
            await _reclaimSpace(db, speechGeneration);
          } catch (_) {
            return null;
          }
        }
      } catch (_) {
        _failed = true;
        return null;
      }
    }
    return null;
  }

  Future<LocalJob?> _claim(
    Database db,
    Set<JobKind> kinds,
    String speech,
  ) async {
    for (final kind in kinds) {
      var after = '';
      while (true) {
        final batch = source.pendingJobs(
          transcription: kind == JobKind.transcription,
          after: after,
        );
        for (final r in batch) {
          final generation = kind == JobKind.transcription
              ? speech
              : source.indexModelVersion;
          final key = sha256
              .convert(
                utf8.encode(
                  jsonEncode([kind.name, r.id, r.revision, generation]),
                ),
              )
              .toString();
          db.execute(
            'INSERT OR IGNORE INTO jobs VALUES (?,?,?,?,?,?,?,?,?,?)',
            [
              key,
              kind.name,
              r.id,
              r.revision,
              generation,
              'pending',
              0,
              0,
              '',
              null,
            ],
          );
        }
        final ready = db.select(
          "SELECT * FROM jobs WHERE state='pending' AND kind=? AND next_attempt_at<=? ORDER BY next_attempt_at,key LIMIT 32",
          [kind.name, DateTime.now().toUtc().millisecondsSinceEpoch],
        );
        for (final row in ready) {
          final job = _read(row);
          if (!_needed(job, speech)) {
            db.execute(
              "UPDATE jobs SET state='stale',lease_token='' WHERE key=?",
              [job.key],
            );
            continue;
          }
          final lease = const Uuid().v4();
          db.execute(
            "UPDATE jobs SET state='running',attempt=attempt+1,lease_token=? WHERE key=? AND state='pending'",
            [lease, job.key],
          );
          return _read(
            db.select('SELECT * FROM jobs WHERE key=?', [job.key]).single,
          );
        }
        if (batch.isEmpty && ready.length < 32) break;
        if (batch.isNotEmpty) after = batch.last.id;
        // At most 32 source rows per turn; source mutations and foreground
        // requests can run between turns, without holding either transaction.
        await Future<void>.delayed(Duration.zero);
      }
    }
    return null;
  }

  Future<void> finish(LocalJob job, JobOutcome outcome) async {
    final db = _open();
    if (db == null) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        _finish(db, job, outcome);
        _spaceBlocked = false;
        return;
      } on SqliteException catch (error) {
        if (error.resultCode != 13) {
          _failed = true;
          return;
        }
        _spaceBlocked = true;
        if (attempt == 0) {
          try {
            await _reclaimSpace(db, null);
          } catch (_) {
            return;
          }
        }
      } catch (_) {
        _failed = true;
        return;
      }
    }
    // An unacknowledged lease remains intact for source reconciliation on
    // restart. A full optional cache never affects the already committed source.
  }

  void _finish(Database db, LocalJob job, JobOutcome outcome) {
    final rows = db.select(
      "SELECT * FROM jobs WHERE key=? AND state='running' AND lease_token=?",
      [job.key, job.leaseToken],
    );
    if (rows.isEmpty) return;
    final actual = _read(rows.single);
    final r = source.get(actual.sourceId);
    var state = switch (outcome) {
      JobOutcome.succeeded => 'succeeded',
      JobOutcome.failedTransient => actual.attempt < 3 ? 'pending' : 'failed',
      JobOutcome.failedPermanent => 'failed',
      JobOutcome.stale => 'stale',
      JobOutcome.cancelled => 'cancelled',
    };
    // Transcription commit itself increments revision. Success is accepted
    // only when the source result exists; all other late leases are stale.
    final committed =
        r != null &&
        (actual.kind == JobKind.transcription
            ? r.transcription == 'done' &&
                  r.revision == actual.sourceRevision + 1
            : r.revision == actual.sourceRevision &&
                  r.vectorRevision == r.revision &&
                  actual.modelGeneration == source.indexModelVersion);
    if (committed) {
      state = 'succeeded';
    } else if (r == null ||
        r.revision != actual.sourceRevision ||
        outcome == JobOutcome.succeeded) {
      state = 'stale';
    }
    if (state == 'succeeded') {
      db.execute('DELETE FROM jobs WHERE key=? AND lease_token=?', [
        actual.key,
        actual.leaseToken,
      ]);
      return;
    }
    final delay = actual.attempt == 1 ? 1000 : 5000;
    db.execute(
      'UPDATE jobs SET state=?,next_attempt_at=?,lease_token=?,error_code=? WHERE key=? AND lease_token=?',
      [
        state,
        DateTime.now().toUtc().millisecondsSinceEpoch + delay,
        '',
        outcome == JobOutcome.failedTransient
            ? 'transient'
            : outcome == JobOutcome.failedPermanent
            ? 'permanent'
            : null,
        actual.key,
        actual.leaseToken,
      ],
    );
  }

  DateTime? nextAttempt(Set<JobKind> kinds) {
    try {
      final row = _open()
          ?.select(
            "SELECT MIN(next_attempt_at) AS n FROM jobs WHERE state='pending' AND kind IN (${kinds.map((_) => '?').join(',')})",
            kinds.map((k) => k.name).toList(),
          )
          .single;
      final n = row?['n'] as int?;
      return n == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(n, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  void close() {
    _db?.close();
    _db = null;
    _owner?.close();
    _owner = null;
  }
}
