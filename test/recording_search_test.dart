import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:nianxia/data/capture_store.dart';

Future<void> writeWave(String path, {bool interrupted = false}) async {
  final b = ByteData(32044);
  void tag(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, interrupted ? 0 : 32036, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, interrupted ? 0 : 32000, Endian.little);
  await File(path).writeAsBytes(b.buffer.asUint8List(), flush: true);
}

class TextTranscriber implements Transcriber {
  TextTranscriber(this.text);
  final Future<String> text;
  @override
  Future<String> transcribe(String path) => text;
}

class UnitEmbedder implements Embedder {
  @override
  Future<List<double>> embed(String text, {required bool query}) async => [
    1,
    ...List<double>.filled(511, 0),
  ];
}

class UnavailableEmbedder implements Embedder {
  @override
  Future<List<double>> embed(String text, {required bool query}) async {
    throw const NotebookException('未就绪');
  }
}

void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-record-test-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    book.dispose();
    await home.delete(recursive: true);
  });
  test('录音先验证落盘，转写不覆盖并发编辑，删除后不复活', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final r = await book.finishCapture(draft);
    expect(r.durationMs, 1000);
    expect(File(book.audioPath(r)).existsSync(), isTrue);
    final task = book.transcribe(
      r.id,
      TextTranscriber(
        Future.delayed(const Duration(milliseconds: 20), () => '识别结果'),
      ),
    );
    await book.edit(r.id, '用户修订', expectedRevision: r.revision);
    expect(await task, isFalse);
    expect(book.get(r.id)!.body, '用户修订');
    final retry = book.transcribe(
      r.id,
      TextTranscriber(
        Future.delayed(const Duration(milliseconds: 20), () => '迟到结果'),
      ),
    );
    await book.delete(r.id);
    expect(await retry, isFalse);
    expect(book.records, isEmpty);
    expect(await File(book.audioPath(r)).exists(), isFalse);
  });
  test('重启恢复中断的有效 WAV，取消及查询不会产生记录', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path, interrupted: true);
    book.dispose();
    book = await Notebook.open(home);
    expect(book.records.single.durationMs, 1000);
    expect(book.recoveredCount, 1);
    expect(await validateWave(File(book.audioPath(book.records.single))), 1000);
    final query = await book.beginCapture(query: true);
    await writeWave(query.path);
    expect(
      await book.transcribeQuery(query, TextTranscriber(Future.value('产品想法'))),
      '产品想法',
    );
    expect(await File(query.path).exists(), isFalse);
    final cancel = await book.beginCapture();
    await writeWave(cancel.path);
    await book.cancelCapture(cancel);
    expect(book.records.length, 1);
  });
  test('追加可查，日期可筛选，编辑删除与收藏持久一致', () async {
    final parent = await book.saveText('不要自动上传');
    final child = await book.saveText('ＳＱＬｉｔｅ 与中文检索', parentId: parent.id);
    await book.favorite(parent.id, true);
    expect((await book.search('sqlite')).single.record.id, child.id);
    expect((await book.search('中文')).single.record.parentId, parent.id);
    expect(await book.search('不存在'), isEmpty);
    expect(await book.search('中文', from: DateTime(2100)), isEmpty);
    await book.edit(child.id, '改用本地数据库', expectedRevision: child.revision);
    expect(await book.search('sqlite'), isEmpty);
    expect(book.get(parent.id)!.favorite, isTrue);
    await book.delete(parent.id);
    expect(await book.search('数据库'), isEmpty);
    expect(book.records, isEmpty);
  });
  test('损坏录音不显示成功，空白正文与过期修订被拒绝', () async {
    final draft = await book.beginCapture();
    await File(draft.path).writeAsString('not audio');
    await expectLater(
      book.finishCapture(draft),
      throwsA(isA<NotebookException>()),
    );
    expect(book.records, isEmpty);
    await book.cancelCapture(draft);
    await expectLater(book.saveText('  '), throwsA(isA<NotebookException>()));
    final r = await book.saveText('原文');
    await book.edit(r.id, '修改', expectedRevision: r.revision);
    await expectLater(
      book.edit(r.id, '旧页面', expectedRevision: r.revision),
      throwsA(isA<NotebookException>()),
    );
    expect(book.get(r.id)!.body, '修改');
  });
  test('平台 WAV 的额外 chunk 不会误判损坏，恢复后可再次校验', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final old = await File(draft.path).readAsBytes();
    final bytes = Uint8List(old.length + 16);
    bytes.setRange(0, 36, old.sublist(0, 36));
    bytes.setRange(36, 40, 'JUNK'.codeUnits);
    ByteData.sublistView(bytes).setUint32(40, 8, Endian.little);
    bytes.setRange(52, bytes.length, old.sublist(36));
    ByteData.sublistView(bytes).setUint32(4, bytes.length - 8, Endian.little);
    await File(draft.path).writeAsBytes(bytes);
    final saved = await book.finishCapture(draft);
    expect(saved.durationMs, 1000);
    expect(await validateWave(File(book.audioPath(saved))), 1000);
  });

  test('迟到的取消不能删除已提交记录的原音频', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await book.finishCapture(draft);
    await expectLater(
      book.cancelCapture(draft),
      throwsA(isA<NotebookException>()),
    );
    expect(book.get(saved.id), isNotNull);
    expect(await File(book.audioPath(saved)).exists(), isTrue);
  });

  test('语义推理失败仍返回关键词结果，并明确报告降级', () async {
    await book.saveText('本地关键词查找');
    final result = await book.search('关键词', embedder: UnavailableEmbedder());
    expect(result.single.record.body, '本地关键词查找');
    expect(result.semanticUsed, isFalse);
    expect(result.fallbackReason, contains('语义'));
  });
  test('模型或索引算法版本改变后旧向量被重建，同版重启保留', () async {
    book.setSearchModelVersion('bge-v1');
    final r = await book.saveText('原始正文');
    await book.index(r.id, UnitEmbedder());
    expect(
      (await book.search('另一种说法', embedder: UnitEmbedder())).single.record.id,
      r.id,
    );
    book.dispose();
    book = await Notebook.open(home);
    book.setSearchModelVersion('bge-v1');
    expect(
      (await book.search('另一种说法', embedder: UnitEmbedder())).single.record.id,
      r.id,
    );
    book.setSearchModelVersion('bge-v2');
    expect(await book.search('另一种说法', embedder: UnitEmbedder()), isEmpty);
  });
}
