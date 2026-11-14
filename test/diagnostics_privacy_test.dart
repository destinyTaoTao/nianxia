import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';
import 'package:nianxia/app/notebook_session.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/domain/diagnostic_event.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'contentNeverSerialized even when a failing operation contains secrets',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-diag-private-');
      final diag = LocalDiagnostics(Directory('${home.path}/diagnostics'));
      const sentinel = '正文-查询-Key-password-/private/original-path-sentinel';
      try {
        await expectLater(
          diag.trace(
            DiagnosticKind.search,
            () async => throw const FileSystemException(sentinel, sentinel),
          ),
          throwsA(isA<FileSystemException>()),
        );
        await diag.flush();
        final preview = await diag.previewExport();
        expect(preview.entries, greaterThan(0));
        expect(preview.includedFields, contains('结果与安全错误码'));
        final exported = await diag.export();
        final contents = await exported.readAsString();
        expect(contents, isNot(contains(sentinel)));
        expect(contents, isNot(contains(home.path)));
        expect(contents, contains('ioFailure'));
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test('ioFailureCannotFailSavedOperation or successful backup', () async {
    final home = await Directory.systemTemp.createTemp('nx-diag-io-');
    final book = await Notebook.open(Directory('${home.path}/book'));
    final blocked = File('${home.path}/blocked')
      ..writeAsStringSync('synthetic blocking file');
    final diag = LocalDiagnostics(Directory(blocked.path));
    try {
      final saved = await diag.trace(
        DiagnosticKind.sourceWrite,
        () => book.saveText('synthetic retained record'),
      );
      final archive = await BackupService(book, diagnostics: diag).export();
      expect(await archive.exists(), isTrue);
      await diag.flush();
      expect((await book.get(saved.id))!.body, 'synthetic retained record');
      expect(diag.dropped, greaterThan(0));
    } finally {
      await book.close();
      await diag.close();
      await home.delete(recursive: true);
    }
  });
  test(
    'unknown fields or future diagnostics are never copied into an export',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-diag-input-');
      final diag = LocalDiagnostics(home);
      try {
        await diag.record(
          DiagnosticEvent(
            kind: DiagnosticKind.startup,
            phase: DiagnosticPhase.prepare,
            result: DiagnosticResult.succeeded,
          ),
        );
        await diag.flush();
        final database = sqlite3.open('${home.path}/diagnostics.sqlite');
        database.execute(
          'INSERT INTO events(at,payload,weight) VALUES(?,?,?)',
          [
            DateTime.now().toUtc().millisecondsSinceEpoch,
            '{"version":1,"body":"private-input-sentinel"}',
            1,
          ],
        );
        database.close();
        await File('${home.path}/diag-v1-malformed.jsonl')
            .writeAsString('{"version":1,"body":"private-input-sentinel"}\n');
        await File('${home.path}/future-v2.jsonl')
            .writeAsString('{"version":2,"body":"future-private-sentinel"}\n');
        final text = await (await diag.export()).readAsString();
        expect(text, isNot(contains('private-input-sentinel')));
        expect(text, isNot(contains('future-private-sentinel')));
        expect(File('${home.path}/future-v2.jsonl').existsSync(), isTrue);
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test(
    'future diagnostics store is preserved and never blocks business',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-diag-future-');
      final file = File('${home.path}/diagnostics.sqlite');
      final db = sqlite3.open(file.path);
      db.execute('PRAGMA application_id=1314407495');
      db.execute('PRAGMA user_version=2');
      db.execute('CREATE TABLE future(value TEXT)');
      db.execute('INSERT INTO future VALUES(?)', ['future-private-sentinel']);
      db.close();
      final before = sha256.convert(await file.readAsBytes());
      final diag = LocalDiagnostics(home);
      try {
        expect(
          await diag.trace(DiagnosticKind.sourceWrite, () async => 42),
          42,
        );
        await diag.flush();
        expect(diag.dropped, greaterThan(0));
        expect((await diag.previewExport()).available, isFalse);
        expect(sha256.convert(await file.readAsBytes()), before);
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test('source open failure still produces safe startup diagnostics', () async {
    final home = await Directory.systemTemp.createTemp('nx-diag-startup-');
    final source = File('${home.path}/records.sqlite');
    final db = sqlite3.open(source.path);
    db.execute('PRAGMA user_version=999');
    db.close();
    final before = sha256.convert(await source.readAsBytes());
    try {
      await expectLater(
        NotebookSession.open(home, loadModelManifest: () async => '[]'),
        throwsA(isA<NotebookException>()),
      );
      final diag = LocalDiagnostics(Directory('${home.path}/diagnostics'));
      try {
        expect((await diag.previewExport()).entries, greaterThan(0));
        expect(sha256.convert(await source.readAsBytes()), before);
      } finally {
        await diag.close();
      }
    } finally {
      await home.delete(recursive: true);
    }
  });
}
