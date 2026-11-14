// Public/TTS fixtures, real native models/player and SQLite; no user content.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/domain/search_page.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:record/record.dart';

import 'support/fixture_record_platform.dart';
import 'support/isolated_validation.dart';

class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('Network forbidden during offline acceptance');
  }
}

// Hold a real ASR result at the writeback boundary for deterministic edit/delete.
class _HeldResult implements Transcriber {
  _HeldResult(this.models);
  final LocalModels models;
  final ready = Completer<void>(), release = Completer<void>();
  @override
  Future<String> transcribe(String path) async {
    final text = await models.transcribe(path);
    ready.complete();
    await release.future;
    return text;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('isolated offline workflow and measured search', (tester) async {
    await requireIsolatedValidation();
    const testCase = String.fromEnvironment('VALIDATION_CASE');
    if (!{'offline-end-to-end', 'performance'}.contains(testCase)) {
      throw StateError('No ordinary smoke substitution for this case');
    }
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('公开语音与合成资料隔离验收'),
      ),
    );
    final home = await Directory.systemTemp.createTemp('acceptance-synthetic-');
    final book = await Notebook.open(home);
    final store = ModelStore(
      Directory('/data/local/tmp/nianxia-models'),
      ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
    );
    final models = LocalModels(store);
    final previous = HttpOverrides.current;
    final network = _NoNetwork();
    HttpOverrides.global = network;
    final nativeRecorder = RecordPlatform.instance;
    CaptureController? capture;
    final metrics = <String, num>{};
    var peakRss = ProcessInfo.currentRss;
    final rssSampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      peakRss = math.max(peakRss, ProcessInfo.currentRss);
    });
    try {
      expect(
        await store.ready('sensevoice'),
        isTrue,
      ); // pinned SHA-256 verification
      expect(await store.ready('bge'), isTrue);
      await book.setSearchModelVersion(models.searchModelVersion!);
      if (testCase == 'offline-end-to-end') {
        final fixture = FixtureRecordPlatform(
          '/data/local/tmp/nianxia-models/note.wav',
        );
        RecordPlatform.instance = fixture;
        capture = CaptureController(book);
        await capture.start();
        expect(capture.state, 'recording');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!fixture.delivered && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(fixture.delivered, isTrue);
        await capture.finish();
        expect(capture.state, 'done');
        final source = capture.saved!;
        expect((await book.records).length, 1);
        final watch = Stopwatch()..start();
        expect(await book.transcribe(source.id, models), isTrue);
        metrics['fixtureAsrMs'] = watch.elapsedMilliseconds;
        final transcribed = (await book.get(source.id))!;
        expect(transcribed.body, contains('数据库'));
        expect(transcribed.transcript, contains('查询速度'));
        final other = await book.saveText('周末准备去公园散步。');
        await book.index(source.id, models);
        await book.index(other.id, models);
        await book.repository.waitForSearchIndex();
        expect(
          (await book.searchPage(SearchQuery(text: '索引'))).entries.single.id,
          source.id,
        );
        final voiceText = await models.transcribe(
          '/data/local/tmp/nianxia-models/query.wav',
        );
        expect(voiceText, contains('数据库'));
        expect(
          (await book.searchPage(
            SearchQuery(text: voiceText),
            embedder: models,
          )).entries.first.id,
          source.id,
        );
        expect(
          (await book.searchPage(
            SearchQuery(text: '月球上的火山如何喷发'),
            embedder: models,
          )).entries,
          isEmpty,
        );
        final player = AudioPlayer();
        try {
          await player.setFilePath(book.audioPath(transcribed));
          await player.play().timeout(const Duration(seconds: 10));
          expect(player.processingState, ProcessingState.completed);
        } finally {
          await player.dispose();
        }
        final edit = _HeldResult(models);
        final lateEdit = book.transcribe(source.id, edit);
        await edit.ready.future;
        await book.edit(
          source.id,
          '用户手动确认的正文。',
          expectedRevision: transcribed.revision,
        );
        edit.release.complete();
        expect(await lateEdit, isFalse);
        expect((await book.get(source.id))!.body, '用户手动确认的正文。');
        final deletion = _HeldResult(models);
        final lateDelete = book.transcribe(source.id, deletion);
        await deletion.ready.future;
        await book.delete(source.id);
        deletion.release.complete();
        expect(await lateDelete, isFalse);
        expect(await book.get(source.id), isNull);
        expect(
          (await book.searchPage(SearchQuery(text: '用户手动确认'))).entries,
          isEmpty,
        );
        expect(await File(book.audioPath(transcribed)).exists(), isFalse);
        metrics.addAll({
          'fixtureRecordingSaved': 1,
          'nativeAsr': 1,
          'nativeSemanticSearch': 1,
          'nativePlaybackCompleted': 1,
          'lateEditPreserved': 1,
          'lateDeleteNotResurrected': 1,
          'microphoneIsPublicFixture': 1,
        });
      } else {
        // 10k synthetic rows, one real model vector copied as a load fixture.
        // This measures paging/runtime cost, never human retrieval quality.
        final vector = await models.embed('给数据库建立索引，可以加快查询速度。', query: false);
        final source = RecordRepository(home);
        source.transaction(() {
          for (var i = 0; i < 10000; i++) {
            final r = Record(
              id: 'synthetic-${i.toString().padLeft(5, '0')}',
              body: 'marker 数据库索引 $i ${'长正文'.padRight(1000, '文')}',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            );
            source.insert(r);
            source.embedding(r.id, 1, vector);
          }
        });
        source.close();
        final cold = Stopwatch()..start();
        await book.repository.waitForSearchIndex();
        metrics['indexBuildMs'] = cold.elapsedMilliseconds;
        peakRss = math.max(peakRss, ProcessInfo.currentRss);
        final samples = <int>[];
        for (var i = 0; i < 20; i++) {
          final watch = Stopwatch()..start();
          final result = await book.searchPage(SearchQuery(text: 'marker'));
          expect(result.entries.length, 40);
          samples.add(watch.elapsedMicroseconds);
          peakRss = math.max(peakRss, ProcessInfo.currentRss);
        }
        samples.sort();
        metrics['keywordFirstPageP95Us'] =
            samples[(samples.length * .95).ceil() - 1];
        final semantic = Stopwatch()..start();
        final result = await book.searchPage(
          SearchQuery(text: '怎样优化数据库的查询性能'),
          embedder: models,
        );
        expect(result.entries, isNotEmpty);
        metrics['modelQueryFirstPageMs'] = semantic.elapsedMilliseconds;
        metrics['sampledProcessRssBytes'] = math.max(
          peakRss,
          ProcessInfo.currentRss,
        );
        metrics['sourceRows'] = 10000;
        metrics['samples'] = samples.length;
      }
      metrics['sampledFullProcessRssBytes'] = math.max(
        peakRss,
        ProcessInfo.currentRss,
      );
      metrics['verifiedModelBytes'] = store.models.fold<int>(
        0,
        (total, model) =>
            total + model.files.fold<int>(0, (sum, asset) => sum + asset.bytes),
      );
      var sourceBytes = 0, cacheBytes = 0;
      await for (final entity in home.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.path.substring(home.path.length + 1);
        if (name.startsWith('records.sqlite') || name.startsWith('audio/')) {
          sourceBytes += await entity.length();
        } else {
          cacheBytes += await entity.length();
        }
      }
      metrics['sourceDiskBytes'] = sourceBytes;
      metrics['derivedAndTemporaryDiskBytes'] = cacheBytes;
      metrics['dartNetworkAttempts'] = network.attempts;
      expect(network.attempts, 0);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: metrics,
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      rssSampler.cancel();
      capture?.dispose();
      RecordPlatform.instance = nativeRecorder;
      await models.close();
      store.dispose();
      await book.close();
      HttpOverrides.global = previous;
      await home.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
