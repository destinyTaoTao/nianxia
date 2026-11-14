import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/domain/diagnostic_event.dart';

void main() {
  test(
    'sizeOrAgeEvictsOldest and rollback keeps bounded valid metadata',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-diag-retain-');
      var now = DateTime.utc(2026, 11, 1);
      final diag = LocalDiagnostics(
        home,
        clock: () => now,
        maxBytes: 2048,
        maxAge: const Duration(days: 7),
      );
      try {
        for (var i = 0; i < 20; i++) {
          await diag.record(
            DiagnosticEvent(
              kind: DiagnosticKind.embedding,
              phase: DiagnosticPhase.run,
              result: DiagnosticResult.succeeded,
              sourceRevision: i + 1,
            ),
          );
          await diag.flush();
        }
        var preview = await diag.previewExport();
        expect(preview.bytes, lessThanOrEqualTo(2048));
        expect(preview.entries, greaterThan(0));
        expect(preview.entries, lessThan(20));
        expect(
          await File('${home.path}/diagnostics.sqlite').length(),
          lessThanOrEqualTo(2048),
        );
        now = DateTime.utc(2026, 11, 10);
        await diag.record(
          DiagnosticEvent(
            kind: DiagnosticKind.startup,
            phase: DiagnosticPhase.prepare,
            result: DiagnosticResult.succeeded,
          ),
        );
        await diag.flush();
        preview = await diag.previewExport();
        expect(preview.firstAt, now);
        now = DateTime.utc(2026, 10, 1);
        await diag.record(
          DiagnosticEvent(
            kind: DiagnosticKind.startup,
            phase: DiagnosticPhase.prepare,
            result: DiagnosticResult.succeeded,
          ),
        );
        await diag.flush();
        preview = await diag.previewExport();
        expect(preview.lastAt, now);
        expect(preview.bytes, lessThanOrEqualTo(2048));
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test(
    'pending queue is bounded and dropped diagnostics never block business',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-diag-pressure-');
      final diag = LocalDiagnostics(home);
      try {
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
        expect(diag.pending, 0);
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test(
    'managed export copies stay bounded and close joins an active export',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'nx-diag-export-retain-',
      );
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
        for (var i = 0; i < 8; i++) {
          await diag.export();
        }
        final files = await Directory('${home.path}/exports').list().toList();
        expect(
          files
              .whereType<File>()
              .where((f) => f.path.endsWith('.jsonl'))
              .length,
          lessThanOrEqualTo(5),
        );
        final exporting = diag.export();
        final closing = diag.close();
        final file = await exporting;
        await closing;
        expect(await file.exists(), isTrue);
      } finally {
        await diag.close();
        await home.delete(recursive: true);
      }
    },
  );
  test('preview time range remains ordered after a clock rollback inside one queued batch', () async {
    final home = await Directory.systemTemp.createTemp('nx-diag-clock-');
    final later = DateTime.utc(2026, 11, 14, 12);
    var now = later;
    final diag = LocalDiagnostics(home, clock: () => now);
    try {
      diag.record(
        DiagnosticEvent(
          kind: DiagnosticKind.search,
          phase: DiagnosticPhase.run,
          result: DiagnosticResult.succeeded,
        ),
      );
      now = later.subtract(const Duration(hours: 1));
      diag.record(
        DiagnosticEvent(
          kind: DiagnosticKind.search,
          phase: DiagnosticPhase.run,
          result: DiagnosticResult.succeeded,
        ),
      );
      now = later.add(const Duration(hours: 1));
      await diag.flush();
      final preview = await diag.previewExport();
      expect(preview.firstAt, later.subtract(const Duration(hours: 1)));
      expect(preview.lastAt, later);
    } finally {
      await diag.close();
      await home.delete(recursive: true);
    }
  });
}
