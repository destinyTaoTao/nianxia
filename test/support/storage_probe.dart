import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/record_repository.dart';

/// Test-only fault injection/inspection through a separate short-lived SQLite
/// connection. Production callers never receive the storage worker's handle.
class StorageProbe {
  StorageProbe(this.book);
  final Notebook book;
  void execute(String sql, [List<Object?> parameters = const []]) {
    final db = sqlite3.open(p.join(book.home.path, 'records.sqlite'));
    try {
      db.execute(sql, parameters);
    } finally {
      db.close();
    }
  }

  List<Map<String, Object?>> select(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    final db = sqlite3.open(p.join(book.home.path, 'records.sqlite'));
    try {
      return db
          .select(sql, parameters)
          .map((r) => Map<String, Object?>.from(r))
          .toList();
    } finally {
      db.close();
    }
  }

  String? restoredId(String hash) {
    final rows = select('SELECT record_id FROM restored WHERE fingerprint=?', [
      hash,
    ]);
    return rows.isEmpty ? null : rows.single['record_id'] as String;
  }
}

T withFixtureRepository<T>(Notebook book, T Function(RecordRepository) action) {
  final repository = RecordRepository(book.home);
  try {
    return action(repository);
  } finally {
    repository.close();
  }
}
