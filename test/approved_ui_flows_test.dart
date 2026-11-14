import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';

import 'support/ui_native_capture.dart';

import 'support/async_storage_tester.dart';

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-approved-ui-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });
  testWidgets('homeUsesTopSearchSingleCaptureAction', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    final bottom = find.byType(BottomNavigationBar);
    expect(bottom, findsNothing);
    expect(find.byKey(const Key('home-search')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('home-search'))).dy,
      lessThan(180),
    );
    expect(
      tester.getTopLeft(find.text('写文字')).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('home-search'))).dy),
    );
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      find.descendant(
        of: find.byWidget(scaffold.bottomNavigationBar!),
        matching: find.text('记一下'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byWidget(scaffold.bottomNavigationBar!),
        matching: find.text('写文字'),
      ),
      findsNothing,
    );
  });
  testWidgets(
    'searchUsesBoundedSummaryPages and preserves results on index-only events',
    (tester) async {
      await storageRead(tester, () async {
        for (var i = 0; i < 91; i++) {
          await book.saveText(
            'synthetic-match-$i\n${'wide '.padRight(3000, 'x')}',
          );
        }
      });
      await tester.pumpWidget(NianxiaApp(book: book));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('找一下'));
      await pumpStorageAndSettle(tester);
      await tester.enterText(
        find.byKey(const Key('search-input')),
        'synthetic-match',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await pumpStorageAndSettle(tester);
      expect(find.text('已显示 40 条记录'), findsOneWidget);
      book.changed(content: false);
      await pumpStorageAndSettle(tester);
      expect(find.text('已显示 40 条记录'), findsOneWidget);
    },
  );
  testWidgets(
    'expired search cursor reloads actual first page instead of showing no results',
    (tester) async {
      await storageRead(tester, () async {
        for (var i = 0; i < 91; i++) {
          await book.saveText('cursor-match-$i\n正文保持可查找');
        }
      });
      await tester.pumpWidget(NianxiaApp(book: book));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('找一下'));
      await pumpStorageAndSettle(tester);
      await tester.enterText(
        find.byKey(const Key('search-input')),
        'cursor-match',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await pumpStorageAndSettle(tester);
      expect(find.text('已显示 40 条记录'), findsOneWidget);
      await storageRead(
        tester,
        () => book.setSearchModelVersion('cursor-model-v2'),
      );
      await pumpStorageAndSettle(tester);
      expect(find.text('已显示 40 条记录'), findsOneWidget);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await pumpStorageAndSettle(tester);
      expect(find.text('没有找到相关记录'), findsNothing);
      expect(find.byType(SearchSummaryRow), findsWidgets);
    },
  );
  testWidgets(
    'native journal failure shows retry instead of an endless saving state',
    (tester) async {
      final endpoint = UiCaptureEndpoint(book);
      final runtime = UiCaptureRuntime();
      final capture = CaptureSessionController(endpoint, book, runtime);
      addTearDown(() {
        capture.dispose();
        runtime.dispose();
      });
      await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('记一下'));
      await pumpStorageAndSettle(tester);
      final old = capture.snapshot!;
      endpoint.value = CaptureSnapshot.fromMap({
        ...old.request.toMap(),
        'phase': 'finalizing',
        'sequence': old.sequence + 1,
        'elapsedMs': 1000,
        'pcmBytes': 32000,
        'level': 0.0,
        'errorCode': 'capture_journal',
      });
      endpoint.updates.add(endpoint.value!);
      await pumpStorageAndSettle(tester);
      expect(find.text('保存未完成，请重试'), findsOneWidget);
      expect(find.text('重试保存'), findsOneWidget);
      expect(capture.savedId, isNull);
      await tester.tap(find.text('重试保存'));
      for (var i = 0; i < 100 && capture.savedId == null; i++) {
        await pumpStorageAndSettle(tester);
      }
      expect(capture.savedId, old.sessionId);
    },
  );
  testWidgets(
    'collapseDoesNotDiscardRecording and returns to the same session',
    (tester) async {
      final endpoint = UiCaptureEndpoint(book);
      final runtime = UiCaptureRuntime();
      final controller = CaptureSessionController(
        endpoint,
        book,
        runtime,
        queryForeground: () async => true,
      );
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await tester.pumpWidget(
        NianxiaApp(book: book, captureSession: controller),
      );
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('记一下'));
      await pumpStorageAndSettle(tester);
      final session = controller.snapshot!.sessionId;
      expect(find.text('正在录音'), findsOneWidget);
      expect(await storageRead(tester, () => book.records), isEmpty);
      await tester.tap(find.text('收起'));
      await pumpStorageAndSettle(tester);
      expect(endpoint.cancels, 0);
      expect(find.byKey(const Key('capture-return')), findsOneWidget);
      await tester.tap(find.byKey(const Key('capture-return')));
      await pumpStorageAndSettle(tester);
      expect(controller.snapshot!.sessionId, session);
      expect(endpoint.starts, 1);
      await tester.tap(find.text('停止并保存'));
      for (var i = 0; i < 60; i++) {
        await pumpStorageAndSettle(tester);
        if (controller.savedId == session &&
            find.text('收起').evaluate().isEmpty) {
          break;
        }
      }
      expect((await storageRead(tester, () => book.records)).length, 1);
      expect(endpoint.cancels, 0);
    },
  );
  testWidgets('queryRequiresConfirmationAndStopsWhenHidden', (tester) async {
    await storageRead(tester, () => book.saveText('临时查询的原始记录'));
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final controller = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    addTearDown(() {
      controller.dispose();
      runtime.dispose();
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: controller));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('语音查找'));
    await pumpStorageAndSettle(tester);
    expect(find.text('说出要找的内容'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    for (var i = 0; i < 60 && book.captureActive; i++) {
      await pumpStorageAndSettle(tester);
    }
    expect(book.captureActive, isFalse);
    expect(runtime.transcriptions, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('识别查询'));
    for (var i = 0; i < 60; i++) {
      await pumpStorageAndSettle(tester);
      if (find.text('识别文字可以修改，确认后点“查找”。').evaluate().isNotEmpty) break;
    }
    expect(find.text('识别文字可以修改，确认后点“查找”。'), findsOneWidget);
    expect((await storageRead(tester, () => book.records)).length, 1);
  });
  testWidgets(
    'native append returns to same parent session and confirms standalone after parent deletion',
    (tester) async {
      final parent = await storageRead(
        tester,
        () => book.saveText('synthetic parent'),
      );
      final endpoint = UiCaptureEndpoint(book);
      final runtime = UiCaptureRuntime();
      final controller = CaptureSessionController(endpoint, book, runtime);
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
      });
      await storageRead(
        tester,
        () => controller.start(mode: CaptureMode.record, parentId: parent.id),
      );
      await tester.pumpWidget(
        NianxiaApp(book: book, captureSession: controller),
      );
      await pumpStorageAndSettle(tester);
      await storageRead(tester, () => book.delete(parent.id));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.byKey(const Key('capture-return')));
      await pumpStorageAndSettle(tester);
      expect(find.text('正在录音'), findsOneWidget);
      await tester.tap(find.text('停止并保存'));
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final button = find.widgetWithText(OutlinedButton, '保存为独立记录');
        if (button.evaluate().isNotEmpty &&
            tester.widget<OutlinedButton>(button).onPressed != null) {
          break;
        }
      }
      await tester.ensureVisible(find.text('保存为独立记录'));
      await tester.pump();
      expect(await storageRead(tester, () => book.records), isEmpty);
      await tester.tap(find.text('保存为独立记录'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, () => book.records), isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '保存为独立记录'));
      for (var i = 0; i < 60; i++) {
        await pumpStorageAndSettle(tester);
        if (controller.savedId != null && find.text('收起').evaluate().isEmpty) {
          break;
        }
      }
      final saved = (await storageRead(tester, () => book.records)).single;
      expect(saved.parentId, isNull);
      expect(endpoint.starts, 1);
    },
  );
  testWidgets(
    'native shortcut capsule shares owner and collapse keeps recording',
    (tester) async {
      final endpoint = UiCaptureEndpoint(book);
      final runtime = UiCaptureRuntime();
      final controller = CaptureSessionController(endpoint, book, runtime);
      final shortcut = ValueNotifier<String?>('capsule');
      var returned = 0;
      addTearDown(() {
        controller.dispose();
        runtime.dispose();
        shortcut.dispose();
      });
      await tester.pumpWidget(
        NianxiaApp(
          book: book,
          captureSession: controller,
          shortcut: shortcut,
          onCapsuleReturn: () async {
            returned++;
          },
        ),
      );
      await pumpStorageAndSettle(tester);
      expect(endpoint.starts, 1);
      await tester.tap(find.text('收起'));
      await pumpStorageAndSettle(tester);
      expect(returned, 1);
      expect(endpoint.cancels, 0);
      expect(find.byKey(const Key('capture-return')), findsOneWidget);
    },
  );
  testWidgets('native capsule can retry failed return without stopping owner', (
    tester,
  ) async {
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final controller = CaptureSessionController(endpoint, book, runtime);
    final shortcut = ValueNotifier<String?>('capsule');
    var attempts = 0;
    addTearDown(() {
      controller.dispose();
      runtime.dispose();
      shortcut.dispose();
    });
    await tester.pumpWidget(
      NianxiaApp(
        book: book,
        captureSession: controller,
        shortcut: shortcut,
        onCapsuleReturn: () async {
          attempts++;
          if (attempts == 1) throw StateError('synthetic return failure');
        },
      ),
    );
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('收起'));
    await pumpStorageAndSettle(tester);
    expect(attempts, 1);
    await tester.tap(find.text('收起'));
    await pumpStorageAndSettle(tester);
    expect(attempts, 2);
    expect(endpoint.cancels, 0);
    expect(endpoint.starts, 1);
  });
  testWidgets(
    'home surfaces actual recoverable artifacts without a permanent warning',
    (tester) async {
      await storageRead(tester, () async {
        final q = await Directory(
          '${home.path}/quarantine/11111111-1111-4111-8111-111111111111',
        ).create(recursive: true);
        await File('${q.path}/original.bin').writeAsBytes([1, 2, 3]);
      });
      await tester.pumpWidget(NianxiaApp(book: book));
      await pumpStorageAndSettle(tester);
      for (var i = 0; i < 100 && find.text('核对待恢复资料').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('核对待恢复资料'), findsOneWidget);
      await tester.tap(find.text('核对待恢复资料'));
      await pumpStorageAndSettle(tester);
      expect(find.text('隔离片段'), findsOneWidget);
    },
  );
}
