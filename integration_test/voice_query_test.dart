import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';
import 'package:path/path.dart' as p;

import '../test/capture_controller_test.dart' show QueryReadyStore;
import '../test/voice_query_test.dart' show QueryModels;
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device microphone query, confirmation and cancellation', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('缺少隔离运行标识。');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = await Directory(
      p.join(identity['cacheRoot'] as String, 'voice-query', runId),
    ).create(recursive: true);
    final shots = await Directory(p.join(root.path, 'screenshots')).create();
    final book = await Notebook.open(Directory(p.join(root.path, 'source')));
    final store = QueryReadyStore(
      Directory(p.join(root.path, 'model-fixture')),
    );
    final models = QueryModels(store);
    final input = find.byKey(const Key('search-input'));
    final hold = find.byKey(const Key('hold-query'));
    Future<void> waitFor(bool Function() condition) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!condition() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 25));
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

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
    }

    Future<void> enterVoice() async {
      await tester.ensureVisible(find.text('语音查找'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音查找'));
      await tester.pumpAndSettle();
      expect(hold, findsOneWidget);
      expect(book.captureActive, isFalse);
    }

    Future<TestGesture> press() async {
      await tester.ensureVisible(hold);
      await tester.pumpAndSettle();
      final rect = tester.getRect(hold);
      final gesture = await tester.startGesture(rect.center);
      await waitFor(() => find.text('松手识别，上滑取消').evaluate().isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(tester.getRect(hold), rect);
      return gesture;
    }

    Future<void> assertClean() async {
      expect((await book.records).length, 2);
      expect(book.captureActive, isFalse);
      expect(
        await book.home
            .list(recursive: true)
            .where((f) => f.path.endsWith('.wav'))
            .isEmpty,
        isTrue,
      );
    }

    try {
      await book.saveText('缓存一致性方案\n先检查数据失效，再判断是否增加缓存。');
      await book.saveText('离线存储方案\n保留原始内容，索引可以重新构建。');
      // Actual DeviceMicrophone and WAV validation; only transcription output
      // is controlled. This does not claim real ASR quality or offline models.
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        await book.saveThemeMode(mode.name);
        await tester.pumpWidget(
          NianxiaApp(key: ValueKey(mode), book: book, models: models),
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
        await enterVoice();
        await shot('ready-${mode.name}');
        final gesture = await press();
        await shot('recording-${mode.name}');
        await gesture.up();
        await waitFor(
          () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
        );
        expect(tester.widget<TextField>(input).controller!.text, '缓存');
        expect(find.byType(SearchSummaryRow), findsNothing);
        expect(models.audio, isNotNull);
        expect(await File(models.audio!).exists(), isFalse);
        await assertClean();
        await shot('review-${mode.name}');
        await tester.enterText(input, '离线');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('search-submit')));
        await waitFor(() => find.text('离线存储方案').evaluate().isNotEmpty);
        expect(find.text('缓存一致性方案'), findsNothing);
        await shot('confirmed-${mode.name}');
        models.audio = null;
        await enterVoice();
        final cancelling = await press();
        await cancelling.moveBy(const Offset(0, -90));
        await tester.pump();
        await shot('cancel-${mode.name}');
        await cancelling.up();
        await waitFor(() => find.text('按住说出线索').evaluate().isNotEmpty);
        expect(models.audio, isNull);
        await tester.tap(find.text('改用文字'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, '离线');
        await assertClean();
        models.fail = true;
        await enterVoice();
        final failing = await press();
        await failing.up();
        await waitFor(() => find.text('重说').evaluate().isNotEmpty);
        await shot('failure-${mode.name}');
        await assertClean();
        models.fail = false;
        await tester.tap(find.text('改用文字'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sourceRows': 2,
          'deviceMicrophone': 1,
          'controlledTranscription': 1,
          'themes': 2,
          'screenshots': 12,
          'confirmBeforeLookup': 1,
          'cancelAndFailureCleaned': 1,
          'queryCreatedNoRecords': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      tester.testTextInput.unregister();
      await tester.pumpWidget(const SizedBox.shrink());
      await book.close();
      await models.close();
      store.dispose();
      final source = Directory(p.join(root.path, 'source'));
      if (await source.exists()) await source.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
