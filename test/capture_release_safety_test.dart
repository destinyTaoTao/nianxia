import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/platform/playback_coordinator.dart';

import 'capture_controller_test.dart' show QueryReadyStore;
import 'support/storage_probe.dart';

class _UncertainMicrophone implements MicrophoneInput {
  final chunks = StreamController<Uint8List>();
  bool stopFails = false, cancelFails = false, closeFails = false;
  bool hardwareActive = false;
  final closeRequested = Completer<void>();
  final stopRequested = Completer<void>();
  Completer<void>? closeGate;
  @override
  Future<bool> allowed() async => true;
  @override
  Future<Stream<Uint8List>> start() async {
    hardwareActive = true;
    return chunks.stream;
  }

  Future<void> _stopped() async {
    hardwareActive = false;
    if (!chunks.isClosed) await chunks.close();
  }

  @override
  Future<void> stop() async {
    if (!stopRequested.isCompleted) stopRequested.complete();
    if (stopFails) throw const FileSystemException('controlled stop fault');
    await _stopped();
  }

  @override
  Future<void> cancel() async {
    if (cancelFails) throw const FileSystemException('controlled cancel fault');
    await _stopped();
  }

  @override
  Future<void> close() async {
    if (!closeRequested.isCompleted) closeRequested.complete();
    await closeGate?.future;
    if (closeFails) throw const FileSystemException('controlled close fault');
    await _stopped();
  }

  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Stream<void> get interruptions => const Stream.empty();
}

class _ObserverCancelFault extends _UncertainMicrophone {
  final levelEvents = StreamController<double>(
    onCancel: () async {
      throw const FileSystemException(
        'controlled level observer cleanup fault',
      );
    },
  );
  final stateEvents = StreamController<void>(
    onCancel: () async {
      throw const FileSystemException(
        'controlled state observer cleanup fault',
      );
    },
  );
  @override
  Stream<double> get levels => levelEvents.stream;
  @override
  Stream<void> get interruptions => stateEvents.stream;
  @override
  Future<void> close() async {
    await super.close();
    if (!levelEvents.isClosed) await levelEvents.close();
    if (!stateEvents.isClosed) await stateEvents.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Notebook book;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (_) async => true,
        );
    root = await Directory.systemTemp.createTemp('nx-device-release-');
    book = await Notebook.open(Directory('${root.path}/book'));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
    await book.close();
    await root.delete(recursive: true);
  });
  test('停止取消关闭均失败，仍占用设备且重试不能假报保存成功', () async {
    final mic = _UncertainMicrophone()
      ..stopFails = true
      ..cancelFails = true
      ..closeFails = true;
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      mic.chunks.add(Uint8List(3200));
      await capture.finish();
      expect(capture.state, 'failed');
      expect(mic.hardwareActive, isTrue);
      expect(book.captureActive, isTrue);
      await capture.retry();
      expect(capture.state, 'failed');
      expect(capture.saved, isNull);
      expect(await book.records, isEmpty);
    } finally {
      mic.stopFails = false;
      mic.cancelFails = false;
      mic.closeFails = false;
      capture.dispose();
      await PlaybackCoordinator.startCapture(book, () async {});
      await mic.close();
    }
  });
  test('dispose等待真实关闭，其他入口及资料库不能绕过未确认设备', () async {
    final mic = _UncertainMicrophone()
      ..stopFails = true
      ..cancelFails = true
      ..closeGate = Completer<void>();
    final capture = CaptureController(book, microphone: mic);
    final other = await Notebook.open(Directory('${root.path}/other'));
    final otherPlayback = PlaybackCoordinator.retain(other);
    Future<void>? starting;
    try {
      await capture.start();
      capture.dispose();
      await mic.closeRequested.future;
      expect(mic.hardwareActive, isTrue);
      expect(
        mic.chunks.hasListener,
        isFalse,
        reason: 'A disposed page must stop consuming PCM even before device release is acknowledged.',
      );
      expect(book.captureActive, isTrue);
      expect(otherPlayback.blocked, isTrue);
      var physicalStarts = 0;
      starting = PlaybackCoordinator.startCapture(other, () async {
        physicalStarts++;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(physicalStarts, 0);
      mic.closeGate!.complete();
      await starting;
      expect(physicalStarts, 1);
      expect(mic.hardwareActive, isFalse);
      expect(book.captureActive, isFalse);
      expect(otherPlayback.blocked, isFalse);
    } finally {
      if (!mic.closeGate!.isCompleted) mic.closeGate!.complete();
      capture.dispose();
      await starting;
      await PlaybackCoordinator.startCapture(book, () async {});
      await mic.close();
      await otherPlayback.release();
      await other.close();
    }
  });
  test('重试确认停录后保存仍失败，也释放设备占用并保留可重试音频', () async {
    final mic = _UncertainMicrophone()
      ..stopFails = true
      ..cancelFails = true
      ..closeFails = true;
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      mic.chunks.add(Uint8List(3200));
      await capture.finish();
      expect(book.captureActive, isTrue);
      mic.stopFails = false;
      mic.cancelFails = false;
      mic.closeFails = false;
      StorageProbe(book).execute(
        "CREATE TRIGGER reject_save BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'controlled save failure'); END",
      );
      await capture.retry();
      expect(capture.state, 'failed');
      expect(mic.hardwareActive, isFalse);
      expect(book.captureActive, isFalse);
      expect(await book.records, isEmpty);
      StorageProbe(book).execute('DROP TRIGGER reject_save');
      await capture.retry();
      expect(capture.state, 'done');
      expect((await book.records).single.id, capture.draft!.id);
    } finally {
      mic.stopFails = false;
      mic.cancelFails = false;
      mic.closeFails = false;
      capture.dispose();
      await PlaybackCoordinator.startCapture(book, () async {});
      await mic.close();
    }
  });

  test('取消PCM订阅需要设备停止时，dispose仍先发出停止请求', () async {
    final mic = _UncertainMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      mic.chunks.onCancel = () => mic.stopRequested.future;
      capture.dispose();
      await expectLater(
        mic.stopRequested.future.timeout(const Duration(seconds: 1)),
        completes,
      );
    } finally {
      if (!mic.stopRequested.isCompleted) mic.stopRequested.complete();
      capture.dispose();
      await PlaybackCoordinator.startCapture(book, () async {});
      await mic.close();
    }
  });

  test('辅助观察流取消失败也不逃逸或阻止物理录音释放', () async {
    final mic = _ObserverCancelFault();
    final capture = CaptureController(book, microphone: mic);
    final unhandled = <Object>[];
    try {
      await runZonedGuarded(() async {
        await capture.start();
        capture.dispose();
        for (var i = 0; i < 100 && book.captureActive; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }, (error, stack) => unhandled.add(error));
      expect(book.captureActive, isFalse);
      expect(mic.hardwareActive, isFalse);
      expect(mic.chunks.hasListener, isFalse);
      expect(unhandled, isEmpty);
    } finally {
      capture.dispose();
      await mic.close();
    }
  });

  test('已经接受保存后立即卸载，仍等候积压PCM真正关闭再校验WAV', () async {
    final mic = _UncertainMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      for (var i = 0; i < 2000; i++) {
        mic.chunks.add(Uint8List(320));
      }
      await Future<void>.delayed(Duration.zero);
      final finishing = capture.finish();
      capture.dispose();
      await finishing;
      expect(capture.state, 'done');
      expect(capture.saved, isNotNull);
      expect(await File(book.audioPath(capture.saved!)).length(), 640044);
    } finally {
      capture.dispose();
      await mic.close();
      await PlaybackCoordinator.startCapture(book, () async {});
    }
  });

  test('查询删除和设备停止同时失败时仍明确显示麦克风尚未停止', () async {
    final models = LocalModels(
      QueryReadyStore(Directory('${root.path}/models')),
    );
    final mic = _UncertainMicrophone()
      ..stopFails = true
      ..cancelFails = true
      ..closeFails = true;
    final capture = CaptureController(
      book,
      microphone: mic,
      query: true,
      models: models,
    );
    Directory? queries;
    try {
      await capture.start();
      mic.chunks.add(Uint8List(3200));
      queries = File(capture.draft!.path).parent;
      expect((await Process.run('chmod', ['0555', queries.path])).exitCode, 0);
      await capture.finish();
      expect(book.captureActive, isTrue);
      expect(capture.error, contains('麦克风尚未确认停止'));
      expect(capture.error, contains('清理'));
      expect(await File(capture.draft!.path).exists(), isTrue);
    } finally {
      if (queries != null) await Process.run('chmod', ['0755', queries.path]);
      mic.stopFails = mic.cancelFails = mic.closeFails = false;
      capture.dispose();
      await PlaybackCoordinator.startCapture(book, () async {});
      await mic.close();
      await models.close();
    }
  }, skip: Platform.isWindows);

  test(
    '仅查询文件清理失败不漏全局占用，明确失败且可在恢复权限后丢弃',
    () async {
      final models = LocalModels(
        QueryReadyStore(Directory('${root.path}/models')),
      );
      final mic = _UncertainMicrophone()..stopFails = true;
      final capture = CaptureController(
        book,
        microphone: mic,
        query: true,
        models: models,
      );
      Directory? queries;
      try {
        await capture.start();
        mic.chunks.add(Uint8List(3200));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        queries = File(capture.draft!.path).parent;
        final mode = await Process.run('chmod', ['0555', queries.path]);
        expect(mode.exitCode, 0);
        await expectLater(capture.finish(), completes);
        expect(mic.hardwareActive, isFalse);
        expect(book.captureActive, isFalse);
        expect(capture.state, 'failed');
        expect(capture.queryText, isNull);
        expect(capture.error, contains('清理未完成'));
        expect(await book.records, isEmpty);
        expect(await File(capture.draft!.path).exists(), isTrue);
        await Process.run('chmod', ['0755', queries.path]);
        await capture.discard();
        expect(await File(capture.draft!.path).exists(), isFalse);
      } finally {
        if (queries != null) await Process.run('chmod', ['0755', queries.path]);
        mic.stopFails = false;
        capture.dispose();
        await PlaybackCoordinator.startCapture(book, () async {});
        await mic.close();
        models.dispose();
      }
    },
    skip: Platform.isWindows
        ? 'Host permission fault uses POSIX directory modes.'
        : false,
  );
}
