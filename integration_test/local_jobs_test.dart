import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/domain/local_job.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test/recording_search_test.dart' show writeWave;
import 'support/isolated_validation.dart';

class _Speech implements Transcriber {
  @override
  Future<String> transcribe(String path) async =>
      'synthetic committed transcript';
}

class _Runtime extends ChangeNotifier implements InferenceRuntime {
  @override
  String get searchModelVersion => 'synthetic-model-v1';
  @override
  String get speechModelVersion => 'synthetic-speech-v1';
  @override
  void setCaptureActive(bool active) {}
  @override
  Future<void> close() async => dispose();
  @override
  Future<bool> ready(InferenceCapability capability) async =>
      capability == InferenceCapability.semantic;
  @override
  Future<List<double>> embed(String text, {required bool query}) async => [
    1,
    0,
  ];
  @override
  Future<String> transcribe(String path, {bool foreground = true}) =>
      _Speech().transcribe(path);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('隔离任务恢复、旧租约拒绝及在途队列资源关闭', (tester) async {
    await requireIsolatedValidation();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('任务恢复隔离验证'),
      ),
    );
    final home = await Directory.systemTemp.createTemp('jobs-synthetic-');
    var book = await Notebook.open(home);
    try {
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      final saved = await book.finishCapture(draft);
      expect(
        await book.claimLocalJob(kinds: {JobKind.transcription}),
        isNotNull,
      );
      expect(await book.transcribe(saved.id, _Speech()), isTrue);
      await book.close();
      book = await Notebook.open(home);
      expect(await book.claimLocalJob(kinds: {JobKind.transcription}), isNull);
      final old = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
      final r = (await book.get(saved.id))!;
      await book.edit(
        saved.id,
        'synthetic edited body',
        expectedRevision: r.revision,
      );
      await book.finishLocalJob(old, outcome: JobOutcome.succeeded);
      final fresh = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
      expect(fresh.sourceRevision, r.revision + 1);
      expect(fresh.leaseToken, isNot(old.leaseToken));
      final competing = await Notebook.open(home);
      try {
        expect(
          await competing.claimLocalJob(kinds: {JobKind.embedding}),
          isNull,
        );
      } finally {
        await competing.close();
      }
      final queue = InferenceQueue();
      final entered = Completer<void>();
      final release = Completer<void>();
      var freed = false;
      final rejected = expectLater(
        queue.run(() async {
          entered.complete();
          try {
            await release.future;
            return 1;
          } finally {
            freed = true;
          }
        }),
        throwsA(isA<NotebookException>()),
      );
      await entered.future;
      var closed = false;
      final closing = queue.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      release.complete();
      await closing;
      await rejected;
      expect(freed, isTrue);
      final text = await book.saveText('synthetic capture pause');
      book.captureActive = true;
      final runtime = _Runtime();
      final tasks = BackgroundTasks(book, runtime);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect((await book.get(text.id))!.vectorRevision, isNull);
        book.captureActive = false;
        final until = DateTime.now().add(const Duration(seconds: 5));
        while ((await book.get(text.id))!.vectorRevision == null &&
            DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect((await book.get(text.id))!.vectorRevision, 1);
      } finally {
        tasks.dispose();
        await runtime.close();
      }
      final db = sqlite3.open('${home.path}/records.sqlite');
      expect(db.userVersion, 2);
      db.close();
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sourceRows': (await book.records).length,
          'committedTranscriptReplayed': 0,
          'staleLeaseRejected': 1,
          'inFlightActionReleased': freed ? 1 : 0,
          'sourceSchema': 2,
          'captureStateWakeup': 1,
          'ownerLeaseProtected': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await book.close();
      await home.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
