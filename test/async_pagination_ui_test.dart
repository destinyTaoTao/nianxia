import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'recording_search_test.dart' show UnitEmbedder;
import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';

void main() {
  late Directory home;
  late Notebook book;
  final records = <Record>[];
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-pages-ui-');
    var minute = 0;
    book = await Notebook.open(
      home,
      clock: () => DateTime.utc(2026, 1, 1, 0, minute++),
    );
    records.clear();
    for (var i = 0; i < 95; i++) {
      records.add(await book.saveText('想法$i'));
    }
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });

  testWidgets('跨页浏览后索引和收藏不收缩已加载窗口或丢失滚动位置', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('想法94'), findsOneWidget);
    expect(find.text('想法25'), findsNothing);
    for (var i = 0; i < 35 && find.text('想法25').evaluate().isEmpty; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -650));
      await pumpStorageAndSettle(tester);
    }
    await tester.ensureVisible(find.text('想法25'));
    await pumpStorageAndSettle(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    final position = controller.offset;
    expect(position, greaterThan(1000));
    await storageRead(tester, () => book.index(records[25].id, UnitEmbedder()));
    await pumpStorageAndSettle(tester);
    expect(find.text('想法25'), findsOneWidget);
    expect(controller.offset, closeTo(position, 1));
    await tester.ensureVisible(find.byTooltip('收藏：想法25'));
    await tester.tap(find.byTooltip('收藏：想法25'));
    await pumpStorageAndSettle(tester);
    expect(find.byTooltip('取消收藏：想法25'), findsOneWidget);
    expect(find.text('想法25'), findsOneWidget);
    expect(controller.offset, greaterThan(1000));
    expect(
      (await storageRead(tester, () => book.get(records[25].id)))!.favorite,
      isTrue,
    );
  });

  testWidgets('读取失败明确重试，存储恢复后能加载原有记录', (tester) async {
    StorageProbe(book)
        .execute('ALTER TABLE records RENAME TO temporarily_unavailable');
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('记录未能加载，请重试。'), findsOneWidget);
    StorageProbe(book)
        .execute('ALTER TABLE temporarily_unavailable RENAME TO records');
    await tester.tap(find.text('重试'));
    await pumpStorageAndSettle(tester);
    expect(find.text('想法94'), findsOneWidget);
    expect(find.text('记录未能加载，请重试。'), findsNothing);
    expect((await storageRead(tester, () => book.records)).length, 95);
  });
}
