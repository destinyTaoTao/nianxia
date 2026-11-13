import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/app/notebook.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-storage-lifecycle-');
  });
  tearDown(() async => home.delete(recursive: true));

  test('备份媒体租约期间拒绝删除但允许编辑和新记录，嵌套释放后可删除', () async {
    final book = await Notebook.open(home);
    addTearDown(book.close);
    final record = await book.saveText('原始正文');
    await book.withMediaLease(() async {
      await expectLater(
        book.delete(record.id),
        throwsA(isA<NotebookException>()),
      );
      await book.edit(record.id, '用户编辑', expectedRevision: record.revision);
      await book.saveText('备份期间新记录');
      await book.withMediaLease(() async {
        await expectLater(
          book.delete(record.id),
          throwsA(isA<NotebookException>()),
        );
      });
      await expectLater(
        book.delete(record.id),
        throwsA(isA<NotebookException>()),
      );
    });
    expect((await book.get(record.id))!.body, '用户编辑');
    await book.delete(record.id);
    expect((await book.records).single.body, '备份期间新记录');
  });

  test('备份失败释放媒体租约，不把删除永久锁住', () async {
    final book = await Notebook.open(home);
    addTearDown(book.close);
    final record = await book.saveText('原始正文');
    await expectLater(
      book.withMediaLease<void>(
        () async => throw const FileSystemException('full'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    await book.delete(record.id);
    expect((await book.records), isEmpty);
  });

  test('启动未知孤儿音频保留在隔离目录，不永久删除字节', () async {
    var book = await Notebook.open(home);
    final record = await book.saveText('健康资料');
    await book.close();
    await File('${home.path}/audio/unknown.wav').writeAsBytes([1, 2, 3, 4]);
    book = await Notebook.open(home);
    addTearDown(book.close);
    expect((await book.get(record.id))!.body, '健康资料');
    final retained = await Directory('${home.path}/quarantine')
        .list(recursive: true)
        .where((f) => f is File)
        .toList();
    expect(retained.length, 1);
    expect(await File(retained.single.path).readAsBytes(), [1, 2, 3, 4]);
    expect(book.recoveryWarnings, greaterThan(0));
  });

  test('启动恢复失败释放SQLite连接，重试前不残留文件锁', () async {
    final book = await Notebook.open(home);
    await book.saveText('保留原文');
    StorageProbe(book).execute("UPDATE records SET transcription='running'");
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_startup BEFORE UPDATE OF transcription ON records BEGIN SELECT RAISE(ABORT,'startup failure'); END",
    );
    await book.close();
    await expectLater(Notebook.open(home), throwsA(isA<NotebookException>()));
    final check = sqlite3.open('${home.path}/records.sqlite');
    try {
      check.execute('PRAGMA locking_mode = EXCLUSIVE');
      check.execute('BEGIN EXCLUSIVE');
      expect(check.select('SELECT body FROM records').single['body'], '保留原文');
      check.execute('ROLLBACK');
    } finally {
      check.close();
    }
  });

  test('删除提交后进程中断，重启按日志清理，不把已删音频隔离保留', () async {
    var book = await Notebook.open(home);
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await book.finishCapture(draft);
    final audioPath = book.audioPath(saved);
    (await book.repository.delete(
      saved.id,
    )); // Simulate termination before file unlink.
    expect(await File(audioPath).exists(), isTrue);
    await book.close();
    book = await Notebook.open(home);
    addTearDown(book.close);
    expect((await book.records), isEmpty);
    expect(await File(audioPath).exists(), isFalse);
    expect((await book.repository.pendingMediaDeletions()), isEmpty);
    expect(await Directory('${home.path}/quarantine').exists(), isFalse);
  });

  test('媒体清理确认SQL失败不会误报已提交的删除失败，重启仍可打开', () async {
    var book = await Notebook.open(home);
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await book.finishCapture(draft);
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_cleanup_ack BEFORE DELETE ON pending_media_deletions BEGIN SELECT RAISE(ABORT,'test cleanup failure'); END",
    );
    try {
      await book.delete(saved.id);
      expect((await book.get(saved.id)), isNull);
      expect(await File(book.audioPath(saved)).exists(), isFalse);
      expect((await book.repository.pendingMediaDeletions()), [saved.audio]);
      expect(book.recoveryWarnings, greaterThan(0));
    } finally {
      await book.close();
    }
    book = await Notebook.open(home);
    addTearDown(book.close);
    expect((await book.records), isEmpty);
    expect((await book.repository.pendingMediaDeletions()), [saved.audio]);
    StorageProbe(book).execute('DROP TRIGGER fail_cleanup_ack');
    await book.delete(saved.id);
    expect((await book.repository.pendingMediaDeletions()), isEmpty);
  });

  test('已删音频清理失败保留日志，阻塞目录移除后重启可重试', () async {
    var book = await Notebook.open(home);
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await book.finishCapture(draft);
    final path = book.audioPath(saved);
    await File(path).delete();
    await Directory(path).create();
    await book.delete(saved.id);
    expect((await book.get(saved.id)), isNull);
    expect((await book.repository.pendingMediaDeletions()), [saved.audio]);
    expect(book.recoveryWarnings, greaterThan(0));
    await book.close();
    await Directory(path).delete();
    book = await Notebook.open(home);
    addTearDown(book.close);
    expect((await book.repository.pendingMediaDeletions()), isEmpty);
  });
}
