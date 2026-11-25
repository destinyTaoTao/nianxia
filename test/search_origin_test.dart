import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';

import 'playback_coordination_test.dart' show OutputFixture;
import 'recording_search_test.dart' show TextTranscriber, writeWave;
import 'support/async_storage_tester.dart';

void main() {
  late Directory root;
  late Notebook book;
  late Record parent, audio;
  late OutputFixture device;
  late PlaybackCoordinator playback;
  var minute = 0;
  final input = find.byKey(const Key('search-input'));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-search-origin-');
    minute = 0;
    book = await Notebook.open(
      root,
      clock: () => DateTime.utc(2026, 11, 20, 9, minute++),
    );
    parent = await book.saveText('原记录的条件\n保留这个来源，不自动补造结论。');
    final draft = await book.beginCapture(parentId: parent.id);
    await writeWave(draft.path);
    audio = await book.finishCapture(draft);
    await book.transcribe(
      audio.id,
      TextTranscriber(Future.value('线索关键补充\n这次追加保留自己的原音。')),
    );
    audio = (await book.get(audio.id))!;
    await book.saveText('线索关键文字\n文字项不显示音频按钮。');
    device = OutputFixture();
    playback = PlaybackCoordinator.retain(book, output: device);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await playback.release();
      await book.close();
      await root.delete(recursive: true);
    });
  });
  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 150 && !ready(); i++) {
      await pumpStorageAndSettle(tester);
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
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byKey(const Key('home-search')));
    await tester.pumpAndSettle();
    await tester.enterText(input, '线索关键');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await until(tester, () => find.textContaining('找到 ').evaluate().isNotEmpty);
  }

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final list = find.byKey(const Key('search-scroll'));
    final scroll = tester.widget<CustomScrollView>(list).controller!;
    scroll.jumpTo(0);
    await pumpStorageAndSettle(tester);
    for (var i = 0; i < 60 && target.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, -300));
      await pumpStorageAndSettle(tester);
    }
    expect(target, findsOneWidget);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpStorageAndSettle(tester);
  }

  testWidgets('所属链接打开原记录，命中标题打开追加，返回保留查询且不预载音频', (tester) async {
    try {
      await launch(tester);
      await reveal(tester, find.text('所属：原记录的条件'));
      expect(find.text('所属：原记录的条件'), findsOneWidget);
      expect(find.byKey(ValueKey('result-play-${audio.id}')), findsOneWidget);
      expect(device.loads, isEmpty);
      await tester.ensureVisible(find.text('所属：原记录的条件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所属：原记录的条件'));
      await pumpStorageAndSettle(tester);
      expect(find.text('原记录的条件'), findsOneWidget);
      expect(find.text('查看所属记录'), findsNothing);
      await tester.tap(find.byType(BackButton));
      await pumpStorageAndSettle(tester);
      expect(tester.widget<TextField>(input).controller!.text, '线索关键');
      await tester.tap(find.text('线索关键补充'));
      await pumpStorageAndSettle(tester);
      expect(find.text('查看所属记录'), findsOneWidget);
      expect(find.text('追加内容'), findsNothing);
      expect(device.loads, isEmpty);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('音频按需播放、暂停及两条互斥，清空查找停止旧回放', (tester) async {
    try {
      final second = await storageRead(tester, () async {
        final draft = await book.beginCapture();
        await writeWave(draft.path);
        final record = await book.finishCapture(draft);
        await book.transcribe(
          record.id,
          TextTranscriber(Future.value('线索关键另一段')),
        );
        return record;
      });
      await launch(tester);
      expect(device.loads, isEmpty);
      await reveal(tester, find.byKey(ValueKey('result-play-${audio.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('result-play-${audio.id}')));
      await until(tester, () => device.playing);
      expect(device.loads, [book.audioPath(audio)]);
      await reveal(tester, find.byKey(ValueKey('result-play-${second.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('result-play-${second.id}')));
      await until(tester, () => device.heard.length == 2);
      expect(device.heard.last, book.audioPath(second));
      await tester.tap(find.byKey(ValueKey('result-play-${second.id}')));
      await pumpStorageAndSettle(tester);
      expect(device.playing, isFalse);
      await tester.tap(find.byKey(ValueKey('result-play-${second.id}')));
      await pumpStorageAndSettle(tester);
      expect(device.playing, isTrue);
      await reveal(tester, find.byTooltip('清空查找内容'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('清空查找内容'));
      await pumpStorageAndSettle(tester);
      expect(device.playing, isFalse);
      expect(find.byType(SearchSummaryRow), findsNothing);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('跨页所属导航返回保留日期关键词及像素位置', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      await storageRead(tester, () async {
        for (var i = 0; i < 95; i++) {
          await book.saveText('线索关键资料$i');
        }
      });
      await tester.pumpWidget(NianxiaApp(book: book));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.byKey(const Key('home-search')));
      await tester.pumpAndSettle();
      await tester.enterText(input, '线索关键');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpStorageAndSettle(tester);
      final list = find.byKey(const Key('search-scroll'));
      for (
        var i = 0;
        i < 60 && find.text('所属：原记录的条件').evaluate().isEmpty;
        i++
      ) {
        await tester.drag(list, const Offset(0, -650));
        await pumpStorageAndSettle(tester);
      }
      await tester.ensureVisible(find.text('所属：原记录的条件'));
      await tester.pumpAndSettle();
      final scroll = tester.widget<CustomScrollView>(list).controller!;
      final position = scroll.offset;
      expect(position, greaterThan(1000));
      await tester.tap(find.text('所属：原记录的条件'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.byType(BackButton));
      await pumpStorageAndSettle(tester);
      expect(scroll.offset, closeTo(position, 1));
      scroll.jumpTo(0);
      await pumpStorageAndSettle(tester);
      expect(tester.widget<TextField>(input).controller!.text, '线索关键');
      expect(tester.testTextInput.isVisible, isFalse);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('删除后旧播放回调不能读取旧音频或打开假内容', (tester) async {
    try {
      await launch(tester);
      await reveal(tester, find.byKey(ValueKey('result-play-${audio.id}')));
      final play = tester
          .widget<TextButton>(find.byKey(ValueKey('result-play-${audio.id}')))
          .onPressed!;
      await storageRead(tester, () => book.delete(audio.id));
      play();
      await until(tester, () => find.text('线索关键补充').evaluate().isEmpty);
      expect(device.loads, isEmpty);
      expect(device.heard, isEmpty);
      expect(find.text('找到 1 条记录'), findsOneWidget);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('320双倍字体下所属链接与播放控件可达', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    try {
      await launch(tester);
      await reveal(tester, find.text('所属：原记录的条件'));
      await tester.pumpAndSettle();
      expect(find.text('所属：原记录的条件').hitTestable(), findsOneWidget);
      final play = find.byKey(ValueKey('result-play-${audio.id}'));
      await tester.ensureVisible(play);
      await tester.pumpAndSettle();
      expect(play.hitTestable(), findsOneWidget);
      final node = tester.getSemantics(play);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester
          .renderObject(play)
          .owner!
          .semanticsOwner!
          .performAction(node.id, SemanticsAction.tap);
      await until(tester, () => device.playing);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      await unmount(tester);
    }
  });
  testWidgets('设备报错后点击一次重新加载并恢复原音', (tester) async {
    try {
      await launch(tester);
      final button = find.byKey(ValueKey('result-play-${audio.id}'));
      await reveal(tester, button);
      await tester.tap(button);
      await until(tester, () => device.playing);
      device.failure = StateError('controlled decoder failure');
      device.notifyListeners();
      await pumpStorageAndSettle(tester);
      expect(playback.error, isNotNull);
      expect(find.byTooltip('播放原音频'), findsOneWidget);
      device.failure = null;
      await tester.tap(button);
      await pumpStorageAndSettle(tester);
      expect(device.loads.length, 2);
      expect(playback.error, isNull);
      expect(playback.playing, isTrue);
    } finally {
      await unmount(tester);
    }
  });
  testWidgets('读取原音期间切后台，迟到读取不能恢复播放', (tester) async {
    try {
      await launch(tester);
      await reveal(tester, find.byKey(ValueKey('result-play-${audio.id}')));
      tester
          .widget<TextButton>(find.byKey(ValueKey('result-play-${audio.id}')))
          .onPressed!();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pumpStorageAndSettle(tester);
      expect(device.loads, isEmpty);
      expect(device.heard, isEmpty);
    } finally {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await unmount(tester);
    }
  });
}
