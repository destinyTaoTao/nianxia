import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import '../test/recording_search_test.dart' show TextTranscriber, writeWave;
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('search origin and actual lazy playback in isolated notebook', (
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
      p.join(identity['cacheRoot'] as String, 'search-origin', runId),
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
      await tester.pumpAndSettle();
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
      screenshotCount++;
    }

    try {
      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        final parent = await book.saveText('先保留想法的条件\n查找时要能回到原话，不自动补造结论。');
        await book.saveText('查找线索文字\n这是一条纯文字的线索。');
        final draft = await book.beginCapture(parentId: parent.id);
        await writeWave(draft.path);
        final bytes = Uint8List(320044)
          ..setRange(0, 44, await File(draft.path).readAsBytes());
        final header = ByteData.sublistView(bytes);
        header.setUint32(4, 320036, Endian.little);
        header.setUint32(40, 320000, Endian.little);
        await File(draft.path).writeAsBytes(bytes, flush: true);
        final audio = await book.finishCapture(draft);
        await book.transcribe(
          audio.id,
          TextTranscriber(Future.value('查找线索追加\n保留这次补充的原音和所属记录。')),
        );
        await book.saveThemeMode(mode.name);
        await tester.pumpWidget(NianxiaApp(key: ValueKey(mode), book: book));
        await waitFor(
          () => find.byKey(const Key('home-search')).evaluate().isNotEmpty,
        );
        tester.testTextInput.register();
        await tap(find.byKey(const Key('home-search')));
        if (mode == ThemeMode.dark) {
          await binding.convertFlutterSurfaceToImage();
          await tester.pump();
        }
        await tester.enterText(find.byKey(const Key('search-input')), '查找线索');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await waitFor(
          () => find.text('所属：${parent.title}').evaluate().isNotEmpty,
        );
        expect(playback.loadedPath, isNot(book.audioPath(audio)));
        await shot('results-${mode.name}');
        await tap(find.byKey(ValueKey('result-play-${audio.id}')));
        await waitFor(
          () => playback.playing && playback.position.inMilliseconds > 50,
        );
        expect(playback.loadedPath, book.audioPath(audio));
        await shot('playing-${mode.name}');
        await tap(find.byKey(ValueKey('result-play-${audio.id}')));
        await waitFor(() => !playback.playing);
        await shot('paused-${mode.name}');
        await tap(find.text('所属：${parent.title}'));
        await waitFor(() => find.text('追加内容').evaluate().isNotEmpty);
        expect((await book.get(parent.id))!.body, parent.body);
        expect(playback.playing, isFalse);
        await shot('parent-${mode.name}');
        await tap(find.byType(BackButton));
        await waitFor(() => find.text('查找线索追加').evaluate().isNotEmpty);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('search-input')))
              .controller!
              .text,
          '查找线索',
        );
        await shot('returned-${mode.name}');
        await tap(find.text('查找线索追加'));
        await waitFor(() => find.text('查看所属记录').evaluate().isNotEmpty);
        await shot('append-${mode.name}');
        await tap(find.byType(BackButton));
        await waitFor(() => find.text('查找线索追加').evaluate().isNotEmpty);
        await File(book.audioPath(audio))
            .rename('${book.audioPath(audio)}.unavailable');
        await tap(find.byKey(ValueKey('result-play-${audio.id}')));
        await waitFor(() => playback.error != null);
        await shot('unavailable-${mode.name}');
        await File('${book.audioPath(audio)}.unavailable')
            .rename(book.audioPath(audio));
        await tap(find.byKey(ValueKey('result-play-${audio.id}')));
        await waitFor(() => playback.error == null && playback.playing);
        await shot('recovered-${mode.name}');
        await book.delete(parent.id);
        await book.delete(
          (await book.records)
              .singleWhere((v) => v.body.startsWith('查找线索文字'))
              .id,
        );
        await waitFor(() => find.text('没有找到相关记录').evaluate().isNotEmpty);
        await shot('deleted-${mode.name}');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await playback.stop();
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'screenshots': screenshotCount,
          'themes': 2,
          'realPlayer': 1,
          'lazySource': 1,
          'sourceRemoved': 1,
          'sourceRefresh': 1,
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
