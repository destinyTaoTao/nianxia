import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';
import 'support/ui_native_capture.dart';

import 'package:nianxia/app/capture_session_controller.dart';

void main() {
  late Directory dir;
  late Notebook book;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nx-continuous-home-');
    book = await Notebook.open(
      dir,
      clock: () => DateTime.utc(2026, 11, 16, 10, 24),
    );
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await dir.delete(recursive: true);
    });
  });
  testWidgets('首页按原当地日期分组并显示时间列，底部文字保存失败可重试', (tester) async {
    await storageRead(tester, () => book.saveText('原有想法\n先验证，再扩大范围。'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('11月16日'), findsOneWidget);
    expect(find.text('10:24'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home-mode-text')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('body-editor')), '  ');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('home-save-text')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('body-editor')), '新的想法');
    await tester.pump();
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_home_text BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'test fault'); END",
    );
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('body-editor')))
          .controller!
          .text,
      '新的想法',
    );
    expect((await storageRead(tester, () => book.records)), hasLength(1));
    expect(find.textContaining('操作失败'), findsOneWidget);
    StorageProbe(book).execute('DROP TRIGGER fail_home_text');
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(find.text('新的想法'), findsOneWidget);
    expect((await storageRead(tester, () => book.records)), hasLength(2));
    expect(find.text('按住说话').hitTestable(), findsOneWidget);
  });
  testWidgets('文字草稿遇快捷录音收起仍保留，隐藏输入不能持有焦点', (tester) async {
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    final shortcut = ValueNotifier<String?>(null);
    await tester.pumpWidget(
      NianxiaApp(book: book, captureSession: capture, shortcut: shortcut),
    );
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-mode-text')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('body-editor')), '未保存的文字草稿');
    await tester.pump();
    shortcut.value = 'capture';
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('收起'));
    await pumpStorageAndSettle(tester);
    final field = tester.widget<TextField>(
      find.byKey(const Key('body-editor'), skipOffstage: false),
    );
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.controller!.text, '未保存的文字草稿');
    await storageRead(tester, () => capture.stop());
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('body-editor')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('body-editor')))
          .controller!
          .text,
      '未保存的文字草稿',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    capture.dispose();
    runtime.dispose();
    shortcut.dispose();
  });
  testWidgets('跨页同日不重复标题，按创建offset展示日期而不重新排序', (tester) async {
    await storageRead(tester, () async {
      await book.close();
      var minute = 0;
      book = await Notebook.open(
        dir,
        clock: () => DateTime.utc(2026, 11, 16, 0, minute++),
      );
      for (var i = 0; i < 95; i++) {
        await book.saveText('跨页想法$i');
      }
    });
    final oldest = (await storageRead(tester, () => book.records)).last;
    StorageProbe(
      book,
    ).execute('UPDATE records SET offset_minutes=-60 WHERE id=?', [oldest.id]);
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('11月16日'), findsOneWidget);
    final list = find.byType(CustomScrollView);
    for (var i = 0; i < 60 && find.text('跨页想法0').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -600));
      await pumpStorageAndSettle(tester);
    }
    expect(find.text('跨页想法0'), findsOneWidget);
    expect(find.text('11月15日'), findsOneWidget);
    expect(find.text('23:00'), findsOneWidget);
    expect(
      find.text('11月16日'),
      findsNothing,
    ); // No duplicate title at page 2/3.
    final controller = tester.widget<CustomScrollView>(list).controller!;
    final offset = controller.offset;
    await tester.tap(find.text('跨页想法0'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('返回'));
    await pumpStorageAndSettle(tester);
    expect(controller.offset, closeTo(offset, 1));
  });
  testWidgets('320窄屏双倍字体与键盘下文字保存仍可达', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-mode-text')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('body-editor')), '键盘也不能挡住保存');
    tester.view.viewInsets = FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('home-save-text')));
    expect(
      find.byKey(const Key('home-save-text')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
