import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/app/notebook_session.dart';

import 'recording_search_test.dart' show writeWave;

void main() {
  late Directory home;
  setUp(
    () async =>
        home = await Directory.systemTemp.createTemp('nianxia-session-'),
  );
  tearDown(() async => home.delete(recursive: true));

  test('模型目录加载失败仍可记录和关键词查找', () async {
    final session = await NotebookSession.open(
      home,
      loadModelManifest: () async =>
          throw const FormatException('bad manifest'),
    );
    try {
      expect(session.modelNotice, isNotNull);
      await session.book.saveText('synthetic fallback');
      expect((await session.book.records).single.body, 'synthetic fallback');
      expect(session.models.store.models, isEmpty);
    } finally {
      await session.close();
    }
  });

  test('启动先返回资料库，完整孤儿维护可延后且不移动新录音', () async {
    final audio = await Directory('${home.path}/audio').create(recursive: true);
    await File('${audio.path}/unknown.wav').writeAsBytes([1, 2, 3]);
    final session = await NotebookSession.open(
      home,
      loadModelManifest: () async => '[]',
    );
    final draft = await session.book.beginCapture();
    await writeWave(draft.path);
    await session.maintenance;
    expect(await File(draft.path).exists(), isTrue);
    expect(session.book.isClosed, isFalse);
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
