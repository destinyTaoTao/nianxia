import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';

void main() {
  late Directory root;
  late Notebook book;
  late Record parent;
  late ValueNotifier<String?> shortcut;
  var minute = 0;
  final input = find.byKey(const Key('body-editor'));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-text-append-');
    minute = 0;
    book = await Notebook.open(
      root,
      clock: () => DateTime.utc(2026, 11, 19, 9, minute++),
    );
    parent = await book.saveText('原来的想法\n保留原记录的正文。');
    shortcut = ValueNotifier(null);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await root.delete(recursive: true);
      shortcut.dispose();
    });
  });
  Future<void> append(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book, shortcut: shortcut));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text(parent.title));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('追加内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追加文字'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await pumpStorageAndSettle(tester);
  }

  testWidgets('追加持续显示所属，空白和放弃均不改变原记录', (tester) async {
    await append(tester);
    expect(find.text('追加到：原来的想法'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNull,
    );
    expect((await storageRead(tester, () => book.records)).length, 1);
    await tester.enterText(input, '未保存的补充');
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await pumpStorageAndSettle(tester);
    expect(await storageRead(tester, () => book.childCount(parent.id)), 0);
    expect(
      (await storageRead(tester, () => book.get(parent.id)))!.body,
      parent.body,
    );
  });
  testWidgets('95次追加后保存直接定位本次内容，重复点击只保存一次，前后窗口可继续浏览', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await storageRead(tester, () async {
      for (var i = 0; i < 95; i++) {
        await book.saveText('早先补充$i', parentId: parent.id);
      }
    });
    await append(tester);
    await tester.enterText(input, '本次新增的条件');
    await tester.pumpAndSettle();
    final submit = tester
        .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
        .onPressed!;
    submit();
    submit();
    await pumpStorageAndSettle(tester);
    expect(find.text('本次新增的条件').hitTestable(), findsOneWidget);
    expect(await storageRead(tester, () => book.childCount(parent.id)), 96);
    expect(find.textContaining('刚刚追加'), findsOneWidget);
    // Let the saved notice expire before using the bottom paging action.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('早先补充0'), findsNothing);
    await tester.ensureVisible(find.text('查看更早追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看更早追加'));
    await pumpStorageAndSettle(tester);
    expect(find.text('本次新增的条件'), findsNothing);
    await tester.ensureVisible(find.text('查看更晚追加'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看更晚追加'));
    await pumpStorageAndSettle(tester);
    await tester.ensureVisible(find.text('本次新增的条件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本次新增的条件'));
    await pumpStorageAndSettle(tester);
    expect(find.text('查看所属记录'), findsOneWidget);
    expect(find.text('追加内容'), findsNothing);
  });
  testWidgets('追加保存故障保留正文，重试成功不覆盖原记录', (tester) async {
    await append(tester);
    await tester.enterText(input, '故障后保留的补充');
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_append BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic fault'); END",
    );
    await save(tester);
    expect(tester.widget<TextField>(input).controller!.text, '故障后保留的补充');
    expect(find.textContaining('保存未完成'), findsOneWidget);
    StorageProbe(book).execute('DROP TRIGGER fail_append');
    await save(tester);
    expect(find.text('故障后保留的补充').hitTestable(), findsOneWidget);
    expect(await storageRead(tester, () => book.childCount(parent.id)), 1);
    expect(
      (await storageRead(tester, () => book.get(parent.id)))!.body,
      parent.body,
    );
  });
  testWidgets('父删除保留输入，取消独立确认不写入，主动独立保存才转换', (tester) async {
    await append(tester);
    await tester.enterText(input, '原记录消失时的补充');
    await storageRead(tester, () => book.delete(parent.id));
    await save(tester);
    expect(find.text('原记录已删除，追加内容仍保留。'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '原记录消失时的补充');
    expect(await storageRead(tester, () => book.records), isEmpty);
    await tester.tap(find.text('保存为独立记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await storageRead(tester, () => book.records), isEmpty);
    await tester.tap(find.text('保存为独立记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存为独立记录').last);
    await pumpStorageAndSettle(tester);
    final records = await storageRead(tester, () => book.records);
    expect(records, hasLength(1));
    expect(records.single.parentId, isNull);
    expect(records.single.body, '原记录消失时的补充');
    expect(find.text('原记录消失时的补充'), findsOneWidget);
    expect(await storageRead(tester, () => book.get(parent.id)), isNull);
  });
  testWidgets('320双倍字体和键盘下所属始终可见，保存入口可达', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await append(tester);
    await tester.enterText(input, '窄屏也能补充条件');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    expect(find.text('追加到：原来的想法').hitTestable(), findsOneWidget);
    expect(find.widgetWithText(TextButton, '保存').hitTestable(), findsOneWidget);
    await save(tester);
    expect(find.text('窄屏也能补充条件').hitTestable(), findsOneWidget);
    expect(await storageRead(tester, () => book.childCount(parent.id)), 1);
    expect(tester.takeException(), isNull);
  });
  for (final standalone in [false, true]) {
    testWidgets('保存${standalone ? '独立记录' : '追加'}期间系统查找叠加，返回后仍消费结果身份', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (!standalone) {
        await storageRead(tester, () async {
          for (var i = 0; i < 95; i++) {
            await book.saveText('之前的条件$i', parentId: parent.id);
          }
        });
      }
      await append(tester);
      await tester.enterText(input, '快捷入口期间保存的新内容');
      if (standalone) {
        await storageRead(tester, () => book.delete(parent.id));
        await save(tester);
        await tester.tap(find.text('保存为独立记录'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存为独立记录').last);
      } else {
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, '保存'));
      }
      shortcut.value = 'search';
      await pumpStorageAndSettle(tester);
      expect(find.byKey(const Key('search-input')), findsOneWidget);
      expect(input, findsNothing);
      await tester.tap(find.byType(BackButton));
      await pumpStorageAndSettle(tester);
      expect(find.text('快捷入口期间保存的新内容').hitTestable(), findsOneWidget);
      expect(find.text('记录已删除'), findsNothing);
      final records = await storageRead(tester, () => book.records);
      expect(records.where((v) => v.body == '快捷入口期间保存的新内容'), hasLength(1));
      expect(
        records.singleWhere((v) => v.body == '快捷入口期间保存的新内容').parentId,
        standalone ? null : parent.id,
      );
    });
  }
}
