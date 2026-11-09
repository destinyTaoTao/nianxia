import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/local_models.dart';

class TestMicrophone implements MicrophoneInput {
  final chunks = StreamController<Uint8List>();
  bool failStop = false;
  @override
  Future<bool> allowed() async => true;
  @override
  Future<Stream<Uint8List>> start() async => chunks.stream;
  @override
  Future<void> stop() async {
    if (failStop) {
      throw const FileSystemException('stop failure');
    }
    await chunks.close();
  }

  @override
  Future<void> cancel() async {
    if (!chunks.isClosed) {
      await chunks.close();
    }
  }

  @override
  Future<void> close() async {
    if (!chunks.isClosed) {
      await chunks.close();
    }
  }

  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Stream<void> get interruptions => const Stream.empty();
}

class QueryReadyStore extends ModelStore {
  QueryReadyStore(Directory home) : super(home, []);
  @override
  Future<bool> ready(String id) async => true;
}

class PendingPermissionMicrophone extends TestMicrophone {
  final permission = Completer<bool>();
  final permissionRequested = Completer<void>();
  bool started = false;
  @override
  Future<bool> allowed() {
    permissionRequested.complete();
    return permission.future;
  }

  @override
  Future<Stream<Uint8List>> start() {
    started = true;
    return super.start();
  }

  @override
  Future<void> stop() async {
    if (!chunks.hasListener) chunks.stream.listen((_) {});
    await super.stop();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  bool? screenAvailable = true;
  setUp(() async {
    screenAvailable = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async => call.method == 'recordingScreenAvailable'
              ? screenAvailable
              : null,
        );
    home = await Directory.systemTemp.createTemp('nianxia-microphone-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
    book.dispose();
    await home.delete(recursive: true);
  });
  test('Android 快速息屏仅触发 inactive 也停止保存，唤醒不自动续录', () async {
    final mic = TestMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      mic.chunks.add(Uint8List(32000));
      final done = Completer<void>();
      capture.addListener(() {
        if (capture.state == 'done' && !done.isCompleted) done.complete();
      });
      screenAvailable = false;
      capture.didChangeAppLifecycleState(AppLifecycleState.inactive);
      CaptureController.screenTurnedOff();
      await done.future.timeout(const Duration(seconds: 2));
      screenAvailable = true;
      capture.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(capture.state, 'done');
      expect(book.records.single.durationMs, 1000);
    } finally {
      capture.dispose();
    }
  });
  test('Android 启动前锁屏或屏幕状态无法核验，不启动麦克风', () async {
    for (final available in [false, null]) {
      screenAvailable = available;
      final mic = PendingPermissionMicrophone()..permission.complete(true);
      final capture = CaptureController(book, microphone: mic);
      try {
        await capture.start();
        expect(mic.started, isFalse);
        expect(capture.state, 'failed');
        expect(book.records, isEmpty);
        expect(book.recoveryDrafts, isEmpty);
      } finally {
        capture.dispose();
      }
    }
  });
  test('等待权限时收到系统息屏通知，授权返回也不会开始采集', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      final starting = capture.start();
      await mic.permissionRequested.future;
      CaptureController.screenTurnedOff();
      mic.permission.complete(true);
      await starting;
      expect(mic.started, isFalse);
      expect(capture.state, 'failed');
      expect(book.records, isEmpty);
      expect(book.recoveryDrafts, isEmpty);
    } finally {
      capture.dispose();
    }
  });
  test('屏幕状态异常或超时不启动采集，迟到响应也不重新启动', () async {
    for (final timeout in [false, true]) {
      final response = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('app.nianxia/system'), (
            call,
          ) async {
            if (!timeout) throw PlatformException(code: 'screen_unavailable');
            return response.future;
          });
      final mic = PendingPermissionMicrophone()..permission.complete(true);
      final capture = CaptureController(book, microphone: mic);
      try {
        await capture.start().timeout(const Duration(seconds: 2));
        expect(capture.state, 'failed');
        expect(capture.error, contains('无法核验屏幕状态'));
        expect(mic.started, isFalse);
        response.complete(true);
        await Future<void>.delayed(Duration.zero);
        expect(mic.started, isFalse);
        expect(book.records, isEmpty);
      } finally {
        if (!response.isCompleted) response.complete(true);
        capture.dispose();
      }
    }
  });
  test('等待权限时退到后台，不会在授权返回后偷偷开始采集', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      final starting = capture.start();
      capture.didChangeAppLifecycleState(AppLifecycleState.paused);
      mic.permission.complete(true);
      await starting;
      expect(mic.started, isFalse);
      expect(capture.state, 'failed');
      expect(book.captureActive, isFalse);
      expect(book.records, isEmpty);
    } finally {
      capture.dispose();
    }
  });
  test('短暂 inactive 不截断当前录音，真正进入后台才停止保存', () async {
    final mic = TestMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      mic.chunks.add(Uint8List(32000));
      capture.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(capture.state, 'recording');
      final done = Completer<void>();
      capture.addListener(() {
        if (capture.state == 'done' && !done.isCompleted) done.complete();
      });
      capture.didChangeAppLifecycleState(AppLifecycleState.paused);
      await done.future.timeout(const Duration(seconds: 5));
      expect(book.records.single.durationMs, 1000);
    } finally {
      capture.dispose();
    }
  });
  test('两分钟采样边界自动保存，原生停止延迟不会使整段丢失', () async {
    final mic = TestMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      final done = Completer<void>();
      capture.addListener(() {
        if (capture.state == 'done' && !done.isCompleted) {
          done.complete();
        }
      });
      mic.chunks.add(
        Uint8List(3846400),
      ); // A final device buffer crosses the declared limit.
      await done.future.timeout(const Duration(seconds: 5));
      expect(capture.error, isNull);
      expect(book.records.single.durationMs, 120000);
      expect(await File(book.audioPath(book.records.single)).length(), 3840044);
    } finally {
      capture.dispose();
    }
  });
  test('查询原生停止失败也立即清理临时音频，不保存查询记录', () async {
    final mic = TestMicrophone()..failStop = true;
    final store = QueryReadyStore(home);
    final capture = CaptureController(
      book,
      microphone: mic,
      models: LocalModels(store),
      query: true,
    );
    try {
      await capture.start();
      mic.chunks.add(Uint8List(32000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await capture.finish();
      expect(capture.state, 'failed');
      expect(book.records, isEmpty);
      expect(await File(capture.draft!.path).exists(), isFalse);
    } finally {
      capture.dispose();
      store.dispose();
    }
  });
}
