import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';

import 'recording_search_test.dart' show writeWave;

class _CountingOrganizer implements Organizer {
  int requests = 0;
  @override
  Future<Map<String, dynamic>> organize(String text) async {
    requests++;
    return {'title': '整理', 'points': [], 'tasks': []};
  }
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('storage-race-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });

  test('媒体租约等待已经接收的删除及清理，不能越过异步SQL窗口', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final r = await book.finishCapture(draft);
    var deletionFinished = false;
    final deleting = book
        .delete(r.id)
        .whenComplete(() => deletionFinished = true);
    await book.withMediaLease(() async {
      expect(deletionFinished, isTrue);
      expect(await File(book.audioPath(r)).exists(), isFalse);
    });
    await deleting;
  });

  test('关闭发生在异步资料读取期间，不得再发起新的付费整理请求', () async {
    final record = await book.saveText('本地原文');
    final consent = await book.prepareOrganization(record.id);
    final organizer = _CountingOrganizer();
    final organizing = book.organize(consent, organizer);
    await book.close();
    expect(await organizing, isFalse);
    expect(organizer.requests, 0);
  });
}
