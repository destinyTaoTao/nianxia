import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/search.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';

import 'support/ui_native_capture.dart';

import 'support/async_storage_tester.dart';

class DelayedStartEndpoint extends UiCaptureEndpoint {
  DelayedStartEndpoint(super.book);
  final requested = Completer<void>();
  final proceed = Completer<void>();
  bool failCancel = false;
  @override
  Future<void> cancel(String id) async {
    if (failCancel) throw const FileSystemException('cancel fault');
    await super.cancel(id);
  }

  @override
  Future<CaptureSnapshot> start(CaptureRequest request) async {
    final result = await super.start(request);
    requested.complete();
    await proceed.future;
    return value ?? result;
  }
}

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
  testWidgets('homeUsesTopSearchAndBottomTextAndVoiceModes', (tester) async {
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
      greaterThan(tester.getTopLeft(find.byKey(const Key('home-search'))).dy),
    );
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(
      find.descendant(
        of: find.byWidget(scaffold.bottomNavigationBar!),
        matching: find.text('按住说话'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byWidget(scaffold.bottomNavigationBar!),
        matching: find.text('写文字'),
      ),
      findsOneWidget,
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
      await tester.testTextInput.receiveAction(TextInputAction.search);
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
      await tester.testTextInput.receiveAction(TextInputAction.search);
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
  testWidgets('native terminal recording survives an abandoned start page', (
    tester,
  ) async {
    await storageRead(tester, () async {
      final endpoint = DelayedStartEndpoint(book);
      final runtime = UiCaptureRuntime();
      final capture = CaptureSessionController(endpoint, book, runtime);
      var allowed = true;
      final work = capture.start(
        mode: CaptureMode.record,
        startAllowed: () => allowed,
      );
      await endpoint.requested.future;
      await endpoint.stop(endpoint.value!.sessionId);
      allowed = false;
      final rejected = expectLater(work, throwsA(isA<NotebookException>()));
      endpoint.proceed.complete();
      await rejected;
      expect(endpoint.cancels, 0);
      final saved = (await book.records).single;
      expect(capture.savedId, saved.id);
      expect(await File(book.audioPath(saved)).length(), greaterThan(44));
      capture.dispose();
      runtime.dispose();
    });
  });
  testWidgets('native abandoned terminal query is cleaned instead of reused', (
    tester,
  ) async {
    await storageRead(tester, () async {
      for (final phase in [
        NativeCapturePhase.finalized,
        NativeCapturePhase.failed,
      ]) {
        final endpoint = DelayedStartEndpoint(book);
        final runtime = UiCaptureRuntime();
        final capture = CaptureSessionController(endpoint, book, runtime);
        var allowed = true;
        final work = capture.start(
          mode: CaptureMode.query,
          startAllowed: () => allowed,
        );
        await endpoint.requested.future;
        endpoint.value = endpoint.snapshot(
          endpoint.value!.request,
          phase,
          bytes: 32000,
        );
        allowed = false;
        final rejected = expectLater(work, throwsA(isA<NotebookException>()));
        endpoint.proceed.complete();
        await rejected;
        expect(endpoint.cancels, 1);
        expect(capture.snapshot, isNull);
        expect(await book.records, isEmpty);
        capture.dispose();
        runtime.dispose();
      }
    });
  });
  testWidgets('native abandoned start surfaces a failed cancellation', (
    tester,
  ) async {
    final endpoint = DelayedStartEndpoint(book)..failCancel = true;
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('点按录音'));
    await pumpStorageAndSettle(tester);
    expect(endpoint.requested.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    endpoint.proceed.complete();
    await pumpStorageAndSettle(tester);
    expect(capture.lastError, contains('结束录音未完成'));
    expect(capture.snapshot?.phase, NativeCapturePhase.recording);
    endpoint.failCancel = false;
    await storageRead(tester, () => capture.discard());
    capture.dispose();
    runtime.dispose();
  });
  testWidgets(
    'native late start releases microphone after initiating page leaves',
    (tester) async {
      final endpoint = DelayedStartEndpoint(book);
      final runtime = UiCaptureRuntime();
      final capture = CaptureSessionController(endpoint, book, runtime);
      await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('点按录音'));
      await pumpStorageAndSettle(tester);
      expect(endpoint.requested.isCompleted, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      endpoint.proceed.complete();
      await pumpStorageAndSettle(tester);
      expect(endpoint.cancels, 1);
      expect(book.captureActive, isFalse);
      expect(await storageRead(tester, () => book.records), isEmpty);
      capture.dispose();
      runtime.dispose();
    },
  );
  testWidgets(
    'native recovery registration failure does not claim retained audio',
    (tester) async {
      final endpoint = UiCaptureEndpoint(book);
      final runtime = UiCaptureRuntime();
      final capture = CaptureSessionController(endpoint, book, runtime);
      await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('点按录音'));
      await pumpStorageAndSettle(tester);
      final old = capture.snapshot!;
      final drafts = book.captures.marker(old.sessionId).parent;
      await storageRead(tester, () async {
        await drafts.rename('${drafts.path}-held');
        await File(drafts.path).writeAsString('fault');
      });
      endpoint.value = CaptureSnapshot.fromMap({
        ...old.request.toMap(),
        'phase': 'failed',
        'sequence': old.sequence + 1,
        'elapsedMs': 1000,
        'pcmBytes': 32000,
        'level': 0.0,
      });
      endpoint.updates.add(endpoint.value!);
      for (var i = 0; i < 10; i++) {
        await pumpStorageAndSettle(tester);
      }
      expect(capture.lastError, contains('无法登记恢复资料'));
      expect(capture.lastError, isNot(contains('已保留')));
      expect(await storageRead(tester, () => book.records), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      capture.dispose();
      runtime.dispose();
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
      await tester.tap(find.text('点按录音'));
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
      await tester.tap(find.text('点按录音'));
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
    final hold = find.byKey(const Key('hold-query'));
    final gesture = await tester.startGesture(tester.getCenter(hold));
    for (var i = 0; i < 60 && !book.captureActive; i++) {
      await pumpStorageAndSettle(tester);
    }
    expect(book.captureActive, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await gesture.up();
    for (var i = 0; i < 60 && book.captureActive; i++) {
      await pumpStorageAndSettle(tester);
    }
    expect(book.captureActive, isFalse);
    expect(runtime.transcriptions, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(find.byKey(const Key('voice-query-panel')), findsNothing);
    expect(find.text('识别文字可以修改，确认后点“查找”。'), findsNothing);
    await tester.tap(find.text('语音查找'));
    await pumpStorageAndSettle(tester);
    final again = await tester.startGesture(tester.getCenter(hold));
    for (var i = 0; i < 60 && !book.captureActive; i++) {
      await pumpStorageAndSettle(tester);
    }
    expect(book.captureActive, isTrue);
    await again.up();
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
