import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/backup.dart';

import 'recording_search_test.dart' show writeWave;

void main() {
  late Directory home, other;
  late Notebook book, restored;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-export-');
    other = await Directory.systemTemp.createTemp('nianxia-import-');
    book = await Notebook.open(home);
    restored = await Notebook.open(other);
  });
  tearDown(() async {
    book.dispose();
    restored.dispose();
    await home.delete(recursive: true);
    await other.delete(recursive: true);
  });
  test('备份带走文本音频收藏关系，凭证和模型排除，重复恢复幂等', () async {
    final parent = await book.saveText('中文灵感：原文');
    await book.favorite(parent.id, true);
    final draft = await book.beginCapture(parentId: parent.id);
    await writeWave(draft.path);
    final child = await book.finishCapture(draft);
    await File('${home.path}/secret-key').writeAsString('not-for-export');
    final backup = await BackupService(book).export();
    final zip = ZipDecoder().decodeBytes(await backup.readAsBytes());
    expect(zip.files.any((f) => f.name.contains('secret')), isFalse);
    final report = await BackupService(restored).restore(backup);
    expect(report.added, 2);
    expect(report.conflicts, 0);
    expect(restored.get(parent.id)!.favorite, isTrue);
    expect(restored.get(child.id)!.parentId, parent.id);
    expect(
      File(restored.audioPath(restored.get(child.id)!)).existsSync(),
      isTrue,
    );
    expect((await BackupService(restored).restore(backup)).skipped, 2);
    expect(restored.records.length, 2);
  });
  test('ID冲突保留副本且重映射父子，重复冲突导入不再造副本', () async {
    final parent = await book.saveText('父项原文');
    await book.saveText('追加原文', parentId: parent.id);
    final service = BackupService(book);
    final old = await service.export();
    await book.edit(parent.id, '本地已修改', expectedRevision: parent.revision);
    final report = await service.restore(old);
    expect(report.conflicts, 1);
    expect(book.get(parent.id)!.body, '本地已修改');
    final copy = book.records.singleWhere((r) => r.body == '父项原文');
    final appended = book.records.where((r) => r.body == '追加原文').toList();
    expect(appended.any((r) => r.parentId == copy.id), isTrue);
    final count = book.records.length;
    await service.restore(old);
    expect(book.records.length, count);
  });
  test('拒绝路径穿越、压缩炸弹格式和损坏备份，保留已有数据', () async {
    await book.saveText('既有内容');
    for (final name in [
      '../escape.txt',
      'audio/../../escape.wav',
      'manifest.json',
    ]) {
      final file = File('${other.path}/malicious.zip');
      final archive = Archive()
        ..add(ArchiveFile.bytes(name, utf8.encode('broken')));
      await file.writeAsBytes(ZipEncoder().encode(archive));
      await expectLater(
        BackupService(book).restore(file),
        throwsA(isA<NotebookException>()),
      );
      expect(book.records.single.body, '既有内容');
      expect(File('${home.parent.path}/escape.txt').existsSync(), isFalse);
    }
  });
  test('恢复过的记录被编辑后，再次导入保留原备份冲突副本', () async {
    final r = await book.saveText('备份中的原文');
    final backup = await BackupService(book).export();
    await BackupService(restored).restore(backup);
    await restored.edit(
      r.id,
      '恢复后在本地修改',
      expectedRevision: restored.get(r.id)!.revision,
    );
    final result = await BackupService(restored).restore(backup);
    expect(result.conflicts, 1);
    expect(
      restored.records.map((r) => r.body),
      containsAll(['备份中的原文', '恢复后在本地修改']),
    );
    final count = restored.records.length;
    await BackupService(restored).restore(backup);
    expect(restored.records.length, count);
  });
  test('应用拒绝生成超过自身恢复条数上限的备份', () async {
    // Real persistence, batched only to keep fixture creation inexpensive.
    book.repository.transaction(() {
      for (var i = 0; i < 10001; i++) {
        book.repository.insert(
          Record(
            id: '${i.toString().padLeft(8, '0')}-0000-4000-8000-000000000000',
            body: '记录',
            createdAt: DateTime.utc(2026),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
      }
    });
    await expectLater(
      BackupService(book).export(),
      throwsA(isA<NotebookException>()),
    );
    expect(book.records.length, 10001);
  });
}
