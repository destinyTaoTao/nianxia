import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

Future<File> storedZip(Directory dir, Map<String, List<int>> files) async {
  final archive = Archive();
  for (final e in files.entries) {
    archive.add(
      ArchiveFile.bytes(e.key, e.value)..compression = CompressionType.none,
    );
  }
  return File('${dir.path}/fixture.zip')
      .writeAsBytes(ZipEncoder().encode(archive));
}

Map<String, dynamic> legacyRow({
  String id = '10000000-0000-4000-8000-000000000000',
}) => {
  'id': id,
  'parentId': null,
  'body': '旧版原始正文',
  'createdAt': '2026-01-01T00:00:00.000Z',
  'timezone': 'UTC',
  'offsetMinutes': 0,
  'revision': 1,
  'favorite': true,
  'audio': null,
  'durationMs': 0,
  'transcript': null,
  'transcription': 'none',
  'organization': {'old': '派生缓存'},
  'organizationRevision': 1,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home, other;
  late Notebook book, source;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('backup-v2-');
    other = await Directory.systemTemp.createTemp('backup-v2-src-');
    book = await Notebook.open(home);
    source = await Notebook.open(other);
  });
  tearDown(() async {
    await book.close();
    await source.close();
    await home.delete(recursive: true);
    await other.delete(recursive: true);
  });
  test('本地音频丢失仍可恢复有效备份，保留旧行并恢复带音频的副本', () async {
    final draft = await source.beginCapture();
    await writeWave(draft.path);
    final original = await source.finishCapture(draft);
    final backup = await BackupService(source).export();
    await BackupService(book).restore(backup);
    await File(book.audioPath((await book.get(original.id))!)).delete();
    final report = await BackupService(book).restore(backup);
    expect(report.added, 1);
    expect(report.conflicts, 1);
    expect((await book.records), hasLength(2));
    expect((await book.get(original.id)), isNotNull);
    final copy = (await book.records).singleWhere((r) => r.id != original.id);
    expect(
      await File(book.audioPath(copy)).readAsBytes(),
      await File(source.audioPath(original)).readAsBytes(),
    );
    final again = await BackupService(book).restore(backup);
    expect(again.skipped, 1);
    expect((await book.records), hasLength(2));
  });

  test('冻结v1读取保留原始字段并兼容已有restored指纹别名', () async {
    final row = legacyRow();
    final local = Record.fromJson({
      ...row,
      'id': '20000000-0000-4000-8000-000000000000',
    });
    (await book.repository.insert(local));
    final fingerprint = sha256
        .convert(utf8.encode('${jsonEncode(row)}null'))
        .toString();
    StorageProbe(book).execute('INSERT OR REPLACE INTO restored VALUES(?,?)', [
      fingerprint,
      local.id,
    ]);
    final file = await storedZip(other, {
      'manifest.json': utf8.encode(
        jsonEncode({
          'format': 'nianxia',
          'version': 1,
          'records': [row],
          'audio': {},
        }),
      ),
    });
    final report = await BackupService(book).restore(file);
    expect(report.skipped, 1);
    expect(report.added, 0);
    expect((await book.records).single.id, local.id);
    expect((await book.records).single.favorite, isTrue);
  });
  test('新版导出只包含原始DTO，损坏派生缓存不影响备份', () async {
    final r = await source.saveText('原始正文');
    StorageProbe(source).execute(
      "INSERT INTO record_organizations(record_id,source_revision,format_version,model_version,payload) VALUES(?,1,1,'organization-v1','bad-json')",
      [r.id],
    );
    final file = await BackupService(source).export();
    final archive = ZipDecoder().decodeBytes(
      await file.readAsBytes(),
      verify: true,
    );
    final manifest = jsonDecode(
      utf8.decode(archive.findFile('manifest.json')!.content),
    );
    expect(manifest['version'], 2);
    expect(archive.files.any((f) => f.name.contains('sqlite')), isFalse);
    final report = await BackupService(book).restore(file);
    expect(report.added, 1);
    expect((await book.get(r.id))!.body, '原始正文');
  });
  test('未知版本与chunk校验失败不改变已有记录', () async {
    await book.saveText('已有内容');
    await source.saveText('待导入');
    final good = await BackupService(source).export();
    final archive = ZipDecoder().decodeBytes(await good.readAsBytes());
    final original = {
      for (final f in archive.files) f.name: List<int>.from(f.content),
    };
    for (final unknown in [true, false]) {
      final files = Map<String, List<int>>.from(original);
      if (unknown) {
        final m = jsonDecode(utf8.decode(files['manifest.json']!));
        m['version'] = 999;
        files['manifest.json'] = utf8.encode(jsonEncode(m));
      } else {
        final chunk = files.keys.firstWhere((n) => n.startsWith('chunks/'));
        files[chunk] = utf8.encode(
          utf8.decode(files[chunk]!).replaceFirst('待导入', '坏内容'),
        );
      }
      final bad = await storedZip(other, files);
      await expectLater(
        BackupService(book).restore(bad),
        throwsA(isA<NotebookException>()),
      );
      expect((await book.records).single.body, '已有内容');
      expect(await Directory('${home.path}/audio').list().length, 0);
    }
  });
  test('单条字段及未引用条目资源预算仍被拒绝', () async {
    for (final oversized in [true, false]) {
      final row = legacyRow();
      if (oversized) row['body'] = '记' * 100001;
      final f = await storedZip(other, {
        'manifest.json': utf8.encode(
          jsonEncode({
            'format': 'nianxia',
            'version': 1,
            'records': [row],
            'audio': {},
          }),
        ),
        if (!oversized) 'text/00000000.txt': [1],
      });
      await expectLater(
        BackupService(book).restore(f),
        throwsA(isA<NotebookException>()),
      );
      expect((await book.records), isEmpty);
    }
  });
  test('空间不足提前拒绝导入和导出，原件与已有记录不变', () async {
    await book.saveText('已有内容');
    await source.saveText('待导入');
    final good = await BackupService(source).export();
    final service = BackupService(book, availableBytes: (_) => Future.value(1));
    await expectLater(service.restore(good), throwsA(isA<NotebookException>()));
    await expectLater(service.export(), throwsA(isA<NotebookException>()));
    expect((await book.records).single.body, '已有内容');
    expect(await good.exists(), isTrue);
  });
  test('最终SQL事务失败整体回滚原始库', () async {
    await book.saveText('已有内容');
    await source.saveText('待导入');
    final good = await BackupService(source).export();
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_restore BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'test'); END",
    );
    await expectLater(
      BackupService(book).restore(good),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.records).single.body, '已有内容');
    expect(StorageProbe(book).select('SELECT * FROM restored'), isEmpty);
    expect(await Directory('${home.path}/imports').list().length, 0);
  });
  test('有效STORE包的CRC损坏仍被拒绝', () async {
    await book.saveText('已有内容');
    await source.saveText('unique-CRC-payload');
    final good = await BackupService(source).export();
    final bytes = await good.readAsBytes();
    final marker = utf8.encode('unique-CRC-payload');
    var at = -1;
    for (var i = 0; i <= bytes.length - marker.length; i++) {
      if (List.generate(
        marker.length,
        (j) => bytes[i + j] == marker[j],
      ).every((b) => b)) {
        at = i;
        break;
      }
    }
    expect(at, greaterThanOrEqualTo(0));
    bytes[at] = bytes[at] ^ 1;
    final bad = await File('${other.path}/crc-broken.zip').writeAsBytes(bytes);
    await expectLater(
      BackupService(book).restore(bad),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.records).single.body, '已有内容');
  });
  test('导出持有一致快照和媒体租约，允许编辑并拒绝删除', () async {
    final row = await source.saveText('快照中的原文');
    final pending = <Future<void>>[];
    var changed = false;
    final good = await BackupService(source).export(
      progress: (_) {
        if (changed) return;
        changed = true;
        pending.add(
          expectLater(source.delete(row.id), throwsA(isA<NotebookException>())),
        );
        pending.add(
          source.edit(row.id, '导出期间编辑', expectedRevision: row.revision),
        );
        pending.add(source.saveText('快照之后新增').then((_) {}));
      },
    );
    await Future.wait(pending);
    expect((await source.get(row.id))!.body, '导出期间编辑');
    final report = await BackupService(book).restore(good);
    expect(report.added, 1);
    expect((await book.get(row.id))!.body, '快照中的原文');
    await source.delete(row.id);
    expect((await source.get(row.id)), isNull);
  });
  test('导出取消不留下成功包且释放媒体租约', () async {
    final row = await source.saveText('原文');
    final service = BackupService(source);
    await expectLater(
      service.export(progress: (_) => service.cancelled = true),
      throwsA(isA<NotebookException>()),
    );
    expect(await Directory('${other.path}/exports').list().length, 0);
    expect((await source.get(row.id))!.body, '原文');
    await source.delete(row.id);
    expect((await source.get(row.id)), isNull);
  });

  test('进度回调异常归入本次失败，不留下成功包或泄漏租约', () async {
    final r = await source.saveText('原文');
    await expectLater(
      BackupService(source)
          .export(progress: (_) => throw StateError('callback')),
      throwsA(isA<NotebookException>()),
    );
    expect(await Directory('${other.path}/exports').list().length, 0);
    await source.delete(r.id);
    expect((await source.records), isEmpty);
  });

  test('恢复中的运行态转写会排队恢复，而不永久停留在running', () async {
    final draft = await source.beginCapture();
    await writeWave(draft.path);
    final r = await source.finishCapture(draft);
    (await source.repository.transcriptionState(r.id, 'running'));
    await BackupService(book).restore(await BackupService(source).export());
    expect((await book.get(r.id))!.transcription, 'pending');
    expect(
      await File(book.audioPath((await book.get(r.id))!)).exists(),
      isTrue,
    );
  });

  test('恢复副本在提交前有持久清理意图，取消后移除副本与清理日志', () async {
    final draft = await source.beginCapture();
    await writeWave(draft.path);
    await source.finishCapture(draft);
    final backup = await BackupService(source).export();
    final service = BackupService(book);
    List<String>? pendingAtCopy;
    await expectLater(
      service.restore(
        backup,
        progress: (value) {
          if (value == 1) {
            pendingAtCopy = StorageProbe(book)
                .select('SELECT audio FROM pending_media_deletions')
                .map((r) => r['audio'] as String)
                .toList();
            service.cancelled = true;
          }
        },
      ),
      throwsA(isA<NotebookException>()),
    );
    expect(pendingAtCopy, hasLength(1));
    expect((await book.repository.pendingMediaDeletions()), isEmpty);
    expect(await Directory('${home.path}/audio').list().length, 0);
  });
}
