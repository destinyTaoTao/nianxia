import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import '../test/recording_search_test.dart' show TextTranscriber;
import '../test/support/ui_native_capture.dart' show UiCaptureRuntime;
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual ordinary and native voice append, playback and origin', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Invalid isolated run');
    }
    if (!Platform.isAndroid) {
      throw StateError(
        'This actual native capture validation requires Android.',
      );
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final cache = identity['cacheRoot'] as String;
    final root = await Directory(p.join(cache, 'voice-append', runId))
        .create(recursive: true);
    final shots = await Directory(p.join(root.path, 'screenshots')).create();
    final workspace = Directory(p.join(cache, 'validation-ui', runId));
    const channel = MethodChannel('app.nianxia/capture');
    var configured = false, screenshotCount = 0, savedCount = 0;
    Notebook? opened;
    CaptureSessionController? capture;
    PlaybackCoordinator? playback;
    final runtime = UiCaptureRuntime();
    String? ownedId;
    Future<void> waitFor(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 25));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 25));
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
      await channel.invokeMethod<void>('setValidationWorkspace', {
        'runId': runId,
      });
      configured = true;
      var minute = 0;
      final book = await Notebook.open(
        Directory(p.join(workspace.path, 'nianxia')),
        clock: () => DateTime.utc(2026, 11, 20, 9, minute++),
      );
      opened = book;
      playback = PlaybackCoordinator.retain(book);
      final player = playback;
      for (final native in [false, true]) {
        if (native) {
          capture = CaptureSessionController(
            NativeCaptureBridge(),
            book,
            runtime,
          );
        }
        for (final mode in [ThemeMode.dark, ThemeMode.light]) {
          final suffix = '${native ? 'native' : 'ordinary'}-${mode.name}';
          final parent = await book.saveText('保留想法的条件\n先记下原话，再核对下一步。');
          for (var i = 0; i < 45; i++) {
            await book.saveText('先前的补充$i', parentId: parent.id);
          }
          await book.saveThemeMode(mode.name);
          await tester.pumpWidget(
            NianxiaApp(
              key: ValueKey(suffix),
              book: book,
              captureSession: native ? capture : null,
            ),
          );
          await waitFor(() => find.text(parent.title).evaluate().isNotEmpty);
          await tap(find.text(parent.title).first);
          if (!native && mode == ThemeMode.dark) {
            await binding.convertFlutterSurfaceToImage();
            await tester.pump();
          }
          await tap(find.text('追加内容'));
          await tap(find.text('追加语音'));
          expect(book.captureActive, isFalse);
          expect(find.text('按住追加'), findsOneWidget);
          expect(find.text('追加到：${parent.title}'), findsOneWidget);
          await shot('ready-$suffix');
          final hold = find.byKey(const Key('hold-record'));
          final rect = tester.getRect(hold);
          final gesture = await tester.startGesture(rect.center);
          await waitFor(() => find.text('松手保存追加，上滑取消').evaluate().isNotEmpty);
          if (native) ownedId = capture!.snapshot!.sessionId;
          expect(tester.getRect(hold), rect);
          await Future<void>.delayed(const Duration(milliseconds: 1000));
          await shot('recording-$suffix');
          await gesture.up();
          await waitFor(
            () =>
                find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
          );
          await waitFor(
            () => find.text('语音记录，等待转写').hitTestable().evaluate().isNotEmpty,
          );
          final audio = (await book.children(parent.id))
              .singleWhere((v) => v.audio != null);
          expect(audio.parentId, parent.id);
          expect(audio.durationMs, greaterThan(100));
          expect(await File(book.audioPath(audio)).length(), greaterThan(44));
          expect(await book.childCount(parent.id), 46);
          if (native) expect(audio.id, ownedId);
          savedCount++;
          await shot('focused-$suffix');
          // Controlled text only proves the asynchronous source relationship.
          // Microphone, WAV, storage and playback above/below remain actual.
          const transcript = '追加的语音条件\n条件还需要核对，不能自动得出结论。';
          expect(
            await book.transcribe(
              audio.id,
              TextTranscriber(Future.value(transcript)),
            ),
            isTrue,
          );
          await waitFor(() => find.text(transcript).evaluate().isNotEmpty);
          await tap(find.text(transcript));
          await tap(find.byTooltip('播放原音频'));
          await waitFor(
            () =>
                player.playing &&
                player.error == null &&
                player.position.inMilliseconds > 50,
          );
          expect(player.loadedPath, book.audioPath(audio));
          await shot('playing-$suffix');
          await tap(find.text('查看所属记录'));
          await waitFor(() => find.text(parent.title).evaluate().isNotEmpty);
          expect(player.playing, isFalse);
          expect((await book.get(parent.id))!.body, parent.body);
          expect(await book.childCount(parent.id), 46);
          await shot('origin-$suffix');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'themes': 2,
          'capturePaths': 2,
          'actualSavedAudio': savedCount,
          'screenshots': screenshotCount,
          'actualOrdinaryMicrophone': 1,
          'actualNativeMicrophone': 1,
          'actualPlayback': 1,
          'appendsBeforeEachSave': 45,
          'savedIdentityLocated': 1,
          'originNavigation': 1,
          'originalBodyUnchanged': 1,
          'transcriptionControlled': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      if (capture != null && ownedId != null && capture.savedId != ownedId) {
        try {
          await capture.discard(sessionId: ownedId);
        } catch (_) {
          /* Keep failed native evidence if cancellation cannot be confirmed. */
        }
      }
      capture?.dispose();
      runtime.dispose();
      await playback?.release();
      await opened?.close();
      if (configured) {
        await channel.invokeMethod<void>('endValidationWorkspace', {
          'runId': runId,
        });
      }
      if (configured && await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
