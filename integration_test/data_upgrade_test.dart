// Real native SQLite/files, isolated test package only. No microphone fixture or
// inference is needed to prove storage compatibility and backup round-tripping.
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';
import 'package:sqlite3/sqlite3.dart';

import '../test/fixtures/schema_v1.dart';
import '../test/recording_search_test.dart' show writeWave;
import 'support/test_sandbox.dart';
import '../test/support/storage_probe.dart';

void main() {
  requireModelTestSandbox();
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const parent = '10000000-0000-4000-8000-000000000000';
  const child = '20000000-0000-4000-8000-000000000000';
  const audio = '30000000-0000-4000-8000-000000000000.wav';

  testWidgets('Android私有存储可用空间与原生SQLite版本可核验', (tester) async {
    final free = await const MethodChannel('app.nianxia/system')
        .invokeMethod<int>('availableStorageBytes');
    expect(free, greaterThan(0));
    final db = sqlite3.openInMemory();
    try {
      // Only environment metadata; never user records, audio or credentials.
      // ignore: avoid_print
      print(
        'Native storage: SQLite=${db.select('SELECT sqlite_version()').single.values.single}, freeBytes=$free',
      );
    } finally {
      db.close();
    }
  });

  testWidgets('原生v1升级保真，坏缓存降级，新备份往返幂等与整组删除清理', (tester) async {
    final home = await Directory.systemTemp.createTemp('upgrade-v1-');
    final target = await Directory.systemTemp.createTemp('upgrade-restore-');
    Notebook? book, restored;
    try {
      await Directory('${home.path}/audio').create();
      final file = File('${home.path}/audio/$audio');
      await writeWave(file.path);
      final hash = (await sha256.bind(file.openRead()).first).toString();
      final seed = sqlite3.open('${home.path}/records.sqlite');
      seed.execute(
        schemaV1Fixture
            .replaceAll("'parent'", "'$parent'")
            .replaceAll("'child'", "'$child'")
            .replaceAll("'original.wav',1234", "'$audio',1000"),
      );
      seed.close();
      book = await Notebook.open(home);
      expect(
        StorageProbe(book).select('PRAGMA user_version').single.values.single,
        2,
      );
      expect((await book.get(parent))!.body, '原文不改写');
      expect((await book.get(parent))!.transcript, '原始转写');
      expect((await book.get(parent))!.revision, 7);
      expect((await book.get(parent))!.favorite, isTrue);
      expect((await book.get(child))!.parentId, parent);
      expect((await book.get(child))!.organization, isNull);
      expect(StorageProbe(book).restoredId('frozen-hash'), parent);
      expect((await sha256.bind(file.openRead()).first).toString(), hash);
      final backup = await BackupService(book).export();
      restored = await Notebook.open(target);
      expect((await BackupService(restored).restore(backup)).added, 2);
      expect((await BackupService(restored).restore(backup)).skipped, 2);
      expect((await restored.get(child))!.parentId, parent);
      final copy = File(restored.audioPath((await restored.get(parent))!));
      expect((await sha256.bind(copy.openRead()).first).toString(), hash);
      StorageProbe(restored).execute(
        "CREATE TRIGGER fail_cleanup_ack BEFORE DELETE ON pending_media_deletions BEGIN SELECT RAISE(ABORT,'test'); END",
      );
      await restored.delete(parent);
      expect((await restored.records), isEmpty);
      expect(await copy.exists(), isFalse);
      expect((await restored.repository.pendingMediaDeletions()), hasLength(1));
      expect(restored.recoveryWarnings, greaterThan(0));
      StorageProbe(restored).execute('DROP TRIGGER fail_cleanup_ack');
      await restored.delete(parent);
      expect((await restored.repository.pendingMediaDeletions()), isEmpty);
    } finally {
      await book?.close();
      await restored?.close();
      await home.delete(recursive: true);
      await target.delete(recursive: true);
    }
  });

  testWidgets('高版本库拒绝打开且原始文件不改写', (tester) async {
    final home = await Directory.systemTemp.createTemp('future-schema-');
    try {
      final file = File('${home.path}/records.sqlite');
      final seed = sqlite3.open(file.path);
      seed.execute(schemaV1Fixture);
      seed.execute('PRAGMA user_version=99');
      seed.close();
      final before = await sha256.bind(file.openRead()).first;
      await expectLater(Notebook.open(home), throwsA(isA<NotebookException>()));
      expect(await sha256.bind(file.openRead()).first, before);
    } finally {
      await home.delete(recursive: true);
    }
  });

  testWidgets('原生storage isolate有界分页和排空关闭后重开保留资料', (tester) async {
    final home = await Directory.systemTemp.createTemp('storage-native-');
    Notebook? book;
    try {
      book = await Notebook.open(home, clock: () => DateTime.utc(2026));
      for (var i = 0; i < 125; i++) {
        await book.saveText('原生记录 $i');
      }
      var page = await book.page();
      expect(page.entries.length, 40);
      final ids = page.entries.map((e) => e.record.id).toSet();
      while (page.next != null) {
        page = await book.page(after: page.next, generation: page.generation);
        ids.addAll(page.entries.map((e) => e.record.id));
      }
      expect(ids.length, 125);
      final pending = book.saveText('关闭前提交');
      await book.close();
      final saved = await pending;
      book = await Notebook.open(home);
      expect((await book.get(saved.id))!.body, '关闭前提交');
      expect((await book.records).length, 126);
    } finally {
      await book?.close();
      await home.delete(recursive: true);
    }
  });
}
