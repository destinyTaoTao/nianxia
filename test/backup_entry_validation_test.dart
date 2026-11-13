import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/backup_codec.dart';
import 'package:nianxia/domain/record.dart';

import 'backup_v2_test.dart' show storedZip, legacyRow;

void main() {
  test('逐条读取仍校验旧版正文CRC，篡改正文不得被导入', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-entry-crc-');
    final work = await Directory('${home.path}/work').create();
    final progress = ReceivePort()..listen((_) {});
    try {
      final file = await storedZip(home, {
        'manifest.json': utf8.encode(
          jsonEncode({
            'format': 'nianxia',
            'version': 1,
            'records': [
              {...legacyRow(), 'body': 'original body'},
            ],
            'audio': {},
          }),
        ),
      });
      final bytes = await file.readAsBytes();
      final at = latin1.decode(bytes).indexOf('original body');
      expect(at, greaterThan(0));
      bytes[at] = 'O'.codeUnitAt(0);
      await file.writeAsBytes(bytes);
      await expectLater(
        decodeBackup(file.path, work.path, progress.sendPort),
        throwsA(anything),
      );
    } finally {
      progress.close();
      await home.delete(recursive: true);
    }
  });

  for (final version in [2, 999]) {
    test('格式 $version 的无引用条目在写入音频前拒绝', () async {
      final home = await Directory.systemTemp.createTemp('nianxia-entry-');
      final work = await Directory('${home.path}/work').create();
      final progress = ReceivePort()..listen((_) {});
      try {
        final file = await storedZip(home, {
          'audio/10000000-0000-4000-8000-000000000000.wav': [1, 2, 3],
          'manifest.json': utf8.encode(
            jsonEncode({
              'format': 'nianxia',
              'version': version,
              'minimumReader': 2,
              'records': 0,
              'audio': 0,
              'chunks': [],
            }),
          ),
        });
        await expectLater(
          decodeBackup(file.path, work.path, progress.sendPort),
          throwsA(isA<NotebookException>()),
        );
        expect(await Directory('${work.path}/audio').exists(), isFalse);
      } finally {
        progress.close();
        await home.delete(recursive: true);
      }
    });
  }
}
