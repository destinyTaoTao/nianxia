import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/settings.dart';
import 'package:nianxia/ui/detail.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';
import 'support/async_storage_tester.dart';

class CheckingStore extends ModelStore {
  CheckingStore(Directory home)
    : super(home, [
        const ModelSpec(
          id: 'sensevoice',
          version: 'fixture',
          label: '离线语音',
          files: [],
        ),
      ]);
  final checked = Completer<bool>();
  @override
  Future<bool> ready(String id) => checked.future;
}

class VoiceOnlyStore extends ModelStore {
  VoiceOnlyStore(Directory home) : super(home, []);
  @override
  Future<bool> ready(String id) async => id == 'sensevoice';
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-ui-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });
  testWidgets('无正文的录音详情区分待处理、处理中和失败，不误报等待', (tester) async {
    late Record record;
    await tester.runAsync(() async {
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      record = await book.finishCapture(draft);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: DetailPage(book: book, id: record.id),
      ),
    );
    await pumpStorageAndSettle(tester);
    expect(find.text('音频已保存，等待转写。'), findsOneWidget);
    (await storageRead(
      tester,
      () => book.repository.transcriptionState(record.id, 'failed'),
    ));
    book.changed();
    await pumpStorageAndSettle(tester);
    expect(find.text('这段录音暂未转写成功，原音频已保留。'), findsOneWidget);
    expect(find.text('音频已保存，等待转写。'), findsNothing);
    (await storageRead(
      tester,
      () => book.repository.transcriptionState(record.id, 'running'),
    ));
    book.changed();
    await pumpStorageAndSettle(tester);
    expect(find.text('正在转写，请稍候。'), findsOneWidget);
    expect(find.text('重新转写'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('合法JSON但字段损坏的整理缓存不影响打开详情', (tester) async {
    late Record record;
    await tester.runAsync(() async {
      record = await book.saveText('坏缓存不能隐藏原文');
    });
    StorageProbe(book).execute(
      'INSERT INTO record_organizations VALUES(?,1,1,?,?)',
      [record.id, 'organization-v1', '{"title":1}'],
    );
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('坏缓存不能隐藏原文'));
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('编辑正文'), findsOneWidget);
    expect(find.text('坏缓存不能隐藏原文'), findsOneWidget);
  });

  testWidgets('校验已有本地模型期间不提供重复下载入口', (tester) async {
    final store = CheckingStore(Directory('${home.path}/models'));
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          book: book,
          models: LocalModels(store),
          themeMode: ThemeMode.dark,
          onTheme: (_) => true,
          modelsFirst: true,
        ),
      ),
    );
    await pumpStorageAndSettle(tester);
    expect(find.widgetWithText(OutlinedButton, '下载模型'), findsNothing);
    expect(find.text('正在检查本地模型…'), findsOneWidget);
    store.checked.complete(true);
    await pumpStorageAndSettle(tester);
    expect(find.text('已就绪，可离线使用'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '下载模型'), findsNothing);
  });
  testWidgets('切换浅色后重新打开应用仍保留选择', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('切换浅色主题'));
    await pumpStorageAndSettle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await book.close();
      book = await Notebook.open(home);
    });
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.byTooltip('切换深色主题'), findsOneWidget);
  });
  testWidgets('主题写入失败时保留设置选择并告知重试', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('设置'));
    await pumpStorageAndSettle(tester);
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_theme BEFORE INSERT ON metadata WHEN NEW.key='theme_mode' BEGIN SELECT RAISE(ABORT,'theme write failure'); END",
    );
    addTearDown(() => StorageProbe(book).execute('DROP TRIGGER fail_theme'));
    await tester.tap(find.text('深色'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('浅色').last);
    await pumpStorageAndSettle(tester);
    expect(find.text('主题设置未保存，请重试。'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('浅色'), findsNothing);
  });
  testWidgets('首页可滚动找回所有主记录，底部记录入口始终可用', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await book.close();
      var minute = 0;
      book = await Notebook.open(
        home,
        clock: () => DateTime.utc(2026, 11, 9, 9, minute++),
      );
      for (var i = 1; i <= 12; i++) {
        await book.saveText('想法 $i');
      }
    });
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('记一下').hitTestable(), findsOneWidget);
    expect(find.text('写文字'), findsOneWidget);
    expect(find.text('找一下'), findsOneWidget);
    expect(find.text('想法 12'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('想法 1'), 350);
    await pumpStorageAndSettle(tester);
    expect(find.text('想法 1').hitTestable(), findsOneWidget);
    expect(find.text('记一下').hitTestable(), findsOneWidget);
    expect(find.text('写文字').hitTestable(), findsOneWidget);
    await tester.tap(find.text('想法 1'));
    await pumpStorageAndSettle(tester);
    expect(find.byTooltip('编辑正文'), findsOneWidget);
  });
  testWidgets('Android 日历入口明确说明提醒仍需在系统页手动设置', (tester) async {
    await tester.runAsync(() => book.saveText('待安排的模拟器验收事项'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('待安排的模拟器验收事项'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('加入日历'));
    await pumpStorageAndSettle(tester);
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
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('开始时').last);
    await pumpStorageAndSettle(tester);
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
    await pumpStorageAndSettle(tester);
    expect(find.text('离线转写尚未就绪'), findsOneWidget);
    await tester.tap(find.text('准备语音转写'));
    await pumpStorageAndSettle(tester);
    for (
      var i = 0;
      i < 50 && find.widgetWithText(OutlinedButton, '下载模型').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text('离线模型').hitTestable(), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, '下载模型').hitTestable(),
      findsOneWidget,
    );
    await tester.runAsync(() => store.download('sensevoice'));
    await tester.tap(find.byTooltip('返回'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await pumpStorageAndSettle(tester);
    expect(find.text('离线转写尚未就绪'), findsNothing);
    expect(find.text('记一下'), findsOneWidget);
  });
  testWidgets('用户可从文字入口保存、查看、编辑并查找记录', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    expect(find.text('记一下'), findsOneWidget);
    expect(find.text('找一下'), findsOneWidget);
    await tester.tap(find.text('写文字'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('body-editor')), '这是一条产品灵感');
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(find.text('这是一条产品灵感'), findsOneWidget);
    await tester.tap(find.text('这是一条产品灵感'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('编辑正文'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(
      find.byKey(const Key('body-editor')),
      '这是一条 SQLite 灵感',
    );
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(find.text('这是一条 SQLite 灵感'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('search-input')), 'sqlite');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('这是一条 SQLite 灵感'), findsOneWidget);
  });
  testWidgets('收藏追加记录后可从收藏入口找回所属内容', (tester) async {
    final parent = await storageRead(tester, () => book.saveText('原始想法'));
    final child = await storageRead(
      tester,
      () => book.saveText('值得收藏的追加', parentId: parent.id),
    );
    await storageRead(tester, () => book.favorite(child.id, true));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('收藏'));
    await pumpStorageAndSettle(tester);
    expect(find.text('值得收藏的追加'), findsOneWidget);
    await tester.tap(find.text('值得收藏的追加'));
    await pumpStorageAndSettle(tester);
    expect(find.text('查看所属记录'), findsOneWidget);
  });
  testWidgets('便笺可直接收藏，切换主题和筛选仍保留收藏结果', (tester) async {
    final keep = await storageRead(tester, () => book.saveText('值得留下'));
    await storageRead(tester, () => book.saveText('暂时不收藏'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('收藏：值得留下'));
    await pumpStorageAndSettle(tester);
    expect(
      (await storageRead(tester, () => book.get(keep.id)))!.favorite,
      isTrue,
    );
    await tester.tap(find.text('收藏'));
    await pumpStorageAndSettle(tester);
    expect(find.text('值得留下'), findsOneWidget);
    expect(find.text('暂时不收藏'), findsNothing);
    await tester.tap(find.byTooltip('切换浅色主题'));
    await pumpStorageAndSettle(tester);
    expect(
      Theme.of(tester.element(find.text('值得留下'))).brightness,
      Brightness.light,
    );
    expect(find.text('暂时不收藏'), findsNothing);
    await tester.tap(find.byTooltip('取消收藏：值得留下'));
    await pumpStorageAndSettle(tester);
    expect(
      (await storageRead(tester, () => book.get(keep.id)))!.favorite,
      isFalse,
    );
    expect(find.text('还没有收藏'), findsOneWidget);
    await tester.tap(find.text('全部'));
    await pumpStorageAndSettle(tester);
    expect(find.text('值得留下'), findsOneWidget);
  });
  testWidgets('收藏视图取消文字记录保持筛选，成功保存后显示新记录', (tester) async {
    final keep = await storageRead(tester, () => book.saveText('原来的收藏'));
    await storageRead(tester, () => book.favorite(keep.id, true));
    await storageRead(tester, () => book.saveText('未收藏的已有记录'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('收藏'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('写文字'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('返回'));
    await pumpStorageAndSettle(tester);
    expect(find.text('未收藏的已有记录'), findsNothing);
    await tester.tap(find.text('写文字'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('body-editor')), '刚保存的新想法');
    await tester.tap(find.text('保存'));
    // Frame idleness does not imply that the storage isolate has replied.
    // The editor also contains the new text, so wait for its actual list row.
    final savedRow = find.byTooltip('收藏：刚保存的新想法');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      await pumpStorageAndSettle(tester);
    } while (savedRow.evaluate().isEmpty && DateTime.now().isBefore(deadline));
    expect(savedRow, findsOneWidget);
    expect(find.byKey(const Key('body-editor')), findsNothing);
    expect(find.text('刚保存的新想法').hitTestable(), findsOneWidget);
    expect(
      (await storageRead(tester, () => book.get(keep.id)))!.favorite,
      isTrue,
    );
    expect(find.text('未收藏的已有记录'), findsOneWidget);
  });
  testWidgets('收藏视图录音启动失败转文字后，新保存内容可见', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('app.nianxia/system');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final keep = await storageRead(tester, () => book.saveText('保留的收藏'));
    await storageRead(tester, () => book.favorite(keep.id, true));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('收藏'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('记一下'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await pumpStorageAndSettle(tester);
    await tester.ensureVisible(find.text('写文字').last);
    await tester.tap(find.text('写文字').last);
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('body-editor')), '失败回退后保存的文字');
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(find.text('失败回退后保存的文字').hitTestable(), findsOneWidget);
    expect(
      (await storageRead(tester, () => book.get(keep.id)))!.favorite,
      isTrue,
    );
  });
  testWidgets('首页摘要保留正文实际重复的首行', (tester) async {
    await storageRead(tester, () => book.saveText('先核对条件\n先核对条件\n再决定方案'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(find.text('先核对条件\n再决定方案'), findsOneWidget);
  });
  testWidgets('详情固定追加入口保存独立内容，原正文与所属关系不变', (tester) async {
    final parent = await storageRead(tester, () => book.saveText('先保存原来的想法'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('先保存原来的想法'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('追加内容'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('追加文字'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('body-editor')), '后来补充的条件');
    await tester.tap(find.text('保存'));
    await pumpStorageAndSettle(tester);
    expect(
      (await storageRead(tester, () => book.get(parent.id)))!.body,
      '先保存原来的想法',
    );
    expect(
      (await storageRead(tester, () => book.children(parent.id))).single.body,
      '后来补充的条件',
    );
    expect(
      (await storageRead(
        tester,
        () => book.children(parent.id),
      )).single.parentId,
      parent.id,
    );
    await tester.ensureVisible(find.text('后来补充的条件'));
    await tester.tap(find.text('后来补充的条件'));
    await pumpStorageAndSettle(tester);
    expect(find.text('查看所属记录'), findsOneWidget);
  });
  testWidgets('查找可一键清空，清空后不显示旧结果', (tester) async {
    await storageRead(tester, () => book.saveText('离线查找的产品灵感'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '产品');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
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
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
  });
  testWidgets('输入时保留键盘，明确查找后收起键盘显示结果', (tester) async {
    await storageRead(tester, () => book.saveText('键盘交互的离线记录'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '离线');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, '查找'));
    await pumpStorageAndSettle(tester);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('键盘交互的离线记录'), findsOneWidget);
  });
  testWidgets('命中标题的多行记录保留正文摘要，不重复显示标题', (tester) async {
    await storageRead(tester, () => book.saveText('缓存方案还需要验证\n先验证一致性，再决定方案。'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '缓存');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('缓存方案还需要验证'), findsOneWidget);
    expect(find.textContaining('先验证一致性，再决定方案。'), findsOneWidget);
  });
  testWidgets('语音返回的查询可先修改，确认前不显示结果且不新建笔记', (tester) async {
    await storageRead(tester, () => book.saveText('缓存的一点想法'));
    await storageRead(tester, () => book.saveText('离线查找的灵感'));
    final store = VoiceOnlyStore(Directory('${home.path}/models'));
    addTearDown(store.dispose);
    const channel = MethodChannel('app.nianxia/system');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The route result is the boundary under test; do not start a host microphone.
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(NianxiaApp(book: book, models: LocalModels(store)));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('语音查找'));
    // Only complete the route entrance, not the native recorder's progress loop.
    await tester.pump(const Duration(milliseconds: 300));
    Navigator.of(tester.element(find.text('说出要找的内容'))).pop('缓存');
    await pumpStorageAndSettle(tester);
    expect(find.text('识别文字可以修改，确认后点“查找”。'), findsOneWidget);
    expect(find.text('缓存的一点想法'), findsNothing);
    await tester.enterText(find.byKey(const Key('search-input')), '离线');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(find.text('离线查找的灵感'), findsNothing);
    await tester.tap(find.text('查找'));
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(find.text('离线查找的灵感'), findsOneWidget);
    expect((await storageRead(tester, () => book.records)).length, 2);
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
    await pumpStorageAndSettle(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('找回之前的想法'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpStorageAndSettle(tester);
    expect(find.text('找回之前的想法').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('按日期筛选'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await pumpStorageAndSettle(tester);
    expect(find.text('按日期筛选').hitTestable(), findsOneWidget);
  });
  testWidgets('日期限制无结果时，可从提示清除条件并找回记录', (tester) async {
    await storageRead(tester, () => book.saveText('日期筛选的产品灵感'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('找一下'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(find.byKey(const Key('search-input')), '产品');
    await tester.pump(const Duration(milliseconds: 400));
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('日期筛选的产品灵感'), findsOneWidget);
    await tester.tap(find.text('按日期筛选'));
    await pumpStorageAndSettle(tester);
    // Exercise the selected-range boundary; Flutter owns the picker controls.
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop(
      DateTimeRange(start: DateTime(2099, 1, 1), end: DateTime(2099, 1, 2)),
    );
    await pumpStorageAndSettle(tester);
    expect(find.text('没有找到相关记录'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(OutlinedButton, '清除日期条件'));
    await tester.tap(find.widgetWithText(OutlinedButton, '清除日期条件'));
    await pumpStorageAndSettle(tester);
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
    await storageRead(tester, () => book.saveText('安排提醒'));
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.ensureVisible(find.text('安排提醒'));
    await tester.tap(find.text('安排提醒'));
    await pumpStorageAndSettle(tester);
    await tester.ensureVisible(find.text('加入日历'));
    await tester.tap(find.text('加入日历'));
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    final reminder = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('开始前 1 小时').last);
    await pumpStorageAndSettle(tester);
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
    await pumpStorageAndSettle(tester);
    expect(
      tester
          .widget<MaterialApp>(find.byType(MaterialApp))
          .themeAnimationDuration,
      Duration.zero,
    );
  });
}
