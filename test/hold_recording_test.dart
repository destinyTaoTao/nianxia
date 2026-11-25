import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/settings.dart';

import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';
import 'support/ui_native_capture.dart';

import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';

class HoldMicrophone implements MicrophoneInput {
  final chunks = StreamController<Uint8List>();
  Completer<bool>? permission;
  Completer<void>? starting;
  var starts = 0;
  @override
  Future<bool> allowed() async =>
      permission == null ? true : await permission!.future;
  @override
  Future<Stream<Uint8List>> start() async {
    starts++;
    await starting?.future;
    return chunks.stream;
  }

  void feed() =>
      chunks.add(Uint8List.fromList(List.generate(3200, (i) => i % 127)));
  @override
  Future<void> stop() async {
    if (chunks.isClosed) return;
    if (!chunks.hasListener) chunks.stream.listen((_) {});
    if (!chunks.isClosed) await chunks.close();
  }

  @override
  Future<void> cancel() => stop();
  @override
  Future<void> close() => stop();
  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Stream<void> get interruptions => const Stream.empty();
}

class CancelFaultEndpoint extends UiCaptureEndpoint {
  CancelFaultEndpoint(super.book);
  bool failCancel = true;
  @override
  Future<void> cancel(String id) async {
    if (failCancel) throw const FileSystemException('cancel fault');
    await super.cancel(id);
  }
}

void main() {
  late Directory root;
  late Notebook book;
  late HoldMicrophone mic;
  const system = MethodChannel('app.nianxia/system');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-hold-test-');
    book = await Notebook.open(root);
    mic = HoldMicrophone();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(system, (_) async => true);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(system, null);
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await mic.close();
      await book.close();
      await root.delete(recursive: true);
    });
  });
  final button = find.byKey(const Key('hold-record'));
  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book, captureMicrophone: mic));
    await pumpStorageAndSettle(tester);
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100 && !ready(); i++) {
      await pumpStorageAndSettle(tester);
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
  }

  Future<TestGesture> begin(WidgetTester tester) async {
    final gesture = await tester.startGesture(tester.getCenter(button));
    await pumpStorageAndSettle(tester);
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    mic.feed();
    await pumpStorageAndSettle(tester);
    return gesture;
  }

  testWidgets('按住位置固定，模式禁用，松手只创建一条真实音频记录', (tester) async {
    await launch(tester);
    final rect = tester.getRect(button);
    final gesture = await begin(tester);
    expect(tester.getRect(button), rect);
    await tester.tap(find.byKey(const Key('home-mode-text')));
    await tester.pump();
    expect(find.byKey(const Key('body-editor')), findsNothing);
    await gesture.up();
    await pumpStorageAndSettle(tester);
    await until(
      tester,
      () => find.textContaining('音频已保存').evaluate().isNotEmpty,
    );
    final records = await storageRead(tester, () => book.records);
    expect(records, hasLength(1));
    expect(
      await storageRead(
        tester,
        () => File(book.audioPath(records.single)).length(),
      ),
      greaterThan(44),
    );
    expect(find.text('等待转写'), findsOneWidget);
    expect(find.text('音频已保存，等待转写'), findsOneWidget);
  });
  testWidgets('上滑候选可移回且不重启，滞回内保持取消，区域松手不确认', (tester) async {
    await launch(tester);
    final origin = tester.getCenter(button);
    final gesture = await begin(tester);
    await gesture.moveTo(origin - const Offset(0, 90));
    await tester.pump();
    expect(find.text('松手取消，移回继续'), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('松手取消')),
      findsOneWidget,
    );
    await gesture.moveTo(origin - const Offset(0, 50));
    await tester.pump();
    expect(find.text('松手取消，移回继续'), findsOneWidget);
    await gesture.moveTo(origin - const Offset(0, 20));
    await tester.pump();
    expect(find.text('松手保存，上滑取消'), findsOneWidget);
    expect(mic.starts, 1);
    await gesture.moveTo(origin - const Offset(0, 90));
    await tester.pump();
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(await storageRead(tester, () => book.records), isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      (await storageRead(
        tester,
        () => Directory('${root.path}/audio').list().toList(),
      )).whereType<File>(),
      isEmpty,
    );
  });
  testWidgets('系统pointer取消保留已采集音频，不能误作上滑丢弃', (tester) async {
    await launch(tester);
    final gesture = await begin(tester);
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    await gesture.cancel();
    await pumpStorageAndSettle(tester);
    await until(
      tester,
      () => find.textContaining('音频已保存').evaluate().isNotEmpty,
    );
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });
  testWidgets('权限尚未完成时松手废止，迟到授权不启动麦克风', (tester) async {
    mic.permission = Completer<bool>();
    await launch(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await pumpStorageAndSettle(tester);
    expect(find.text('正在准备录音…'), findsOneWidget);
    await gesture.up();
    mic.permission!.complete(true);
    await pumpStorageAndSettle(tester);
    expect(mic.starts, 0);
    expect(book.captureActive, isFalse);
    expect(await storageRead(tester, () => book.records), isEmpty);
  });
  testWidgets('启动Future迟到与首次授权inactive均废止旧手势', (tester) async {
    mic.starting = Completer<void>();
    await launch(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await pumpStorageAndSettle(tester);
    await until(tester, () => mic.starts == 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    mic.starting!.complete();
    await gesture.up();
    await pumpStorageAndSettle(tester);
    await until(tester, () => !book.captureActive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(book.captureActive, isFalse);
    expect(await storageRead(tester, () => book.records), isEmpty);
  });
  testWidgets('保存故障保留片段，重试只提交一次，不自动转文字', (tester) async {
    await launch(tester);
    final gesture = await begin(tester);
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_hold BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'test fault'); END",
    );
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(await storageRead(tester, () => book.records), isEmpty);
    await until(tester, () => find.text('重试保存').evaluate().isNotEmpty);
    expect(find.byKey(const Key('body-editor')), findsNothing);
    expect(
      find.descendant(of: button, matching: find.text('录音未保存')),
      findsOneWidget,
    );
    StorageProbe(book).execute('DROP TRIGGER fail_hold');
    await tester.tap(find.text('重试保存'));
    await pumpStorageAndSettle(tester);
    await until(
      tester,
      () => find.textContaining('音频已保存').evaluate().isNotEmpty,
    );
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });
  testWidgets('两分钟采样截止先完成时，迟到上滑和松手不能删除已保存记录', (tester) async {
    await launch(tester);
    final gesture = await begin(tester);
    mic.chunks.add(Uint8List(3840000));
    await until(tester, () => find.text('音频已保存，请松手').evaluate().isNotEmpty);
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await pumpStorageAndSettle(tester);
    final rows = await storageRead(tester, () => book.records);
    expect(rows, hasLength(1));
    expect(rows.single.durationMs, 120000);
    expect(
      await storageRead(
        tester,
        () => File(book.audioPath(rows.single)).exists(),
      ),
      isTrue,
    );
  });
  testWidgets('没有有效PCM不提交空记录，也不假装已保存', (tester) async {
    await launch(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    await gesture.up();
    await until(tester, () => find.text('重试保存').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), isEmpty);
    expect(find.textContaining('音频已保存'), findsNothing);
  });
  testWidgets('第二触点不会接管第一触点或松手提前保存', (tester) async {
    await launch(tester);
    final gesture = await begin(tester);
    final other = await tester.startGesture(
      tester.getCenter(button),
      pointer: 42,
    );
    await other.moveBy(const Offset(0, -100));
    await other.up();
    await pumpStorageAndSettle(tester);
    expect(find.text('松手保存，上滑取消'), findsOneWidget);
    expect(await storageRead(tester, () => book.records), isEmpty);
    expect(mic.starts, 1);
    await gesture.up();
    await until(tester, () => find.text('音频已保存，等待转写').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });
  testWidgets('原生会话反馈不能替换手指下的入口，截止后不会再次取消', (tester) async {
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    final rect = tester.getRect(button);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    expect(tester.getRect(button), rect);
    await storageRead(tester, () => endpoint.stop(capture.snapshot!.sessionId));
    await until(tester, () => find.text('音频已保存，请松手').evaluate().isNotEmpty);
    await gesture.moveBy(const Offset(0, -100));
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(endpoint.cancels, 0);
    expect(await storageRead(tester, () => book.records), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    capture.dispose();
    runtime.dispose();
  });
  testWidgets('临近两分钟提醒可读且不移动按住入口，320宽双倍字体仍可松手保存', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    TestGesture? gesture;
    try {
      await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
      await pumpStorageAndSettle(tester);
      final rect = tester.getRect(button);
      gesture = await tester.startGesture(tester.getCenter(button));
      await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
      void elapsed(int milliseconds) {
        endpoint.value = CaptureSnapshot.fromMap({
          ...endpoint.value!.request.toMap(),
          'phase': 'recording',
          'sequence': endpoint.value!.sequence + 1,
          'elapsedMs': milliseconds,
          'pcmBytes': milliseconds * 32,
          'level': 0.1,
        });
        endpoint.updates.add(endpoint.value!);
      }

      elapsed(104999);
      await pumpStorageAndSettle(tester);
      expect(find.text('即将达到两分钟，录音将自动结束。'), findsNothing);
      elapsed(105000);
      await pumpStorageAndSettle(tester);
      expect(find.text('即将达到两分钟，录音将自动结束。'), findsOneWidget);
      expect(tester.getRect(button), rect);
      expect(tester.takeException(), isNull);
      await gesture.up();
      gesture = null;
      await until(tester, () => find.text('音频已保存，等待转写').evaluate().isNotEmpty);
      expect(await storageRead(tester, () => book.records), hasLength(1));
    } finally {
      await gesture?.up();
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStorageAndSettle(tester);
      capture.dispose();
      runtime.dispose();
    }
  });
  testWidgets('按住不能冒领原生所有者已有的录音，返回后仍可继续处理', (tester) async {
    final endpoint = UiCaptureEndpoint(book);
    await endpoint.start(
      CaptureRequest(
        sessionId: '11111111-1111-4111-8111-111111111111',
        mode: CaptureMode.record,
        createdAtUtc: DateTime.utc(2026, 11, 16),
        timezone: 'UTC',
        offsetMinutes: 0,
      ),
    );
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await pumpStorageAndSettle(tester);
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(endpoint.starts, 1);
    expect(endpoint.cancels, 0);
    expect(await storageRead(tester, () => book.records), isEmpty);
    await until(
      tester,
      () => find.textContaining('请先处理已有录音').evaluate().isNotEmpty,
    );
    expect(find.textContaining('请先处理已有录音'), findsOneWidget);
    await tester.tap(find.text('重新操作'));
    await pumpStorageAndSettle(tester);
    await storageRead(tester, () => capture.stop());
    await pumpStorageAndSettle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    capture.dispose();
    runtime.dispose();
  });
  testWidgets('原生截止后台提交失败可重试，不能一直停留保存中', (tester) async {
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_native_hold BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'test fault'); END",
    );
    await storageRead(tester, () => endpoint.stop(capture.snapshot!.sessionId));
    await gesture.up();
    await until(tester, () => find.text('重试保存').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), isEmpty);
    StorageProbe(book).execute('DROP TRIGGER fail_native_hold');
    await tester.tap(find.text('重试保存'));
    await until(tester, () => find.text('音频已保存，等待转写').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('明确上滑取消失败时重试取消，不得把重试变成保存', (tester) async {
    final endpoint = CancelFaultEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    await gesture.moveBy(const Offset(0, -90));
    await gesture.up();
    await until(tester, () => find.text('重试取消').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), isEmpty);
    endpoint.failCancel = false;
    await tester.tap(find.text('重试取消'));
    await until(tester, () => find.text('按住说话').evaluate().isNotEmpty);
    expect(endpoint.cancels, 1);
    expect(await storageRead(tester, () => book.records), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('320双倍字体的键盘激活走点按录音替代', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    final semantics = tester.ensureSemantics();
    try {
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
    Focus.of(tester.element(button)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await until(tester, () => find.text('停止并保存').evaluate().isNotEmpty);
    mic.feed();
    await pumpStorageAndSettle(tester);
    await tester.ensureVisible(find.text('停止并保存'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('停止并保存'));
    await until(tester, () => find.byType(BottomSheet).evaluate().isEmpty);
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });

  testWidgets('320双倍字体在上滑反馈前后按钮不漂移', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    final rect = tester.getRect(button);
    final gesture = await begin(tester);
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump();
    expect(tester.getRect(button), rect);
    expect(
      tester.getTopLeft(find.text('松手取消，移回继续')).dy,
      greaterThanOrEqualTo(0),
    );
    await gesture.up();
    await until(tester, () => find.text('按住说话').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), isEmpty);
  });
  for (final interruption in ['pointer', 'lifecycle']) {
    testWidgets('截止已保存后 $interruption 丢失触点仍释放首页操作', (tester) async {
      await launch(tester);
      final gesture = await begin(tester);
      mic.chunks.add(Uint8List(3840000));
      await until(tester, () => find.text('音频已保存，请松手').evaluate().isNotEmpty);
      if (interruption == 'pointer') {
        await gesture.cancel();
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await pumpStorageAndSettle(tester);
      expect(find.text('按住说话'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('home-mode-text')))
            .onPressed,
        isNotNull,
      );
      expect(await storageRead(tester, () => book.records), hasLength(1));
    });
  }

  testWidgets('取消先受理但IPC失败，后续平台截止也不能变成保存', (tester) async {
    final endpoint = CancelFaultEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(button));
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    final id = capture.snapshot!.sessionId;
    await gesture.moveBy(const Offset(0, -90));
    await gesture.up();
    await until(tester, () => find.text('重试取消').evaluate().isNotEmpty);
    await storageRead(tester, () => endpoint.stop(id));
    await pumpStorageAndSettle(tester);
    // Await all queued owner work rather than treating a transient empty list as success.
    var settled = false;
    final barrier = capture.reconnect().then((_) => settled = true);
    await until(tester, () => settled);
    await barrier;
    await pumpStorageAndSettle(tester);
    expect(await storageRead(tester, () => book.records), isEmpty);
    expect(find.text('音频已保存，等待转写'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('已有设置键盘焦点不能绕过按住录音期间的导航锁', (tester) async {
    await launch(tester);
    Focus.of(tester.element(find.byIcon(Icons.settings_outlined)))
        .requestFocus();
    await tester.pump();
    final gesture = await begin(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpStorageAndSettle(tester);
    expect(find.byType(SettingsPage), findsNothing);
    await gesture.up();
    await until(tester, () => find.text('音频已保存，等待转写').evaluate().isNotEmpty);
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });
  testWidgets('截止后的同批up与新down不能在旧所有者释放前重启', (tester) async {
    await launch(tester);
    final origin = tester.getCenter(button);
    await tester.startGesture(origin, pointer: 77);
    await until(tester, () => find.text('松手保存，上滑取消').evaluate().isNotEmpty);
    mic.chunks.add(Uint8List(3840000));
    await until(tester, () => find.text('音频已保存，请松手').evaluate().isNotEmpty);
    tester.binding.handlePointerEvent(
      PointerUpEvent(pointer: 77, position: origin),
    );
    tester.binding.handlePointerEvent(
      PointerDownEvent(pointer: 99, position: origin, buttons: 1),
    );
    await tester.pump();
    try {
      expect(find.text('按住说话'), findsOneWidget);
    } finally {
      tester.binding.handlePointerEvent(
        PointerUpEvent(pointer: 99, position: origin),
      );
      await until(tester, () => !book.captureActive);
      await pumpStorageAndSettle(tester);
    }
    expect(mic.starts, 1);
    expect(await storageRead(tester, () => book.records), hasLength(1));
  });
}
