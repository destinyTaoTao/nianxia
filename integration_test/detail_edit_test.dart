import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import '../test/recording_search_test.dart' show TextTranscriber;
import 'support/isolated_validation.dart';

Future<void> tone(String path) async {
  const samples = 16000 * 8;
  final data = ByteData(44 + samples * 2);
  void tag(int at, String value) {
    data.buffer.asUint8List().setRange(at, at + value.length, value.codeUnits);
  }

  tag(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (600 * math.sin(2 * math.pi * 440 * i / 16000)).round(),
      Endian.little,
    );
  }
  await File(path).writeAsBytes(data.buffer.asUint8List(), flush: true);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real playback, editing conflicts and capture in isolated workspace',
    (tester) async {
      await requireIsolatedValidation();
      const runId = String.fromEnvironment('VALIDATION_RUN_ID');
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(runId)) {
        throw StateError('Invalid isolated run');
      }
      final identity = (await const MethodChannel('app.nianxia/system')
          .invokeMapMethod<String, Object?>('validationIdentity'))!;
      final root = await Directory(
        p.join(identity['cacheRoot'] as String, 'detail-edit', runId),
      ).create(recursive: true);
      final shots = await Directory(p.join(root.path, 'screenshots')).create();
      var now = DateTime(2026, 11, 19, 9, 40);
      final book = await Notebook.open(
        Directory(p.join(root.path, 'source')),
        clock: () => now,
      );
      final diagnostics = LocalDiagnostics(
        Directory(p.join(root.path, 'diagnostics')),
      );
      final playback = PlaybackCoordinator.retain(
        book,
        diagnostics: diagnostics,
      );
      var screenshots = 0, rows = 2;
      Future<void> waitFor(bool Function() condition) async {
        final until = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(until)) {
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
        screenshots++;
      }

      Future<void> tapText(String text) async {
        final target = find.text(text);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
      }

      Future<void> play() async {
        await tester.ensureVisible(find.byTooltip('播放原音频'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放原音频'));
        await waitFor(
          () =>
              playback.playing &&
              !playback.busy &&
              playback.error == null &&
              playback.position.inMilliseconds > 100,
        );
      }

      Future<Record> clip(String value, {String? parent}) async {
        final draft = await book.beginCapture(parentId: parent);
        await tone(draft.path);
        final saved = await book.finishCapture(draft);
        await book.transcribe(saved.id, TextTranscriber(Future.value(value)));
        return (await book.get(saved.id))!;
      }

      const original = '录音里的想法\n先写下原话，整理时再核对条件。';
      const draft = '我的草稿\n保留原话，并核对新的条件。';
      const external = '另一个版本\n保留条件，不自动得出结论。';
      const edited = '核对后的正文\n保留原话，并核对新的条件。';
      final input = find.byKey(const Key('body-editor'));
      try {
        final parent = await clip(original);
        now = DateTime(2026, 11, 19, 10, 15);
        final child = await clip('这次追加的条件\n先离线运行，再验证模型效果。', parent: parent.id);
        final originalHash = sha256
            .convert(await File(book.audioPath(parent)).readAsBytes())
            .toString();
        for (final mode in [ThemeMode.dark, ThemeMode.light]) {
          await book.saveThemeMode(mode.name);
          await tester.pumpWidget(
            NianxiaApp(
              key: ValueKey(mode),
              book: book,
              diagnostics: diagnostics,
            ),
          );
          final latest = (await book.get(parent.id))!;
          await waitFor(() => find.text(latest.title).evaluate().isNotEmpty);
          tester.testTextInput.register();
          await tapText(latest.title);
          if (mode == ThemeMode.dark && Platform.isAndroid) {
            await binding.convertFlutterSurfaceToImage();
            await tester.pump();
          }
          await shot('detail-${mode.name}');
          await play();
          expect(playback.loadedPath, book.audioPath(parent));
          await shot('playing-${mode.name}');
          await tester.tap(find.byTooltip('暂停原音频'));
          await waitFor(() => !playback.playing);
          await tester.tapAt(tester.getCenter(find.byType(Slider)));
          await waitFor(
            () =>
                playback.position.inMilliseconds > 3200 &&
                playback.position.inMilliseconds < 4800,
          );
          final paused = playback.position;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
          expect(
            (playback.position - paused).inMilliseconds.abs(),
            lessThan(150),
          );
          await shot('paused-${mode.name}');
          await tester.tap(find.byTooltip('编辑正文'));
          await tester.pumpAndSettle();
          expect(playback.playing, isFalse);
          await tester.enterText(input, draft);
          await book.edit(
            parent.id,
            external,
            expectedRevision: latest.revision,
          );
          await tester.pumpAndSettle();
          await tapText('保存');
          await waitFor(() => find.text('记录已更新，草稿仍保留。').evaluate().isNotEmpty);
          expect(tester.widget<TextField>(input).controller!.text, draft);
          await shot('conflict-${mode.name}');
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          tester.testTextInput.unregister();
          await tester.showKeyboard(input);
          await waitFor(() => tester.view.viewInsets.bottom > 0);
          await tester.ensureVisible(find.text('复制我的草稿'));
          await tester.pumpAndSettle();
          final keyboardTop =
              (tester.view.physicalSize.height -
                  tester.view.viewInsets.bottom) /
              tester.view.devicePixelRatio;
          expect(
            tester.getBottomRight(find.text('复制我的草稿')).dy,
            lessThanOrEqualTo(keyboardTop),
          );
          await shot('editor-keyboard-${mode.name}');
          await File(p.join(root.path, 'native-checkpoint.json')).writeAsString(
            jsonEncode({
              'applicationId': validationApplicationId,
              'runId': runId,
              'stage': 'editor-keyboard-${mode.name}',
              'keyboardInset': tester.view.viewInsets.bottom,
            }),
            flush: true,
          );
          await Future<void>.delayed(const Duration(seconds: 6));
          FocusManager.instance.primaryFocus?.unfocus();
          await waitFor(() => tester.view.viewInsets.bottom == 0);
          tester.testTextInput.register();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
          await tester.pumpAndSettle();
          await tapText('查看最新内容');
          await shot('latest-${mode.name}');
          await tapText('返回草稿');
          expect(tester.widget<TextField>(input).controller!.text, draft);
          await tapText('载入最新正文');
          await shot('replace-${mode.name}');
          await tapText('替换草稿');
          await waitFor(
            () => tester.widget<TextField>(input).controller!.text == external,
          );
          await tester.enterText(input, edited);
          await tester.pumpAndSettle();
          await tapText('保存');
          await waitFor(() => input.evaluate().isEmpty);
          expect((await book.get(parent.id))!.body, edited);
          expect((await book.get(parent.id))!.transcript, original);
          expect(
            sha256
                .convert(await File(book.audioPath(parent)).readAsBytes())
                .toString(),
            originalHash,
          );
          await tester.ensureVisible(find.text('查看原始转写'));
          await tester.pumpAndSettle();
          await tapText('查看原始转写');
          expect(find.text(original), findsOneWidget);
          await shot('edited-original-${mode.name}');
          await tester.ensureVisible(find.text(child.body));
          await tester.pumpAndSettle();
          await tapText(child.body);
          await play();
          expect(playback.loadedPath, book.audioPath(child));
          await shot('child-playing-${mode.name}');
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(playback.playing, isFalse);
          await play();
          final childFile = File(book.audioPath(child));
          final healthy = await childFile.readAsBytes();
          try {
            await childFile.writeAsString(
              'synthetic damaged audio',
              flush: true,
            );
            await tester.ensureVisible(find.text(child.body));
            await tester.pumpAndSettle();
            await tapText(child.body);
            await tester.tap(find.byTooltip('播放原音频'));
            await waitFor(
              () => find.textContaining('无法回放').evaluate().isNotEmpty,
            );
            await shot('damaged-child-${mode.name}');
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            await play();
            expect(playback.loadedPath, book.audioPath(parent));
            await shot('parent-recovered-${mode.name}');
          } finally {
            await childFile.writeAsBytes(healthy, flush: true);
          }
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(playback.playing, isFalse);
          await tapText('点按录音');
          await waitFor(() => find.text('停止并保存').evaluate().isNotEmpty);
          await Future<void>.delayed(const Duration(milliseconds: 800));
          await tapText('停止并保存');
          await waitFor(() => find.text('停止并保存').evaluate().isEmpty);
          final records = await book.records;
          expect(records.length, ++rows);
          final recorded = records.firstWhere(
            (v) =>
                v.id != parent.id &&
                v.id != child.id &&
                v.transcription == 'pending',
          );
          expect(
            await File(book.audioPath(recorded)).length(),
            greaterThan(44),
          );
          expect(playback.playing, isFalse);
          await shot('microphone-saved-${mode.name}');
          expect(tester.takeException(), isNull);
        }
        binding.reportData = await writeValidationResult(
          passed: true,
          metrics: {
            'themes': 2,
            'sourceRows': rows,
            'screenshots': screenshots,
            'actualPlayback': 1,
            'pauseAndSeek': 1,
            'actualKeyboard': 1,
            'keyboardFontScale': 2,
            'actualMicrophone': 1,
            'casConflict': 1,
            'originalAudioAndTranscriptUnchanged': 1,
            'failedSwitchRecoveredCorrectParent': 1,
            'noAutoplayAfterNavigation': 1,
          },
        );
      } catch (_) {
        binding.reportData = await writeValidationResult(passed: false);
        rethrow;
      } finally {
        tester.testTextInput.unregister();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        await tester.pumpWidget(const SizedBox.shrink());
        await playback.release();
        await diagnostics.close();
        await book.close();
        final source = Directory(p.join(root.path, 'source'));
        if (await source.exists()) await source.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
