import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import '../test/support/storage_probe.dart';
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('text append identity, bounded navigation and parent loss', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Missing isolated run identity');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = await Directory(
      p.join(identity['cacheRoot'] as String, 'text-append', runId),
    ).create(recursive: true);
    final shots = await Directory(p.join(root.path, 'screenshots')).create();
    var minute = 0;
    final book = await Notebook.open(
      Directory(p.join(root.path, 'source')),
      clock: () => DateTime.utc(2026, 11, 19, 9, minute++),
    );
    var count = 0;
    final input = find.byKey(const Key('body-editor'));
    Future<void> waitFor(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        ready(),
        isTrue,
        reason: find
            .byType(Text)
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .join('|'),
      );
      await tester.pump();
    }

    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
      count++;
    }

    Future<void> openAppend() async {
      await tap(find.text('追加内容'));
      await tap(find.text('追加文字'));
      expect(input, findsOneWidget);
    }

    Future<void> save(String visible) async {
      await tester.pumpAndSettle();
      await tap(find.widgetWithText(TextButton, '保存'));
      await waitFor(
        () =>
            input.evaluate().isEmpty &&
            find.text(visible).evaluate().isNotEmpty,
      );
    }

    try {
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        final title = mode == ThemeMode.dark ? '产品记录的入口' : '本地查找的条件';
        final parent = await book.saveText('$title\n先保留想法，再核对具体条件。');
        for (var i = 0; i < 95; i++) {
          await book.saveText('之前补充$i', parentId: parent.id);
        }
        await book.saveThemeMode(mode.name);
        await tester.pumpWidget(NianxiaApp(key: ValueKey(mode), book: book));
        await waitFor(() => find.text(title).evaluate().isNotEmpty);
        tester.testTextInput.register();
        await tap(find.text(title));
        if (mode == ThemeMode.dark && Platform.isAndroid) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        await shot('detail-before-${mode.name}');
        await openAppend();
        expect(find.text('追加到：$title'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
              .onPressed,
          isNull,
        );
        expect(await book.childCount(parent.id), 95);
        await shot('append-empty-${mode.name}');
        const added = '本次补充\n只有保存成功才返回，并定位这一次内容。';
        await tester.enterText(input, added);
        await tester.pumpAndSettle();
        await shot('append-draft-${mode.name}');
        await save(added);
        await waitFor(
          () => find.text(added).hitTestable().evaluate().isNotEmpty,
        );
        expect(await book.childCount(parent.id), 96);
        final saved = (await book.children(parent.id))
            .singleWhere((row) => row.body == added);
        final window = (await book.detail(
          parent.id,
          aroundId: saved.id,
        ))!.children;
        expect(window.entries.length, lessThanOrEqualTo(40));
        expect(window.entries.any((v) => v.record.id == saved.id), isTrue);
        expect(find.textContaining('刚刚追加'), findsOneWidget);
        expect(find.text('之前补充0'), findsNothing);
        await shot('saved-focused-${mode.name}');
        await Future<void>.delayed(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await tap(find.text('查看更早追加'));
        await waitFor(() => find.text('之前补充36').evaluate().isNotEmpty);
        expect(find.text(added), findsNothing);
        await shot('earlier-window-${mode.name}');
        await tap(find.text('查看更晚追加'));
        await waitFor(() => find.text(added).evaluate().isNotEmpty);
        await tap(find.text(added));
        expect(find.text('查看所属记录'), findsOneWidget);
        expect(find.text('追加内容'), findsNothing);
        await shot('child-detail-${mode.name}');
        await tap(find.byType(BackButton));
        await openAppend();
        const retryText = '故障后仍保留\n恢复存储后只保存一次。';
        await tester.enterText(input, retryText);
        StorageProbe(book).execute(
          "CREATE TRIGGER fail_append BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic fault'); END",
        );
        await tap(find.widgetWithText(TextButton, '保存'));
        await waitFor(() => find.textContaining('保存未完成').evaluate().isNotEmpty);
        expect(tester.widget<TextField>(input).controller!.text, retryText);
        await shot('save-failed-${mode.name}');
        StorageProbe(book).execute('DROP TRIGGER fail_append');
        await save(retryText);
        await waitFor(
          () => find.text(retryText).hitTestable().evaluate().isNotEmpty,
        );
        expect(await book.childCount(parent.id), 97);
        expect((await book.get(parent.id))!.body, parent.body);
        await shot('retry-saved-${mode.name}');
        await tap(find.byType(BackButton));
        final lost = await book.saveText('临时原记录\n验证保存时原记录消失。');
        await waitFor(() => find.text(lost.title).evaluate().isNotEmpty);
        await tap(find.text(lost.title));
        await openAppend();
        final standalone = '需要留下的补充\n$title：由我确认保存为独立记录。';
        await tester.enterText(input, standalone);
        await book.delete(lost.id);
        await tap(find.widgetWithText(TextButton, '保存'));
        await waitFor(() => find.text('原记录已删除，追加内容仍保留。').evaluate().isNotEmpty);
        expect(tester.widget<TextField>(input).controller!.text, standalone);
        await shot('parent-missing-${mode.name}');
        await tap(find.text('保存为独立记录'));
        await shot('standalone-confirm-${mode.name}');
        await tap(find.text('取消'));
        expect(input, findsOneWidget);
        await tap(find.text('保存为独立记录'));
        await tap(find.text('保存为独立记录').last);
        await waitFor(
          () =>
              input.evaluate().isEmpty &&
              find.text('需要留下的补充').evaluate().isNotEmpty,
        );
        final independent = (await book.records).singleWhere(
          (row) => row.body == standalone,
        );
        expect(independent.parentId, isNull);
        expect(await book.get(lost.id), isNull);
        await shot('standalone-saved-${mode.name}');
        expect(tester.takeException(), isNull);
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'themes': 2,
          'screenshots': count,
          'initialAppendsPerTheme': 95,
          'savedIdentityLocated': 1,
          'boundedWindowMaximum': 40,
          'previousAndNextWindows': 1,
          'saveFailureRetry': 1,
          'explicitStandaloneAfterParentDeletion': 1,
          'parentBodyUnchanged': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      tester.testTextInput.unregister();
      await tester.pumpWidget(const SizedBox.shrink());
      await book.close();
      final source = Directory(p.join(root.path, 'source'));
      if (await source.exists()) await source.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
