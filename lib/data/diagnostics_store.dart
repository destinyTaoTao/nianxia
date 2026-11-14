import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/diagnostic_event.dart';

const _applicationId = 0x4e584447;
Database _open(String directory, int maxBytes) {
  final root = Directory(directory)..createSync(recursive: true);
  final file = File(p.join(root.path, 'diagnostics.sqlite'));
  if (file.existsSync() && file.lengthSync() > 0) {
    final probe = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      if (probe.select('PRAGMA application_id').single.values.first !=
              _applicationId ||
          probe.select('PRAGMA user_version').single.values.first != 1) {
        throw const FormatException('未知诊断版本，保持原文件。');
      }
    } finally {
      probe.close();
    }
  }
  final db = sqlite3.open(file.path);
  try {
    db.execute('PRAGMA page_size=512');
    db.execute('PRAGMA auto_vacuum=FULL');
    db.execute('PRAGMA journal_mode=OFF');
    db.execute('PRAGMA synchronous=OFF');
    db.execute('PRAGMA cache_size=-512');
    db.execute('PRAGMA application_id=$_applicationId');
    db.execute('PRAGMA user_version=1');
    final page = db.select('PRAGMA page_size').single.values.first as int;
    db.execute('PRAGMA max_page_count=${maxBytes ~/ page}');
    db.execute(
      'CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY,at INTEGER NOT NULL,payload TEXT NOT NULL,weight INTEGER NOT NULL)',
    );
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

void _prune(Database db, int now, int maxAgeMs) {
  db.execute('DELETE FROM events WHERE at<? OR at>?', [now - maxAgeMs, now]);
}

void _append(
  String directory,
  int maxBytes,
  int maxAgeMs,
  int now,
  List<Map<String, Object?>> entries,
) {
  final db = _open(directory, maxBytes);
  try {
    _prune(db, now, maxAgeMs);
    var weight =
        db.select('SELECT coalesce(sum(weight),0) n FROM events').single['n']
            as int;
    for (final data in entries) {
      final entry = DiagnosticEntry.fromMap(data);
      final at = entry.at.millisecondsSinceEpoch;
      if (at < now - maxAgeMs || at > now) continue;
      final payload = jsonEncode(entry.toMap());
      final size = utf8.encode(payload).length + 512;
      if (size > maxBytes - 1024) continue;
      while (weight + size > maxBytes - 1024) {
        final oldest = db.select(
          'SELECT seq,weight FROM events ORDER BY seq LIMIT 1',
        );
        if (oldest.isEmpty) break;
        weight -= oldest.single['weight'] as int;
        db.execute('DELETE FROM events WHERE seq=?', [oldest.single['seq']]);
      }
      db.execute('INSERT INTO events(at,payload,weight) VALUES(?,?,?)', [
        at,
        payload,
        size,
      ]);
      weight += size;
    }
  } finally {
    db.close();
  }
}

List<Map<String, Object?>> _read(
  String directory,
  int maxBytes,
  int maxAgeMs,
  int now,
) {
  final db = _open(directory, maxBytes);
  try {
    _prune(db, now, maxAgeMs);
    final safe = <Map<String, Object?>>[];
    for (final row in db.select('SELECT payload FROM events ORDER BY seq')) {
      final text = row['payload'];
      if (text is! String || text.length > 2048) continue;
      try {
        final value = Map<String, Object?>.from(jsonDecode(text) as Map);
        safe.add(DiagnosticEntry.fromMap(value).toMap());
      } catch (_) {
        /* Never export unrecognized or content-bearing input. */
      }
    }
    return safe;
  } finally {
    db.close();
  }
}

class DiagnosticsStore {
  DiagnosticsStore(
    this.directory, {
    required this.maxBytes,
    required this.maxAge,
  });
  final Directory directory;
  final int maxBytes;
  final Duration maxAge;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> append(List<DiagnosticEntry> entries, DateTime now) {
    final path = directory.path,
        bytes = maxBytes,
        age = maxAge.inMilliseconds,
        timestamp = now.toUtc().millisecondsSinceEpoch;
    final data = entries.map((e) => e.toMap()).toList(growable: false);
    return _serial(() => _appendWorker(path, bytes, age, timestamp, data));
  }

  Future<List<DiagnosticEntry>> read(DateTime now) async {
    final path = directory.path,
        bytes = maxBytes,
        age = maxAge.inMilliseconds,
        timestamp = now.toUtc().millisecondsSinceEpoch;
    final values = await _serial(
      () => _readWorker(path, bytes, age, timestamp),
    );
    return values.map(DiagnosticEntry.fromMap).toList(growable: false);
  }
}

Future<void> _appendWorker(
  String path,
  int bytes,
  int age,
  int timestamp,
  List<Map<String, Object?>> data,
) => Isolate.run(() => _append(path, bytes, age, timestamp, data));
Future<List<Map<String, Object?>>> _readWorker(
  String path,
  int bytes,
  int age,
  int timestamp,
) => Isolate.run(() => _read(path, bytes, age, timestamp));
