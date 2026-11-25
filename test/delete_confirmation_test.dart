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
  late Record parent, child;
  late ValueNotifier<String?> shortcut;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-delete-confirm-');
    book = await Notebook.open(root);
    parent = await book.saveText('保留原记录');
    child = await book.saveText('只删这一段', parentId: parent.id);
    shortcut = ValueNotifier(null);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await root.delete(recursive: true);
      shortcut.dispose();
    });
  });
  Future<void> launch(WidgetTester tester, {bool single = false}) async {
    await tester.pumpWidget(NianxiaApp(book: book, shortcut: shortcut));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text(parent.title));
    await pumpStorageAndSettle(tester);
    if (single) {
      await tester.tap(find.text(child.body));
      await pumpStorageAndSettle(tester);
    }
  }

  Future<void> prompt(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除记录'));
    await pumpStorageAndSettle(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpStorageAndSettle(tester);
  }

  testWidgets('取消整组确认不改任何记录或所属', (tester) async {
    try {
      await launch(tester);
      await prompt(tester);
      expect(find.text('删除这组 2 条记录？'), findsOneWidget);
      expect(find.textContaining('包括原记录及其全部追加'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.get(parent.id)), isNotNull);
      expect(await storageRead(tester, () => book.childCount(parent.id)), 1);
      expect(find.text('追加内容'), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('确认期间新增追加使确认失效，留页重新确认后才整组删除', (tester) async {
    try {
      await launch(tester);
      await prompt(tester);
      await storageRead(
        tester,
        () => book.saveText('未确认的新增', parentId: parent.id),
      );
      await tester.tap(find.text('删除'));
      await pumpStorageAndSettle(tester);
      expect(find.text('记录或追加已变化，请重新确认删除范围。'), findsOneWidget);
      expect(await storageRead(tester, () => book.childCount(parent.id)), 2);
      expect(find.text('追加内容'), findsOneWidget);
      await prompt(tester);
      expect(find.text('删除这组 3 条记录？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.records), isEmpty);
      expect(find.byKey(const Key('home-search')), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('真实SQL删除失败留页并保留内容，解除故障可重试', (tester) async {
    try {
      await launch(tester);
      await prompt(tester);
      StorageProbe(book).execute(
        "CREATE TRIGGER reject_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'controlled'); END",
      );
      await tester.tap(find.text('删除'));
      await pumpStorageAndSettle(tester);
      expect(find.text('追加内容'), findsOneWidget);
      expect(await storageRead(tester, () => book.childCount(parent.id)), 1);
      StorageProbe(book).execute('DROP TRIGGER reject_delete');
      await prompt(tester);
      await tester.tap(find.text('删除'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.records), isEmpty);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('单次追加删除明确保留原记录和日历，成功回所属详情', (tester) async {
    try {
      await launch(tester, single: true);
      await prompt(tester);
      expect(find.text('删除这次追加？'), findsOneWidget);
      expect(find.textContaining('所属原记录和其他追加会保留'), findsOneWidget);
      expect(find.textContaining('已加入系统日历的事件保持不变'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.get(child.id)), isNull);
      expect(
        (await storageRead(tester, () => book.get(parent.id)))!.body,
        parent.body,
      );
      expect(find.text('追加内容'), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('确认提交期间系统查找叠加，成功不能误关查找页', (tester) async {
    try {
      await launch(tester);
      await prompt(tester);
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '删除'))
          .onPressed!();
      shortcut.value = 'search';
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.records), isEmpty);
      expect(find.byKey(const Key('search-input')), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('320双倍字体确认完整解释且取消删除均可达', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      await launch(tester);
      await prompt(tester);
      await tester.ensureVisible(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('取消').hitTestable(), findsOneWidget);
      expect(find.text('删除').hitTestable(), findsOneWidget);
      await tester.tap(find.text('取消'));
      await pumpStorageAndSettle(tester);
      expect(tester.takeException(), isNull);
      expect(await storageRead(tester, () => book.childCount(parent.id)), 1);
    } finally {
      await unmount(tester);
    }
  });
}
