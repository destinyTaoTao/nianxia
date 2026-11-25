import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'support/async_storage_tester.dart';
import 'recording_search_test.dart' show writeWave, TextTranscriber;
import 'support/storage_probe.dart';

void main() {
  late Directory root;
  late Notebook book;
  late Record original;
  late ValueNotifier<String?> shortcut;
  String? copied;
  final editor = find.byKey(const Key('body-editor'));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-edit-conflict-');
    book = await Notebook.open(root);
    original = await book.saveText('原始正文');
    copied = null;
    shortcut = ValueNotifier<String?>(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      shortcut.dispose();
      await book.close();
      await root.delete(recursive: true);
    });
  });
  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book, shortcut: shortcut));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('原始正文'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('编辑正文'));
    await pumpStorageAndSettle(tester);
  }

  Future<void> save(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    await pumpStorageAndSettle(tester);
  }

  testWidgets('正文恢复原样视为未改，返回不确认也不写新revision', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '临时改动');
    await tester.enterText(editor, '原始正文');
    await tester.tap(find.byTooltip('返回'));
    await pumpStorageAndSettle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(editor, findsNothing);
    expect(
      (await storageRead(tester, () => book.get(original.id)))!.revision,
      1,
    );
  });
  testWidgets('CAS冲突保留草稿，可查看新正文及复制，确认载入后用新revision保存', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '我的草稿');
    await storageRead(
      tester,
      () => book.edit(original.id, '另一个新版本', expectedRevision: 1),
    );
    await save(tester);
    expect(find.text('记录已更新，草稿仍保留。'), findsOneWidget);
    expect(tester.widget<TextField>(editor).controller!.text, '我的草稿');
    expect(
      (await storageRead(tester, () => book.get(original.id)))!.body,
      '另一个新版本',
    );
    await tester.tap(find.text('复制我的草稿'));
    await tester.pump();
    expect(copied, '我的草稿');
    await tester.tap(find.text('查看最新内容'));
    await pumpStorageAndSettle(tester);
    expect(find.text('另一个新版本'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('body-editor'), skipOffstage: false),
          )
          .controller!
          .text,
      '我的草稿',
    );
    await tester.tap(find.text('返回草稿'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('载入最新正文'));
    await pumpStorageAndSettle(tester);
    expect(find.text('替换当前草稿？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await pumpStorageAndSettle(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '我的草稿');
    await tester.tap(find.text('载入最新正文'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('替换草稿'));
    await pumpStorageAndSettle(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '另一个新版本');
    await tester.enterText(editor, '核对后的正文');
    await save(tester);
    final saved = await storageRead(tester, () => book.get(original.id));
    expect(saved!.body, '核对后的正文');
    expect(saved.revision, 3);
    expect(editor, findsNothing);
  });
  testWidgets('编辑期间记录被删时保留草稿供复制，不复活或另存记录', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '删除前的草稿');
    await storageRead(tester, () => book.delete(original.id));
    await save(tester);
    expect(find.text('记录已删除，草稿仍保留。'), findsOneWidget);
    expect(tester.widget<TextField>(editor).controller!.text, '删除前的草稿');
    await tester.tap(find.text('复制我的草稿'));
    await tester.pump();
    expect(copied, '删除前的草稿');
    expect(await storageRead(tester, () => book.records), isEmpty);
    expect(find.text('载入最新正文'), findsNothing);
  });
  testWidgets('SQLite保存故障保留输入，移除故障后重试只修改一次', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '故障保留正文');
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_edit BEFORE UPDATE ON records BEGIN SELECT RAISE(ABORT,'synthetic fault'); END",
    );
    await save(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '故障保留正文');
    expect(find.textContaining('保存未完成'), findsOneWidget);
    expect(find.text('记录已更新，草稿仍保留。'), findsNothing);
    StorageProbe(book).execute('DROP TRIGGER fail_edit');
    await save(tester);
    final saved = await storageRead(tester, () => book.get(original.id));
    expect(saved!.body, '故障保留正文');
    expect(saved.revision, 2);
  });
  testWidgets('确认载入期间最新记录又被删除时不销毁我的草稿', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '仍需保留的草稿');
    await storageRead(
      tester,
      () => book.edit(original.id, '较新版本', expectedRevision: 1),
    );
    await save(tester);
    await tester.tap(find.text('载入最新正文'));
    await pumpStorageAndSettle(tester);
    await storageRead(tester, () => book.delete(original.id));
    await tester.tap(find.text('替换草稿'));
    await pumpStorageAndSettle(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '仍需保留的草稿');
    expect(find.text('记录已删除，草稿仍保留。'), findsOneWidget);
    expect(await storageRead(tester, () => book.records), isEmpty);
  });
  testWidgets('320双倍字体与键盘下冲突操作可滚动访问且保留草稿', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await launch(tester);
    await tester.enterText(editor, '窄屏草稿');
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await storageRead(
      tester,
      () => book.edit(original.id, '外部新版本', expectedRevision: 1),
    );
    await save(tester);
    final copy = find.text('复制我的草稿');
    await tester.scrollUntilVisible(
      copy,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(copy.hitTestable(), findsOneWidget);
    await tester.tap(copy);
    await tester.pump();
    expect(copied, '窄屏草稿');
    final reload = find.text('载入最新正文');
    await tester.scrollUntilVisible(
      reload,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(reload.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('编辑音频正文保留只读原始转写和WAV，迟到转写不能覆盖修改', (tester) async {
    await storageRead(tester, () async {
      await book.delete(original.id);
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      final audio = await book.finishCapture(draft);
      await book.transcribe(audio.id, TextTranscriber(Future.value('识别原文')));
      final transcribed = (await book.get(audio.id))!;
      await book.edit(audio.id, '原始正文', expectedRevision: transcribed.revision);
      original = (await book.get(audio.id))!;
    });
    await launch(tester);
    final late = Completer<String>();
    var finished = false;
    final job = book.transcribe(original.id, TextTranscriber(late.future));
    job.then<void>((_) => finished = true);
    for (var i = 0; i < 100; i++) {
      final current = await storageRead(tester, () => book.get(original.id));
      if (current!.transcription == 'running') break;
      await tester.pump();
    }
    await tester.enterText(editor, '我核对后的正文');
    await save(tester);
    late.complete('迟到的新识别');
    for (var i = 0; i < 200 && !finished; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(finished, isTrue);
    await pumpStorageAndSettle(tester);
    final record = (await storageRead(tester, () => book.get(original.id)))!;
    expect(record.body, '我核对后的正文');
    expect(record.transcript, '识别原文');
    expect(record.audio, original.audio);
    expect(record.revision, 4);
    expect(
      await storageRead(tester, () => File(book.audioPath(record)).length()),
      32044,
    );
    await tester.scrollUntilVisible(
      find.text('查看原始转写'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看原始转写'));
    await tester.pumpAndSettle();
    expect(find.text('识别原文'), findsOneWidget);
    expect(find.byKey(const Key('body-editor')), findsNothing);
  });
  testWidgets('保存期间系统查找叠加时只结束本编辑器，不误关查找页或留下busy页面', (tester) async {
    await launch(tester);
    await tester.enterText(editor, '快捷入口期间保存');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '保存'));
    shortcut.value = 'search';
    await pumpStorageAndSettle(tester);
    expect(
      (await storageRead(tester, () => book.get(original.id)))!.body,
      '快捷入口期间保存',
    );
    expect(find.byKey(const Key('search-input')), findsOneWidget);
    expect(editor, findsNothing);
    await tester.tap(find.byType(BackButton));
    await pumpStorageAndSettle(tester);
    expect(editor, findsNothing);
    expect(find.text('快捷入口期间保存'), findsOneWidget);
  });
}
