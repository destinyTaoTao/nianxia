import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/data/record_repository.dart';

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    final candidate = File(
      p.join(
        directory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    );
    if (candidate.existsSync()) return candidate.path;
    directory = directory.parent;
  }
  throw StateError('Cannot find the Flutter Dart SDK for the host crash test');
}

void main() {
  test('迁移关键阶段被操作系统强制终止，DELETE与WAL日志均可重启升级且原件不变', () async {
    final fixture = await File('test/fixtures/schema_v1.sql').readAsString();
    for (final mode in ['DELETE', 'WAL']) {
      for (final stage in [
        'snapshot',
        'copied',
        'switched',
        'versioned',
        'validated',
        'beforeCommit',
      ]) {
        final home = await Directory.systemTemp.createTemp('nianxia-crash-');
        try {
          final seed = sqlite3.open('${home.path}/records.sqlite');
          final parentVersion = seed
              .select('SELECT sqlite_version()')
              .single
              .values
              .single;
          seed.execute(fixture);
          seed.execute('PRAGMA journal_mode=$mode');
          seed.close();
          final audio = await File('${home.path}/original.wav')
              .writeAsBytes([0, 1, 255, 42], flush: true);
          final child = await Process.start(_dartExecutable(), [
            '--packages=${File('.dart_tool/package_config.json').absolute.path}',
            File('test/support/migration_crash_child.dart').absolute.path,
            home.path,
            stage,
          ]);
          final errors = child.stderr.transform(utf8.decoder).join();
          final output = child.stdout.drain<void>();
          int? earlyExit;
          child.exitCode.then((value) => earlyExit = value);
          try {
            final marker = File('${home.path}/crash-ready');
            final deadline = DateTime.now().add(const Duration(seconds: 15));
            while (!await marker.exists() &&
                earlyExit == null &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!await marker.exists()) {
              child.kill(
                Platform.isWindows
                    ? ProcessSignal.sigterm
                    : ProcessSignal.sigkill,
              );
              await child.exitCode;
              final runtime = File('${home.path}/sqlite-runtime');
              fail(
                '$mode/$stage parentSQLite=$parentVersion childSQLite=${runtime.existsSync() ? runtime.readAsStringSync() : 'unknown'} exit $earlyExit before stage: ${await errors}',
              );
            }
            expect(
              child.kill(
                Platform.isWindows
                    ? ProcessSignal.sigterm
                    : ProcessSignal.sigkill,
              ),
              isTrue,
            );
            expect(await child.exitCode, isNot(0));
            expect(await errors, isEmpty);
            await output;
          } finally {
            child.kill(
              Platform.isWindows
                  ? ProcessSignal.sigterm
                  : ProcessSignal.sigkill,
            );
            await child.exitCode;
          }
          // Reopen through production first: an independent writable probe
          // would recover the hot journal and hide startup recovery failures.
          var checkedRolledBackSnapshot = false;
          final retry = RecordRepository(
            home,
            migrationHook: (nextStage) {
              if (nextStage != 'snapshot') return;
              final check = sqlite3.open(
                '${home.path}/records.sqlite.migration-v1.snapshot',
                mode: OpenMode.readOnly,
              );
              try {
                expect(
                  check.select('PRAGMA user_version').single.values.single,
                  1,
                  reason: '$mode/$stage',
                );
                expect(
                  check
                      .select("SELECT body FROM records WHERE id='parent'")
                      .single['body'],
                  '原文不改写',
                );
                expect(
                  check
                      .select('SELECT record_id FROM restored')
                      .single['record_id'],
                  'parent',
                );
                expect(check.select('PRAGMA foreign_key_check'), isEmpty);
                checkedRolledBackSnapshot = true;
              } finally {
                check.close();
              }
            },
          );
          expect(checkedRolledBackSnapshot, isTrue);
          expect(retry.get('child')!.parentId, 'parent');
          expect(
            retry.db.select('PRAGMA user_version').single.values.single,
            2,
          );
          retry.close();
          expect(await audio.readAsBytes(), [0, 1, 255, 42]);
        } finally {
          await home.delete(recursive: true);
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
