import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'continuous home text entry and real keyboard in isolated workspace',
    (tester) async {
      await requireIsolatedValidation();
      tester.testTextInput.unregister();
      const runId = String.fromEnvironment('VALIDATION_RUN_ID');
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(runId)) {
        throw StateError('缺少有效的隔离运行标识。');
      }
      final identity = (await const MethodChannel('app.nianxia/system')
          .invokeMapMethod<String, Object?>('validationIdentity'))!;
      final root = Directory(
        p.join(identity['cacheRoot'] as String, 'continuous-home', runId),
      );
      final shots = await Directory(p.join(root.path, 'screenshots'))
          .create(recursive: true);
      var date = DateTime(2026, 11, 15, 17, 50);
      final book = await Notebook.open(
        Directory(p.join(root.path, 'source')),
        clock: () => date,
      );
      try {
        await book.saveText('周末散步\n带相机去公园，走累了就回家。');
        date = DateTime(2026, 11, 16, 9, 40);
        await book.saveText('产品原型\n先验证记录和查找，再扩大功能范围。');
        date = DateTime(2026, 11, 16, 10, 24);
        await book.saveText('优化数据库查询\n先检查慢查询，再评估索引；不要先加缓存。');
        await tester.pumpWidget(
          NianxiaApp(book: book, initialTheme: ThemeMode.dark),
        );
        Future<void> waitFor(bool Function() condition) async {
          final deadline = DateTime.now().add(const Duration(seconds: 15));
          while (!condition() && DateTime.now().isBefore(deadline)) {
            await tester.pump(const Duration(milliseconds: 100));
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(condition(), isTrue);
          await tester.pumpAndSettle();
        }

        await waitFor(() => find.text('优化数据库查询').evaluate().isNotEmpty);
        if (Platform.isAndroid) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        Future<void> shot(String name) async {
          await tester.pumpAndSettle();
          final bytes = await binding.takeScreenshot(name);
          await File(p.join(shots.path, '$name.png'))
              .writeAsBytes(bytes, flush: true);
        }

        await shot('home-dark');
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        await shot('settings-dark');
        await tester.tap(find.byKey(const Key('theme-choice-light')));
        await waitFor(() => book.themeMode == 'light');
        await shot('settings-light');
        await tester.tap(find.byType(BackButton));
        await shot('home-light');
        tester.testTextInput.unregister();
        await tester.tap(find.byKey(const Key('home-mode-text')));
        await tester.pumpAndSettle();
        await tester.showKeyboard(find.byKey(const Key('body-editor')));
        await waitFor(() => tester.view.viewInsets.bottom > 0);
        final keyboardTop =
            (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
            tester.view.devicePixelRatio;
        expect(
          tester.getBottomRight(find.byKey(const Key('home-save-text'))).dy,
          lessThanOrEqualTo(keyboardTop),
        );
        await shot('text-real-keyboard');
        await Future<void>.delayed(const Duration(seconds: 4));
        // Only text injection is simulated; the preceding IME/insets are real.
        await tester.tap(find.byTooltip('返回'));
        await tester.pumpAndSettle();
        await waitFor(() => tester.view.viewInsets.bottom == 0);
        tester.testTextInput.register();
        await tester.tap(find.byKey(const Key('home-mode-text')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('body-editor')),
          '新的想法\n先把最短闭环做好。',
        );
        await tester.pump();
        date = DateTime(2026, 11, 16, 11, 8);
        await tester.tap(find.byKey(const Key('home-save-text')));
        await waitFor(() => find.byTooltip('收藏：新的想法').evaluate().isNotEmpty);
        expect((await book.records).length, 4);
        expect((await book.records).first.body, contains('新的想法'));
        tester.testTextInput.unregister();
        FocusManager.instance.primaryFocus?.unfocus();
        await waitFor(() => tester.view.viewInsets.bottom == 0);
        await shot('text-saved');
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await shot('home-large-text');
        tester.testTextInput.unregister();
        await tester.tap(find.byKey(const Key('home-mode-text')));
        await tester.pumpAndSettle();
        await tester.showKeyboard(find.byKey(const Key('body-editor')));
        await waitFor(() => tester.view.viewInsets.bottom > 0);
        await tester.ensureVisible(find.byKey(const Key('home-save-text')));
        await shot('text-large-keyboard');
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
        binding.reportData = await writeValidationResult(
          passed: true,
          metrics: {
            'sourceRows': 4,
            'lightAndDarkScreens': 1,
            'actualKeyboardInsetsObserved': 1,
            'largeTextScale': 2,
          },
        );
      } catch (_) {
        binding.reportData = await writeValidationResult(passed: false);
        rethrow;
      } finally {
        tester.testTextInput.unregister();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.pumpWidget(const SizedBox.shrink());
        await book.close();
        // Keep only this run's synthetic screenshots for visual review.
        final source = Directory(p.join(root.path, 'source'));
        if (await source.exists()) await source.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
