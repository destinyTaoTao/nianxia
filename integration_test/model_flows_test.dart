// Public/TTS fixture audio replaces the microphone input only. Native ASR and
// BGE, private PCM files, SQLite, background processing and widgets are real.
import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:record/record.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/ui/app.dart';

import 'support/fixture_record_platform.dart';
import 'support/test_sandbox.dart';
import 'local_models_test.dart' as native;

const fixtures = '/data/local/tmp/nianxia-models';

void main() {
  requireModelTestSandbox();
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Also exercise the real native microphone/player, beyond fixture input.
  native.main();

  Future<void> until(
    WidgetTester tester,
    FutureOr<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final end = DateTime.now().add(timeout);
    while (!await condition() && DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      await condition(),
      isTrue,
      reason: 'Timed out waiting for native workflow',
    );
  }

  Future<void> screenshot(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final bytes = await binding.takeScreenshot(name);
    final directory = Directory(
      '${Directory.systemTemp.path}/model-check-results',
    );
    await directory.create(recursive: true);
    await File('${directory.path}/$name.png').writeAsBytes(bytes);
  }

  Future<ModelStore> openStore() async {
    final store = ModelStore(
      Directory(fixtures),
      ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
    );
    expect(await store.ready('sensevoice'), isTrue);
    expect(await store.ready('bge'), isTrue);
    return store;
  }

  testWidgets('公开中文样本与已知中文合成语音使用可信测试模型完成真实识别', (tester) async {
    await tester.runAsync(() async {
      final store = await openStore();
      final models = LocalModels(store);
      try {
        final public = await models.transcribe('$fixtures/zh.wav');
        final note = await models.transcribe('$fixtures/note.wav');
        final query = await models.transcribe('$fixtures/query.wav');
        // The pinned INT8 model's documented public zh.wav output.
        expect(public, '开饭时间早上9点至下午5点。');
        for (final term in ['数据库', '索引', '查询速度']) {
          expect(note, contains(term));
        }
        for (final term in ['优化', '数据库', '查询性能']) {
          expect(query, contains(term));
        }
        // Only public or synthetic test content, never existing user records.
        // ignore: avoid_print
        print('Fixture ASR: public=$public; note=$note; query=$query');
      } finally {
        store.dispose();
      }
    });
  });

  testWidgets('录音落盘转写后可通过语音确认查询和语义找回，查询不入笔记', (tester) async {
    final store = await openStore();
    final models = LocalModels(store);
    final home = await Directory.systemTemp.createTemp('model-ui-flow-');
    final book = await Notebook.open(home);
    final background = BackgroundTasks(book, models);
    final nativeRecorder = RecordPlatform.instance;
    final microphone = FixtureRecordPlatform('$fixtures/note.wav');
    RecordPlatform.instance = microphone;
    try {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpWidget(NianxiaApp(book: book, models: models));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记一下'));
      await until(tester, () async => find.text('停止并保存').evaluate().isNotEmpty);
      await until(tester, () async => microphone.delivered);
      await tester.tap(find.text('停止并保存'));
      await until(tester, () async => (await book.records).length == 1);
      final id = (await book.records).single.id;
      expect(
        await File(book.audioPath((await book.get(id))!)).exists(),
        isTrue,
      );
      expect((await book.get(id))!.durationMs, greaterThan(3000));
      await until(
        tester,
        () async => (await book.get(id))!.transcription == 'done',
      );
      expect((await book.get(id))!.body, contains('数据库'));
      expect((await book.get(id))!.body, contains('索引'));
      expect((await book.get(id))!.transcript, contains('查询速度'));
      await until(
        tester,
        () async =>
            (await book.get(id))!.vectorRevision ==
            (await book.get(id))!.revision,
      );
      await tester.tap(find.text((await book.get(id))!.title));
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放原音频'), findsOneWidget);
      await screenshot(tester, 'recording-transcribed-detail');
      await tester.tap(find.byTooltip('播放原音频'));
      await until(
        tester,
        () async => find.byTooltip('暂停原音频').evaluate().isNotEmpty,
      );
      await until(
        tester,
        () async => find.byTooltip('播放原音频').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15),
      );
      // Completion must allow replay in one tap, rather than pause then play.
      await tester.tap(find.byTooltip('播放原音频'));
      await until(
        tester,
        () async => find.byTooltip('暂停原音频').evaluate().isNotEmpty,
      );
      await tester.tap(find.byTooltip('暂停原音频'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      final other = await book.saveText('周末准备去公园散步。');
      await until(
        tester,
        () async =>
            (await book.get(other.id))!.vectorRevision == other.revision,
      );
      microphone.path = '$fixtures/query.wav';
      microphone.delivered = false;
      await tester.tap(find.text('找一下'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('语音查找'));
      await until(
        tester,
        () async => find.text('停止并查看文字').evaluate().isNotEmpty,
      );
      await until(tester, () async => microphone.delivered);
      await tester.tap(find.text('停止并查看文字'));
      await until(
        tester,
        () async => find.text('识别文字可以修改，确认后点“查找”。').evaluate().isNotEmpty,
      );
      final input = find.byKey(const Key('search-input'));
      final recognized = tester.widget<TextField>(input).controller!.text;
      expect(recognized, contains('查询性能'));
      expect(find.text((await book.get(id))!.title), findsNothing);
      expect((await book.records).length, 2);
      expect(await Directory('${home.path}/queries').list().isEmpty, isTrue);
      await screenshot(tester, 'voice-query-review');

      // The phrase is absent from either record: keyword-only search must fail.
      const query = '怎样优化数据库的查询性能？';
      expect(await book.search(query), isEmpty);
      await tester.enterText(input, query);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text((await book.get(id))!.title), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '查找'));
      await until(
        tester,
        () async =>
            find.text((await book.get(id))!.title).evaluate().isNotEmpty,
      );
      expect(find.text('周末准备去公园散步。'), findsNothing);
      expect((await book.records).length, 2);
      await screenshot(tester, 'semantic-voice-result');
      final found = await book.search(query, embedder: models);
      expect(found.semanticUsed, isTrue);
      expect(found.fallbackReason, isNull);
      expect(found.single.record.id, id);

      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, '月球上的火山如何喷发');
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TextField>(input).controller!.text, '月球上的火山如何喷发');
      await until(tester, () {
        final button = find.widgetWithText(FilledButton, '查找');
        return button.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(button).onPressed != null;
      });
      await tester.tap(find.widgetWithText(FilledButton, '查找'));
      await tester.pump();
      await until(
        tester,
        () async => find.text('没有找到相关记录').evaluate().isNotEmpty,
      );
      await screenshot(tester, 'semantic-unrelated-empty');

      final r = (await book.get(id))!;
      await book.edit(id, '周末一起去湖边散步。', expectedRevision: r.revision);
      await until(
        tester,
        () async =>
            (await book.get(id))!.vectorRevision ==
            (await book.get(id))!.revision,
      );
      expect(await book.search(query, embedder: models), isEmpty);
      expect((await book.get(id))!.transcript, contains('数据库'));
      const editedQuery = '周末去湖边散步';
      expect(await book.search(editedQuery), isEmpty);
      final beforeDelete = await book.search(editedQuery, embedder: models);
      expect(beforeDelete.semanticUsed, isTrue);
      expect(beforeDelete.any((hit) => hit.record.id == id), isTrue);
      await book.delete(id);
      final afterDelete = await book.search(editedQuery, embedder: models);
      expect(afterDelete.any((hit) => hit.record.id == id), isFalse);
      expect((await book.records).single.id, other.id);
      expect(await Directory('${home.path}/queries').list().isEmpty, isTrue);
      // ignore: avoid_print
      print(
        'Full model flow: capture/transcript/index/voice review/search/edit/delete passed',
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      background.dispose();
      await microphone.drained();
      // Wait for a possible final background query to release model resources.
      await models.queue.run(() async {});
      RecordPlatform.instance = nativeRecorder;
      await book.close();
      store.dispose();
      await home.delete(recursive: true);
    }
  });

  testWidgets('静音转写失败仍保留录音，静音语音查询不产生笔记或临时文件', (tester) async {
    final store = await openStore();
    final models = LocalModels(store);
    final home = await Directory.systemTemp.createTemp('model-silence-');
    final book = await Notebook.open(home);
    final nativeRecorder = RecordPlatform.instance;
    final microphone = FixtureRecordPlatform('$fixtures/silence.wav');
    RecordPlatform.instance = microphone;
    final capture = CaptureController(book, models: models);
    final query = CaptureController(book, models: models, query: true);
    try {
      await capture.start();
      expect(capture.state, 'recording');
      await until(tester, () async => microphone.delivered);
      await capture.finish();
      expect(capture.state, 'done');
      final saved = (await book.records).single;
      await expectLater(
        book.transcribe(saved.id, models),
        throwsA(isA<NotebookException>()),
      );
      expect((await book.get(saved.id))!.transcription, 'failed');
      expect((await book.get(saved.id))!.body, isEmpty);
      expect(await File(book.audioPath(saved)).length(), greaterThan(44));
      microphone.delivered = false;
      await query.start();
      expect(query.state, 'recording');
      await until(tester, () async => microphone.delivered);
      await query.finish();
      expect(query.state, 'failed');
      expect(query.error, contains('未检测到有效语音'));
      expect(query.error, isNot(contains('保留')));
      expect((await book.records).single.id, saved.id);
      expect(await Directory('${home.path}/queries').list().isEmpty, isTrue);
    } finally {
      capture.dispose();
      query.dispose();
      await microphone.drained();
      await models.queue.run(() async {});
      RecordPlatform.instance = nativeRecorder;
      await book.close();
      store.dispose();
      await home.delete(recursive: true);
    }
  });
}
