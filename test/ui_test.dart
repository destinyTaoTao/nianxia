import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
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
  testWidgets('Android 日历入口明确说明提醒仍需在系统页手动设置', (tester) async {
    await tester.runAsync(() => book.saveText('待安排的模拟器验收事项'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await tester.tap(find.text('待安排的模拟器验收事项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入日历'));
    await tester.pumpAndSettle();
    expect(find.text('计划提醒时间'), findsOneWidget);
    expect(find.textContaining('本页尚未设置提醒'), findsOneWidget);
    final reminder = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始时').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('请在系统日历中手动设置提醒：开始时'), findsOneWidget);
  });
  testWidgets('用户可从文字入口保存、查看、编辑并查找记录', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    expect(find.text('记一下'), findsOneWidget);
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
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.text('值得收藏的追加'), findsOneWidget);
    await tester.tap(find.text('值得收藏的追加'));
    await tester.pumpAndSettle();
    expect(find.text('查看所属记录'), findsOneWidget);
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
