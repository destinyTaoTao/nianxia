import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home, other;
  late Notebook book, restored;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-export-');
    other = await Directory.systemTemp.createTemp('nianxia-import-');
    book = await Notebook.open(home);
    restored = await Notebook.open(other);
  });
  tearDown(() async {
    await book.close();
    await restored.close();
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
    expect((await restored.get(parent.id))!.favorite, isTrue);
    expect((await restored.get(child.id))!.parentId, parent.id);
    expect(
      File(restored.audioPath((await restored.get(child.id))!)).existsSync(),
      isTrue,
    );
    expect((await BackupService(restored).restore(backup)).skipped, 2);
    expect((await restored.records).length, 2);
  });
  test('ID冲突保留副本且重映射父子，重复冲突导入不再造副本', () async {
    final parent = await book.saveText('父项原文');
    await book.saveText('追加原文', parentId: parent.id);
    final service = BackupService(book);
    final old = await service.export();
    await book.edit(parent.id, '本地已修改', expectedRevision: parent.revision);
    final report = await service.restore(old);
    expect(report.conflicts, 1);
    expect((await book.get(parent.id))!.body, '本地已修改');
    final copy = (await book.records).singleWhere((r) => r.body == '父项原文');
    final appended = (await book.records)
        .where((r) => r.body == '追加原文')
        .toList();
    expect(appended.any((r) => r.parentId == copy.id), isTrue);
    final count = (await book.records).length;
    await service.restore(old);
    expect((await book.records).length, count);
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
      expect((await book.records).single.body, '既有内容');
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
      expectedRevision: (await restored.get(r.id))!.revision,
    );
    final result = await BackupService(restored).restore(backup);
    expect(result.conflicts, 1);
    expect(
      (await restored.records).map((r) => r.body),
      containsAll(['备份中的原文', '恢复后在本地修改']),
    );
    final count = (await restored.records).length;
    await BackupService(restored).restore(backup);
    expect((await restored.records).length, count);
  });
  test('超过一万条记录完整往返且重复恢复幂等', () async {
    // Real persistence, batched only to keep fixture creation inexpensive.
    withFixtureRepository(
      book,
      (fixture) => fixture.transaction(() {
        for (var i = 0; i < 10001; i++) {
          fixture.insert(
            Record(
              id: '${i.toString().padLeft(8, '0')}-0000-4000-8000-000000000000',
              body: '记录',
              createdAt: DateTime.utc(2026),
              timezone: 'UTC',
              offsetMinutes: 0,
            ),
          );
        }
      }),
    );
    final backup = await BackupService(book).export();
    expect((await BackupService(restored).restore(backup)).added, 10001);
    expect((await restored.records).length, 10001);
    expect((await BackupService(restored).restore(backup)).skipped, 10001);
  });
  test('恢复最后音频核验期间取消，不提交新增记录且清理暂存副本', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final audio = await book.finishCapture(draft);
    await BackupService(restored).restore(await BackupService(book).export());
    final added = await book.saveText('取消后不应导入');
    final file = await BackupService(book).export();
    final service = BackupService(restored);
    await expectLater(
      service.restore(
        file,
        progress: (value) {
          if (value == 1) scheduleMicrotask(() => service.cancelled = true);
        },
      ),
      throwsA(isA<NotebookException>()),
    );
    expect((await restored.get(added.id)), isNull);
    expect((await restored.records).single.id, audio.id);
    expect(
      await File(restored.audioPath((await restored.records).single)).exists(),
      isTrue,
    );
    expect(await Directory('${other.path}/audio').list().length, 1);
    expect(await Directory('${other.path}/imports').list().length, 0);
  });
  test('超过512MiB完整备份真实往返且音频字节保持', () async {
    // Real sparse two-minute WAVs exceed 512 MiB; the text and metadata
    // each also exceed the former 16 MiB whole-library boundary.
    for (var i = 0; i < 140; i++) {
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      final file = await File(draft.path).open(mode: FileMode.append);
      final size = ByteData(4)..setUint32(0, 3840036, Endian.little);
      await file.setPosition(4);
      await file.writeFrom(size.buffer.asUint8List());
      size.setUint32(0, 3840000, Endian.little);
      await file.setPosition(40);
      await file.writeFrom(size.buffer.asUint8List());
      await file.truncate(3840044);
      await file.close();
      await book.finishCapture(draft);
    }
    for (var i = 0; i < 60; i++) {
      await book.saveText('记' * 100000);
    }
    final backup = await BackupService(book).export();
    expect(await backup.length(), greaterThan(512 * 1024 * 1024));
    expect((await BackupService(restored).restore(backup)).added, 200);
    expect((await restored.records).length, 200);
    for (final r in (await book.records).where((r) => r.audio != null)) {
      final copy = (await restored.get(r.id))!;
      expect(
        await sha256.bind(File(book.audioPath(r)).openRead()).first,
        await sha256.bind(File(restored.audioPath(copy)).openRead()).first,
      );
    }
  });
}
