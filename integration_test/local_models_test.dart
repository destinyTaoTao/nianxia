// Requires the trusted assets staged by tool/stage_android_models.sh.
// Runs the real Android/iOS plugin path; it is not part of the host-only suite.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('同一个安装包中 CPU 语音识别与 BGE 向量推理可串行运行', (tester) async {
    await tester.runAsync(() async {
      final store = ModelStore(
        Directory('/data/local/tmp/nianxia-models'),
        ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
      );
      final models = LocalModels(store);
      try {
        expect(await store.ready('sensevoice'), isTrue);
        expect(await store.ready('bge'), isTrue);
        final text = await models.transcribe(
          '/data/local/tmp/nianxia-models/zh.wav',
        );
        expect(text, isNotEmpty);
        expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(text), isTrue);
        final related = await models.embed('给数据库建立索引，可以加快查询速度。', query: false);
        final unrelated = await models.embed('周末准备去公园散步。', query: false);
        final query = await models.embed('怎样优化数据库的查询性能', query: true);
        expect(related.length, 512);
        expect(
          math.sqrt(related.fold<double>(0, (s, v) => s + v * v)),
          closeTo(1, 0.001),
        );
        double cosine(List<double> a, List<double> b) => List.generate(
          a.length,
          (i) => a[i] * b[i],
        ).fold(0, (s, v) => s + v);
        final good = cosine(query, related), bad = cosine(query, unrelated);
        expect(good, greaterThan(bad));
        final home = await Directory.systemTemp.createTemp('native-search-');
        final book = await Notebook.open(home);
        try {
          final record = await book.saveText('给数据库建立索引，可以加快查询速度。');
          final other = await book.saveText('周末准备去公园散步。');
          await book.index(record.id, models);
          await book.index(other.id, models);
          final found = await book.search('怎样优化数据库的查询性能', embedder: models);
          expect(found, isNotEmpty);
          expect(found.first.record.id, record.id);
          expect(await book.search('月球上的火山如何喷发', embedder: models), isEmpty);
        } finally {
          book.dispose();
          await home.delete(recursive: true);
        }
        // Only synthetic test metrics, never user note/audio content.
        // ignore: avoid_print
        print(
          'Native smoke: ASR characters=${text.length}; BGE related=$good unrelated=$bad',
        );
      } finally {
        store.dispose();
      }
    });
  });
  testWidgets('Android 原生 PCM 采集经真实私有文件保存为可回放 WAV', (tester) async {
    await tester.runAsync(() async {
      final home = await Directory.systemTemp.createTemp('native-capture-');
      final book = await Notebook.open(home);
      final capture = CaptureController(book);
      try {
        await capture.start();
        expect(capture.state, 'recording');
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await capture.finish();
        expect(capture.state, 'done');
        expect(book.records.single.durationMs, greaterThan(0));
        expect(
          await File(book.audioPath(book.records.single)).length(),
          greaterThan(44),
        );
        final player = AudioPlayer();
        try {
          await player.setFilePath(book.audioPath(book.records.single));
          await player.play().timeout(const Duration(seconds: 8));
          expect(player.processingState, ProcessingState.completed);
        } finally {
          await player.dispose();
        }
      } finally {
        capture.dispose();
        book.dispose();
        await home.delete(recursive: true);
      }
    });
  });
}
