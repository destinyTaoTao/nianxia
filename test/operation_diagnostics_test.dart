import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/app/notebook_session.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/domain/search_page.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/platform/capture_controller.dart';

import 'hold_recording_test.dart' show HoldMicrophone;
import 'capture_controller_test.dart' show PendingPermissionMicrophone;
import 'support/ui_native_capture.dart';

class _PendingSearch implements Embedder {
  final started = Completer<void>();
  final answer = Completer<List<double>>();
  @override
  Future<List<double>> embed(String text, {required bool query}) {
    started.complete();
    return answer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late NotebookSession session;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-operation-diag-');
    session = await NotebookSession.open(
      home,
      loadModelManifest: () async => '[]',
    );
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
    await session.close();
    await home.delete(recursive: true);
  });
  Future<List<Map<String, dynamic>>> events(
    LocalDiagnostics diagnostics,
  ) async {
    final file = await diagnostics.export();
    return (await file.readAsLines())
        .skip(1)
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
  }

  test('真实写入和查找发出诊断，错误和取消有别，正文查询源ID路径不进入日志', () async {
    const sentinel = 'private-body-query-key-path-sentinel';
    final book = session.book;
    final record = await book.saveText(sentinel);
    await book.edit(record.id, '$sentinel edited', expectedRevision: 1);
    await book.favorite(record.id, true);
    await book.searchPage(SearchQuery(text: sentinel));
    await book.search(sentinel);
    final cancelled = SearchCancellation()..cancel();
    await expectLater(
      book.searchPage(SearchQuery(text: sentinel), cancellation: cancelled),
      throwsA(anything),
    );
    await expectLater(
      book.edit(record.id, sentinel, expectedRevision: 1),
      throwsA(anything),
    );
    await book.delete(record.id);
    final entries = await events(session.diagnostics);
    final writes = entries.where((e) => e['kind'] == 'sourceWrite');
    expect(
      writes.where((e) => e['result'] == 'succeeded').length,
      greaterThanOrEqualTo(4),
    );
    expect(writes.where((e) => e['result'] == 'failed'), isNotEmpty);
    expect(
      entries.where((e) => e['kind'] == 'search' && e['result'] == 'cancelled'),
      hasLength(1),
    );
    expect(
      entries.where((e) => e['kind'] == 'search' && e['result'] == 'succeeded'),
      hasLength(2),
    );
    final serialized = jsonEncode(entries);
    for (final secret in [sentinel, record.id, home.path]) {
      expect(serialized, isNot(contains(secret)));
    }
  });

  test('实际默认采集成功和取消均发出终态，诊断不包含音频资料标识', () async {
    final mic = HoldMicrophone();
    final capture = CaptureController(session.book, microphone: mic);
    final cancelMic = HoldMicrophone();
    final cancelled = CaptureController(session.book, microphone: cancelMic);
    try {
      await capture.start();
      mic.feed();
      await capture.finish();
      expect(capture.saved, isNotNull);
      await session.book.finishCapture(capture.draft!, recovering: true);
      await cancelled.start();
      await cancelled.discard();
      final entries = await events(session.diagnostics);
      final captured = entries.where((e) => e['kind'] == 'capture');
      expect(
        entries.where(
          (e) => e['kind'] == 'sourceWrite' && e['result'] == 'succeeded',
        ),
        hasLength(1),
      );
      expect(
        captured.where(
          (e) => e['result'] == 'succeeded' && e['phase'] == 'finalize',
        ),
        isNotEmpty,
      );
      expect(captured.where((e) => e['result'] == 'cancelled'), hasLength(1));
      expect(jsonEncode(entries), isNot(contains(capture.draft!.id)));
      expect(jsonEncode(entries), isNot(contains(capture.draft!.path)));
    } finally {
      capture.dispose();
      cancelled.dispose();
      await mic.close();
      await cancelMic.close();
    }
  });

  test('dispose期间已接受的保存先完成，再关闭并排空诊断', () async {
    final saving = session.book.saveText('synthetic accepted before close');
    session.dispose();
    await saving;
    await session.close();
    final reopened = LocalDiagnostics(Directory('${home.path}/diagnostics'));
    try {
      final entries = await events(reopened);
      expect(
        entries.where(
          (e) => e['kind'] == 'sourceWrite' && e['result'] == 'succeeded',
        ),
        hasLength(1),
      );
    } finally {
      await reopened.close();
    }
  });

  test('受控原生采集有终态诊断，音量帧不会重复计数', () async {
    final endpoint = UiCaptureEndpoint(session.book);
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(endpoint, session.book, runtime);
    try {
      final value = await capture.start(mode: CaptureMode.record);
      for (var i = 1; i <= 10; i++) {
        endpoint.value = CaptureSnapshot.fromMap({
          ...value.request.toMap(),
          'phase': 'recording',
          'sequence': value.sequence + i,
          'elapsedMs': i * 100,
          'pcmBytes': i * 3200,
          'level': 0.1,
        });
        endpoint.updates.add(endpoint.value!);
      }
      await Future<void>.delayed(Duration.zero);
      await capture.stop();
      final entries = await events(session.diagnostics);
      final captured = entries.where((e) => e['kind'] == 'capture');
      expect(captured.where((e) => e['phase'] == 'run'), hasLength(1));
      expect(
        captured.where(
          (e) => e['phase'] == 'finalize' && e['result'] == 'succeeded',
        ),
        hasLength(1),
      );
      expect(jsonEncode(entries), isNot(contains(value.sessionId)));
    } finally {
      capture.dispose();
      runtime.dispose();
    }
  });

  test('诊断目录不可写不影响真实保存或查找，并报告丢弃计数', () async {
    await session.diagnostics.flush();
    final directory = Directory('${home.path}/diagnostics');
    final retained = await directory.rename(
      '${home.path}/retained-diagnostics',
    );
    final blocked = File(directory.path);
    try {
      await blocked.writeAsString('synthetic blocked optional diagnostics');
      final saved = await session.book.saveText(
        'retained despite diagnostic failure',
      );
      final results = await session.book.search('retained');
      await session.diagnostics.flush();
      expect(results.single.record.id, saved.id);
      expect(
        (await session.book.get(saved.id))!.body,
        'retained despite diagnostic failure',
      );
      expect(session.diagnostics.dropped, greaterThan(0));
    } finally {
      if (await blocked.exists()) await blocked.delete();
      await retained.rename(directory.path);
    }
  });

  test('关闭不等待迟到检索模型，已接受查找诊断以stale排空', () async {
    final engine = _PendingSearch();
    final searching = session.book.searchPage(
      SearchQuery(text: 'synthetic search'),
      embedder: engine,
    );
    await engine.started.future;
    await session.close().timeout(const Duration(seconds: 2));
    expect((await searching).entries, isEmpty);
    final reopened = LocalDiagnostics(Directory('${home.path}/diagnostics'));
    try {
      final entries = await events(reopened);
      expect(
        entries.where((e) => e['kind'] == 'search' && e['result'] == 'stale'),
        hasLength(1),
      );
      engine.answer.complete([1, 0]);
      await Future<void>.delayed(Duration.zero);
    } finally {
      if (!engine.answer.isCompleted) engine.answer.complete([1, 0]);
      await reopened.close();
    }
  });

  test('源修订使真实分页失效时记为stale，不重复计成功', () async {
    for (var i = 0; i < 3; i++) {
      await session.book.saveText('paging marker $i');
    }
    final query = SearchQuery(text: 'paging marker');
    final first = await session.book.searchPage(query, limit: 1);
    expect(first.next, isNotNull);
    await session.book.edit(
      first.entries.single.id,
      'paging marker revised',
      expectedRevision: 1,
    );
    final invalidated = await session.book.searchPage(
      query,
      after: first.next,
      limit: 1,
    );
    expect(invalidated.reset, isTrue);
    final entries = await events(session.diagnostics);
    expect(
      entries.where((e) => e['kind'] == 'search' && e['result'] == 'stale'),
      hasLength(1),
    );
  });

  test('准备期主动取消不记作设备启动失败', () async {
    final mic = PendingPermissionMicrophone();
    final capture = CaptureController(session.book, microphone: mic);
    try {
      final starting = capture.start();
      await mic.permissionRequested.future;
      final cancelling = capture.discard();
      mic.permission.complete(true);
      await starting;
      await cancelling;
      final entries = await events(session.diagnostics);
      final captured = entries.where((e) => e['kind'] == 'capture');
      expect(captured.where((e) => e['result'] == 'failed'), isEmpty);
      expect(
        captured.where(
          (e) => e['phase'] == 'cleanup' && e['result'] == 'cancelled',
        ),
        hasLength(1),
      );
    } finally {
      if (!mic.permission.isCompleted) mic.permission.complete(false);
      if (!mic.started) await mic.stop();
      capture.dispose();
      await mic.close();
    }
  });
}
