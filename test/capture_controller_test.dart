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

class StateErrorMicrophone extends TestMicrophone {
  final states = StreamController<void>.broadcast();
  @override
  Stream<void> get interruptions => states.stream;
  @override
  Future<void> close() async {
    await super.close();
    if (!states.isClosed) await states.close();
  }
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

class PendingStartMicrophone extends TestMicrophone {
  final requested = Completer<void>();
  final response = Completer<Stream<Uint8List>>();
  bool released = false;
  @override
  Future<Stream<Uint8List>> start() {
    requested.complete();
    return response.future;
  }

  @override
  Future<void> stop() async {
    released = true;
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
    await book.close();
    await home.delete(recursive: true);
  });
  test('设备状态流错误由录音收口，停止并保存有效PCM而不产生未捕获异常', () async {
    final mic = StateErrorMicrophone();
    final unexpected = <Object>[];
    late CaptureController capture;
    String? stateAfterError;
    try {
      await runZonedGuarded<Future<void>>(() async {
        capture = CaptureController(book, microphone: mic);
        await capture.start();
        mic.chunks.add(Uint8List(3200));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        mic.states.addError(StateError('controlled device state error'));
        for (var i = 0; i < 100 && capture.state != 'done'; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        stateAfterError = capture.state;
        await capture.finish();
      }, (error, _) => unexpected.add(error));
      expect(unexpected, isEmpty);
      expect(stateAfterError, 'done');
      final saved = (await book.records).single;
      expect(await File(book.audioPath(saved)).length(), greaterThan(44));
      expect(book.captureActive, isFalse);
    } finally {
      capture.dispose();
      await mic.close();
    }
  });

  test('准备期结束会废止迟到授权，不再启动采集', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final starting = capture.start();
    await mic.permissionRequested.future;
    final ending = capture.finish();
    mic.permission.complete(true);
    await starting;
    await ending;
    expect(mic.started, isFalse);
    expect(capture.active, isFalse);
    expect(await book.records, isEmpty);
    capture.dispose();
  });
  test('重复启动共享准备过程，不再次请求授权', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final first = capture.start();
    await mic.permissionRequested.future;
    final second = capture.start();
    mic.permission.complete(true);
    await Future.wait([first, second]);
    expect(capture.state, 'recording');
    await capture.discard();
    capture.dispose();
  });
  test('取消准备完成后，迟到授权不能改变取消状态', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final starting = capture.start();
    await mic.permissionRequested.future;
    final cancelling = capture.discard();
    mic.permission.complete(true);
    await Future.wait([starting, cancelling]);
    expect(capture.state, 'cancelled');
    expect(mic.started, isFalse);
    expect(book.captureActive, isFalse);
    expect(await book.records, isEmpty);
    capture.dispose();
  });
  test('保存成功后的重试和丢弃不改变已提交记录', () async {
    final mic = TestMicrophone();
    final capture = CaptureController(book, microphone: mic);
    await capture.start();
    mic.chunks.add(Uint8List(32000));
    await capture.finish();
    final id = capture.saved!.id;
    await capture.retry();
    await capture.discard();
    expect(capture.state, 'done');
    expect(capture.saved!.id, id);
    expect((await book.records).single.id, id);
    capture.dispose();
  });
  test('设备启动尚未返回就结束，释放设备且清理未录入片段', () async {
    final mic = PendingStartMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final starting = capture.start();
    await mic.requested.future;
    final draft = capture.draft!;
    final ending = capture.finish();
    mic.response.complete(mic.chunks.stream);
    await Future.wait([starting, ending]);
    expect(capture.state, 'cancelled');
    expect(mic.released, isTrue);
    expect(await File(draft.path).exists(), isFalse);
    expect(await book.records, isEmpty);
    capture.dispose();
  });
  test('停止失败后并发重试仅提交一次，迟到取消不能删除记录', () async {
    final mic = TestMicrophone()..failStop = true;
    final capture = CaptureController(book, microphone: mic);
    await capture.start();
    mic.chunks.add(Uint8List(32000));
    await capture.finish();
    expect(capture.state, 'failed');
    await Future.wait([capture.retry(), capture.retry()]);
    expect(capture.state, 'done');
    final saved = (await book.records).single;
    await capture.discard();
    expect((await book.records).single.id, saved.id);
    expect(await File(book.audioPath(saved)).length(), 32044);
    capture.dispose();
  });
  test('没有PCM的录音不产生空记录', () async {
    final capture = CaptureController(book, microphone: TestMicrophone());
    await capture.start();
    await capture.finish();
    expect(capture.saved, isNull);
    expect(await book.records, isEmpty);
    expect(capture.state, 'failed');
    await capture.discard();
    capture.dispose();
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
      expect((await book.records).single.durationMs, 1000);
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
        expect((await book.records), isEmpty);
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
      expect((await book.records), isEmpty);
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
        expect((await book.records), isEmpty);
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
      expect((await book.records), isEmpty);
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
      expect((await book.records).single.durationMs, 1000);
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
      expect((await book.records).single.durationMs, 120000);
      expect(
        await File(book.audioPath((await book.records).single)).length(),
        3840044,
      );
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
      expect((await book.records), isEmpty);
      expect(await File(capture.draft!.path).exists(), isFalse);
    } finally {
      capture.dispose();
      store.dispose();
    }
  });
}
