import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:path/path.dart' as p;

import 'recording_search_test.dart' show writeWave;
import 'support/storage_probe.dart';

/// Deterministic inference fixtures; storage, indexing and ranking remain real.
class _Vectors implements Embedder {
  const _Vectors({required this.documents, required this.queries});
  final Map<String, List<double>> documents;
  final Map<String, List<double>> queries;

  @override
  Future<List<double>> embed(String text, {required bool query}) async {
    final vector = (query ? queries : documents)[text];
    if (vector == null) throw StateError('Missing embedding fixture: $text');
    return vector;
  }
}

class _PendingVector implements Embedder {
  final started = Completer<void>();
  final result = Completer<List<double>>();

  @override
  Future<List<double>> embed(String text, {required bool query}) {
    started.complete();
    return result.future;
  }
}

void main() {
  late Directory home;
  late Notebook book;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-indexed-search-');
    book = await Notebook.open(home);
  });

  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });

  test('关键词保留一字、二字、长子串以及全半角和大小写兼容', () async {
    final target = await book.saveText('灵感匣：中文检索支持ＳＱＬｉｔｅ、Ａ＋Ｂ，保留１００％_原文。');
    await book.saveText('中文说明：检索分词不应跨越标点；A B；100元。');
    await book.saveText('离线记录和本地转写。');

    for (final query in [
      '匣',
      '文检',
      '中文检索',
      'sqlite',
      'ＳｑＬＩＴＥ',
      'a+b',
      'Ａ＋Ｂ',
      '100%_',
      '、a+b,',
      '_',
    ]) {
      final hits = await book.search(query);
      expect(hits.map((hit) => hit.record.id), [target.id], reason: query);
      expect(hits.single.snippet, target.body, reason: query);
    }
    for (final query in ['中文支持', '中文 检索', '100X_', '不存在', '   ']) {
      expect(await book.search(query), isEmpty, reason: query);
    }
  });

  test('候选字符全部存在也不能把非连续子串误当精确命中', () async {
    final target = await book.saveText('产品技术复盘');
    await book.saveText('产品讨论，随后技术复盘');
    await book.saveText('产品技，品技术，产品，技术');
    final hits = await book.search('产品技术');
    expect(hits.map((hit) => hit.record.id), [target.id]);
  });

  test('长正文尾部的中文子串可查并返回原文片段', () async {
    final target = await book.saveText('${'背景内容。' * 1000}特殊尾部灵感');
    await book.saveText('特殊开头，但尾部并没有目标');
    final hits = await book.search('尾部灵感');
    expect(hits.map((hit) => hit.record.id), [target.id]);
    expect(hits.single.snippet, contains('尾部灵感'));
  });

  test('离线向量召回无公共关键词的记录，并保留精确命中排序', () async {
    const vectors = _Vectors(
      documents: {
        '买杯热饮': [1, 0],
        '讨论数据库': [0, 1],
      },
      queries: {
        '咖啡': [4, 0],
      },
    );
    await book.setSearchModelVersion('fixture-two-dimensions');
    final semantic = await book.saveText('买杯热饮');
    final unrelated = await book.saveText('讨论数据库');
    final exact = await book.saveText('咖啡提醒');
    expect(await book.index(semantic.id, vectors), isTrue);
    expect(await book.index(unrelated.id, vectors), isTrue);

    final hits = await book.search('咖啡', embedder: vectors);
    expect(hits.map((hit) => hit.record.id), [exact.id, semantic.id]);
    expect(hits.semanticUsed, isTrue);
    expect(hits.last.snippet, '买杯热饮');
    expect(hits.every((hit) => hit.record.vector == null), isTrue);
  });

  test('模型维度不兼容时保留关键词，切换模型代后不能召回旧向量', () async {
    const two = _Vectors(
      documents: {
        '原始正文': [1, 0],
      },
      queries: {
        '不同表达': [1, 0],
      },
    );
    const three = _Vectors(
      documents: {
        '原始正文': [0, 0, 1],
      },
      queries: {
        '不同表达': [0, 0, 1],
        '原始': [0, 0, 1],
      },
    );
    await book.setSearchModelVersion('two');
    final note = await book.saveText('原始正文');
    expect(await book.index(note.id, two), isTrue);
    expect(
      (await book.search('不同表达', embedder: two)).single.record.id,
      note.id,
    );
    expect(await book.search('不同表达', embedder: three), isEmpty);
    expect(
      (await book.search('原始', embedder: three)).single.record.id,
      note.id,
    );

    await book.setSearchModelVersion('three');
    expect(await book.search('不同表达', embedder: three), isEmpty);
    expect(await book.index(note.id, three), isTrue);
    expect(
      (await book.search('不同表达', embedder: three)).single.record.id,
      note.id,
    );
    await book.close();
    book = await Notebook.open(home);
    await book.setSearchModelVersion('three');
    expect(
      (await book.search('不同表达', embedder: three)).single.record.id,
      note.id,
    );
    expect((await book.get(note.id))!.body, '原始正文');
  });

  test('模型切换拒绝迟到的旧代索引结果', () async {
    await book.setSearchModelVersion('old');
    final note = await book.saveText('原始正文');
    final pending = _PendingVector();
    final work = book.index(note.id, pending);
    await pending.started.future;
    await book.setSearchModelVersion('new');
    pending.result.complete([1, 0]);
    expect(await work, isFalse);
    const query = _Vectors(
      documents: {},
      queries: {
        '另一种说法': [1, 0],
      },
    );
    expect(await book.search('另一种说法', embedder: query), isEmpty);
    expect((await book.search('原始')).single.record.id, note.id);
  });

  for (final delete in [false, true]) {
    test('${delete ? '删除' : '编辑'}期间完成的旧修订索引不能恢复旧命中', () async {
      final note = await book.saveText('旧版热饮计划');
      final pending = _PendingVector();
      final work = book.index(note.id, pending);
      await pending.started.future;
      if (delete) {
        await book.delete(note.id);
      } else {
        await book.edit(note.id, '新版出行计划', expectedRevision: note.revision);
      }
      pending.result.complete([1, 0]);
      expect(await work, isFalse);
      const query = _Vectors(
        documents: {},
        queries: {
          '咖啡': [1, 0],
        },
      );
      expect(await book.search('咖啡', embedder: query), isEmpty);
      expect(await book.search('旧版'), isEmpty);
      if (delete) {
        expect(await book.get(note.id), isNull);
      } else {
        expect((await book.search('新版')).single.record.id, note.id);
        expect((await book.get(note.id))!.body, '新版出行计划');
      }
    });
  }

  test('编辑和级联删除立即更新关键词与语义，重开不恢复旧命中', () async {
    const vectors = _Vectors(
      documents: {
        '旧版热饮计划': [1, 0],
        '新版出行计划': [0, 1],
      },
      queries: {
        '咖啡': [1, 0],
        '旅游': [0, 1],
      },
    );
    await book.setSearchModelVersion('plans');
    final parent = await book.saveText('主题记录');
    final child = await book.saveText('旧版热饮计划', parentId: parent.id);
    expect(await book.index(child.id, vectors), isTrue);
    expect(
      (await book.search('咖啡', embedder: vectors)).single.record.id,
      child.id,
    );
    await book.edit(child.id, '新版出行计划', expectedRevision: child.revision);
    expect(await book.search('旧版'), isEmpty);
    expect(await book.search('咖啡', embedder: vectors), isEmpty);
    expect((await book.search('新版')).single.record.id, child.id);
    expect(await book.index(child.id, vectors), isTrue);
    await book.close();
    book = await Notebook.open(home);
    expect(
      (await book.search('旅游', embedder: vectors)).single.record.id,
      child.id,
    );
    expect(await book.search('旧版'), isEmpty);
    await book.delete(parent.id);
    expect(await book.search('新版'), isEmpty);
    expect(await book.search('旅游', embedder: vectors), isEmpty);
    await book.close();
    book = await Notebook.open(home);
    expect(await book.search('新版'), isEmpty);
    expect(await book.search('旅游', embedder: vectors), isEmpty);
    expect(await book.get(child.id), isNull);
  });

  test('外部连接编辑及插入在下次查找可见，不能继续返回缓存正文', () async {
    final note = await book.saveText('外部修改前');
    expect((await book.search('修改前')).single.record.id, note.id);
    expect(await book.search('外部新增'), isEmpty);
    final probe = StorageProbe(book);
    probe.execute('UPDATE records SET body=?,revision=revision+1 WHERE id=?', [
      '外部修改后',
      note.id,
    ]);
    probe.execute(
      'INSERT INTO records '
      '(id,parent_id,body,created_at,timezone,offset_minutes,revision,favorite,'
      'audio,duration_ms,transcript,transcription) '
      'VALUES (?,NULL,?,?,?,0,1,0,NULL,0,NULL,?)',
      ['external-note', '外部新增', '2026-11-12T00:00:00.000Z', 'UTC', 'none'],
    );
    expect(await book.search('修改前'), isEmpty);
    final updated = (await book.search('修改后')).single.record;
    expect(updated.id, note.id);
    expect(updated.body, '外部修改后');
    expect(updated.revision, note.revision + 1);
    expect((await book.search('外部新增')).single.record.id, 'external-note');
    probe.execute('DELETE FROM records WHERE id=?', ['external-note']);
    expect(await book.search('外部新增'), isEmpty);
  });

  test('外部连接替换向量后下次语义查找不使用旧索引', () async {
    const vectors = _Vectors(
      documents: {
        '热饮建议': [1, 0],
        '数据存储': [0, 1],
      },
      queries: {
        '咖啡': [1, 0],
      },
    );
    await book.setSearchModelVersion('external-vectors');
    final first = await book.saveText('热饮建议');
    final second = await book.saveText('数据存储');
    expect(await book.index(first.id, vectors), isTrue);
    expect(await book.index(second.id, vectors), isTrue);
    expect(
      (await book.search('咖啡', embedder: vectors)).single.record.id,
      first.id,
    );
    StorageProbe(book).execute(
      'UPDATE record_embeddings SET payload='
      '(SELECT payload FROM record_embeddings WHERE record_id=?) '
      'WHERE record_id=?',
      [second.id, first.id],
    );
    expect(await book.search('咖啡', embedder: vectors), isEmpty);
    expect((await book.get(first.id))!.body, '热饮建议');
  });

  for (final corrupt in [false, true]) {
    test('${corrupt ? '损坏' : '删除'} sidecar 后重开重建检索，原始数据与音频保持不变', () async {
      const vectors = _Vectors(
        documents: {
          '原始热饮记录': [1, 0],
        },
        queries: {
          '咖啡': [1, 0],
        },
      );
      await book.setSearchModelVersion('recoverable');
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      final note = await book.finishCapture(draft);
      await book.edit(note.id, '原始热饮记录', expectedRevision: note.revision);
      await book.favorite(note.id, true);
      final child = await book.saveText('追加原始文本', parentId: note.id);
      expect(await book.index(note.id, vectors), isTrue);
      expect(
        (await book.search('咖啡', embedder: vectors)).single.record.id,
        note.id,
      );
      expect((await book.search('追加')).single.record.id, child.id);
      final raw = StorageProbe(book)
          .select('SELECT * FROM records ORDER BY id');
      final embeddings = StorageProbe(book)
          .select('SELECT * FROM record_embeddings ORDER BY record_id');
      final audio = File(book.audioPath(note));
      final bytes = await audio.readAsBytes();
      await book.close();

      final sidecar = File(p.join(home.path, 'search-index.sqlite'));
      expect(await sidecar.exists(), isTrue);
      for (final suffix in ['-wal', '-shm']) {
        final companion = File('${sidecar.path}$suffix');
        if (await companion.exists()) await companion.delete();
      }
      if (corrupt) {
        await sidecar.writeAsString(
          'broken disposable search cache',
          flush: true,
        );
      } else {
        await sidecar.delete();
      }

      book = await Notebook.open(home);
      expect((await book.search('原始热饮')).single.record.id, note.id);
      expect((await book.search('追加')).single.record.id, child.id);
      expect(
        (await book.search('咖啡', embedder: vectors)).single.record.id,
        note.id,
      );
      expect(
        StorageProbe(book).select('SELECT * FROM records ORDER BY id'),
        raw,
      );
      expect(
        StorageProbe(book)
            .select('SELECT * FROM record_embeddings ORDER BY record_id'),
        embeddings,
      );
      expect(await audio.readAsBytes(), bytes);
      expect(
        StorageProbe(book).select('PRAGMA user_version').single.values.single,
        2,
      );
    });
  }
}
