import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';

void main() {
  test('下载文件大小及 SHA-256 都正确后才原子启用，损坏重试保留旧版本', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-model-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var corrupt = false;
    server.listen((req) async {
      req.response.add(utf8.encode(corrupt ? 'damaged' : 'weights'));
      await req.response.close();
    });
    final uri = Uri.parse('http://127.0.0.1:${server.port}/model');
    final good = ModelSpec(
      id: 'test',
      version: 'v1',
      label: '测试模型',
      files: [
        ModelFile(
          name: 'model.onnx',
          url: uri,
          bytes: 7,
          sha256: sha256.convert(utf8.encode('weights')).toString(),
        ),
      ],
    );
    final store = ModelStore(home, [good]);
    try {
      expect(await store.ready('test'), isFalse);
      await store.download('test');
      expect(await store.ready('test'), isTrue);
      corrupt = true;
      final update = ModelSpec(
        id: 'test',
        version: 'v2',
        label: '测试模型',
        files: good.files,
      );
      final next = ModelStore(home, [update]);
      await expectLater(next.download('test'), throwsA(anything));
      expect(await next.ready('test'), isFalse);
      expect(await store.ready('test'), isTrue);
      expect(
        await File('${store.directory(good).path}/model.onnx').readAsString(),
        'weights',
      );
    } finally {
      await server.close(force: true);
      await home.delete(recursive: true);
    }
  });
  test('BGE tokenizer 保留大小写，中文拆字，WordPiece 与特殊 token 对齐', () {
    final tok = BertTokenizer([
      '[PAD]',
      '[UNK]',
      '[CLS]',
      '[SEP]',
      '中',
      '文',
      'SQL',
      '##ite',
      '!',
    ]);
    expect(tok.encode('中文 SQLite!'), [2, 4, 5, 6, 7, 8, 3]);
    expect(tok.encode('sqlite'), [2, 1, 3]);
  });
  test('BERT 清理零宽控制字符，保持中文分词和原有大小写', () {
    final tok = BertTokenizer(['[PAD]', '[UNK]', '[CLS]', '[SEP]', '中', '文']);
    expect(tok.encode('中\u200b文'), [2, 4, 5, 3]);
  });
}
