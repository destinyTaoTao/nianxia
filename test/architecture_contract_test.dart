import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';

import 'recording_search_test.dart' show writeWave, TextTranscriber;

class _Vector implements Embedder {
  _Vector(this.result);
  final Future<List<double>> result;
  @override
  Future<List<double>> embed(String text, {required bool query}) => result;
}

class _Organization implements Organizer {
  _Organization(this.result);
  final Future<Map<String, dynamic>> result;
  @override
  Future<Map<String, dynamic>> organize(String text) => result;
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-architecture-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });

  test('并发保存同一录音只提交一次，所有调用返回同一记录', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await Future.wait([
      book.finishCapture(draft),
      book.finishCapture(draft),
    ]);
    expect(saved.map((r) => r.id).toSet(), {draft.id});
    expect((await book.records).length, 1);
    expect(await File(book.audioPath(saved.first)).exists(), isTrue);
  });

  test('保存与丢弃交错时，迟到的丢弃不能删除已提交音频', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saving = book.finishCapture(draft);
    final discarding = book.cancelCapture(draft);
    final rejected = expectLater(discarding, throwsA(isA<NotebookException>()));
    final saved = await saving;
    await rejected;
    expect((await book.get(saved.id)), isNotNull);
    expect(await File(book.audioPath(saved)).exists(), isTrue);
  });

  test('查询推理期间切换模型代际，不与新索引混算', () async {
    await book.setSearchModelVersion('model-a');
    final r = await book.saveText('本地关键词');
    final pending = Completer<List<double>>();
    final finding = book.search('关键词', embedder: _Vector(pending.future));
    await book.setSearchModelVersion('model-b');
    await book.index(r.id, _Vector(Future.value([1, 0])));
    pending.complete([1, 0]);
    final found = await finding;
    expect(found.single.record.id, r.id);
    expect(found.semanticUsed, isFalse);
    expect(found.fallbackReason, isNotNull);
  });

  test('插件返回非有限查询向量时明确降级关键词', () async {
    await book.saveText('本地关键词');
    final found = await book.search(
      '关键词',
      embedder: _Vector(Future.value([double.nan, 0])),
    );
    expect(found.single.record.body, '本地关键词');
    expect(found.semanticUsed, isFalse);
    expect(found.fallbackReason, contains('不可用'));
  });

  test('插件的有限非零向量按余弦相似度比较，不受向量幅度影响', () async {
    final r = await book.saveText('另一种表达');
    await book.index(r.id, _Vector(Future.value([0.1, 0])));
    final found = await book.search(
      '相似说法',
      embedder: _Vector(Future.value([0.1, 0])),
    );
    expect(found.single.record.id, r.id);
  });

  test('检索命中只保留展示记录，不把向量工作载荷留在结果集中', () async {
    final r = await book.saveText('原始正文');
    await book.index(r.id, _Vector(Future.value([1, 0])));
    final found = await book.search(
      '另一种表达',
      embedder: _Vector(Future.value([1, 0])),
    );
    expect(found.single.record.body, '原始正文');
    expect(found.single.record.vector, isNull);
    expect(found.single.record.vectorRevision, r.revision);
    expect((await book.get(r.id))!.vector, isNotNull);
  });

  test('零向量拒绝写入索引，保留关键词路径', () async {
    final r = await book.saveText('原始正文');
    await expectLater(
      book.index(r.id, _Vector(Future.value([0, 0]))),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.get(r.id))!.vectorRevision, isNull);
    expect((await book.search('原始')).single.record.id, r.id);
  });

  test('转写Adapter返回超出原始资料契约的正文时拒绝写入，音频可重试', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final r = await book.finishCapture(draft);
    await expectLater(
      book.transcribe(r.id, TextTranscriber(Future.value('x' * 100001))),
      throwsA(isA<NotebookException>()),
    );
    final actual = (await book.get(r.id))!;
    expect(actual.body, isEmpty);
    expect(actual.transcript, isNull);
    expect(actual.transcription, 'failed');
    expect(await File(book.audioPath(actual)).exists(), isTrue);
  });

  test('分页检索期间删除已扫描记录，结果不残留已删除内容', () async {
    final records = <Record>[];
    for (var i = 0; i < 80; i++) {
      records.add(await book.saveText('共同关键词 $i'));
    }
    // ID ordering is the storage scan order, independent of creation time.
    records.sort((a, b) => a.id.compareTo(b.id));
    final finding = book.search('共同关键词');
    await book.delete(records.first.id);
    final found = await finding;
    expect(found.length, 79);
    expect(found.any((hit) => hit.record.id == records.first.id), isFalse);
  });

  test('替换整理Adapter仍执行原文依据校验，不能绕过业务不变量', () async {
    final r = await book.saveText('暂时不做同步');
    await expectLater(
      book.organize(
        (await book.prepareOrganization(r.id)),
        _Organization(
          Future.value({
            'title': '整理',
            'points': [
              {'text': '开始同步', 'evidence': '不存在的原文'},
            ],
            'tasks': [],
          }),
        ),
      ),
      throwsA(isA<NotebookException>()),
    );
    expect((await book.get(r.id))!.organization, isNull);
    expect((await book.get(r.id))!.body, '暂时不做同步');
  });

  test('整理模型代际变更拒绝迟到结果，不能标成新模型产物', () async {
    final r = await book.saveText('暂时不做同步');
    (await book.repository.ensureOrganizationVersion('cloud-a'));
    final result = Completer<Map<String, dynamic>>();
    final work = book.organize(
      (await book.prepareOrganization(r.id)),
      _Organization(result.future),
    );
    (await book.repository.ensureOrganizationVersion('cloud-b'));
    result.complete({'title': '整理', 'points': [], 'tasks': []});
    expect(await work, isFalse);
    expect((await book.get(r.id))!.organization, isNull);
  });
}
