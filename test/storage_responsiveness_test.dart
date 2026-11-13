import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';
import 'package:nianxia/data/record_repository.dart';

import 'recording_search_test.dart' show writeWave, TextTranscriber;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home, sourceHome;
  late Notebook book, source;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('storage-responsive-');
    sourceHome = await Directory.systemTemp.createTemp('storage-source-');
    final raw = RecordRepository(sourceHome);
    raw.transaction(() {
      for (var i = 0; i < 20000; i++) {
        raw.insert(
          Record(
            id: '${i.toString().padLeft(8, '0')}-0000-4000-8000-000000000000',
            body: '第 $i 条原始正文',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
      }
    });
    raw.close();
    source = await Notebook.open(sourceHome);
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await source.close();
    await home.delete(recursive: true);
    await sourceHome.delete(recursive: true);
  });

  test('两万条真实恢复不阻塞调用方事件循环，期间新增及原有资料都保留', () async {
    final original = await book.saveText('原有资料');
    final archive = await BackupService(source).export();
    final watch = Stopwatch()..start();
    var last = 0, maximumGap = 0, pulses = 0;
    final pulse = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = watch.elapsedMilliseconds;
      final gap = now - last;
      if (gap > maximumGap) maximumGap = gap;
      last = now;
      pulses++;
    });
    Future<Record>? concurrent;
    try {
      final report = await BackupService(book).restore(
        archive,
        progress: (value) {
          if (value >= 0.5) concurrent ??= book.saveText('恢复期间新增');
        },
      );
      final added = await concurrent!;
      expect(report.added, 20000);
      expect((await book.get(original.id))!.body, '原有资料');
      expect((await book.get(added.id))!.body, '恢复期间新增');
      expect((await book.records).length, 20002);
      expect(pulses, greaterThan(10));
      // Host regression guard against the former ~1s synchronous merge, not a
      // phone P95 commitment. The budget tolerates normal host scheduling noise.
      expect(maximumGap, lessThan(500));
      // ignore: avoid_print
      print(
        'Storage restore: 20000 records, ${watch.elapsedMilliseconds} ms, max event gap $maximumGap ms',
      );
    } finally {
      pulse.cancel();
    }
  });

  test('恢复提交许可前取消，原有资料和去重映射均不受部分合并影响', () async {
    final original = await book.saveText('必须保留');
    final archive = await BackupService(source).export();
    final service = BackupService(book);
    await expectLater(
      service.restore(
        archive,
        progress: (value) {
          if (value == 1) scheduleMicrotask(() => service.cancelled = true);
        },
      ),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.records).single.id, original.id);
    expect((await book.repository.pendingMediaDeletions()), isEmpty);
    expect((await BackupService(book).restore(archive)).added, 20000);
  });

  test('关闭会取消在途推理结果并排空落盘操作，迟到转写不写已关闭资料库', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final recording = await book.finishCapture(draft);
    final gate = Completer<String>();
    final transcribing = book.transcribe(
      recording.id,
      TextTranscriber(gate.future),
    );
    final saved = book.saveText('关闭前已接收');
    await book.close().timeout(const Duration(seconds: 3));
    expect(await transcribing, isFalse);
    final text = await saved;
    gate.complete('迟到结果');
    book = await Notebook.open(home);
    expect((await book.get(text.id))!.body, '关闭前已接收');
    expect((await book.get(recording.id))!.transcript, isNull);
    expect(await File(book.audioPath(recording)).exists(), isTrue);
  });
}
