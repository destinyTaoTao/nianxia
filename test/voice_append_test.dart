import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';

import 'hold_recording_test.dart' show HoldMicrophone;
import 'playback_coordination_test.dart' show OutputFixture;
import 'support/async_storage_tester.dart';
import 'support/storage_probe.dart';
import 'support/ui_native_capture.dart';

class FailedAppendTranscriber implements Transcriber {
  @override
  Future<String> transcribe(String path) async =>
      throw const NotebookException('合成转写失败');
}

void main() {
  for (final native in [false, true]) {
    group(native ? '受控原生追加' : '普通语音追加', () {
      late Directory root;
      late Notebook book;
      late Record parent;
      late HoldMicrophone mic;
      late OutputFixture output;
      late PlaybackCoordinator playback;
      CaptureSessionController? capture;
      UiCaptureEndpoint? endpoint;
      UiCaptureRuntime? runtime;
      var minute = 0;
      final button = find.byKey(const Key('hold-record'));
      setUp(() async {
        root = await Directory.systemTemp.createTemp('nx-voice-append-');
        minute = 0;
        book = await Notebook.open(
          root,
          clock: () => DateTime.utc(2026, 11, 20, 9, minute++),
        );
        parent = await book.saveText('原来的录音上下文\n保留原有条件。');
        mic = HoldMicrophone();
        output = OutputFixture();
        playback = PlaybackCoordinator.retain(book, output: output);
        if (native) {
          endpoint = UiCaptureEndpoint(book);
          runtime = UiCaptureRuntime();
          capture = CaptureSessionController(endpoint!, book, runtime!);
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app.nianxia/system'),
              (_) async => true,
            );
      });
      tearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('app.nianxia/system'),
              null,
            );
        await TestWidgetsFlutterBinding.instance.runAsync(() async {
          capture?.dispose();
          runtime?.dispose();
          capture = null;
          runtime = null;
          endpoint = null;
          await mic.close();
          await playback.release();
          await book.close();
          await root.delete(recursive: true);
        });
      });
      Future<void> until(WidgetTester tester, bool Function() ready) async {
        for (var i = 0; i < 100 && !ready(); i++) {
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
        await tester.pumpWidget(
          NianxiaApp(
            book: book,
            captureMicrophone: mic,
            captureSession: capture,
          ),
        );
        await pumpStorageAndSettle(tester);
        await tester.tap(find.text(parent.title));
        await pumpStorageAndSettle(tester);
        await tester.tap(find.text('追加内容'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('追加语音'));
        await pumpStorageAndSettle(tester);
      }

      Future<TestGesture> begin(WidgetTester tester) async {
        final gesture = await tester.startGesture(tester.getCenter(button));
        await until(
          tester,
          () => find.text('松手保存追加，上滑取消').evaluate().isNotEmpty,
        );
        if (!native) {
          mic.feed();
          await pumpStorageAndSettle(tester);
        }
        return gesture;
      }

      Future<Record> saved(WidgetTester tester) async {
        await until(
          tester,
          () => find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
        );
        final children = await storageRead(
          tester,
          () => book.children(parent.id),
        );
        return children.singleWhere((v) => v.audio != null);
      }

      Future<void> unmount(WidgetTester tester) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStorageAndSettle(tester);
        final current = capture?.snapshot;
        if (current != null &&
            capture?.savedId == null &&
            await storageRead(tester, () => book.get(current.sessionId)) ==
                null) {
          var done = false;
          Object? failure;
          capture!.discard().then<void>(
            (_) => done = true,
            onError: (Object error, StackTrace _) {
              failure = error;
              done = true;
            },
          );
          await until(tester, () => done);
          if (failure != null) {
            expect(
              await storageRead(tester, () => book.get(current.sessionId)),
              isNotNull,
              reason: 'An unmount may finish saving before cleanup; committed audio must be preserved.',
            );
          }
        }
      }

      testWidgets('按住前所属已删除，不宣称保留音频或提供无片段的独立保存', (tester) async {
        try {
          await launch(tester);
          await storageRead(tester, () => book.delete(parent.id));
          final gesture = await tester.startGesture(tester.getCenter(button));
          await pumpStorageAndSettle(tester);
          await gesture.up();
          await until(tester, () => find.text('重新操作').evaluate().isNotEmpty);
          expect(find.text('保存为独立记录'), findsNothing);
          expect(find.textContaining('音频仍保留'), findsNothing);
          expect(find.text('原记录已删除，本次尚未开始录音。'), findsOneWidget);
          expect(mic.starts, 0);
          expect(await storageRead(tester, () => book.records), isEmpty);
        } finally {
          await unmount(tester);
        }
      });

      testWidgets('默认不开麦，95次后按住松手定位实际音频，转写失败仍可回放', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        try {
          await storageRead(tester, () async {
            for (var i = 0; i < 95; i++) {
              await book.saveText('已有条件$i', parentId: parent.id);
            }
          });
          await launch(tester);
          expect(find.text('追加到：${parent.title}'), findsOneWidget);
          expect(native ? endpoint!.starts : mic.starts, 0);
          expect(find.text('按住追加'), findsOneWidget);
          final gesture = await begin(tester);
          await gesture.up();
          final row = await saved(tester);
          expect(row.parentId, parent.id);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            96,
          );
          expect(
            await tester.runAsync(() => File(book.audioPath(row)).length()),
            greaterThan(44),
          );
          expect(find.text('语音记录，等待转写').hitTestable(), findsOneWidget);
          expect(
            (await storageRead(tester, () => book.get(parent.id)))!.body,
            parent.body,
          );
          await tester.tap(find.text('语音记录，等待转写'));
          await pumpStorageAndSettle(tester);
          expect(find.text('查看所属记录'), findsOneWidget);
          await tester.tap(find.byTooltip('播放原音频'));
          await pumpStorageAndSettle(tester);
          expect(output.heard.last, book.audioPath(row));
          await tester.runAsync(() async {
            await expectLater(
              book.transcribe(row.id, FailedAppendTranscriber()),
              throwsA(isA<NotebookException>()),
            );
          });
          await pumpStorageAndSettle(tester);
          expect(
            (await storageRead(tester, () => book.get(row.id)))!.transcription,
            'failed',
          );
          expect(find.byTooltip('暂停原音频'), findsOneWidget);
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('上滑取消不追加也不改变原正文', (tester) async {
        try {
          await launch(tester);
          final gesture = await begin(tester);
          await gesture.moveBy(const Offset(0, -80));
          await tester.pump();
          await gesture.up();
          await until(tester, () => find.text('按住追加').evaluate().isNotEmpty);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            0,
          );
          expect(
            (await storageRead(tester, () => book.get(parent.id)))!.canonical,
            parent.canonical,
          );
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('320双倍字体下所属固定可见，按住控件和反馈可达', (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        try {
          await launch(tester);
          expect(
            find.text('追加到：${parent.title}').hitTestable(),
            findsOneWidget,
          );
          expect(button.hitTestable(), findsOneWidget);
          final gesture = await begin(tester);
          expect(
            find.text('追加到：${parent.title}').hitTestable(),
            findsOneWidget,
          );
          final feedback = tester.getRect(find.text('松手保存追加，上滑取消'));
          expect(
            feedback.top,
            greaterThanOrEqualTo(
              tester.getBottomLeft(find.text('追加到：${parent.title}')).dy,
            ),
          );
          expect(
            feedback.bottom,
            lessThanOrEqualTo(tester.getTopLeft(button).dy),
          );
          await gesture.up();
          await saved(tester);
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });
      if (!native) {
        testWidgets('授权未决时松手不启动迟到麦克风，也不生成追加', (tester) async {
          try {
            mic.permission = Completer<bool>();
            await launch(tester);
            final gesture = await tester.startGesture(tester.getCenter(button));
            await tester.pump();
            await gesture.up();
            mic.permission!.complete(true);
            await until(tester, () => find.text('按住追加').evaluate().isNotEmpty);
            expect(mic.starts, 0);
            expect(
              await storageRead(tester, () => book.childCount(parent.id)),
              0,
            );
          } finally {
            await unmount(tester);
          }
        });
        testWidgets('两分钟采样截止后迟到上滑与松手不丢失追加身份', (tester) async {
          try {
            await launch(tester);
            final gesture = await begin(tester);
            mic.chunks.add(Uint8List(3840000));
            await until(
              tester,
              () => find.text('音频已保存，请松手').evaluate().isNotEmpty,
            );
            expect(find.byKey(const Key('voice-append-panel')), findsOneWidget);
            await gesture.moveBy(const Offset(0, -100));
            await gesture.up();
            final row = await saved(tester);
            expect(row.durationMs, 120000);
            expect(
              await storageRead(tester, () => book.childCount(parent.id)),
              1,
            );
          } finally {
            await unmount(tester);
          }
        });
      }
      testWidgets('保存失败保留片段，重试只形成一个追加身份', (tester) async {
        try {
          await launch(tester);
          final gesture = await begin(tester);
          StorageProbe(book).execute(
            "CREATE TRIGGER fail_voice_append BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic fault'); END",
          );
          await gesture.up();
          await until(tester, () => find.text('重试保存').evaluate().isNotEmpty);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            0,
          );
          StorageProbe(book).execute('DROP TRIGGER fail_voice_append');
          await tester.tap(find.text('重试保存'));
          final row = await saved(tester);
          expect(row.parentId, parent.id);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            1,
          );
          expect(
            await tester.runAsync(() => File(book.audioPath(row)).length()),
            greaterThan(44),
          );
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('父被删保留音频，取消独立确认无记录，确认后才独立保存', (tester) async {
        try {
          await launch(tester);
          final gesture = await begin(tester);
          await storageRead(tester, () => book.delete(parent.id));
          await gesture.up();
          await until(tester, () => find.text('保存为独立记录').evaluate().isNotEmpty);
          expect(await storageRead(tester, () => book.records), isEmpty);
          await tester.tap(find.text('保存为独立记录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(await storageRead(tester, () => book.records), isEmpty);
          await tester.tap(find.text('保存为独立记录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存为独立记录').last);
          await until(
            tester,
            () =>
                find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
          );
          final records = await storageRead(tester, () => book.records);
          expect(records, hasLength(1));
          expect(records.single.parentId, isNull);
          expect(records.single.audio, isNotNull);
          expect(await storageRead(tester, () => book.get(parent.id)), isNull);
          expect(
            await tester.runAsync(
              () => File(book.audioPath(records.single)).length(),
            ),
            greaterThan(44),
          );
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('点按替代也返回实际身份并保留所属', (tester) async {
        try {
          await launch(tester);
          await tester.tap(find.text('点按追加'));
          await until(tester, () => find.text('停止并保存').evaluate().isNotEmpty);
          if (!native) {
            mic.feed();
            await pumpStorageAndSettle(tester);
          }
          await tester.tap(find.text('停止并保存'));
          final row = await saved(tester);
          expect(row.parentId, parent.id);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            1,
          );
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('点按追加中父删除也必须确认独立保存', (tester) async {
        try {
          await launch(tester);
          await tester.tap(find.text('点按追加'));
          await until(tester, () => find.text('停止并保存').evaluate().isNotEmpty);
          if (!native) {
            mic.feed();
            await pumpStorageAndSettle(tester);
          }
          await storageRead(tester, () => book.delete(parent.id));
          await tester.tap(find.text('停止并保存'));
          await until(
            tester,
            () => find
                .widgetWithText(OutlinedButton, '保存为独立记录')
                .evaluate()
                .any((e) => (e.widget as OutlinedButton).onPressed != null),
          );
          expect(await storageRead(tester, () => book.records), isEmpty);
          await tester.tap(find.text('保存为独立记录'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存为独立记录').last);
          await until(
            tester,
            () =>
                find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
          );
          final records = await storageRead(tester, () => book.records);
          expect(records, hasLength(1));
          expect(records.single.parentId, isNull);
          expect(
            await tester.runAsync(
              () => File(book.audioPath(records.single)).length(),
            ),
            greaterThan(44),
          );
        } finally {
          await unmount(tester);
        }
      });
      testWidgets('点按丢弃确认期间截止保存，关闭正确路由并交付追加身份', (tester) async {
        try {
          await launch(tester);
          await tester.tap(find.text('点按追加'));
          await until(tester, () => find.text('停止并保存').evaluate().isNotEmpty);
          if (!native) {
            mic.feed();
            await pumpStorageAndSettle(tester);
          }
          await tester.tap(find.text(native ? '丢弃这段录音' : '取消录音'));
          await tester.pumpAndSettle();
          expect(find.text('确认丢弃'), findsOneWidget);
          if (native) {
            await storageRead(tester, () => capture!.stop());
          } else {
            mic.chunks.add(Uint8List(3840000));
          }
          await until(
            tester,
            () =>
                find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
          );
          expect(find.text('确认丢弃'), findsNothing);
          expect(
            await storageRead(tester, () => book.childCount(parent.id)),
            1,
          );
          expect(find.text('语音记录，等待转写').hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await unmount(tester);
        }
      });
      if (native) {
        testWidgets('原生追加收起并返回首页后仍显示所属，保存回原记录定位', (tester) async {
          try {
            await launch(tester);
            await tester.tap(find.text('点按追加'));
            await until(tester, () => find.text('停止并保存').evaluate().isNotEmpty);
            final id = capture!.snapshot!.sessionId;
            await tester.tap(find.text('收起'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('关闭语音追加'));
            await tester.pumpAndSettle();
            await tester.tap(find.byType(BackButton));
            await pumpStorageAndSettle(tester);
            await tester.tap(find.byKey(const Key('capture-return')));
            await pumpStorageAndSettle(tester);
            expect(find.text('追加到：${parent.title}'), findsOneWidget);
            await tester.tap(find.text('停止并保存'));
            await until(
              tester,
              () => find.text('语音记录，等待转写').hitTestable().evaluate().isNotEmpty,
            );
            expect(
              (await storageRead(tester, () => book.get(id)))!.parentId,
              parent.id,
            );
            expect(
              await storageRead(tester, () => book.childCount(parent.id)),
              1,
            );
          } finally {
            await unmount(tester);
          }
        });
        testWidgets('截止回执早于松手时保持按住位置，松手才返回同一追加身份', (tester) async {
          try {
            await launch(tester);
            final gesture = await begin(tester);
            final id = capture!.snapshot!.sessionId;
            await storageRead(
              tester,
              () => capture!.stop(expectedSessionId: id),
            );
            await pumpStorageAndSettle(tester);
            expect(find.byKey(const Key('voice-append-panel')), findsOneWidget);
            expect(find.text('音频已保存，请松手'), findsOneWidget);
            expect(
              await storageRead(tester, () => book.childCount(parent.id)),
              1,
            );
            await gesture.up();
            final record = await saved(tester);
            expect(record.id, id);
            expect(
              await storageRead(tester, () => book.childCount(parent.id)),
              1,
            );
          } finally {
            await unmount(tester);
          }
        });
      }
    });
  }
}
