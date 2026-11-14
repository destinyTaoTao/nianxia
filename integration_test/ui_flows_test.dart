import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import 'support/isolated_validation.dart';

// This case validates the real microphone/control/source boundary. It deliberately
// has no speech model: no captured room audio is transcribed or exported.
class _UnavailableRuntime extends ChangeNotifier implements InferenceRuntime {
  @override
  String get searchModelVersion => 'unavailable';
  @override
  String get speechModelVersion => 'unavailable';
  @override
  void setCaptureActive(bool active) {}
  @override
  Future<bool> ready(InferenceCapability capability) async => false;
  @override
  Future<List<double>> embed(String text, {required bool query}) =>
      throw StateError('No inference in this validation');
  @override
  Future<String> transcribe(String path, {bool foreground = true}) =>
      throw StateError('No inference in this validation');
  @override
  Future<void> close() async => dispose();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native recording UI keeps one owner and commits before saved', (
    tester,
  ) async {
    await requireIsolatedValidation();
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    const channel = MethodChannel('app.nianxia/capture');
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'validation-ui', runId),
    );
    Notebook? book;
    CaptureSessionController? capture;
    final runtime = _UnavailableRuntime();
    var configured = false;
    String? ownedId;
    try {
      await expectLater(
        channel.invokeMethod<void>('setValidationWorkspace', {
          'runId': '../bad',
        }),
        throwsA(isA<PlatformException>()),
      );
      await channel.invokeMethod<void>('setValidationWorkspace', {
        'runId': runId,
      });
      configured = true;
      book = await Notebook.open(Directory(p.join(root.path, 'nianxia')));
      await book.saveText('离线记录的想法\n先可靠保存，再慢慢整理。');
      await book.saveText('周末散步\n带上相机，看看街边的树。');
      capture = CaptureSessionController(NativeCaptureBridge(), book, runtime);
      await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
      await tester.pumpAndSettle();
      Future<void> waitFor(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(condition(), isTrue);
      }

      Future<void> screenshot(String name) async {
        if (const bool.fromEnvironment('dart.vm.product')) return;
        final directory = await Directory(p.join(root.path, 'screenshots'))
            .create(recursive: true);
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 120));
        final bytes = await binding.takeScreenshot(name);
        await File(p.join(directory.path, '$name.png'))
            .writeAsBytes(bytes, flush: true);
      }

      if (Platform.isAndroid &&
          !const bool.fromEnvironment('dart.vm.product')) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
      }
      await screenshot('home-dark');
      await tester.tap(find.text('记一下'));
      await waitFor(
        () => capture!.snapshot?.phase == NativeCapturePhase.recording,
      );
      ownedId = capture.snapshot!.sessionId;
      await waitFor(() => find.text('收起').evaluate().isNotEmpty);
      await expectLater(
        channel.invokeMethod<void>('endValidationWorkspace', {'runId': runId}),
        throwsA(isA<PlatformException>()),
      );
      await tester.pump(const Duration(milliseconds: 1200));
      await screenshot('recorder-dark');
      expect(
        (await book.records).length,
        2,
        reason: 'No source row before save',
      );
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('capture-return')), findsOneWidget);
      expect((await capture.port.current())!.sessionId, ownedId);
      await screenshot('collapsed-dark');
      await tester.tap(find.byKey(const Key('capture-return')));
      await tester.pumpAndSettle();
      expect(capture.snapshot!.sessionId, ownedId);
      await tester.tap(find.text('停止并保存'));
      await waitFor(
        () => capture!.savedId == ownedId && find.text('收起').evaluate().isEmpty,
      );
      final saved = (await book.get(ownedId))!;
      expect(saved.audio, isNotNull);
      final audio = File(book.audioPath(saved));
      expect(await audio.length(), greaterThan(44));
      await tester.tap(find.text('找一下'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('search-input')), '散步');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('search-input')))
            .controller!
            .text,
        '散步',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 500));
      await screenshot('search-loading');
      await waitFor(() => find.text('周末散步').evaluate().isNotEmpty);
      await screenshot('search-dark');
      expect(find.text('找到 1 条记录'), findsOneWidget);
      // Exercise the actual theme and large-text layout on the running engine.
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('切换浅色主题'));
      await waitFor(
        () =>
            Theme.of(tester.element(find.text('记一下'))).brightness ==
            Brightness.light,
      );
      await screenshot('home-light');
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      await screenshot('home-large-text');
      await tester.tap(find.text('记一下'));
      await waitFor(
        () =>
            capture!.snapshot?.phase == NativeCapturePhase.recording &&
            find.text('收起').evaluate().isNotEmpty,
      );
      ownedId = capture.snapshot!.sessionId;
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.ensureVisible(find.text('停止并保存'));
      await screenshot('recorder-large-text');
      final stop = find.widgetWithText(FilledButton, '停止并保存');
      expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
      await tester.tap(stop);
      await waitFor(
        () => capture!.savedId == ownedId && find.text('收起').evaluate().isEmpty,
      );
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pumpAndSettle();
      // A new field after unregistering uses the real Android IME connection.
      tester.testTextInput.unregister();
      await tester.tap(find.text('找一下'));
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byKey(const Key('search-input')));
      await waitFor(() => tester.view.viewInsets.bottom > 0);
      final keyboardTop =
          (tester.view.physicalSize.height - tester.view.viewInsets.bottom) /
          tester.view.devicePixelRatio;
      expect(
        tester.getBottomRight(find.byKey(const Key('search-input'))).dy,
        lessThan(keyboardTop),
      );
      await screenshot('search-keyboard');
      FocusScope.of(tester.element(find.byKey(const Key('search-input'))))
          .unfocus();
      await waitFor(() => tester.view.viewInsets.bottom == 0);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sourceRows': (await book.records).length,
          'recordedBytes': await audio.length(),
          'singleSessionAfterCollapse': 1,
          'sourceCommittedBeforeSaved': 1,
          'summarySearchResults': 1,
          'capturedAudioTranscribed': 0,
          'largeTextScale': 2,
          'largeTextStopMinHeight': 48,
          'actualKeyboardInsetsObserved': 1,
          'lightAndDarkScreens': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox());
      if (capture != null && ownedId != null && capture.savedId != ownedId) {
        try {
          await capture.discard(sessionId: ownedId);
        } catch (_) {
          // An interrupted claimed fixture remains recoverable; never mask the
          // assertion that failed or broaden cleanup to another session.
        }
      }
      capture?.dispose();
      await runtime.close();
      await book?.close();
      if (configured) {
        await channel.invokeMethod<void>('endValidationWorkspace', {
          'runId': runId,
        });
      }
      final source = Directory(p.join(root.path, 'nianxia'));
      if (await source.exists()) await source.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
