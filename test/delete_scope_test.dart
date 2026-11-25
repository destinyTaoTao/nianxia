import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

void main() {
  late Directory root;
  late Notebook book;
  late Record parent, child;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-delete-scope-');
    book = await Notebook.open(root);
    parent = await book.saveText('原记录保留条件');
    child = await book.saveText('第一次追加', parentId: parent.id);
  });
  tearDown(() async {
    await book.close();
    await root.delete(recursive: true);
  });
  test('确认后新增或移除使旧范围失效，必须重新确认', () async {
    final first = await book.deletionScope(parent.id);
    expect(first.count, 2);
    final added = await book.saveText('未确认的新追加', parentId: parent.id);
    await expectLater(
      book.delete(parent.id, scope: first),
      throwsA(isA<NotebookException>()),
    );
    expect(await book.get(parent.id), isNotNull);
    expect(await book.get(added.id), isNotNull);
    final second = await book.deletionScope(parent.id);
    await book.delete(child.id);
    await expectLater(
      book.delete(parent.id, scope: second),
      throwsA(isA<NotebookException>()),
    );
    expect(await book.childCount(parent.id), 1);
    await book.delete(parent.id, scope: await book.deletionScope(parent.id));
    expect(await book.records, isEmpty);
  });
  test('数量相同但成员替换以及同ID同版本改写都使确认失效', () async {
    final before = await book.deletionScope(parent.id);
    await book.delete(child.id);
    await book.saveText('替换的成员', parentId: parent.id);
    await expectLater(
      book.delete(parent.id, scope: before),
      throwsA(isA<NotebookException>()),
    );
    final current = await book.deletionScope(parent.id);
    StorageProbe(book)
        .execute('UPDATE records SET body=? WHERE id=?', ['外部替换', parent.id]);
    await expectLater(
      book.delete(parent.id, scope: current),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.get(parent.id))!.body, '外部替换');
  });
  test('删除失败整组和音频均保留，单次删除不影响所属及其他追加', () async {
    final draft = await book.beginCapture(parentId: parent.id);
    await writeWave(draft.path);
    final audio = await book.finishCapture(draft);
    final scope = await book.deletionScope(parent.id);
    StorageProbe(book).execute(
      "CREATE TRIGGER reject_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'controlled'); END",
    );
    await expectLater(
      book.delete(parent.id, scope: scope),
      throwsA(isA<NotebookException>()),
    );
    expect(await book.childCount(parent.id), 2);
    expect(await File(book.audioPath(audio)).exists(), isTrue);
    expect(
      StorageProbe(book).select('SELECT * FROM pending_media_deletions'),
      isEmpty,
    );
    StorageProbe(book).execute('DROP TRIGGER reject_delete');
    final single = await book.deletionScope(audio.id);
    expect(single.count, 1);
    expect(single.parentId, parent.id);
    await book.delete(audio.id, scope: single);
    expect(await book.get(parent.id), isNotNull);
    expect(await book.get(child.id), isNotNull);
    expect(await File(book.audioPath(audio)).exists(), isFalse);
    expect(
      (await book.search('语音记录')).any((v) => v.record.id == audio.id),
      isFalse,
    );
    await expectLater(
      book.delete(parent.id, scope: single),
      throwsA(isA<NotebookException>()),
    );
  });
}
