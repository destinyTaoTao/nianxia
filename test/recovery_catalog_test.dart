import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/domain/capture_session.dart';

import 'recording_search_test.dart' show writeWave;
import 'native_capture_handoff_test.dart'
    show clip, wave, id, HandoffEndpoint, HandoffRuntime;

class _DiscardEndpoint extends HandoffEndpoint {
  _DiscardEndpoint(super.book, super.value);
  bool acked = false;
  @override
  Future<List<CaptureSnapshot>> pending({
    String? after,
    int limit = 32,
  }) async => acked ? [] : super.pending(after: after, limit: limit);
  @override
  Future<void> acknowledge(
    String id, {
    required CaptureDisposition disposition,
  }) async {
    expect(disposition, CaptureDisposition.discardedRecord);
    expect(await book.nativeCaptureDiscarded(id), isTrue);
    expect(await book.get(id), isNull);
    acked = true;
  }
}

class _FailedEndpoint extends HandoffEndpoint {
  _FailedEndpoint(super.book, super.value);
  bool removed = false;
  int starts = 0;
  @override
  Future<CaptureSnapshot?> current() async => removed ? null : value;
  @override
  Future<List<CaptureSnapshot>> pending({
    String? after,
    int limit = 32,
  }) async => removed || after != null ? [] : [value];
  @override
  Future<CaptureSnapshot> start(CaptureRequest request) async {
    starts++;
    return value;
  }

  @override
  Future<void> cancel(String id) async {
    expect(await book.nativeCaptureDiscarded(id), isTrue);
    cancels++;
    removed = true;
  }

  @override
  Future<void> acknowledge(
    String id, {
    required CaptureDisposition disposition,
  }) async => fail('Unclaimed failed recording must use native cancel');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-recovery-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });
  test('managed recovery IDs export original bytes and require recognized data before deletion', () async {
    final q = await Directory('${home.path}/quarantine/$id')
        .create(recursive: true);
    final audio = File('${q.path}/original.wav');
    await writeWave(audio.path);
    final before = sha256.convert(await audio.readAsBytes());
    final page = await book.recoveryPage();
    expect(page.entries.length, 1);
    final entry = page.entries.single;
    expect(entry.id, 'q:$id');
    expect(entry.durationMs, 1000);
    expect(entry.bytes, 32044);
    expect(entry.canDiscard, isTrue);
    final exported = await book.exportRecoveryEntry(entry.id);
    expect(await exported.length(), greaterThan(32044));
    expect(sha256.convert(await audio.readAsBytes()), before);
    await book.discardRecoveryEntry(entry.id);
    expect(await audio.exists(), isFalse);
    expect((await book.recoveryPage()).entries, isEmpty);
    await expectLater(
      book.exportRecoveryEntry('q:../../records.sqlite'),
      throwsA(isA<NotebookException>()),
    );
  });
  test(
    'future marker preserved; linked files never leave managed directory',
    () async {
      final marker = book.captures.marker(id);
      await marker.writeAsString(
        jsonEncode({
          'nativeCaptureVersion': 99,
          'id': id,
          'future': 'synthetic original',
        }),
      );
      final before = sha256.convert(await marker.readAsBytes());
      final entry = (await book.recoveryPage()).entries.single;
      expect(entry.canDiscard, isFalse);
      await expectLater(
        book.discardRecoveryEntry(entry.id),
        throwsA(isA<NotebookException>()),
      );
      expect(sha256.convert(await marker.readAsBytes()), before);
      final outside = await Directory.systemTemp.createTemp(
        'nx-recovery-outside-',
      );
      try {
        await File('${outside.path}/synthetic.txt')
            .writeAsString('outside sentinel');
        final q = await Directory('${home.path}/quarantine').create();
        await Link('${q.path}/22222222-2222-4222-8222-222222222222')
            .create(outside.path);
        expect((await book.recoveryPage()).entries.length, 1);
        await expectLater(
          book.exportRecoveryEntry('q:22222222-2222-4222-8222-222222222222'),
          throwsA(isA<NotebookException>()),
        );
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
  test('recovery pages bounded at forty without repeated entries', () async {
    for (var i = 0; i < 45; i++) {
      final q = await Directory(
        '${home.path}/quarantine/${i.toRadixString(16).padLeft(8, '0')}-1111-4111-8111-111111111111',
      ).create(recursive: true);
      await File('${q.path}/original.bin').writeAsBytes([1, 2, 3]);
    }
    final first = await book.recoveryPage();
    expect(first.entries.length, 40);
    expect(first.next, isNotNull);
    final next = await book.recoveryPage(after: first.next);
    expect(next.entries.length, 5);
    expect(next.next, isNull);
    expect(
      {
        ...first.entries.map((e) => e.id),
        ...next.entries.map((e) => e.id),
      }.length,
      45,
    );
  });
  test('discarded native recovery cannot be imported again or resurrected on restart', () async {
    await wave(home);
    final native = clip(parent: '22222222-2222-4222-8222-222222222222');
    await expectLater(
      book.acceptNativeCapture(native),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.recoveryPage()).entries.single.id, 'd:$id');
    await book.discardRecoveryEntry('d:$id');
    expect(await book.nativeCaptureDiscarded(id), isTrue);
    await expectLater(
      book.acceptNativeCapture(native),
      throwsA(isA<NotebookException>()),
    );
    await book.close();
    book = await Notebook.open(home);
    expect(await book.get(id), isNull);
    expect(await book.nativeCaptureDiscarded(id), isTrue);
  });
  test(
    'active capture cannot be deleted through recovery management',
    () async {
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      book.captureActive = true;
      await expectLater(
        book.discardRecoveryEntry('d:${draft.id}'),
        throwsA(isA<NotebookException>()),
      );
      expect(await File(draft.path).exists(), isTrue);
      book.captureActive = false;
    },
  );

  test('native discard is acknowledged distinctly before clearing durable recovery intent', () async {
    await wave(home);
    final native = clip(parent: '22222222-2222-4222-8222-222222222222');
    await expectLater(
      book.acceptNativeCapture(native),
      throwsA(isA<NotebookException>()),
    );
    await book.discardRecoveryEntry('d:$id');
    final endpoint = _DiscardEndpoint(book, native.snapshot);
    final runtime = HandoffRuntime();
    final controller = CaptureSessionController(endpoint, book, runtime);
    try {
      await controller.reconnect();
      expect(endpoint.acked, isTrue);
      expect(controller.snapshot, isNull);
      expect(await book.nativeCaptureDiscarded(id), isFalse);
      expect(await book.get(id), isNull);
    } finally {
      controller.dispose();
      runtime.dispose();
    }
  });
  test('native failed artifact is manageable without auto import or restarting microphone', () async {
    final current = CaptureSnapshot.fromMap({
      ...clip().snapshot.request.toMap(),
      'phase': 'failed',
      'sequence': 2,
      'elapsedMs': 0,
      'pcmBytes': 0,
      'errorCode': 'audio_start',
    });
    final file = File('${home.path}/native-captures/$id.wav');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(44, 0));
    final endpoint = _FailedEndpoint(book, current);
    final runtime = HandoffRuntime();
    final controller = CaptureSessionController(endpoint, book, runtime);
    try {
      await controller.reconnect();
      final page = await book.recoveryPage();
      expect(page.entries.length, 1);
      expect(page.entries.single.canDiscard, isTrue);
      expect(await book.get(id), isNull);
      await controller.start(mode: CaptureMode.record);
      expect(endpoint.starts, 0);
      await book.discardRecoveryEntry('d:$id');
      await controller.reconnect();
      expect(endpoint.cancels, 1);
      expect(await book.nativeCaptureDiscarded(id), isFalse);
      expect((await book.recoveryPage()).entries, isEmpty);
    } finally {
      controller.dispose();
      runtime.dispose();
    }
  });
}
