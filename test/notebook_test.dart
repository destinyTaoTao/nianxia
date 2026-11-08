import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';

void main() {
  late Directory home;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-test-');
  });
  tearDown(() async {
    await home.delete(recursive: true);
  });

  test('文字记录经应用操作保存，重启仍保留，编辑后可删除', () async {
    var book = await Notebook.open(home);
    final saved = await book.saveText('离线记录一个 SQLite 想法');
    expect(book.records.single.body, '离线记录一个 SQLite 想法');
    final created = saved.createdAt;
    book.dispose();
    book = await Notebook.open(home);
    expect(book.records.single.id, saved.id);
    await book.edit(saved.id, '改为本地语音本', expectedRevision: saved.revision);
    expect(book.records.single.createdAt, created);
    expect(book.records.single.revision, saved.revision + 1);
    await book.delete(saved.id);
    expect(book.records, isEmpty);
    book.dispose();
  });
}
