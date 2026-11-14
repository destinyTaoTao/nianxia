import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/diagnostic_event.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('隔离诊断资源预算、脱敏、未知版本与业务隔离', (tester) async {
    await requireIsolatedValidation();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('有界诊断隔离验证'),
      ),
    );
    final work = await Directory.systemTemp.createTemp(
      'diagnostics-synthetic-',
    );
    final book = await Notebook.open(Directory('${work.path}/book'));
    final diag = LocalDiagnostics(
      Directory('${work.path}/diagnostics'),
      maxBytes: 8192,
    );
    final blocked = File('${work.path}/blocked')
      ..writeAsStringSync('synthetic path blocker');
    final failed = LocalDiagnostics(Directory(blocked.path));
    final futureRoot = await Directory('${work.path}/future').create();
    final futureFile = File('${futureRoot.path}/diagnostics.sqlite');
    final futureDb = sqlite3.open(futureFile.path);
    futureDb.execute('PRAGMA application_id=${0x4e584447}');
    futureDb.execute('PRAGMA user_version=2');
    futureDb.execute('CREATE TABLE future(value TEXT)');
    futureDb.execute('INSERT INTO future VALUES(?)', [
      'future-private-sentinel',
    ]);
    futureDb.close();
    final before = sha256.convert(await futureFile.readAsBytes());
    final future = LocalDiagnostics(futureRoot);
    final metrics = <String, num>{};
    try {
      const secret = 'synthetic-original-query-key-password-sentinel';
      final saved = await diag.trace(
        DiagnosticKind.sourceWrite,
        () => book.saveText(secret),
      );
      await expectLater(
        diag.trace(
          DiagnosticKind.search,
          () async =>
              throw const FileSystemException(secret, '/private/path-sentinel'),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await diag.flush();
      for (var i = 0; i < 2000; i++) {
        diag.record(
          DiagnosticEvent(
            kind: DiagnosticKind.search,
            phase: DiagnosticPhase.run,
            result: DiagnosticResult.succeeded,
          ),
        );
      }
      expect(diag.pending, lessThanOrEqualTo(256));
      expect(diag.dropped, greaterThan(0));
      await diag.flush();
      final preview = await diag.previewExport();
      expect(preview.available, isTrue);
      expect(preview.entries, greaterThan(0));
      expect(preview.bytes, lessThanOrEqualTo(8192));
      final file = await diag.export();
      final text = await file.readAsString();
      expect(text, isNot(contains(secret)));
      expect(text, isNot(contains(work.path)));
      expect(text, isNot(contains('/private/path-sentinel')));
      final physical = await File('${diag.directory.path}/diagnostics.sqlite')
          .length();
      expect(physical, lessThanOrEqualTo(8192));
      final retained = await failed.trace(
        DiagnosticKind.sourceWrite,
        () => book.saveText('synthetic saved despite diagnostics IO failure'),
      );
      await failed.flush();
      expect(await book.get(retained.id), isNotNull);
      expect(failed.dropped, greaterThan(0));
      expect(
        await future.trace(DiagnosticKind.sourceWrite, () async => 42),
        42,
      );
      await future.flush();
      expect((await future.previewExport()).available, isFalse);
      expect(sha256.convert(await futureFile.readAsBytes()), before);
      expect((await book.get(saved.id))!.body, secret);
      metrics.addAll({
        'diagnosticBytes': physical,
        'previewBytes': preview.bytes,
        'diagnosticEntries': preview.entries,
        'dropped': diag.dropped,
        'retainedSourceRows': (await book.records).length,
        'futureStoreUnchanged': 1,
        'contentSentinelsExported': 0,
      });
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await diag.close();
      await failed.close();
      await future.close();
      await book.close();
      await work.delete(recursive: true);
    }
    binding.reportData = await writeValidationResult(
      passed: true,
      metrics: metrics,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
