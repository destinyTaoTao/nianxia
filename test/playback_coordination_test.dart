import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/playback_coordinator.dart';
import 'package:nianxia/ui/app.dart';

import 'hold_recording_test.dart' show HoldMicrophone;
import 'recording_search_test.dart' show writeWave;
import 'support/async_storage_tester.dart';
import 'support/ui_native_capture.dart';

class OutputFixture extends ChangeNotifier implements PlaybackOutput {
  @override
  bool playing = false;
  @override
  bool completed = false;
  @override
  Duration position = Duration.zero;
  @override
  Object? failure;
  Completer<void>? stopGate, loadGate;
  bool failLoad = false, failStop = false, failSeek = false, failClose = false;
  final loads = <String>[];
  final heard = <String>[];
  String? source;
  int starts = 0, stops = 0;
  @override
  Future<void> load(String path) async {
    if (await File(path).length() <= 44) {
      throw StateError('Expected actual WAV');
    }
    loads.add(path);
    source = path;
    await loadGate?.future;
    if (failLoad) throw const FileSystemException('output load fault');
    position = Duration.zero;
    completed = false;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    starts++;
    heard.add(source!);
    playing = true;
    completed = false;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    if (failStop) throw const FileSystemException('output stop fault');
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration value) async {
    if (failSeek) throw const FileSystemException('seek fault');
    position = value;
    completed = false;
    notifyListeners();
  }

  void end() {
    completed = true;
    position = const Duration(seconds: 1);
    notifyListeners();
  }

  @override
  Future<void> close() async {
    if (failClose) throw const FileSystemException('close fixture fault');
    dispose();
  }
}

void main() {
  late Directory directory;
  late Notebook book;
  late Record root, child;
  late OutputFixture output;
  late PlaybackCoordinator owner;
  final cleanup = <Future<void> Function()>[];
  setUp(() async {
    cleanup.clear();
    directory = await Directory.systemTemp.createTemp('nx-playback-');
    book = await Notebook.open(directory);
    Future<Record> clip(String body, {String? parent}) async {
      final d = await book.beginCapture(parentId: parent);
      await writeWave(d.path);
      final r = await book.finishCapture(d);
      await book.edit(r.id, body, expectedRevision: r.revision);
      return (await book.get(r.id))!;
    }

    root = await clip('第一段原话');
    child = await clip('这一次追加原话', parent: root.id);
    output = OutputFixture();
    owner = PlaybackCoordinator.retain(book, output: output);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.nianxia/system'),
          (call) async =>
              call.method == 'recordingScreenAvailable' ? true : null,
        );
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await owner.release();
      await book.close();
      await directory.delete(recursive: true);
    });
  });
  Future<void> tick(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (var i = 0; i < 300 && !condition(); i++) {
      await tick(tester);
    }
    expect(condition(), isTrue);
    await tester.pump();
  }

  Future<T> drive<T>(WidgetTester tester, Future<T> future) async {
    var done = false;
    T? result;
    Object? failure;
    StackTrace? trace;
    future.then<void>(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object e, StackTrace s) {
        failure = e;
        trace = s;
        done = true;
      },
    );
    await until(tester, () => done);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return result as T;
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text(root.body));
    await pumpStorageAndSettle(tester);
  }

  Future<void> play(WidgetTester tester) async {
    await tester.ensureVisible(find.byTooltip('播放原音频'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => output.playing);
  }

  void checkPlayback(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        if (tester.binding.lifecycleState == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        }
        if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        if (output.stopGate != null && !output.stopGate!.isCompleted) {
          output.stopGate!.complete();
        }
        if (output.loadGate != null && !output.loadGate!.isCompleted) {
          output.loadGate!.complete();
        }
        await tick(tester);
        for (final release in cleanup.reversed) {
          await release();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpStorageAndSettle(tester);
        await drive(tester, owner.release());
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  checkPlayback('按需加载，播放暂停和进度可用，EOF重播从头开始', (tester) async {
    await launch(tester);
    expect(output.loads, isEmpty);
    await play(tester);
    expect(output.loads, [book.audioPath(root)]);
    expect(find.byTooltip('暂停原音频'), findsOneWidget);
    final slider = find.byType(Slider);
    await tester.tapAt(tester.getCenter(slider));
    await pumpStorageAndSettle(tester);
    expect(output.position.inMilliseconds, inInclusiveRange(400, 600));
    await tester.tap(find.byTooltip('暂停原音频'));
    await until(tester, () => !output.playing);
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => output.playing);
    expect(output.loads, hasLength(1));
    output.end();
    await tester.pump();
    expect(find.byTooltip('播放原音频'), findsOneWidget);
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => !output.completed);
    expect(output.position, Duration.zero);
    expect(output.loads, hasLength(1));
  });
  checkPlayback('进入追加详情先停原记录，下一段独占输出，返回不继续播放', (tester) async {
    await launch(tester);
    await play(tester);
    await tester.ensureVisible(find.text(child.body));
    await tester.pumpAndSettle();
    await tester.tap(find.text(child.body));
    await pumpStorageAndSettle(tester);
    expect(output.playing, isFalse);
    await play(tester);
    expect(output.loads, [book.audioPath(root), book.audioPath(child)]);
    await tester.tap(find.byType(BackButton));
    await pumpStorageAndSettle(tester);
    expect(output.playing, isFalse);
    expect(find.text('第一段原话'), findsOneWidget);
  });
  checkPlayback('普通采集等待实际停播，迟到加载完成不能在录音中恢复播放', (tester) async {
    await launch(tester);
    output.loadGate = Completer<void>();
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => output.loads.isNotEmpty);
    output.stopGate = Completer<void>();
    final mic = HoldMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final work = capture.start();
    cleanup.add(() async {
      await drive(tester, work);
      if (capture.state == 'recording') await drive(tester, capture.discard());
      capture.dispose();
    });
    await until(
      tester,
      () => capture.state == 'recording' || output.stops >= 2,
    );
    final startsBeforeStop = mic.starts;
    output.stopGate!.complete();
    await drive(tester, work);
    expect(capture.state, 'recording');
    output.loadGate!.complete();
    await pumpStorageAndSettle(tester);
    expect(output.playing, isFalse);
    expect(output.starts, 0);
    mic.feed();
    await tick(tester);
    await drive(tester, capture.finish());
    expect(capture.state, 'done');
    expect(startsBeforeStop, 0);
    expect((await storageRead(tester, () => book.records)).length, 3);
  });
  checkPlayback('受控原生物理start同样等待停播', (tester) async {
    await launch(tester);
    await play(tester);
    output.stopGate = Completer<void>();
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, book, runtime);
    final work = capture.start(mode: CaptureMode.record);
    cleanup.add(() async {
      await drive(tester, work);
      await drive(tester, capture.discard());
      capture.dispose();
      runtime.dispose();
    });
    await tick(tester);
    final startsBeforeStop = endpoint.starts;
    output.stopGate!.complete();
    await drive(tester, work);
    expect(endpoint.starts, 1);
    await drive(tester, capture.discard());
    expect(startsBeforeStop, 0);
    expect(output.playing, isFalse);
    expect((await storageRead(tester, () => book.records)).length, 2);
  });
  checkPlayback('加载失败给出重试，离开期间完成的load不得开始播放', (tester) async {
    await launch(tester);
    output.failLoad = true;
    await tester.tap(find.byTooltip('播放原音频'));
    await until(
      tester,
      () => find.textContaining('无法回放').evaluate().isNotEmpty,
    );
    output.failLoad = false;
    output.loadGate = Completer<void>();
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => output.loads.length == 2);
    await tester.tap(find.byType(BackButton));
    await tester.pump(const Duration(milliseconds: 100));
    output.loadGate!.complete();
    await pumpStorageAndSettle(tester);
    expect(output.playing, isFalse);
    expect(output.starts, 0);
  });
  checkPlayback('切后台停播，恢复后不自行继续', (tester) async {
    await launch(tester);
    await play(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await until(tester, () => !output.playing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpStorageAndSettle(tester);
    expect(output.playing, isFalse);
    expect(find.byTooltip('播放原音频'), findsOneWidget);
  });
  checkPlayback('无法停播时不启动麦克风，原音频和源记录不受影响', (tester) async {
    await launch(tester);
    await play(tester);
    output.failStop = true;
    final mic = HoldMicrophone();
    final capture = CaptureController(book, microphone: mic);
    final work = capture.start();
    cleanup.add(() async {
      output.failStop = false;
      await drive(tester, work);
      await drive(tester, capture.discard());
      capture.dispose();
    });
    await drive(tester, work);
    expect(capture.state, 'failed');
    expect(capture.error, contains('原音频暂时无法停止'));
    expect(mic.starts, 0);
    expect((await storageRead(tester, () => book.records)).length, 2);
    expect(
      await storageRead(tester, () => File(book.audioPath(root)).length()),
      greaterThan(44),
    );
  });
  checkPlayback('恢复已有的原生采集也停止输出，不重新启动第二采集', (tester) async {
    await launch(tester);
    await play(tester);
    final endpoint = UiCaptureEndpoint(book);
    final runtime = UiCaptureRuntime();
    await drive(
      tester,
      endpoint.start(
        CaptureRequest(
          sessionId: '11111111-1111-4111-8111-111111111111',
          mode: CaptureMode.record,
          createdAtUtc: DateTime.utc(2026, 11, 19),
          timezone: 'UTC',
          offsetMinutes: 0,
        ),
      ),
    );
    final capture = CaptureSessionController(endpoint, book, runtime);
    cleanup.add(() async {
      await drive(tester, capture.discard());
      capture.dispose();
      runtime.dispose();
    });
    await drive(tester, capture.start(mode: CaptureMode.record));
    expect(output.playing, isFalse);
    expect(endpoint.starts, 1);
  });
  checkPlayback('进度定位失败后重试成功清除旧错误', (tester) async {
    await launch(tester);
    await play(tester);
    output.failSeek = true;
    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await until(
      tester,
      () => find.textContaining('无法调整回放位置').evaluate().isNotEmpty,
    );
    output.failSeek = false;
    await tester.tapAt(tester.getCenter(find.byType(Slider)));
    await pumpStorageAndSettle(tester);
    expect(output.position.inMilliseconds, inInclusiveRange(400, 600));
    expect(find.textContaining('无法调整回放位置'), findsNothing);
  });
  checkPlayback('旧播放器尚未关闭时新会话不开始输出', (tester) async {
    await launch(tester);
    await play(tester);
    final oldOutput = output;
    final oldGate = Completer<void>();
    oldOutput.stopGate = oldGate;
    await tester.pumpWidget(const SizedBox.shrink());
    await tick(tester);
    final closing = owner.release();
    final fresh = OutputFixture();
    owner = PlaybackCoordinator.retain(book, output: fresh);
    output = fresh;
    final newPlay = owner.toggle(Object(), book.audioPath(child));
    try {
      await tick(tester);
      await tick(tester);
      expect(oldOutput.playing, isTrue);
      expect(fresh.stops, 0);
      expect(fresh.playing, isFalse);
    } finally {
      oldGate.complete();
      await drive(tester, closing);
      await drive(tester, newPlay);
    }
  });
  checkPlayback('B切源失败后回A必须重新加载A，不能把B播成A', (tester) async {
    await launch(tester);
    await play(tester);
    await tester.ensureVisible(find.text(child.body));
    await tester.pumpAndSettle();
    await tester.tap(find.text(child.body));
    await pumpStorageAndSettle(tester);
    output.failLoad = true;
    await tester.tap(find.byTooltip('播放原音频'));
    await until(
      tester,
      () => find.textContaining('无法回放').evaluate().isNotEmpty,
    );
    output.failLoad = false;
    await tester.tap(find.byType(BackButton));
    await pumpStorageAndSettle(tester);
    await play(tester);
    expect(output.heard, [book.audioPath(root), book.audioPath(root)]);
    expect(output.loads, [
      book.audioPath(root),
      book.audioPath(child),
      book.audioPath(root),
    ]);
  });
  checkPlayback('同一App状态更换Notebook后，后台停止当前资料库的播放', (tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    final otherDirectory = await storageRead(
      tester,
      () => Directory.systemTemp.createTemp('nx-playback-other-'),
    );
    final other = await storageRead(
      tester,
      () => Notebook.open(otherDirectory),
    );
    late Record clip;
    await storageRead(tester, () async {
      final draft = await other.beginCapture();
      await writeWave(draft.path);
      final saved = await other.finishCapture(draft);
      await other.edit(saved.id, '第二资料库音频', expectedRevision: saved.revision);
      clip = (await other.get(saved.id))!;
    });
    final otherOutput = OutputFixture();
    final otherOwner = PlaybackCoordinator.retain(other, output: otherOutput);
    cleanup.add(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStorageAndSettle(tester);
      await drive(tester, otherOwner.release());
      await storageRead(tester, () => other.close());
      await storageRead(tester, () => otherDirectory.delete(recursive: true));
    });
    await tester.pumpWidget(NianxiaApp(book: other));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text(clip.body));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('播放原音频'));
    await until(tester, () => otherOutput.playing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tick(tester);
    expect(otherOutput.playing, isFalse);
  });
  checkPlayback('停播已确认后的解码器释放失败记录封闭诊断，不伪装为停播失败或永久阻塞采集', (tester) async {
    final diagnostics = LocalDiagnostics(
      Directory('${directory.path}/diagnostics'),
    );
    final lease = PlaybackCoordinator.retain(book, diagnostics: diagnostics);
    try {
      await launch(tester);
      await play(tester);
      output.failClose = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStorageAndSettle(tester);
      await drive(tester, lease.release());
      await drive(tester, owner.release());
      await drive(tester, diagnostics.flush());
      final file = await drive(tester, diagnostics.export());
      final text = await drive(tester, file.readAsString());
      final events = text
          .trim()
          .split('\n')
          .skip(1)
          .map((line) => jsonDecode(line) as Map)
          .toList();
      expect(events, hasLength(1));
      expect(events.single['kind'], 'playback');
      expect(events.single['phase'], 'cleanup');
      expect(events.single['errorCode'], 'unavailable');
      expect(text, isNot(contains(directory.path)));
      expect(text, isNot(contains(root.body)));
      expect(output.playing, isFalse);
      await drive(
        tester,
        PlaybackCoordinator.startCapture<void>(book, () async {}),
      );
    } finally {
      await drive(tester, diagnostics.close());
    }
  });
}
