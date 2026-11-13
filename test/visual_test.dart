import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/recorder.dart';

import 'capture_controller_test.dart' show TestMicrophone;
import 'recording_search_test.dart' show TextTranscriber, writeWave;
import 'support/async_storage_tester.dart';

const output = String.fromEnvironment('SCREENSHOT_DIR');
const fontPath = String.fromEnvironment('SCREENSHOT_FONT');
const iconPath = String.fromEnvironment('SCREENSHOT_ICON_FONT');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  setUpAll(() async {
    if (iconPath.isNotEmpty) {
      final b = await File(iconPath).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(b)))).load();
    }
    if (fontPath.isNotEmpty) {
      final bytes = await File(fontPath).readAsBytes();
      await (FontLoader(
        'ScreenshotFont',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  });
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async =>
              call.method == 'recordingScreenAvailable' ? true : null,
        );
    home = await Directory.systemTemp.createTemp('nianxia-visual-');
    var minute = 20;
    book = await Notebook.open(
      home,
      clock: () => DateTime(2026, 11, 10, 10, minute++),
    );
    final r = await book.saveText('记录要足够快，才能跟上想法。\n先保存原文，再慢慢整理。');
    await book.favorite(r.id, true);
    await book.saveText('SQLite 检索先保证中文关键词可用，语义查找作为增强。');
    await book.saveText('周末试试在散步时记灵感。暂时不做自动同步。');
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final audio = await book.finishCapture(draft);
    await book.transcribe(
      audio.id,
      TextTranscriber(Future.value('缓存方案还需要验证\n先试本地缓存，但一致性还没验证。')),
    );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });
  Future<void> capture(WidgetTester tester, String name) async {
    if (output.isEmpty) {
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('capture-root')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('${mode.name} 手机首页、查找、详情与表单布局', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: NianxiaApp(
            book: book,
            initialTheme: mode,
            fontFamily: fontPath.isEmpty ? null : 'ScreenshotFont',
          ),
        ),
      );
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'home-${mode.name}');
      await tester.tap(find.text('缓存方案还需要验证'));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'detail-${mode.name}');
      await tester.tap(find.byTooltip('返回'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('找一下'));
      await pumpStorageAndSettle(tester);
      await tester.enterText(find.byKey(const Key('search-input')), 'SQLite');
      await tester.pump(const Duration(milliseconds: 400));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'search-${mode.name}');
      await tester.tap(find.byTooltip('返回'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.byTooltip('设置'));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'settings-${mode.name}');
      await tester.tap(find.byTooltip('返回'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('写文字'));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'editor-${mode.name}');
      await tester.tap(find.byTooltip('返回'));
      await pumpStorageAndSettle(tester);
      await tester.ensureVisible(find.text('缓存方案还需要验证'));
      await tester.tap(find.text('缓存方案还需要验证'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('加入日历'));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      await capture(tester, 'calendar-${mode.name}');
    });
    testWidgets('${mode.name} 录音面板使用真实控制器状态并保留取消确认', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('capture-root'),
          child: NianxiaApp(
            book: book,
            initialTheme: mode,
            fontFamily: fontPath.isEmpty ? null : 'ScreenshotFont',
          ),
        ),
      );
      await pumpStorageAndSettle(tester);
      var recorderClosed = false;
      final recorder = openRecorder(
        tester.element(find.text('记一下')),
        book,
        null,
        microphone: TestMicrophone(),
      ).whenComplete(() => recorderClosed = true);
      for (var i = 0; i < 50 && find.text('停止并保存').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await pumpStorageAndSettle(tester);
      expect(find.text('停止并保存'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture(tester, 'recorder-${mode.name}');
      await tester.tap(find.text('取消录音'));
      await pumpStorageAndSettle(tester);
      expect(find.text('确认丢弃'), findsOneWidget);
      await tester.tap(find.text('确认丢弃'));
      for (var i = 0; i < 50 && !recorderClosed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(recorderClosed, isTrue);
      await recorder;
      await pumpStorageAndSettle(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('小屏与两倍字体仍可操作，控件有可访问标签', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await tester.ensureVisible(find.text('收藏'));
    await tester.tap(find.text('收藏'));
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await tester.tap(find.text('全部'));
    await pumpStorageAndSettle(tester);
    await tester.scrollUntilVisible(
      find.byTooltip('设置').hitTestable(),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byTooltip('设置').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('设置').hitTestable());
    await pumpStorageAndSettle(tester);
    expect(find.text('保存在这里'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
