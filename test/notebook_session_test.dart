import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/app/notebook_session.dart';

void main() {
  late Directory home;
  setUp(
    () async =>
        home = await Directory.systemTemp.createTemp('nianxia-session-'),
  );
  tearDown(() async => home.delete(recursive: true));

  test('模型初始化失败释放已打开资料库，不阻止下次重试', () async {
    await expectLater(
      NotebookSession.open(
        home,
        loadModelManifest: () async =>
            throw const FormatException('bad manifest'),
      ),
      throwsA(isA<FormatException>()),
    );
    final db = sqlite3.open('${home.path}/records.sqlite');
    try {
      db.execute('PRAGMA locking_mode = EXCLUSIVE');
      db.execute('BEGIN EXCLUSIVE');
      expect(db.select('SELECT COUNT(*) AS n FROM records').single['n'], 0);
      db.execute('ROLLBACK');
    } finally {
      db.close();
    }
    final session = await NotebookSession.open(
      home,
      loadModelManifest: () => File('assets/models.json').readAsString(),
    );
    await session.book.saveText('重试后保存');
    expect((await session.book.records).single.body, '重试后保存');
    await session.close();
  });

  test('统一生命周期可重复关闭，持久内容保留', () async {
    final session = await NotebookSession.open(
      home,
      loadModelManifest: () => File('assets/models.json').readAsString(),
    );
    await session.book.saveText('保留的正文');
    await session.close();
    await session.close();
    final db = sqlite3.open('${home.path}/records.sqlite');
    try {
      expect(db.select('SELECT body FROM records').single['body'], '保留的正文');
    } finally {
      db.close();
    }
  });
}
