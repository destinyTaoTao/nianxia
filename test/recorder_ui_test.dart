import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/ui/recorder.dart';
import 'package:nianxia/ui/theme.dart';

import 'capsule_test.dart' show DeniedMicrophone;
import 'capture_controller_test.dart' show TestMicrophone, QueryReadyStore;

void main() {
  late Directory home;
  late Notebook book;
  var recorderClosed = false;
  Object? recorderResult;
  setUp(() async {
    recorderClosed = false;
    recorderResult = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async =>
              call.method == 'recordingScreenAvailable' ? true : null,
        );
    home = await Directory.systemTemp.createTemp('nianxia-recorder-ui-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          null,
        );
    book.dispose();
    await home.delete(recursive: true);
  });

  Future<void> launch(
    WidgetTester tester,
    MicrophoneInput microphone, {
    String? parentId,
    bool query = false,
    LocalModels? models,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: notebookTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                recorderResult = await openRecorder(
                  context,
                  book,
                  models,
                  parentId: parentId,
                  query: query,
                  microphone: microphone,
                );
                recorderClosed = true;
              },
              child: const Text('开始录音'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始录音'));
  }

  Future<void> untilVisible(WidgetTester tester, String label) async {
    for (
      var i = 0;
      i < 50 && find.textContaining(label).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.textContaining(label), findsOneWidget);
    await tester.pumpAndSettle();
  }

  for (final append in [false, true]) {
    testWidgets('录音权限拒绝后可直接${append ? '追加文字并保留所属关系' : '写文字并保存'}', (
      tester,
    ) async {
      final parent = append ? await book.saveText('原始想法') : null;
      await launch(tester, DeniedMicrophone(), parentId: parent?.id);
      await untilVisible(tester, '没有麦克风权限');
      await tester.pumpAndSettle();
      expect(find.textContaining('没有麦克风权限'), findsOneWidget);
      expect(book.records.length, append ? 1 : 0);
      await tester.tap(find.text(append ? '追加文字' : '写文字'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('body-editor')),
        '麦克风不可用时也能记住想法',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final saved = book.records.singleWhere((r) => r.body == '麦克风不可用时也能记住想法');
      expect(saved.parentId, parent?.id);
      expect(saved.audio, isNull);
      expect(book.records.length, append ? 2 : 1);
      expect(book.captureActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets('语音查询权限失败仍返回查找，不显示新建笔记入口', (tester) async {
    final store = QueryReadyStore(home);
    addTearDown(store.dispose);
    await launch(
      tester,
      DeniedMicrophone(),
      query: true,
      models: LocalModels(store),
    );
    await untilVisible(tester, '没有麦克风权限');
    expect(find.text('写文字'), findsNothing);
    await tester.tap(find.text('关闭或丢弃'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('body-editor')), findsNothing);
    expect(book.records, isEmpty);
    expect(book.captureActive, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('有有效片段的保存失败继续提供重试，不从文字入口丢失音频', (tester) async {
    final mic = TestMicrophone()..failStop = true;
    await launch(tester, mic);
    await untilVisible(tester, '停止并保存');
    mic.chunks.add(Uint8List(32000));
    await tester.tap(find.text('停止并保存'));
    await untilVisible(tester, '重试保存');
    expect(find.text('写文字'), findsNothing);
    expect(book.records, isEmpty);
    expect(book.recoveryDrafts, hasLength(1));
    expect(
      await tester.runAsync(
        () => File(book.recoveryDrafts.single.path).exists(),
      ),
      isTrue,
    );
    await tester.tap(find.text('重试保存'));
    for (var i = 0; i < 50 && !recorderClosed; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(recorderClosed, isTrue);
    expect((recorderResult as Record).id, book.records.single.id);
    await tester.pumpAndSettle();
    expect(book.records.single.durationMs, 1000);
    expect(
      await tester.runAsync(
        () => File(book.audioPath(book.records.single)).exists(),
      ),
      isTrue,
    );
    expect(book.recoveryDrafts, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
