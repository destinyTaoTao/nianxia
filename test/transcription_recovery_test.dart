import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

class _Engine implements Transcriber {
  _Engine(this.result);
  final Future<String> Function() result;
  int calls = 0;
  @override
  Future<String> transcribe(String path) {
    calls++;
    return result();
  }
}

void main() {
  late Directory home;
  late Notebook book;
  late Record audio;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-transcribe-retry-');
    book = await Notebook.open(home);
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    audio = await book.finishCapture(draft);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });
  test('running写入失败后释放在途标记，原音和正文保留，同会话可再转写', () async {
    final engine = _Engine(() async => '真实重试的转写');
    StorageProbe(book).execute(
      "CREATE TRIGGER reject_running BEFORE UPDATE OF transcription ON records WHEN NEW.transcription='running' BEGIN SELECT RAISE(ABORT,'controlled running failure'); END",
    );
    await expectLater(
      book.transcribe(audio.id, engine),
      throwsA(isA<NotebookException>()),
    );
    expect(engine.calls, 0);
    expect(await File(book.audioPath(audio)).length(), greaterThan(44));
    StorageProbe(book).execute('DROP TRIGGER reject_running');
    await book.edit(audio.id, '用户保留的正文', expectedRevision: audio.revision);
    expect(await book.transcribe(audio.id, engine), isTrue);
    expect(engine.calls, 1);
    final current = (await book.get(audio.id))!;
    expect(current.body, '用户保留的正文');
    expect(current.transcript, '真实重试的转写');
    expect(current.transcription, 'done');
  });
  test('失败状态写入也失败时保留推理原始错误，之后仍能重试', () async {
    const failure = FileSystemException('controlled inference failure');
    final engine = _Engine(() async => throw failure);
    StorageProbe(book).execute(
      "CREATE TRIGGER reject_failure BEFORE UPDATE OF transcription ON records WHEN NEW.transcription='failed' BEGIN SELECT RAISE(ABORT,'controlled failure-state failure'); END",
    );
    await expectLater(
      book.transcribe(audio.id, engine),
      throwsA(same(failure)),
    );
    expect(await File(book.audioPath(audio)).exists(), isTrue);
    StorageProbe(book).execute('DROP TRIGGER reject_failure');
    expect(
      await book.transcribe(audio.id, _Engine(() async => '恢复后的转写')),
      isTrue,
    );
    expect((await book.get(audio.id))!.transcript, '恢复后的转写');
  });
}
