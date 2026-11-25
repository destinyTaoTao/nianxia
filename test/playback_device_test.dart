import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';

import 'hold_recording_test.dart' show HoldMicrophone;
import 'recording_search_test.dart' show writeWave;
import 'support/async_storage_tester.dart';
import 'support/just_audio_device.dart';

void main() {
  for (final rebuild in [false, true]) {
    testWidgets(
      rebuild
          ? '关闭失败后重建App也不能遗忘仍可能发声的旧设备'
          : '实际JustAudio吞停用错误时不能凭本地playing标志放行麦克风',
      (tester) async {
        final root = await tester.runAsync(
          () => Directory.systemTemp.createTemp('nx-audio-device-'),
        );
        final book = (await tester.runAsync(() => Notebook.open(root!)))!;
        final device = JustAudioDeviceFixture()..bind();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app.nianxia/system'),
              (call) async =>
                  call.method == 'recordingScreenAvailable' ? true : null,
            );
        CaptureController? capture;
        Future<void> until(bool Function() condition) async {
          for (var i = 0; i < 300 && !condition(); i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(
            condition(),
            isTrue,
            reason:
                'audible=${device.audible}, devices=${device.devices.length}, text=${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join('|')}',
          );
        }

        try {
          await storageRead(tester, () async {
            final draft = await book.beginCapture();
            await writeWave(draft.path);
            final saved = await book.finishCapture(draft);
            await book.edit(saved.id, '原音频', expectedRevision: saved.revision);
          });

          await tester.pumpWidget(NianxiaApp(book: book));
          await pumpStorageAndSettle(tester);
          await tester.tap(find.text('原音频'));
          await pumpStorageAndSettle(tester);
          await tester.tap(find.byTooltip('播放原音频'));
          await until(() => device.audible);
          device.failDispose = device.failPause = device.failMute = true;
          if (rebuild) {
            await tester.pumpWidget(const SizedBox.shrink());
            await pumpStorageAndSettle(tester);
            await tester.pumpWidget(NianxiaApp(book: book));
            await pumpStorageAndSettle(tester);
            expect(device.audible, isTrue);
          }
          final mic = HoldMicrophone();
          capture = CaptureController(book, microphone: mic);
          var started = false;
          capture.start().then<void>((_) => started = true);
          await until(() => started);
          final actualState = capture.state;
          final starts = mic.starts;
          // Release all fixture work before assertions so failure never strands a
          // live capture or blocks teardown on the fake clock.
          device.allowStops();
          var discarded = false;
          capture.discard().then<void>((_) => discarded = true);
          await until(() => discarded);
          expect(actualState, 'failed');
          expect(starts, 0);
          expect(device.pauseRequests + device.muteRequests, greaterThan(0));
          expect((await storageRead(tester, () => book.records)).length, 1);
          capture.dispose();
          // A recovered mute acknowledgement is valid even if decoder release
          // still fails. The old native player must be inaudible before retry.
          device.failDispose = true;
          final retryMic = HoldMicrophone();
          capture = CaptureController(book, microphone: retryMic);
          var retried = false;
          capture.start().then<void>((_) => retried = true);
          await until(() => retried);
          expect(capture.state, 'recording');
          expect(retryMic.starts, 1);
          expect(device.audible, isFalse);
          expect(device.muteRequests, greaterThan(0));
          var cleaned = false;
          capture.discard().then<void>((_) => cleaned = true);
          await until(() => cleaned);
        } finally {
          device.allowStops();
          capture?.dispose();
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpStorageAndSettle(tester);
          var quiet = false;
          Object? cleanupError;
          PlaybackCoordinator.startCapture<void>(book, () async {}).then<void>(
            (_) => quiet = true,
            onError: (Object e, StackTrace trace) {
              cleanupError = e;
              quiet = true;
              debugPrint('$e\n$trace');
            },
          );
          await until(() => quiet);
          expect(cleanupError, isNull);
          await tester.runAsync(() async {
            await book.close();
            await root!.delete(recursive: true);
          });
          device.unbind();
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
