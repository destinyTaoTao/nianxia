import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/recorder.dart';

import 'capture_controller_test.dart' show QueryReadyStore;
import 'hold_recording_test.dart' show HoldMicrophone;
import 'support/async_storage_tester.dart';

class _PendingStopMicrophone extends HoldMicrophone {
  final stopping = Completer<void>(), acknowledged = Completer<void>();
  @override
  Future<void> stop() async {
    if (!stopping.isCompleted) stopping.complete();
    await acknowledged.future;
    if (starts == 0 && !chunks.isClosed) chunks.stream.listen((_) {});
    if (!chunks.isClosed) await chunks.close();
  }
}

class _FailingReleaseMicrophone extends HoldMicrophone {
  bool failing = true;
  int closes = 0;
  @override
  Future<void> stop() async {
    if (failing) {
      throw const FileSystemException('controlled device stop failure');
    }
    if (!chunks.isClosed) await chunks.close();
  }

  @override
  Future<void> cancel() => stop();
  @override
  Future<void> close() async {
    closes++;
    await stop();
  }
}

void main() {
  for (final hold in [true, false]) {
    testWidgets('同资料库${hold ? '按住' : '点按'}入口可重试已卸载所有者的真实设备释放', (tester) async {
      final (root, book) = await storageRead(tester, () async {
        final root = await Directory.systemTemp.createTemp(
          'nx-same-book-release-',
        );
        return (root, await Notebook.open(root));
      });
      final oldMic = _FailingReleaseMicrophone();
      final mic = _PendingStopMicrophone()..acknowledged.complete();
      final old = CaptureController(book, microphone: oldMic);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('app.nianxia/system'),
        (_) async => true,
      );
      TestGesture? gesture;
      try {
        final starting = old.start();
        for (var i = 0; i < 100 && old.state == 'starting'; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(old.state, 'recording');
        await starting;
        old.dispose();
        for (var i = 0; i < 100 && oldMic.closes < 2; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(book.captureActive, isTrue);
        expect(oldMic.closes, greaterThanOrEqualTo(2));
        oldMic.failing = false;
        await tester.pumpWidget(NianxiaApp(book: book, captureMicrophone: mic));
        await pumpStorageAndSettle(tester);
        if (hold) {
          gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const Key('hold-record'))),
          );
        } else {
          await tester.tap(find.text('点按录音'));
        }
        for (var i = 0; i < 50 && !mic.chunks.hasListener; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(mic.starts, 1);
        expect(mic.chunks.hasListener, isTrue);
        mic.feed();
        await pumpStorageAndSettle(tester);
      } finally {
        oldMic.failing = false;
        await gesture?.up();
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStorageAndSettle(tester);
        var released = false;
        Object? releaseError;
        final releasing = PlaybackCoordinator.startCapture(book, () async {})
            .then<void>(
              (_) => released = true,
              onError: (Object error) {
                releaseError = error;
                released = true;
              },
            );
        for (var i = 0; i < 100 && !released; i++) {
          await pumpStorageAndSettle(tester);
        }
        expect(released, isTrue);
        expect(releaseError, isNull);
        await releasing;
        var inputsClosed = false;
        final closingInputs = Future.wait([oldMic.close(), mic.close()])
            .then<void>((_) => inputsClosed = true);
        for (var i = 0; i < 100 && !inputsClosed; i++) {
          await pumpStorageAndSettle(tester);
        }
        expect(inputsClosed, isTrue);
        await closingInputs;
        for (var i = 0; i < 100 && book.captureActive; i++) {
          await pumpStorageAndSettle(tester);
        }
        expect(book.captureActive, isFalse);
        await tester.runAsync(() async {
          await book.close();
          await root.delete(recursive: true);
        });
        messenger.setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
      }
    });
  }
  for (final query in [false, true]) {
    testWidgets('${query ? '点按查询' : '首页按住'}实际页面移除，停止回执未到也不继续消费PCM', (
      tester,
    ) async {
      final (root, book, models) = await storageRead(tester, () async {
        final root = await Directory.systemTemp.createTemp('nx-page-release-');
        final book = await Notebook.open(root);
        final models = LocalModels(
          QueryReadyStore(Directory('${root.path}/models')),
        );
        return (root, book, models);
      });
      final mic = _PendingStopMicrophone();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('app.nianxia/system'),
        (_) async => true,
      );
      TestGesture? gesture;
      try {
        if (query) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => FilledButton(
                    onPressed: () => openRecorder(
                      context,
                      book,
                      models,
                      query: true,
                      microphone: mic,
                    ),
                    child: const Text('打开查询'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('打开查询'));
        } else {
          await tester.pumpWidget(
            NianxiaApp(book: book, captureMicrophone: mic),
          );
          await pumpStorageAndSettle(tester);
          gesture = await tester.startGesture(
            tester.getCenter(find.byKey(const Key('hold-record'))),
          );
        }
        for (var i = 0; i < 50 && !mic.chunks.hasListener; i++) {
          await pumpStorageAndSettle(tester);
        }
        expect(mic.chunks.hasListener, isTrue);
        mic.feed();
        await pumpStorageAndSettle(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStorageAndSettle(tester);
        expect(mic.stopping.isCompleted, isTrue);
        expect(mic.acknowledged.isCompleted, isFalse);
        expect(mic.chunks.hasListener, isFalse);
        expect(book.captureActive, isTrue);
      } finally {
        if (!mic.acknowledged.isCompleted) mic.acknowledged.complete();
        await gesture?.up();
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStorageAndSettle(tester);
        for (var i = 0; i < 100 && book.captureActive; i++) {
          await pumpStorageAndSettle(tester);
        }
        expect(book.captureActive, isFalse);
        await tester.runAsync(() async {
          await mic.close();
          await models.close();
          await book.close();
          await root.delete(recursive: true);
        });
        messenger.setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
      }
    });
  }
}
