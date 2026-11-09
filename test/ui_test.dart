import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/ui/app.dart';

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-ui-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    book.dispose();
    await home.delete(recursive: true);
  });
  testWidgets('首页直接开始记录，最近三条之外的内容可从全部记录找回', (tester) async {
    await tester.runAsync(() async {
      book.dispose();
      var minute = 0;
      book = await Notebook.open(
        home,
        clock: () => DateTime.utc(2026, 11, 9, 9, minute++),
      );
      for (var i = 1; i <= 4; i++) {
        await book.saveText('想法 $i');
      }
    });
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.pumpAndSettle();
    expect(find.text('录音记一下'), findsOneWidget);
    expect(find.text('写文字'), findsOneWidget);
    expect(find.text('找一下'), findsOneWidget);
    expect(find.text('最近记录'), findsOneWidget);
    expect(find.text('想法 4'), findsOneWidget);
    expect(find.text('想法 1'), findsNothing);
    await tester.ensureVisible(find.text('全部记录'));
    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();
    expect(find.text('想法 1'), findsOneWidget);
    await tester.tap(find.text('想法 1'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('编辑正文'), findsOneWidget);
  });
  testWidgets('Android 日历入口明确说明提醒仍需在系统页手动设置', (tester) async {
    await tester.runAsync(() => book.saveText('待安排的模拟器验收事项'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.tap(find.text('待安排的模拟器验收事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入日历'));
    await tester.pumpAndSettle();
    expect(find.text('计划提醒时间'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('本页尚未设置提醒'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('本页尚未设置提醒'), findsOneWidget);
    final reminder = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始时').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('请在系统日历中手动设置提醒'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('请在系统日历中手动设置提醒：开始时'), findsOneWidget);
  });
  testWidgets('首页说明离线转写未准备，并直接进入可操作的模型下载区域', (tester) async {
    final store = ModelStore(Directory('${home.path}/models'), [
      const ModelSpec(
        id: 'sensevoice',
        version: 'test',
        label: '离线语音',
        files: [],
      ),
    ]);
    addTearDown(store.dispose);
    await tester.pumpWidget(NianxiaApp(book: book, models: LocalModels(store)));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('离线转写尚未就绪'), findsOneWidget);
    await tester.tap(find.text('准备语音转写'));
    await tester.pumpAndSettle();
    expect(find.text('离线模型').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, '下载模型').hitTestable(),
      findsOneWidget,
    );
    await tester.runAsync(() => store.download('sensevoice'));
    await tester.tap(find.byTooltip('返回'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('离线转写尚未就绪'), findsNothing);
    expect(find.text('录音记一下'), findsOneWidget);
  });
  testWidgets('用户可从文字入口保存、查看、编辑并查找记录', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    expect(find.text('录音记一下'), findsOneWidget);
    expect(find.text('找一下'), findsOneWidget);
    await tester.tap(find.text('写文字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('body-editor')), '这是一条产品灵感');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('这是一条产品灵感'), findsOneWidget);
    await tester.tap(find.text('这是一条产品灵感'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑正文'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('body-editor')),
      '这是一条 SQLite 灵感',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('这是一条 SQLite 灵感'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('找一下'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-input')), 'sqlite');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('这是一条 SQLite 灵感'), findsOneWidget);
  });
  testWidgets('收藏追加记录后可从收藏入口找回所属内容', (tester) async {
    final parent = await book.saveText('原始想法');
    final child = await book.saveText('值得收藏的追加', parentId: parent.id);
    await book.favorite(child.id, true);
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('值得收藏的追加'), findsOneWidget);
    await tester.tap(find.text('值得收藏的追加'));
    await tester.pumpAndSettle();
    expect(find.text('查看所属记录'), findsOneWidget);
  });
  testWidgets('查找可一键清空，清空后不显示旧结果', (tester) async {
    await book.saveText('离线查找的产品灵感');
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.tap(find.text('找一下'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-input')), '产品');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('离线查找的产品灵感'), findsOneWidget);
    await tester.tap(find.byTooltip('清空查找内容'));
    await tester.pump();
    expect(find.textContaining('离线查找的产品灵感'), findsNothing);
    expect(find.text('找回之前的想法'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('search-input')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
  });
  testWidgets('小屏大字体打开键盘时，查找提示和日期条件仍可滚动访问', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.ensureVisible(find.text('找一下'));
    await tester.tap(find.text('找一下'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('找回之前的想法'));
    await tester.pumpAndSettle();
    expect(find.text('找回之前的想法').hitTestable(), findsOneWidget);
    await tester.ensureVisible(find.text('按日期筛选'));
    await tester.pumpAndSettle();
    expect(find.text('按日期筛选').hitTestable(), findsOneWidget);
  });
  testWidgets('日期限制无结果时，可从提示清除条件并找回记录', (tester) async {
    await book.saveText('日期筛选的产品灵感');
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.tap(find.text('找一下'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search-input')), '产品');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.textContaining('日期筛选的产品灵感'), findsOneWidget);
    await tester.tap(find.text('按日期筛选'));
    await tester.pumpAndSettle();
    // Exercise the selected-range boundary; Flutter owns the picker controls.
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
      DateTimeRange(start: DateTime(2099, 1, 1), end: DateTime(2099, 1, 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关记录'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '清除日期条件'));
    await tester.tap(find.widgetWithText(OutlinedButton, '清除日期条件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('日期筛选的产品灵感'), findsOneWidget);
    expect(find.text('按日期筛选'), findsOneWidget);
  });
  testWidgets('小屏两倍字体可核对日历并选择完整提醒选项', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await book.saveText('安排提醒');
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.ensureVisible(find.text('安排提醒'));
    await tester.tap(find.text('安排提醒'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加入日历'));
    await tester.tap(find.text('加入日历'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final reminder = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('开始前 1 小时').last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('请在系统日历中手动设置提醒：开始前 60 分钟'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('请在系统日历中手动设置提醒：开始前 60 分钟'), findsOneWidget);
  });
  testWidgets('系统减少动态效果关闭主题切换动画', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .themeAnimationDuration,
      Duration.zero,
    );
  });
}
