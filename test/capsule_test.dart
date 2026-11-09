import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'capture_controller_test.dart' show TestMicrophone;

class DeniedMicrophone extends TestMicrophone {
  @override
  Future<bool> allowed() async => false;
  @override
  Future<void> stop() async {
    // No native capture stream exists after permission denial. Ensure this
    // in-memory stream's close has a consumer, like a completed device stop.
    if (!chunks.hasListener) chunks.stream.listen((_) {});
    await super.stop();
  }
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async =>
              call.method == 'recordingScreenAvailable' ? true : null,
        );
    home = await Directory.systemTemp.createTemp('nianxia-capsule-');
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
  Future<void> untilVisible(WidgetTester tester, String text) async {
    for (var i = 0; i < 50 && find.text(text).evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(find.text(text), findsOneWidget);
  }

  testWidgets('外部呼出只显示录音胶囊，重复呼出不重启，保存后才可返回', (tester) async {
    final action = ValueNotifier<String?>('capsule');
    final mic = TestMicrophone();
    var returned = false;
    await tester.pumpWidget(
      NianxiaApp(
        book: book,
        shortcut: action,
        captureMicrophone: mic,
        onCapsuleReturn: () async {
          returned = true;
        },
      ),
    );
    await untilVisible(tester, '停止并保存');
    expect(find.text('全部记录'), findsNothing);
    expect(find.text('停止并保存'), findsOneWidget);
    mic.chunks.add(Uint8List(32000));
    action.value = 'capsule';
    await tester.pump();
    expect(find.text('停止并保存'), findsOneWidget);
    expect(returned, isFalse);
    await tester.binding.handlePopRoute();
    await untilVisible(tester, '音频已保存');
    expect(find.text('音频已保存'), findsOneWidget);
    expect(book.records.single.durationMs, 1000);
    await tester.tap(find.text('返回原应用'));
    await tester.pumpAndSettle();
    expect(returned, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    action.dispose();
  });
  testWidgets('热启动胶囊保存后保留尚未保存的文字编辑', (tester) async {
    final action = ValueNotifier<String?>(null);
    final mic = TestMicrophone();
    await tester.pumpWidget(
      NianxiaApp(
        book: book,
        shortcut: action,
        captureMicrophone: mic,
        onCapsuleReturn: () async {},
      ),
    );
    await tester.tap(find.text('写文字'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('body-editor')), '未保存的想法');
    action.value = 'capsule';
    await untilVisible(tester, '停止并保存');
    mic.chunks.add(Uint8List(32000));
    await tester.tap(find.text('停止并保存'));
    await untilVisible(tester, '音频已保存');
    action.value = 'search';
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-input')), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('未保存的想法'), findsOneWidget);
    expect(find.byKey(const Key('body-editor')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    action.dispose();
  });
  testWidgets('权限拒绝明确告知且没有虚假保存，仍可退出', (tester) async {
    final action = ValueNotifier<String?>('capsule');
    var returned = false;
    await tester.pumpWidget(
      NianxiaApp(
        book: book,
        shortcut: action,
        captureMicrophone: DeniedMicrophone(),
        onCapsuleReturn: () async {
          returned = true;
        },
      ),
    );
    await untilVisible(tester, '录音未保存');
    expect(find.textContaining('没有麦克风权限'), findsOneWidget);
    expect(book.records, isEmpty);
    expect(find.text('音频已保存'), findsNothing);
    await tester.tap(find.text('写文字'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('body-editor')), findsOneWidget);
    expect(returned, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    action.dispose();
  });
  testWidgets('胶囊两倍字体可操作，丢弃经确认后清除音频', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final action = ValueNotifier<String?>('capsule');
    final mic = TestMicrophone();
    await tester.pumpWidget(
      NianxiaApp(
        book: book,
        shortcut: action,
        captureMicrophone: mic,
        onCapsuleReturn: () async {},
      ),
    );
    await untilVisible(tester, '停止并保存');
    final semantics = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
    mic.chunks.add(Uint8List(32000));
    await tester.tap(find.text('丢弃'));
    await tester.pumpAndSettle();
    expect(find.text('确认丢弃'), findsOneWidget);
    await tester.tap(find.text('确认丢弃'));
    await untilVisible(tester, '全部记录');
    expect(book.records, isEmpty);
    await tester.runAsync(() async {
      expect(await Directory('${home.path}/audio').list().isEmpty, isTrue);
    });
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    action.dispose();
  });
}
