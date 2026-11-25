import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';
import 'package:nianxia/domain/search_page.dart' as paging;

import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';
import 'support/ui_native_capture.dart';

import 'package:nianxia/app/capture_session_controller.dart';

import 'support/search_runtime.dart';

void main() {
  late Directory root;
  late Notebook book;
  var now = DateTime(2026, 11, 19, 10);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-explicit-search-');
    now = DateTime(2026, 11, 19, 10);
    book = await Notebook.open(root, clock: () => now);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await root.delete(recursive: true);
    });
  });
  final input = find.byKey(const Key('search-input'));
  Future<void> tick(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 500 && !ready(); i++) {
      await tick(tester);
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
    await tester.pump();
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.widgetWithText(FilledButton, '查找'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '查找'));
    await tick(tester);
  }

  testWidgets('输入不自动查找，键盘提交才展示结果，清空立即撤销结果', (tester) async {
    await storageRead(tester, () => book.saveText('离线缓存方案'));
    await launch(tester);
    await tester.enterText(input, '缓存');
    await tester.pump(const Duration(seconds: 1));
    await pumpStorageAndSettle(tester);
    expect(find.byType(SearchSummaryRow), findsNothing);
    expect(find.text('没有找到相关记录'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => find.text('离线缓存方案').evaluate().isNotEmpty);
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.byTooltip('清空查找内容'));
    await tester.pump();
    expect(find.byType(SearchSummaryRow), findsNothing);
    expect(find.text('找回之前的想法'), findsOneWidget);
  });
  testWidgets('改词保留旧结果并注明所属查询，失败保留输入和旧结果，恢复后可重试', (tester) async {
    await storageRead(tester, () => book.saveText('缓存一致性方案'));
    await storageRead(tester, () => book.saveText('离线存储方案'));
    await launch(tester);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await until(tester, () => find.text('缓存一致性方案').evaluate().isNotEmpty);
    await tester.enterText(input, '离线');
    await tester.pump(const Duration(seconds: 1));
    await pumpStorageAndSettle(tester);
    expect(find.text('缓存一致性方案'), findsOneWidget);
    expect(find.textContaining('尚未更新'), findsWidgets);
    expect(find.textContaining('“缓存”'), findsOneWidget);
    StorageProbe(book)
        .execute('ALTER TABLE records RENAME TO source_unavailable');
    await submit(tester);
    await until(tester, () => find.text('重试查找').evaluate().isNotEmpty);
    expect(tester.widget<TextField>(input).controller!.text, '离线');
    expect(find.text('缓存一致性方案'), findsOneWidget);
    expect(find.text('没有找到相关记录'), findsNothing);
    StorageProbe(book)
        .execute('ALTER TABLE source_unavailable RENAME TO records');
    await tester.ensureVisible(find.text('重试查找'));
    await tester.tap(find.text('重试查找'));
    await until(tester, () => find.text('离线存储方案').evaluate().isNotEmpty);
    expect(find.text('缓存一致性方案'), findsNothing);
  });
  testWidgets('日期快捷项包含日历端点并按各记录创建offset筛选', (tester) async {
    Future<void> seed(String title, DateTime instant, int offset) async {
      now = instant;
      final row = await book.saveText(title);
      StorageProbe(book).execute(
        'UPDATE records SET offset_minutes=? WHERE id=?',
        [offset, row.id],
      );
    }

    await storageRead(tester, () async {
      await seed('缓存七天起点', DateTime.utc(2026, 11, 13), 0);
      await seed('缓存起点之前', DateTime.utc(2026, 11, 12, 23, 59, 59), 0);
      await seed('缓存东八跨日', DateTime.utc(2026, 11, 18, 16, 30), 480);
      await seed('缓存西一跨日', DateTime.utc(2026, 11, 19, 0, 30), -60);
      await seed('缓存今天末尾', DateTime.utc(2026, 11, 19, 23, 59, 59), 0);
      await seed('缓存明天', DateTime.utc(2026, 11, 20), 0);
    });
    now = DateTime(2026, 11, 19, 10);
    await launch(tester);
    await tester.enterText(input, '缓存');
    await tester.tap(find.byKey(const Key('search-date-today')));
    await pumpStorageAndSettle(tester);
    expect(find.byType(SearchSummaryRow), findsNothing);
    await submit(tester);
    await until(tester, () => find.text('缓存东八跨日').evaluate().isNotEmpty);
    expect(find.text('缓存今天末尾'), findsOneWidget);
    expect(find.text('缓存西一跨日'), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('search-date-week')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('search-date-week')));
    await until(tester, () => find.text('找到 4 条记录').evaluate().isNotEmpty);
    expect(find.text('缓存西一跨日'), findsOneWidget);
    expect(find.text('缓存起点之前'), findsNothing);
    expect(find.text('缓存明天'), findsNothing);
    expect(find.text('找到 4 条记录'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('缓存七天起点'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('缓存七天起点'), findsOneWidget);
  });
  testWidgets('日期应用沿用已确认词而不丢新草稿，自定义取消不改变筛选', (tester) async {
    await storageRead(tester, () => book.saveText('缓存今天'));
    await storageRead(tester, () => book.saveText('离线今天'));
    await launch(tester);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await until(tester, () => find.text('缓存今天').evaluate().isNotEmpty);
    await tester.enterText(input, '离线');
    await tester.tap(find.byKey(const Key('search-date-today')));
    await until(
      tester,
      () => find.textContaining('“缓存” · 2026/11/19').evaluate().isNotEmpty,
    );
    expect(tester.widget<TextField>(input).controller!.text, '离线');
    expect(find.text('离线今天'), findsNothing);
    expect(find.textContaining('尚未更新'), findsWidgets);
    await tester.tap(find.byKey(const Key('search-date-custom')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('search-date-today')))
          .selected,
      isTrue,
    );
    await submit(tester);
    await until(tester, () => find.text('离线今天').evaluate().isNotEmpty);
    await tester.tap(find.byKey(const Key('search-date-custom')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
      DateTimeRange(start: DateTime(2099, 1, 1), end: DateTime(2099, 1, 2)),
    );
    await until(tester, () => find.text('没有找到相关记录').evaluate().isNotEmpty);
    await tester.ensureVisible(find.text('清除日期条件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除日期条件'));
    await until(tester, () => find.text('离线今天').evaluate().isNotEmpty);
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('search-date-all')))
          .selected,
      isTrue,
    );
  });
  testWidgets('迟到推理不能覆盖编辑或清空，新查询加载保留明确标识的旧结果', (tester) async {
    await storageRead(tester, () => book.saveText('缓存旧结果'));
    await storageRead(tester, () => book.saveText('离线新结果'));
    final runtime = SearchRuntime();
    final endpoint = UiCaptureEndpoint(book);
    final capture = CaptureSessionController(endpoint, book, runtime);
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await until(tester, () => runtime.pending.containsKey('缓存'));
    await tester.enterText(input, '离线');
    runtime.pending['缓存']!.complete([1, 0]);
    await pumpStorageAndSettle(tester);
    expect(find.byType(SearchSummaryRow), findsNothing);
    await submit(tester);
    await until(tester, () => runtime.pending.containsKey('离线'));
    runtime.pending['离线']!.complete([1, 0]);
    await until(tester, () => find.text('离线新结果').evaluate().isNotEmpty);
    await tester.enterText(input, '新词');
    await submit(tester);
    await until(tester, () => runtime.pending.containsKey('新词'));
    expect(find.text('离线新结果'), findsOneWidget);
    expect(find.textContaining('“离线”'), findsOneWidget);
    expect(find.textContaining('尚未更新'), findsWidgets);
    await tester.tap(find.byTooltip('清空查找内容'));
    await tester.pump();
    runtime.pending['新词']!.complete([1, 0]);
    await pumpStorageAndSettle(tester);
    expect(find.byType(SearchSummaryRow), findsNothing);
    expect(find.text('找回之前的想法'), findsOneWidget);
    expect(await storageRead(tester, () => book.records), hasLength(2));
  });
  testWidgets('语义推理失败降级关键词，仍能正确找到来源', (tester) async {
    await storageRead(tester, () => book.saveText('关键词保留原文'));
    final runtime = SearchRuntime()..unavailable = true;
    final capture = CaptureSessionController(
      UiCaptureEndpoint(book),
      book,
      runtime,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '关键词');
    await submit(tester);
    await until(tester, () => find.text('关键词保留原文').evaluate().isNotEmpty);
    expect(find.textContaining('已使用关键词查找'), findsOneWidget);
  });
  testWidgets('跨页详情返回保留输入日期和位置，资料变化刷新保留已加载窗口', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Record target;
    await storageRead(tester, () async {
      for (var i = 0; i < 95; i++) {
        now = DateTime(2026, 11, 19, 9, i);
        final row = await book.saveText('列表线索$i');
        if (i == 40) target = row;
      }
    });
    await launch(tester);
    await tester.enterText(input, '列表线索');
    await submit(tester);
    await until(tester, () => find.text('已显示 40 条记录').evaluate().isNotEmpty);
    final list = find.byKey(const Key('search-scroll'));
    for (var i = 0; i < 35 && find.text('列表线索40').evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -650));
      await pumpStorageAndSettle(tester);
    }
    await tester.ensureVisible(find.text('列表线索40'));
    await tester.pumpAndSettle();
    final controller = tester.widget<CustomScrollView>(list).controller!;
    final position = controller.offset;
    expect(position, greaterThan(1000));
    await tester.tap(find.text('列表线索40'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byType(BackButton));
    await pumpStorageAndSettle(tester);
    expect(controller.offset, closeTo(position, 1));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('search-input'), skipOffstage: false),
          )
          .controller!
          .text,
      '列表线索',
    );
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.tap(find.text('列表线索40'));
    await pumpStorageAndSettle(tester);
    await storageRead(
      tester,
      () =>
          book.edit(target.id, '列表线索40已核对', expectedRevision: target.revision),
    );
    await tester.tap(find.byType(BackButton));
    await until(tester, () => find.text('列表线索40已核对').evaluate().isNotEmpty);
    await pumpStorageAndSettle(tester);
    expect(controller.offset, closeTo(position, 1));
    final refreshNotice = find.descendant(
      of: find.byType(SnackBar),
      matching: find.text('记录已变化，已重新查找。'),
    );
    await until(tester, () => refreshNotice.evaluate().isNotEmpty);
    expect(refreshNotice, findsOneWidget);
  });
  testWidgets('320双倍字体与键盘下日期和无键盘提交入口仍可滚动访问', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await storageRead(tester, () => book.saveText('窄屏缓存来源'));
    await launch(tester);
    await tester.enterText(input, '缓存');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('search-date-custom')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('search-date-custom')).hitTestable(),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('search-submit')),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('search-submit')).hitTestable(),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('search-submit')));
    await pumpStorageAndSettle(tester);
    await tester.scrollUntilVisible(
      find.text('窄屏缓存来源'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('窄屏缓存来源').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('日期旧词查询加载时，页面按钮可提交已修改的新词', (tester) async {
    await storageRead(tester, () => book.saveText('缓存旧结果'));
    await storageRead(tester, () => book.saveText('离线新结果'));
    final runtime = SearchRuntime(holdQueries: false);
    final capture = CaptureSessionController(
      UiCaptureEndpoint(book),
      book,
      runtime,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await until(tester, () => find.text('缓存旧结果').evaluate().isNotEmpty);
    await tester.enterText(input, '离线');
    runtime.holdQueries = true;
    await tester.tap(find.byKey(const Key('search-date-today')));
    await until(tester, () => runtime.pending.containsKey('缓存'));
    final button = find.byKey(const Key('search-submit'));
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(
      find.descendant(of: button, matching: find.text('查找')),
      findsOneWidget,
    );
    await tester.tap(button);
    await until(tester, () => runtime.pending.containsKey('离线'));
    runtime.pending['离线']!.complete([1, 0]);
    await until(tester, () => find.text('离线新结果').evaluate().isNotEmpty);
    runtime.pending['缓存']!.complete([1, 0]);
    await pumpStorageAndSettle(tester);
    expect(find.text('缓存旧结果'), findsNothing);
    expect(find.textContaining('“离线”'), findsOneWidget);
  });
  testWidgets('分页游标淘汰后重算立即标旧，成功说明刷新而非声称资料变化', (tester) async {
    await storageRead(tester, () async {
      for (var i = 0; i < 55; i++) {
        await book.saveText('分页线索$i');
      }
    });
    final runtime = SearchRuntime(holdQueries: false);
    final capture = CaptureSessionController(
      UiCaptureEndpoint(book),
      book,
      runtime,
    );
    addTearDown(() {
      capture.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await pumpStorageAndSettle(tester);
    await tester.enterText(input, '分页线索');
    await submit(tester);
    await until(tester, () => find.text('已显示 40 条记录').evaluate().isNotEmpty);
    await storageRead(tester, () async {
      await book.searchPage(paging.SearchQuery(text: '额外查找一'));
      await book.searchPage(paging.SearchQuery(text: '额外查找二'));
    });
    runtime.holdQueries = true;
    final list = find.byKey(const Key('search-scroll'));
    final controller = tester.widget<CustomScrollView>(list).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await until(tester, () => runtime.pending.containsKey('分页线索'));
    controller.jumpTo(0);
    await tester.pump();
    expect(find.textContaining('尚未更新'), findsOneWidget);
    runtime.pending['分页线索']!.complete([1, 0]);
    await until(
      tester,
      () => find.text('查找已刷新，已重新载入结果。').evaluate().isNotEmpty,
    );
    expect(find.text('记录已变化，已重新查找。'), findsNothing);
    expect(find.text('没有找到相关记录'), findsNothing);
  });
  testWidgets('后续页失败在列表尾部提供可见重试，游标重启后仍能继续分页', (tester) async {
    await storageRead(tester, () async {
      for (var i = 0; i < 65; i++) {
        await book.saveText('分页故障$i');
      }
    });
    await launch(tester);
    await tester.enterText(input, '分页故障');
    await submit(tester);
    await until(tester, () => find.text('已显示 40 条记录').evaluate().isNotEmpty);
    StorageProbe(book)
        .execute('ALTER TABLE records RENAME TO source_unavailable');
    final list = find.byKey(const Key('search-scroll'));
    final controller = tester.widget<CustomScrollView>(list).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await pumpStorageAndSettle(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('后续记录未能加载').hitTestable(), findsOneWidget);
    expect(find.text('重试查找').hitTestable(), findsOneWidget);
    StorageProbe(book)
        .execute('ALTER TABLE source_unavailable RENAME TO records');
    await tester.tap(find.text('重试查找'));
    await pumpStorageAndSettle(tester);
    controller.jumpTo(controller.position.maxScrollExtent);
    await pumpStorageAndSettle(tester);
    final more = find.text('继续加载');
    if (more.evaluate().isNotEmpty) {
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await pumpStorageAndSettle(tester);
    }
    controller.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.text('找到 65 条记录'), findsOneWidget);
    expect(find.text('重试查找'), findsNothing);
  });
  testWidgets('长组合字符草稿不会破坏已有结果或日期呈现，提交可解释拒绝', (tester) async {
    await storageRead(tester, () => book.saveText('缓存原始结果'));
    await launch(tester);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await until(tester, () => find.text('缓存原始结果').evaluate().isNotEmpty);
    final draft = 'a${'\u0301' * 10001}';
    await tester.enterText(input, draft);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('search-date-today')));
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('search-submit')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('查找文字过长，请缩短后重试。'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, draft);
    expect(find.text('缓存原始结果'), findsOneWidget);
    await tester.enterText(input, '缓存');
    await submit(tester);
    await pumpStorageAndSettle(tester);
    expect(find.text('查找文字过长，请缩短后重试。'), findsNothing);
  });
}
