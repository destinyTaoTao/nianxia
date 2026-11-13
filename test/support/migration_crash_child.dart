// Host-only crash fixture. The parent owns this fresh temporary notebook and
// kills this process after a durable marker, without running Dart finalizers.
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'package:nianxia/data/record_repository.dart';

void main(List<String> arguments) {
  final home = Directory(arguments[0]);
  final probe = sqlite3.openInMemory();
  File('${home.path}/sqlite-runtime').writeAsStringSync(
    probe.select('SELECT sqlite_version()').single.values.single.toString(),
  );
  probe.close();
  RecordRepository(
    home,
    migrationHook: (stage) {
      if (stage != arguments[1]) return;
      File('${home.path}/crash-ready').writeAsStringSync(stage, flush: true);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        sleep(const Duration(milliseconds: 20));
      }
      exit(74);
    },
  );
}
