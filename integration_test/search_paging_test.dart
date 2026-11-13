import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/domain/search_page.dart';

import 'support/isolated_validation.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('此合成检索验证禁止网络');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('独立应用10001条同分摘要分页与代际重置', (tester) async {
    await requireIsolatedValidation();
    final previous = HttpOverrides.current;
    HttpOverrides.global = _NoNetwork();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('摘要分页隔离验证'),
      ),
    );
    final home = await Directory.systemTemp.createTemp('paging-synthetic-');
    final book = await Notebook.open(home);
    try {
      final fixture = RecordRepository(home);
      fixture.db.execute('BEGIN');
      final insert = fixture.db.prepare(
        'INSERT INTO records(id,parent_id,body,created_at,timezone,offset_minutes,revision,favorite,audio,duration_ms,transcript,transcription) VALUES(?,NULL,?,?,\'UTC\',0,1,0,NULL,0,NULL,\'none\')',
      );
      try {
        for (var i = 0; i < 10001; i++) {
          insert.execute([
            '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
            'marker synthetic $i ${List.filled(16, '正文🔒').join()}',
            '2026-11-14T00:00:00.000Z',
          ]);
        }
        fixture.db.execute('COMMIT');
      } finally {
        insert.close();
        fixture.close();
      }
      final preparing = Stopwatch()..start();
      await book.repository.waitForSearchIndex();
      preparing.stop();
      final query = SearchQuery(text: 'marker');
      var peakRss = ProcessInfo.currentRss;
      var maxGap = 0;
      final clock = Stopwatch()..start();
      var last = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final rss = ProcessInfo.currentRss;
        if (rss > peakRss) peakRss = rss;
        final now = clock.elapsedMilliseconds;
        if (now - last > maxGap) maxGap = now - last;
        last = now;
      });
      final watch = Stopwatch()..start();
      var page = await book.searchPage(query);
      final firstMs = watch.elapsedMilliseconds;
      final firstCursor = page.next;
      final seen = <String>{};
      var count = 0, maxBytes = 0, pages = 0;
      try {
        while (true) {
          expect(page.reset, isFalse);
          expect(page.entries.length, lessThanOrEqualTo(40));
          for (final entry in page.entries) {
            expect(seen.add(entry.id), isTrue);
            expect(entry.title.runes.length, lessThanOrEqualTo(120));
            expect(entry.snippet.runes.length, lessThanOrEqualTo(150));
            expect(entry.toMap().containsKey('body'), isFalse);
          }
          final bytes = utf8.encode(jsonEncode(page.toMap())).length;
          if (bytes > maxBytes) maxBytes = bytes;
          count += page.entries.length;
          pages++;
          if (page.next == null) break;
          page = await book.searchPage(query, after: page.next);
        }
      } finally {
        timer.cancel();
      }
      final allMs = watch.elapsedMilliseconds;
      expect(count, 10001);
      expect(pages, 251);
      await book.edit(seen.first, 'edited marker', expectedRevision: 1);
      expect((await book.searchPage(query, after: firstCursor)).reset, isTrue);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'records': count,
          'pages': pages,
          'indexPreparationMs': preparing.elapsedMilliseconds,
          'firstPageMs': firstMs,
          'allPagesMs': allMs,
          'maxPagePayloadBytes': maxBytes,
          'sampledProcessPeakRss': peakRss,
          'mainTimerMaxGapMs': maxGap,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await book.close();
      await home.delete(recursive: true);
      HttpOverrides.global = previous;
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
