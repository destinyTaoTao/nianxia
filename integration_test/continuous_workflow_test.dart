import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';
import 'package:path/path.dart' as p;

import 'package:record/record.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';

import '../test/support/storage_probe.dart';
import 'support/fixture_record_platform.dart';
import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('offline combined continuous notebook with real models', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Invalid isolated run');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'continuous-workflow', runId),
    );
    final shots = await Directory(p.join(root.path, 'screenshots'))
        .create(recursive: true);
    var minute = 0, screenshotCount = 0;
    final book = await Notebook.open(
      Directory(p.join(root.path, 'source')),
      clock: () => DateTime.utc(2026, 11, 20, 9, minute++),
    );
    final playback = PlaybackCoordinator.retain(book);
    Future<void> waitFor(bool Function() ready) async {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (!ready() && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
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
      await tester.pump();
    }

    Future<void> tap(Finder target) async {
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      expect(target.hitTestable(), findsOneWidget);
      await tester.tap(target);
      await tester.pumpAndSettle();
    }

    Future<void> shot(String name) async {
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final bytes = await binding.takeScreenshot(name);
      await File(p.join(shots.path, '$name.png'))
          .writeAsBytes(bytes, flush: true);
      screenshotCount++;
    }

    final store = ModelStore(
      Directory('/data/local/tmp/nianxia-models'),
      ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
    );
    final models = LocalModels(store);
    final tasks = BackgroundTasks(book, models);
    final nativeRecorder = RecordPlatform.instance;
    final microphone = FixtureRecordPlatform(
      '/data/local/tmp/nianxia-models/note.wav',
    );
    RecordPlatform.instance = microphone;
    final previous = HttpOverrides.current;
    final network = _NoNetwork();
    HttpOverrides.global = network;
    final shortcut = ValueNotifier<String?>(null);
    Future<void> lookup(String text) async {
      final input = find.byKey(const Key('search-input'));
      await tester.ensureVisible(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, text);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await waitFor(
        () =>
            find.textContaining('找到 ').evaluate().isNotEmpty &&
            find.textContaining('尚未更新').evaluate().isEmpty,
      );
    }

    try {
      expect(await store.ready('sensevoice'), isTrue);
      expect(await store.ready('bge'), isTrue);
      await book.saveThemeMode('light');
      await tester.pumpWidget(
        NianxiaApp(book: book, models: models, shortcut: shortcut),
      );
      await waitFor(
        () => find.byKey(const Key('hold-record')).evaluate().isNotEmpty,
      );
      tester.testTextInput.register();
      await binding.convertFlutterSurfaceToImage();
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('hold-record'))),
      );
      await waitFor(() => microphone.delivered);
      await gesture.up();
      await waitFor(
        () => find.text('按住说话').evaluate().isNotEmpty && !book.captureActive,
      );
      Record? source;
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        final rows = await book.records;
        if (rows.length == 1 &&
            rows.single.transcription == 'done' &&
            rows.single.vectorRevision == rows.single.revision) {
          source = rows.single;
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(source, isNotNull);
      final original = source!;
      expect(original.body, contains('数据库'));
      expect(original.transcript, contains('查询速度'));
      expect(await File(book.audioPath(original)).length(), greaterThan(44));
      await shot('transcribed');
      shortcut.value = 'search';
      await waitFor(() => find.text('改用文字').evaluate().isNotEmpty);
      expect(book.captureActive, isFalse);
      await tap(find.text('改用文字'));
      await lookup('索引');
      await waitFor(() => find.text(original.title).evaluate().isNotEmpty);
      await shot('found');
      await tap(find.text(original.title));
      await waitFor(() => find.text('追加内容').evaluate().isNotEmpty);
      await tap(find.text('追加内容'));
      await tap(find.text('追加文字'));
      final editor = find.byKey(const Key('body-editor'));
      await tester.enterText(editor, '组合验收：索引需要实测后确认。');
      StorageProbe(book).execute(
        "CREATE TRIGGER reject_append BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'controlled'); END",
      );
      await tap(find.widgetWithText(TextButton, '保存'));
      await waitFor(() => find.textContaining('保存未完成').evaluate().isNotEmpty);
      expect(
        tester.widget<TextField>(editor).controller!.text,
        '组合验收：索引需要实测后确认。',
      );
      await shot('append-failed');
      StorageProbe(book).execute('DROP TRIGGER reject_append');
      await tap(find.widgetWithText(TextButton, '保存'));
      await waitFor(
        () =>
            find.text('组合验收：索引需要实测后确认。').evaluate().isNotEmpty &&
            editor.evaluate().isEmpty,
      );
      expect(await book.childCount(original.id), 1);
      await shot('text-appended');
      await tester.pump(const Duration(seconds: 4));
      await tap(find.text('追加内容'));
      await tap(find.text('追加语音'));
      microphone.delivered = false;
      final appendGesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('hold-record'))),
      );
      await waitFor(() => microphone.delivered);
      await appendGesture.up();
      await waitFor(
        () => find.byKey(const Key('voice-append-panel')).evaluate().isEmpty,
      );
      Record? voice;
      final appendDeadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(appendDeadline)) {
        final children = await book.children(original.id);
        final audio = children.where((r) => r.audio != null);
        if (audio.length == 1 && audio.single.transcription == 'done') {
          voice = audio.single;
          break;
        }
        await tester.pump(const Duration(milliseconds: 100));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(voice, isNotNull);
      expect(voice!.body, contains('数据库'));
      expect(await book.childCount(original.id), 2);
      expect((await book.get(original.id))!.body, original.body);
      await shot('voice-appended');
      await tap(find.byType(BackButton));
      await waitFor(
        () => find.byKey(const Key('search-input')).evaluate().isNotEmpty,
      );
      await lookup('组合验收');
      await waitFor(
        () => find.text('所属：${original.title}').evaluate().isNotEmpty,
      );
      expect(find.text('组合验收：索引需要实测后确认。'), findsOneWidget);
      await shot('refound');
      await tap(find.text('所属：${original.title}'));
      await waitFor(() => find.text('追加内容').evaluate().isNotEmpty);
      await tap(find.byTooltip('更多操作'));
      await tap(find.text('删除记录'));
      await waitFor(() => find.text('删除这组 3 条记录？').evaluate().isNotEmpty);
      await shot('delete-confirmed-scope');
      await tap(find.text('删除'));
      await waitFor(() => find.text('没有找到相关记录').evaluate().isNotEmpty);
      expect(await book.records, isEmpty);
      expect(await File(book.audioPath(original)).exists(), isFalse);
      expect(await File(book.audioPath(voice)).exists(), isFalse);
      expect(
        await Directory(p.join(book.home.path, 'queries')).exists()
            ? await Directory(p.join(book.home.path, 'queries')).list().isEmpty
            : true,
        isTrue,
      );
      expect(network.attempts, 0);
      await shot('deleted');
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'screenshots': screenshotCount,
          'actualASR': 2,
          'actualBGE': 1,
          'networkAttempts': network.attempts,
          'textVoiceAppend': 1,
          'failureRetry': 1,
          'confirmedScopeDelete': 1,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      tasks.dispose();
      await microphone.drained();
      await models.queue.run(() async {});
      RecordPlatform.instance = nativeRecorder;
      shortcut.dispose();
      HttpOverrides.global = previous;
      await playback.release();
      await book.close();
      store.dispose();
      await Directory(p.join(root.path, 'source')).delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

class _NoNetwork extends HttpOverrides {
  int attempts = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('HTTP forbidden during offline combined acceptance');
  }
}
