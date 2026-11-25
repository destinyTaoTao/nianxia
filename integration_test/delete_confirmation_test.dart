import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import '../test/recording_search_test.dart' show writeWave;
import '../test/support/storage_probe.dart';
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('confirmed deletion and source changes in isolated notebook', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Invalid isolated run');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'delete-confirmation', runId),
    );
    final shots = await Directory(p.join(root.path, 'screenshots'))
        .create(recursive: true);
    var minute = 0, screenshotCount = 0;
    final book = await Notebook.open(
      Directory(p.join(root.path, 'source')),
      clock: () => DateTime.utc(2026, 11, 20, 9, minute++),
    );
    final playback = PlaybackCoordinator.retain(book);
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
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
      screenshotCount++;
    }

    try {
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        final parent = await book.saveText('确认后再删除原记录');
        final child = await book.saveText('只删除这一段', parentId: parent.id);
        final draft = await book.beginCapture(parentId: parent.id);
        await writeWave(draft.path);
        final audio = await book.finishCapture(draft);
        await book.saveThemeMode(mode.name);
        await tester.pumpWidget(NianxiaApp(key: ValueKey(mode), book: book));
        await waitFor(() => find.text(parent.title).evaluate().isNotEmpty);
        await tap(find.text(parent.title));
        if (mode == ThemeMode.dark) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        Future<void> prompt() async {
          await tap(find.byTooltip('更多操作'));
          await tap(find.text('删除记录'));
          await waitFor(() => find.text('取消').evaluate().isNotEmpty);
        }

        await prompt();
        expect(find.text('删除这组 3 条记录？'), findsOneWidget);
        await shot('group-${mode.name}');
        await tap(find.text('取消'));
        expect(await book.childCount(parent.id), 2);
        await tap(find.text(child.body));
        await waitFor(() => find.text('查看所属记录').evaluate().isNotEmpty);
        await prompt();
        expect(find.text('删除这次追加？'), findsOneWidget);
        expect(find.textContaining('所属原记录和其他追加会保留'), findsOneWidget);
        await shot('single-${mode.name}');
        await tap(find.text('删除'));
        await waitFor(() => find.text('追加内容').evaluate().isNotEmpty);
        expect(await book.get(parent.id), isNotNull);
        expect(await book.get(child.id), isNull);
        expect(await File(book.audioPath(audio)).exists(), isTrue);
        await shot('single-deleted-${mode.name}');
        await prompt();
        await book.saveText('尚未确认的新追加', parentId: parent.id);
        await tap(find.text('删除'));
        await waitFor(
          () => find.text('记录或追加已变化，请重新确认删除范围。').evaluate().isNotEmpty,
        );
        expect(await book.childCount(parent.id), 2);
        await shot('scope-changed-${mode.name}');
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await prompt();
        expect(find.text('删除这组 3 条记录？'), findsOneWidget);
        await shot('reconfirmed-${mode.name}');
        StorageProbe(book).execute(
          "CREATE TRIGGER reject_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'controlled'); END",
        );
        await tap(find.text('删除'));
        await waitFor(
          () => find.textContaining('本地存储操作失败').evaluate().isNotEmpty,
        );
        expect(await book.childCount(parent.id), 2);
        expect(await File(book.audioPath(audio)).exists(), isTrue);
        await shot('failed-${mode.name}');
        StorageProbe(book).execute('DROP TRIGGER reject_delete');
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await prompt();
        await tap(find.text('删除'));
        await waitFor(
          () => find.byKey(const Key('home-search')).evaluate().isNotEmpty,
        );
        expect(await book.records, isEmpty);
        expect(await File(book.audioPath(audio)).exists(), isFalse);
        expect((await book.search('尚未确认')).isEmpty, isTrue);
        await shot('deleted-${mode.name}');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'screenshots': screenshotCount,
          'themes': 2,
          'atomicScope': 1,
          'singlePreservesParent': 1,
          'audioCleaned': 1,
          'sqlFailureRollback': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await playback.release();
      await book.close();
      await Directory(p.join(root.path, 'source')).delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
