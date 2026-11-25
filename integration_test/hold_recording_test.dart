import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('hold record saves, cancels and retries with device microphone', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Invalid isolated run identity');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = await Directory(
      p.join(identity['cacheRoot'] as String, 'hold-recording', runId),
    ).create(recursive: true);
    final shots = await Directory(p.join(root.path, 'screenshots')).create();
    final book = await Notebook.open(Directory(p.join(root.path, 'source')));
    Future<void> waitFor(bool Function() ready) async {
      final end = DateTime.now().add(const Duration(seconds: 20));
      while (!ready() && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(ready(), isTrue);
      await tester.pump();
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
    }

    final button = find.byKey(const Key('hold-record'));
    Future<TestGesture> press() async {
      final rect = tester.getRect(button);
      final gesture = await tester.startGesture(rect.center);
      await waitFor(() => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
      expect(tester.getRect(button), rect);
      return gesture;
    }

    void fault(bool enabled) {
      final db = sqlite3.open(p.join(book.home.path, 'records.sqlite'));
      try {
        db.execute(
          enabled
              ? "CREATE TRIGGER fail_hold_device BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'validation fault'); END"
              : 'DROP TRIGGER fail_hold_device',
        );
      } finally {
        db.close();
      }
    }

    try {
      await book.saveText('合成想法\n先留下原话，再慢慢整理。');
      var count = 1;
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        await book.saveThemeMode(mode.name);
        await tester.pumpWidget(NianxiaApp(key: ValueKey(mode), book: book));
        await tester.pumpAndSettle();
        await waitFor(() => find.text('合成想法').evaluate().isNotEmpty);
        if (mode == ThemeMode.dark && Platform.isAndroid) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        await shot('home-${mode.name}');
        final origin = tester.getCenter(button);
        final gesture = await press();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await shot('recording-${mode.name}');
        await gesture.moveTo(origin - const Offset(0, 90));
        await tester.pump();
        expect(find.text('松手取消，移回继续'), findsOneWidget);
        await shot('cancel-candidate-${mode.name}');
        await gesture.moveTo(origin);
        await tester.pump();
        expect(find.text('松手保存，上滑取消'), findsOneWidget);
        await gesture.up();
        await waitFor(() => find.text('按住说话').evaluate().isNotEmpty);
        final rows = await book.records;
        expect(rows.length, ++count);
        final audio = rows.first;
        expect(audio.audio, isNotNull);
        expect(await File(book.audioPath(audio)).length(), greaterThan(44));
        await shot('saved-${mode.name}');
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('home-mode-text')))
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '点按录音'))
              .onPressed,
          isNotNull,
        );
        final cancelling = await press();
        await cancelling.moveBy(const Offset(0, -90));
        await tester.pump();
        await cancelling.up();
        await waitFor(() => find.text('按住说话').evaluate().isNotEmpty);
        expect((await book.records).length, count);
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          await Directory(p.join(book.home.path, 'drafts')).list().isEmpty,
          isTrue,
        );
      }
      ScaffoldMessenger.of(tester.element(button)).clearSnackBars();
      final failing = await press();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      fault(true);
      await failing.up();
      await waitFor(() => find.text('重试保存').evaluate().isNotEmpty);
      expect((await book.records).length, count);
      expect(find.text('音频已保存，等待转写'), findsNothing);
      expect(
        find.descendant(of: button, matching: find.text('录音未保存')),
        findsOneWidget,
      );
      await shot('save-failed-light');
      fault(false);
      await tester.tap(find.text('重试保存'));
      await waitFor(() => find.text('按住说话').evaluate().isNotEmpty);
      expect((await book.records).length, ++count);
      await shot('retry-saved-light');
      expect(tester.takeException(), isNull);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sourceRows': count,
          'normalSaves': 2,
          'explicitCancels': 2,
          'saveFailureAndRetry': 1,
          'lightAndDarkScreens': 1,
          'deviceMicrophone': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await book.close();
      final source = Directory(p.join(root.path, 'source'));
      if (await source.exists()) await source.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
