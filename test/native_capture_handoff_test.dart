import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/capture_session.dart';

const id = '11111111-1111-4111-8111-111111111111';
FinalizedCapture clip({
  String? parent,
  int bytes = 32000,
  String sessionId = id,
}) => FinalizedCapture(
  CaptureSnapshot.fromMap({
    ...CaptureRequest(
      sessionId: sessionId,
      mode: CaptureMode.record,
      createdAtUtc: DateTime.utc(2026, 11, 14),
      timezone: 'Asia/Shanghai',
      offsetMinutes: 480,
      parentId: parent,
    ).toMap(),
    'phase': 'finalized',
    'sequence': 2,
    'elapsedMs': 1000,
    'pcmBytes': bytes,
    'level': 0.0,
    'relativeAudioName': '$sessionId.wav',
  }),
);
Future<File> wave(Directory home, {String location = 'native-captures'}) async {
  final file = File('${home.path}/$location/$id.wav');
  await file.parent.create(recursive: true);
  final b = ByteData(32044);
  final bytes = b.buffer.asUint8List();
  void tag(int offset, String value) {
    bytes.setRange(offset, offset + value.length, value.codeUnits);
  }

  tag(0, 'RIFF');
  b.setUint32(4, 32036, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, 32000, Endian.little);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

class HandoffEndpoint implements NativeCapturePort {
  HandoffEndpoint(this.book, this.value);
  final Notebook book;
  CaptureSnapshot value;
  bool failAck = false;
  List<CaptureSnapshot>? pendingValues;
  int acknowledgements = 0, cancels = 0;
  @override
  Future<CaptureSnapshot?> current() async => value;
  @override
  Future<List<CaptureSnapshot>> pending({
    String? after,
    int limit = 32,
  }) async => after == null ? (pendingValues ?? [value]) : [];
  @override
  Future<FinalizedCapture> claim(String id) async => FinalizedCapture(
    (pendingValues ?? [value]).singleWhere((v) => v.sessionId == id),
  );
  @override
  Future<void> acknowledge(
    String id, {
    required CaptureDisposition disposition,
  }) async {
    if (disposition == CaptureDisposition.importedRecord) {
      expect(await book.get(id), isNotNull);
    } else {
      expect(await book.get(id), isNull);
    }
    if (failAck) throw const NotebookException('controlled ack failure');
    acknowledgements++;
  }

  @override
  Future<CaptureSnapshot> start(CaptureRequest request) async => value;
  @override
  Future<CaptureSnapshot> stop(String id) async => value;
  @override
  Future<void> cancel(String id) async {
    cancels++;
  }

  @override
  Stream<CaptureSnapshot> get events => const Stream.empty();
  @override
  Future<void> close() async {}
}

class HandoffRuntime extends ChangeNotifier implements InferenceRuntime {
  int transcriptions = 0, readinessChecks = 0;
  @override
  String? get searchModelVersion => null;
  @override
  Future<bool> ready(InferenceCapability capability) async {
    readinessChecks++;
    return false;
  }

  @override
  Future<String> transcribe(String path, {bool foreground = true}) async {
    transcriptions++;
    return 'synthetic query';
  }

  @override
  Future<List<double>> embed(String text, {required bool query}) async => [
    1,
    0,
  ];
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-handoff-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });
  test('native finalized clip commits once and retains valid audio', () async {
    await wave(home);
    final saved = await book.acceptNativeCapture(clip());
    final again = await book.acceptNativeCapture(clip());
    expect(saved.id, again.id);
    expect((await book.records).length, 1);
    expect(File(book.audioPath(saved)).existsSync(), isTrue);
  });
  test(
    'restartAfterMoveBeforeCommit recovers native marker and destination',
    () async {
      final file = await wave(home);
      final c = clip();
      await book.captures.persistNative(c);
      await file.rename('${home.path}/audio/$id.wav');
      await book.close();
      book = await Notebook.open(home);
      expect((await book.records).length, 1);
      expect((await book.get(id))!.durationMs, 1000);
      await book.acceptNativeCapture(c);
      expect((await book.records).length, 1);
    },
  );
  test('active native clip is excluded from legacy startup repair', () async {
    final file = await wave(home);
    final before = await file.readAsBytes();
    await book.close();
    book = await Notebook.open(home);
    expect(await book.records, isEmpty);
    expect(await file.readAsBytes(), before);
  });
  test(
    'deletedParentOffersStandalone without silently changing relation',
    () async {
      final parent = await book.saveText('synthetic parent');
      await wave(home);
      final c = clip(parent: parent.id);
      await book.delete(parent.id);
      await expectLater(
        book.acceptNativeCapture(c),
        throwsA(isA<NotebookException>()),
      );
      expect(await book.records, isEmpty);
      final saved = await book.acceptNativeCapture(c, standalone: true);
      expect(saved.parentId, isNull);
    },
  );
  test(
    'inconsistent source identity is rejected after an existing commit',
    () async {
      await wave(home);
      await book.acceptNativeCapture(clip());
      await expectLater(
        book.acceptNativeCapture(clip(bytes: 64000)),
        throwsA(isA<NotebookException>()),
      );
      expect((await book.records).length, 1);
      expect(File('${home.path}/audio/$id.wav').lengthSync(), 32044);
    },
  );
  test('future native marker is retained without importing', () async {
    await wave(home);
    await book.captures
        .marker(id)
        .writeAsString('{"nativeCaptureVersion":2,"id":"$id"}');
    await book.close();
    book = await Notebook.open(home);
    expect(await book.records, isEmpty);
    expect(book.captures.marker(id).existsSync(), isTrue);
  });
  test('restartAfterCommitBeforeAck acknowledges only committed source and preserves success', () async {
    await wave(home);
    final endpoint = HandoffEndpoint(book, clip().snapshot)..failAck = true;
    final runtime = HandoffRuntime();
    final first = CaptureSessionController(endpoint, book, runtime);
    await first.reconnect();
    expect(first.savedId, id);
    expect((await book.records).length, 1);
    expect(book.recoveryWarnings, 1);
    first.dispose();
    endpoint.failAck = false;
    final second = CaptureSessionController(endpoint, book, runtime);
    await second.reconnect();
    expect(endpoint.acknowledgements, 1);
    expect((await book.records).length, 1);
    expect(File('${home.path}/audio/$id.wav').existsSync(), isTrue);
    second.dispose();
    runtime.dispose();
  });
  test('query foreground processing never inserts a source and cleans native query audio', () async {
    final original = clip().snapshot;
    final query = CaptureSnapshot.fromMap({
      ...original.request.toMap(),
      'mode': 'query',
      'phase': 'finalized',
      'sequence': 2,
      'elapsedMs': 1000,
      'pcmBytes': 32000,
      'level': 0.0,
      'relativeAudioName': '$id.wav',
    });
    final file = await wave(home, location: 'native-captures/queries');
    final endpoint = HandoffEndpoint(book, query);
    final runtime = HandoffRuntime();
    final controller = CaptureSessionController(
      endpoint,
      book,
      runtime,
      queryForeground: () async => true,
    );
    await controller.reconnect();
    expect(await controller.finishQuery(), 'synthetic query');
    expect(await book.records, isEmpty);
    expect(file.existsSync(), isFalse);
    expect(endpoint.acknowledgements, 1);
    controller.dispose();
    expect(endpoint.cancels, 0);
    runtime.dispose();
  });
  test(
    'query while locked remains pending and does not run inference',
    () async {
      final query = CaptureSnapshot.fromMap({
        ...clip().snapshot.request.toMap(),
        'mode': 'query',
        'phase': 'finalized',
        'sequence': 2,
        'elapsedMs': 1000,
        'pcmBytes': 32000,
        'level': 0.0,
        'relativeAudioName': '$id.wav',
      });
      final file = await wave(home, location: 'native-captures/queries');
      final endpoint = HandoffEndpoint(book, query);
      final runtime = HandoffRuntime();
      final controller = CaptureSessionController(
        endpoint,
        book,
        runtime,
        queryForeground: () async => false,
      );
      await controller.reconnect();
      await expectLater(
        controller.finishQuery(),
        throwsA(isA<NotebookException>()),
      );
      expect(runtime.transcriptions, 0);
      expect(file.existsSync(), isTrue);
      expect(endpoint.acknowledgements, 0);
      controller.dispose();
      runtime.dispose();
    },
  );
  test(
    'native handoff never overwrites a different existing audio file',
    () async {
      await wave(home);
      final destination = await wave(home, location: 'audio');
      final bytes = await destination.readAsBytes();
      bytes[bytes.length - 1] = 99;
      await destination.writeAsBytes(bytes);
      await expectLater(
        book.acceptNativeCapture(clip()),
        throwsA(isA<NotebookException>()),
      );
      expect(await destination.readAsBytes(), bytes);
      expect(await book.records, isEmpty);
      expect(File('${home.path}/native-captures/$id.wav').existsSync(), isTrue);
    },
  );

  test(
    'failed pending clip does not block later valid finalized clip',
    () async {
      final bad = clip(parent: '00000000-0000-4000-8000-000000000001');
      await wave(home);
      const later = '22222222-2222-4222-8222-222222222222';
      final good = clip(sessionId: later);
      await File('${home.path}/native-captures/$id.wav')
          .copy('${home.path}/native-captures/$later.wav');
      final endpoint = HandoffEndpoint(book, bad.snapshot)
        ..pendingValues = [bad.snapshot, good.snapshot];
      final runtime = HandoffRuntime();
      final controller = CaptureSessionController(endpoint, book, runtime);
      try {
        await controller.reconnect();
        expect(await book.get(id), isNull);
        expect(await book.get(later), isNotNull);
        expect(book.recoveryWarnings, greaterThan(0));
        expect(controller.lastError, isNotNull);
      } finally {
        controller.dispose();
        runtime.dispose();
      }
    },
  );
}
