import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';

import 'support/storage_probe.dart';

void main() {
  late Directory root;
  late Notebook book;
  late Record parent;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-text-submission-');
    book = await Notebook.open(root, clock: () => DateTime.utc(2026, 11, 19));
    parent = await book.saveText('原记录');
  });
  tearDown(() async {
    await book.close();
    await root.delete(recursive: true);
  });
  test('同一文字保存意图并发与超时观察重试共享身份，成功后删除也不复活', () async {
    final intent = book.prepareText('本次文字', parentId: parent.id);
    final first = book.saveTextSubmission(intent);
    final retry = book.saveTextSubmission(intent);
    expect(identical(first, retry), isTrue);
    // Timing out an observer must not cancel or repeat the underlying intent.
    final lateReply = Completer<void>();
    final observer = first.then((record) async {
      await lateReply.future;
      return record;
    });
    await expectLater(
      observer.timeout(Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    final saved = await retry;
    lateReply.complete();
    expect((await observer).id, saved.id);
    expect(saved.id, intent.id);
    expect(saved.parentId, parent.id);
    expect(await book.childCount(parent.id), 1);
    await book.delete(saved.id);
    expect((await book.saveTextSubmission(intent)).id, saved.id);
    expect(await book.get(saved.id), isNull);
    expect(await book.childCount(parent.id), 0);
  });
  test('失败可重试，父消失只在明确独立保存后转换且继续复用身份', () async {
    final intent = book.prepareText('保留的补充', parentId: parent.id);
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_append BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT,'synthetic fault'); END",
    );
    await expectLater(
      book.saveTextSubmission(intent),
      throwsA(isA<NotebookException>()),
    );
    StorageProbe(book).execute('DROP TRIGGER fail_append');
    await book.delete(parent.id);
    await expectLater(
      book.saveTextSubmission(intent),
      throwsA(isA<NotebookException>()),
    );
    expect(await book.records, isEmpty);
    final first = book.saveTextSubmission(intent, standalone: true);
    final second = book.saveTextSubmission(intent, standalone: true);
    expect(identical(first, second), isTrue);
    final saved = await first;
    expect(saved.id, intent.id);
    expect(saved.parentId, isNull);
    expect((await book.saveTextSubmission(intent)).id, saved.id);
    expect(await book.records, hasLength(1));
    expect(await book.get(parent.id), isNull);
  });
  test('已提交但未收到回执的身份只返回现有记录，不覆盖后续编辑', () async {
    final intent = book.prepareText('原提交正文', parentId: parent.id);
    // Real SQL fixture represents a committed insert followed by a lost reply.
    await book.repository.insert(
      Record(
        id: intent.id,
        body: '后来已修改的正文',
        parentId: parent.id,
        createdAt: DateTime.utc(2026),
        timezone: 'UTC',
        offsetMinutes: 0,
        revision: 2,
      ),
    );
    final saved = await book.saveTextSubmission(intent);
    expect(saved.id, intent.id);
    expect(saved.body, '后来已修改的正文');
    expect(saved.revision, 2);
    expect(await book.childCount(parent.id), 1);
  });
  test('有界定位同时间戳95次追加并前后遍历无遗漏，正文和转写投影受限', () async {
    final children = <Record>[];
    for (var i = 0; i < 95; i++) {
      children.add(
        await book.saveText('追加$i${'字' * 1000}', parentId: parent.id),
      );
    }
    children.sort((a, b) => a.id.compareTo(b.id));
    var detail = (await book.detail(parent.id, aroundId: children.last.id))!;
    expect(detail.children.entries.length, lessThanOrEqualTo(40));
    expect(
      detail.children.entries.any((v) => v.record.id == children.last.id),
      isTrue,
    );
    expect(detail.children.previous, isNotNull);
    while (detail.children.previous != null) {
      detail = (await book.detail(
        parent.id,
        before: detail.children.previous,
        generation: detail.children.generation,
      ))!;
    }
    final visited = <String>[];
    while (true) {
      expect(detail.children.entries.length, lessThanOrEqualTo(40));
      for (final entry in detail.children.entries) {
        visited.add(entry.record.id);
        expect(entry.record.body.length, lessThanOrEqualTo(600));
        expect(entry.record.transcript, isNull);
        expect(entry.record.vector, isNull);
      }
      if (detail.children.next == null) break;
      detail = (await book.detail(
        parent.id,
        after: detail.children.next,
        generation: detail.children.generation,
      ))!;
    }
    expect(visited, children.map((v) => v.id).toList());
    expect((await book.get(children.last.id))!.body.length, greaterThan(600));
    final other = await book.saveText('另一个原记录');
    final outside = await book.saveText('别组补充', parentId: other.id);
    final page = (await book.detail(parent.id, aroundId: outside.id))!.children;
    expect(page.entries.any((v) => v.record.id == outside.id), isFalse);
    await book.saveText('改变代次');
    final reset = (await book.detail(
      parent.id,
      after: page.next,
      generation: page.generation,
    ))!.children;
    expect(reset.reset, isTrue);
    expect(reset.entries.first.record.id, children.first.id);
  });
}
