import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../domain/record.dart';
import '../domain/restore_report.dart';
import 'record_repository.dart';
import 'backup_codec.dart';

/// Runs only in the database-owning isolate. Preparation yields for file I/O;
/// the final original-data transaction is synchronous and indivisible there.
class RestoreStore {
  RestoreStore(this.repository, this.home);
  final RecordRepository repository;
  final Directory home;

  Future<void> prepare(String work, void Function(double)? progress) async {
    final stage = openIncoming(work);
    final count =
        stage.select('SELECT count(*) n FROM incoming').single['n'] as int;
    try {
      // Hash only local candidates. The disk-backed incoming table also owns
      // destination names, allowing cleanup without retaining an audio list.
      var prepared = 0;
      for (final row in incomingPages(stage)) {
        checkBackupCancel(work);
        final j = jsonDecode(row['json'] as String) as Map<String, dynamic>;
        final audio = row['audio'] as String?;
        if (audio != null) {
          final name = '${const Uuid().v4()}.wav';
          stage.execute('UPDATE incoming SET new_audio=? WHERE id=?', [
            name,
            row['id'],
          ]);
          // Persist cleanup intent before copying into the media vault. A
          // terminated import is distinguishable from an unknown original.
          repository.reserveMediaForCleanup(name);
          await File(p.join(work, 'audio', audio))
              .copy(p.join(home.path, 'audio', name));
        }
        // Store candidate hashes in the stage database. These describe audio
        // immutable under the media lease; edits may still proceed safely.
        for (final hash in [
          row['fingerprint'],
          row['legacy'],
        ].whereType<String>()) {
          final mapped = repository.restoredId(hash);
          if (mapped != null) await _localAudioHash(stage, mapped);
        }
        await _localAudioHash(stage, j['id'] as String);
        prepared++;
        progress?.call(count == 0 ? 1 : prepared / count);
        // Yield even for text-only libraries so cancellation and UI edits are
        // observed before the final synchronous transaction begins.
        if (prepared % 64 == 0) await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(Duration.zero);
      checkBackupCancel(work);
    } finally {
      stage.close();
    }
  }

  RestoreReport merge(String work) {
    final stage = openIncoming(work);
    try {
      bool same(
        Record local,
        Map<String, dynamic> remote,
        String? parent,
        String? audioHash,
      ) {
        if (local.parentId != parent ||
            (local.audio == null) != (remote['audio'] == null)) {
          return false;
        }
        final left = rawJson(local), right = Map<String, dynamic>.of(remote);
        for (final key in ['id', 'parentId', 'audio', 'transcription']) {
          left.remove(key);
          right.remove(key);
        }
        if (jsonEncode(left) != jsonEncode(right)) return false;
        if (local.audio != null) {
          final rows = stage.select(
            'SELECT hash FROM local_audio WHERE name=?',
            [local.audio],
          );
          return rows.isNotEmpty && rows.first['hash'] == audioHash;
        }
        return true;
      }

      return repository.transaction(() {
        var processed = 0;
        checkBackupCancel(work);
        var added = 0, skipped = 0, conflicts = 0;
        for (final roots in [true, false]) {
          for (final row in incomingPages(
            stage,
            rootsOnly: roots,
            childrenOnly: !roots,
          )) {
            if (++processed % 64 == 0) checkBackupCancel(work);
            final j = jsonDecode(row['json'] as String) as Map<String, dynamic>;
            final id = row['id'] as String, parent = row['parent'] as String?;
            final parentRows = parent == null
                ? null
                : stage.select('SELECT mapped FROM incoming WHERE id=?', [
                    parent,
                  ]);
            final expectedParent = parentRows?.first['mapped'] as String?;
            final existing = repository.get(id);
            Record? restored;
            for (final hash in [
              row['fingerprint'],
              row['legacy'],
            ].whereType<String>()) {
              final mapped = repository.restoredId(hash);
              if (mapped != null) {
                restored = repository.get(mapped);
                if (restored != null) break;
              }
            }
            final candidates = [?restored, ?existing];
            final matching = candidates.where(
              (r) => same(r, j, expectedParent, row['hash'] as String?),
            );
            String mapped;
            var insert = false;
            if (matching.isNotEmpty) {
              mapped = matching.first.id;
              skipped++;
            } else {
              final parentChanged = parent != null && parent != expectedParent;
              mapped = candidates.isNotEmpty || parentChanged
                  ? const Uuid().v4()
                  : id;
              if (candidates.any(
                    (r) => !same(r, j, r.parentId, row['hash'] as String?),
                  ) ||
                  (!parentChanged &&
                      candidates.any((r) => r.parentId != expectedParent))) {
                conflicts++;
              }
              insert = true;
              added++;
            }
            stage.execute(
              'UPDATE incoming SET mapped=?,insert_row=? WHERE id=?',
              [mapped, insert ? 1 : 0, id],
            );
            if (insert) {
              final raw = {
                ...j,
                'id': mapped,
                'parentId': expectedParent,
                'audio': row['new_audio'],
                'transcription': j['transcription'] == 'running'
                    ? 'pending'
                    : j['transcription'],
              };
              repository.insert(rawRecord(raw));
            }
            repository.markRestored(row['fingerprint'] as String, mapped);
            if (row['legacy'] != null) {
              repository.markRestored(row['legacy'] as String, mapped);
            }
          }
        }
        checkBackupCancel(work);
        return RestoreReport(added, skipped, conflicts);
      });
    } finally {
      stage.close();
    }
  }

  Future<int> cleanup(String work) async {
    final stage = openIncoming(work);
    var warnings = 0;
    try {
      for (final row in incomingPages(stage)) {
        final name = row['new_audio'] as String?;
        if (name == null) continue;
        try {
          // The committed vault is authoritative, including when a response or
          // process was lost after COMMIT. Never delete a referenced original.
          final referenced = repository.db.select(
            'SELECT 1 FROM records WHERE audio=? LIMIT 1',
            [name],
          ).isNotEmpty;
          if (!referenced) {
            final file = File(p.join(home.path, 'audio', name));
            if (await file.exists()) await file.delete();
          }
          repository.completeMediaDeletion(name);
        } on FileSystemException {
          warnings++;
        } on SqliteException {
          warnings++;
        }
      }
      return warnings;
    } finally {
      stage.close();
    }
  }

  Future<void> _localAudioHash(Database stage, String id) async {
    stage.execute(
      'CREATE TABLE IF NOT EXISTS local_audio(name TEXT PRIMARY KEY,hash TEXT NOT NULL)',
    );
    final r = repository.get(id);
    if (r?.audio == null) return;
    if (stage.select('SELECT name FROM local_audio WHERE name=?', [
      r!.audio,
    ]).isNotEmpty) {
      return;
    }
    final path = p.join(home.path, 'audio', r.audio!);
    // A missing original is a conflict, not an invalid incoming backup. Restore
    // a complete copy while retaining the existing row for user inspection.
    if (!await File(path).exists()) return;
    final hash = await fileHash(File(path));
    stage.execute('INSERT INTO local_audio VALUES(?,?)', [r.audio, hash]);
  }
}
