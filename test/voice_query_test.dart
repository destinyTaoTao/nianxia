import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';

import 'capture_controller_test.dart' show QueryReadyStore;
import 'hold_recording_test.dart' show HoldMicrophone;
import 'support/async_storage_tester.dart';
import 'support/ui_native_capture.dart';

class QueryModels extends LocalModels {
  QueryModels(super.store);
  Completer<String>? recognition;
  Completer<bool>? speechReady;
  String recognized = '缓存';
  String? audio;
  bool fail = false, available = true;
  @override
  Future<bool> ready(InferenceCapability capability) async =>
      capability != InferenceCapability.speech
      ? false
      : await speechReady?.future ?? available;
  @override
  Future<String> transcribe(String path, {bool foreground = true}) async {
    audio = path;
    if (fail) throw const NotebookException('没有识别到线索，请重说或输入文字。');
    return await recognition?.future ?? recognized;
  }
}

class QueryStopFault extends UiCaptureEndpoint {
  QueryStopFault(super.book);
  bool failStop = true;
  @override
  Future<CaptureSnapshot> stop(String id) async {
    if (failStop) throw const NotebookException('查询停止失败，请重说。');
    return await super.stop(id);
  }
}

void main() {
  late Directory root;
  late Notebook book;
  late QueryModels models;
  late QueryReadyStore store;
  late HoldMicrophone mic;
  final input = find.byKey(const Key('search-input'));
  final hold = find.byKey(const Key('hold-query'));
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    root = await Directory.systemTemp.createTemp('nx-voice-query-');
    book = await Notebook.open(root);
    store = QueryReadyStore(root);
    models = QueryModels(store);
    mic = HoldMicrophone();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async =>
              call.method == 'recordingScreenAvailable' ? true : null,
        );
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      models.dispose();
      store.dispose();
      await root.delete(recursive: true);
    });
  });
  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(
      NianxiaApp(book: book, models: models, captureMicrophone: mic),
    );
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('语音查找'));
    await pumpStorageAndSettle(tester);
  }

  Future<TestGesture> record(WidgetTester tester) async {
    await tester.ensureVisible(hold);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await until(tester, () => mic.chunks.hasListener);
    mic.feed();
    await tester.pump(const Duration(milliseconds: 200));
    return gesture;
  }

  Future<void> noQueryData(WidgetTester tester, int count) async {
    expect((await storageRead(tester, () => book.records)).length, count);
    final waves = await storageRead(
      tester,
      () => root
          .list(recursive: true)
          .where((f) => f.path.endsWith('.wav'))
          .toList(),
    );
    expect(waves, isEmpty);
    expect(book.captureActive, isFalse);
  }

  testWidgets('语音入口不自动开麦，按住松手识别仅供校对，确认才查找且清理临时音频', (tester) async {
    await storageRead(tester, () => book.saveText('缓存原始记录'));
    await storageRead(tester, () => book.saveText('离线原始记录'));
    await launch(tester);
    expect(hold, findsOneWidget);
    expect(book.captureActive, isFalse);
    expect(find.textContaining('松手识别'), findsWidgets);
    final gesture = await record(tester);
    expect(find.text('停止并保存'), findsNothing);
    await gesture.up();
    await until(
      tester,
      () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
    );
    expect(tester.widget<TextField>(input).controller!.text, '缓存');
    expect(find.byType(SearchSummaryRow), findsNothing);
    await tester.enterText(input, '离线');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => find.text('离线原始记录').evaluate().isNotEmpty);
    expect(find.text('缓存原始记录'), findsNothing);
    expect(models.audio, isNotNull);
    expect(
      await storageRead(tester, () => File(models.audio!).exists()),
      isFalse,
    );
    await noQueryData(tester, 2);
  });
  testWidgets('上滑取消不识别不入库，改用文字保留原输入', (tester) async {
    await launch(tester);
    final gesture = await record(tester);
    await gesture.moveBy(const Offset(0, -85));
    await tester.pump();
    expect(find.textContaining('松手取消'), findsWidgets);
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(models.audio, isNull);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    expect(input, findsOneWidget);
    await noQueryData(tester, 0);
  });
  testWidgets('准备期松手废止迟到授权，不稍后启动查询', (tester) async {
    mic.permission = Completer<bool>();
    await launch(tester);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    await gesture.up();
    mic.permission!.complete(true);
    await until(tester, () => !book.captureActive);
    await pumpStorageAndSettle(tester);
    expect(mic.starts, 0);
    expect(models.audio, isNull);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    await noQueryData(tester, 0);
  });
  testWidgets('查询临时目录持续不可写时重说仍保留失败和重试身份', (tester) async {
    models.fail = true;
    Directory? queries;
    try {
      await launch(tester);
      final gesture = await record(tester);
      queries = Directory('${root.path}/queries');
      expect(
        (await storageRead(
          tester,
          () => Process.run('chmod', ['0555', queries!.path]),
        )).exitCode,
        0,
      );
      await gesture.up();
      await until(tester, () => find.text('重说').evaluate().isNotEmpty);
      await tester.tap(find.text('重说'));
      await pumpStorageAndSettle(tester);
      expect(find.text('查询未完成'), findsOneWidget);
      expect(find.text('重说'), findsOneWidget);
      expect(find.text('按住说出线索'), findsNothing);
      expect(
        (await storageRead(tester, () => queries!.list().toList())),
        isNotEmpty,
      );
      expect(
        (await storageRead(
          tester,
          () => Process.run('chmod', ['0755', queries!.path]),
        )).exitCode,
        0,
      );
      await tester.tap(find.text('重说'));
      await pumpStorageAndSettle(tester);
      expect(find.text('按住说出线索'), findsOneWidget);
      await noQueryData(tester, 0);
    } finally {
      if (queries != null) {
        await storageRead(
          tester,
          () => Process.run('chmod', ['0755', queries!.path]),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStorageAndSettle(tester);
    }
  }, skip: Platform.isWindows);

  for (final ownRecorder in [false, true]) {
    testWidgets('后台只关闭自己的语音面板${ownRecorder ? '及点按确认框' : ''}，保留上层新查找页面', (
      tester,
    ) async {
      await launch(tester);
      if (ownRecorder) {
        await tester.tap(find.text('点按说出线索'));
        await until(tester, () => mic.chunks.hasListener);
        mic.feed();
        await tester.tap(find.text('取消查找'));
        await pumpStorageAndSettle(tester);
        expect(find.text('取消本次查询？'), findsOneWidget);
      }
      final context = tester.element(
        find.byKey(const Key('voice-query-panel'), skipOffstage: false),
      );
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => SearchPage(book: book, models: models),
        ),
      );
      await pumpStorageAndSettle(tester);
      await tester.enterText(input, '后来打开页面的文字草稿');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await pumpStorageAndSettle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpStorageAndSettle(tester);
      expect(tester.widget<TextField>(input).controller!.text, '后来打开页面的文字草稿');
      expect(
        find.byKey(const Key('voice-query-panel'), skipOffstage: false),
        findsNothing,
      );
      expect(find.text('取消本次查询？', skipOffstage: false), findsNothing);
      await until(tester, () => !book.captureActive);
      await noQueryData(tester, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStorageAndSettle(tester);
    });
  }
  testWidgets('识别期间取消后迟到文字不覆盖新的输入且删除临时音频', (tester) async {
    models.recognition = Completer<String>();
    await launch(tester);
    final gesture = await record(tester);
    await gesture.up();
    await until(tester, () => models.audio != null);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '新的手工草稿');
    models.recognition!.complete('过期识别');
    await until(tester, () => !book.captureActive);
    await pumpStorageAndSettle(tester);
    expect(tester.widget<TextField>(input).controller!.text, '新的手工草稿');
    expect(find.byType(SearchSummaryRow), findsNothing);
    expect(find.textContaining('识别文字可以修改'), findsNothing);
    await noQueryData(tester, 0);
  });
  testWidgets('查询识别失败提供重说和文字退路，不保留为笔记录音', (tester) async {
    models.fail = true;
    await launch(tester);
    final gesture = await record(tester);
    await gesture.up();
    await until(tester, () => find.text('重说').evaluate().isNotEmpty);
    expect(find.textContaining('没有识别到线索'), findsOneWidget);
    expect(find.text('重试保存'), findsNothing);
    await noQueryData(tester, 0);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    expect(input, findsOneWidget);
  });
  testWidgets('无模型仍可文字查找，活动录音不能启动语音查询', (tester) async {
    models.available = false;
    await launch(tester);
    expect(hold, findsNothing);
    expect(find.textContaining('语音模型未就绪'), findsOneWidget);
    expect(input, findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await pumpStorageAndSettle(tester);
    models.available = true;
    book.captureActive = true;
    await tester.tap(find.text('语音查找'));
    await pumpStorageAndSettle(tester);
    expect(hold, findsNothing);
    expect(find.textContaining('请先处理当前录音'), findsOneWidget);
    book.captureActive = false;
    await noQueryData(tester, 0);
  });
  testWidgets('权限失败清楚保留文字退路且不创建记录', (tester) async {
    mic.permission = Completer<bool>()..complete(false);
    await launch(tester);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await until(tester, () => !book.captureActive);
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('没有麦克风权限'), findsOneWidget);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    await noQueryData(tester, 0);
  });
  testWidgets('切后台取消采集，恢复后不自动识别或覆盖输入', (tester) async {
    await launch(tester);
    final gesture = await record(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await gesture.up();
    await until(tester, () => !book.captureActive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(models.audio, isNull);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await noQueryData(tester, 0);
  });
  testWidgets('受控原生按住查询成功后先校对，音频清理而源记录不增加', (tester) async {
    final runtime = UiCaptureRuntime();
    final endpoint = UiCaptureEndpoint(book);
    final capture = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('语音查找'));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await until(
      tester,
      () => capture.snapshot?.phase == NativeCapturePhase.recording,
    );
    await gesture.up();
    await until(
      tester,
      () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
    );
    expect(tester.widget<TextField>(input).controller!.text, 'synthetic query');
    expect(find.byType(SearchSummaryRow), findsNothing);
    expect(runtime.transcriptions, 1);
    await noQueryData(tester, 0);
  });
  testWidgets('320双倍字体下查询与取消入口可滚动访问', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    await tester.ensureVisible(hold);
    await tester.pumpAndSettle();
    expect(hold.hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('点按说出线索'));
    await tester.pumpAndSettle();
    expect(find.text('点按说出线索').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('改用文字'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    expect(input, findsOneWidget);
    expect(tester.takeException(), isNull);
    await noQueryData(tester, 0);
  });
  testWidgets('点按替代采集切后台时关闭全部查询面板并清理，不留失效外层页面', (tester) async {
    final runtime = UiCaptureRuntime();
    final endpoint = UiCaptureEndpoint(book);
    final capture = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('语音查找'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('点按说出线索'));
    await until(tester, () => book.captureActive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await until(tester, () => !book.captureActive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(input, findsOneWidget);
    expect(runtime.transcriptions, 0);
    await noQueryData(tester, 0);
  });
  testWidgets('系统返回退场期间的迟到识别不能再关闭查找页', (tester) async {
    models.recognition = Completer<String>();
    await launch(tester);
    final gesture = await record(tester);
    await gesture.up();
    await until(tester, () => models.audio != null);
    await tester.binding.handlePopRoute();
    models.recognition!.complete('过期结果');
    await until(tester, () => !book.captureActive);
    await pumpStorageAndSettle(tester);
    expect(input, findsOneWidget);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await noQueryData(tester, 0);
  });
  testWidgets('原生查询自动截止时单次识别，不等待已失效的松手', (tester) async {
    final runtime = UiCaptureRuntime();
    final endpoint = UiCaptureEndpoint(book);
    final capture = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('语音查找'));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await until(tester, () => book.captureActive);
    await storageRead(tester, () => endpoint.stop(capture.snapshot!.sessionId));
    await until(
      tester,
      () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
    );
    await gesture.up();
    await pumpStorageAndSettle(tester);
    expect(runtime.transcriptions, 1);
    expect(tester.widget<TextField>(input).controller!.text, 'synthetic query');
    await noQueryData(tester, 0);
  });
  testWidgets('原生停止失败重说先清理旧查询，再录制可成功进入校对', (tester) async {
    final runtime = UiCaptureRuntime();
    final endpoint = QueryStopFault(book);
    final capture = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('语音查找'));
    await pumpStorageAndSettle(tester);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await until(tester, () => book.captureActive);
    await gesture.up();
    await until(tester, () => find.text('重说').evaluate().isNotEmpty);
    endpoint.failStop = false;
    await tester.tap(find.text('重说'));
    await pumpStorageAndSettle(tester);
    expect(book.captureActive, isFalse);
    final again = await tester.startGesture(tester.getCenter(hold));
    await until(tester, () => book.captureActive);
    await again.up();
    await until(
      tester,
      () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
    );
    expect(runtime.transcriptions, 1);
    await noQueryData(tester, 0);
  });
  testWidgets('普通点按查询切后台立即取消，不在后台开始识别', (tester) async {
    await launch(tester);
    await tester.tap(find.text('点按说出线索'));
    await until(tester, () => mic.chunks.hasListener);
    mic.feed();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await until(tester, () => !book.captureActive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(input, findsOneWidget);
    expect(models.audio, isNull);
    await noQueryData(tester, 0);
  });
  testWidgets('模型就绪检查迟到时不能在后台重新打开语音面板', (tester) async {
    models.speechReady = Completer<bool>();
    await launch(tester);
    expect(hold, findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    models.speechReady!.complete(true);
    await pumpStorageAndSettle(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(input, findsOneWidget);
    await noQueryData(tester, 0);
  });
  testWidgets('取消临时查询不宣称源资料变化或重查当前结果', (tester) async {
    await storageRead(tester, () => book.saveText('缓存来源'));
    await launch(tester);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '缓存');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => find.text('缓存来源').evaluate().isNotEmpty);
    await tester.tap(find.text('语音查找'));
    await pumpStorageAndSettle(tester);
    final gesture = await record(tester);
    await gesture.moveBy(const Offset(0, -85));
    await tester.pump();
    await gesture.up();
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('改用文字'));
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('记录已变化'), findsNothing);
    expect(find.text('缓存来源'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '缓存');
    await noQueryData(tester, 1);
  });
  testWidgets('点按替代明确停止后也先校对，再由用户确认查找', (tester) async {
    await storageRead(tester, () => book.saveText('缓存点按来源'));
    await launch(tester);
    await tester.tap(find.text('点按说出线索'));
    await until(tester, () => mic.chunks.hasListener);
    mic.feed();
    await tester.pump();
    await tester.tap(find.text('停止并查看文字'));
    await until(
      tester,
      () => find.textContaining('识别文字可以修改').evaluate().isNotEmpty,
    );
    expect(tester.widget<TextField>(input).controller!.text, '缓存');
    expect(find.byType(SearchSummaryRow), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => find.text('缓存点按来源').evaluate().isNotEmpty);
    await noQueryData(tester, 1);
  });
}
