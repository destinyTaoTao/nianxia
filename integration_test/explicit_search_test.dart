import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';
import 'package:path/path.dart' as p;

import '../test/support/search_runtime.dart';
import '../test/support/storage_probe.dart';
import '../test/support/ui_native_capture.dart';
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('explicit search, dates and recovery in isolated source', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('缺少有效的隔离运行标识。');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'explicit-search', runId),
    );
    final shots = await Directory(p.join(root.path, 'screenshots'))
        .create(recursive: true);
    var now = DateTime(2026, 11, 18, 10);
    final book = await Notebook.open(
      Directory(p.join(root.path, 'source')),
      clock: () => now,
    );
    // Only inference timing is controlled. Source, lookup, date filtering and
    // SQLite errors use the real notebook; this is not model quality testing.
    final runtime = SearchRuntime(holdQueries: false);
    final capture = CaptureSessionController(
      UiCaptureEndpoint(book),
      book,
      runtime,
    );
    var renamed = false;
    try {
      await book.saveText('缓存一致性\n先检查失效时机，再决定是否增加缓存。');
      now = DateTime(2026, 11, 19, 9, 40);
      await book.saveText('离线存储方案\n保留原始内容，索引可重新构建。');
      now = DateTime(2026, 11, 19, 10, 20);
      await book.saveText('缓存查询优化\n先测量慢查询，再评估索引效果。');
      final input = find.byKey(const Key('search-input'));
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          condition(),
          isTrue,
          reason: find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data)
              .join('|'),
        );
        await tester.pump();
      }

      Future<void> shot(String name, {bool loading = false}) async {
        if (loading) {
          await tester.pump(const Duration(milliseconds: 300));
        } else {
          await tester.pumpAndSettle();
        }
        final bytes = await binding.takeScreenshot(name);
        await File(p.join(shots.path, '$name.png'))
            .writeAsBytes(bytes, flush: true);
      }

      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          NianxiaApp(book: book, captureSession: capture, initialTheme: mode),
        );
        await waitFor(
          () => find.byKey(const Key('home-search')).evaluate().isNotEmpty,
        );
        tester.testTextInput.register();
        await tester.tap(find.byKey(const Key('home-search')));
        await tester.pumpAndSettle();
        if (mode == ThemeMode.dark && Platform.isAndroid) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        final suffix = mode.name;
        await shot('idle-$suffix');
        await tester.enterText(input, '缓存');
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(SearchSummaryRow), findsNothing);
        expect(tester.widget<TextField>(input).controller!.text, '缓存');
        // A pump may build the newly enabled button at its end. Wait for the
        // inherited label animation too, so the image is a stable usable state.
        final submitLabel = find.descendant(
          of: find.byKey(const Key('search-submit')),
          matching: find.text('查找'),
        );
        await waitFor(() {
          final element = submitLabel.evaluate().single;
          return DefaultTextStyle.of(element).style.color ==
              Theme.of(element).colorScheme.onPrimary;
        });
        await shot('typed-$suffix');
        await tester.ensureVisible(find.byKey(const Key('search-submit')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('search-submit')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const Key('search-submit')));
        await tester.pump();
        await waitFor(
          () => find.textContaining('找到 2 条记录').evaluate().isNotEmpty,
        );
        await shot('results-$suffix');
        await tester.tap(find.byKey(const Key('search-date-today')));
        await waitFor(
          () => find.textContaining('找到 1 条记录').evaluate().isNotEmpty,
        );
        expect(find.text('缓存一致性'), findsNothing);
        await shot('today-$suffix');
        await tester.tap(find.byKey(const Key('search-date-week')));
        await waitFor(
          () => find.textContaining('找到 2 条记录').evaluate().isNotEmpty,
        );
        await tester.enterText(input, '离线');
        await tester.pump(const Duration(seconds: 1));
        expect(find.textContaining('尚未更新'), findsWidgets);
        expect(find.textContaining('“缓存”'), findsOneWidget);
        await shot('draft-$suffix');
        runtime.holdQueries = true;
        runtime.pending.clear();
        await tester.ensureVisible(find.byKey(const Key('search-submit')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('search-submit')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const Key('search-submit')));
        await tester.pump();
        await waitFor(() => runtime.pending.containsKey('离线'));
        expect(find.text('缓存查询优化'), findsOneWidget);
        await shot('loading-$suffix', loading: true);
        runtime.pending['离线']!.complete([1, 0]);
        runtime.holdQueries = false;
        await waitFor(() => find.text('离线存储方案').evaluate().isNotEmpty);
        await tester.tap(find.text('离线存储方案'));
        await tester.pumpAndSettle();
        await shot('detail-$suffix');
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, '离线');
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.enterText(input, '缓存');
        StorageProbe(book)
            .execute('ALTER TABLE records RENAME TO source_unavailable');
        renamed = true;
        await tester.ensureVisible(find.byKey(const Key('search-submit')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('search-submit')))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.byKey(const Key('search-submit')));
        await tester.pump();
        await waitFor(() => find.text('重试查找').evaluate().isNotEmpty);
        expect(find.text('离线存储方案'), findsOneWidget);
        expect(find.text('没有找到相关记录'), findsNothing);
        await shot('error-$suffix');
        StorageProbe(book)
            .execute('ALTER TABLE source_unavailable RENAME TO records');
        renamed = false;
        await tester.tap(find.text('重试查找'));
        await waitFor(
          () => find.textContaining('找到 2 条记录').evaluate().isNotEmpty,
        );
        await shot('retry-$suffix');
        await tester.enterText(input, '月球旅行');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await waitFor(() => find.text('没有找到相关记录').evaluate().isNotEmpty);
        await shot('empty-$suffix');
        await tester.tap(find.text('清除日期条件'));
        await waitFor(
          () => tester
              .widget<ChoiceChip>(find.byKey(const Key('search-date-all')))
              .selected,
        );
        await tester.tap(find.byTooltip('清空查找内容'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchSummaryRow), findsNothing);
        expect(find.text('找回之前的想法'), findsOneWidget);
        expect((await book.records).length, 3);
        expect(tester.takeException(), isNull);
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sourceRows': 3,
          'themes': 2,
          'screenshots': 20,
          'explicitSubmission': 1,
          'dateShortcuts': 1,
          'oldResultsDuringLoading': 1,
          'failureAndRetry': 1,
          'detailReturn': 1,
          'queryCreatedNoRecords': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      if (renamed) {
        StorageProbe(book)
            .execute('ALTER TABLE source_unavailable RENAME TO records');
      }
      tester.testTextInput.unregister();
      await tester.pumpWidget(const SizedBox.shrink());
      capture.dispose();
      runtime.dispose();
      await book.close();
      final source = Directory(p.join(root.path, 'source'));
      if (await source.exists()) await source.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
