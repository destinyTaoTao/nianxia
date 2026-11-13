import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'backup_codec.dart';
import 'capture_store.dart';

Future<int> runReadableExport(List<String> arguments, SendPort progress) =>
    Isolate.run(
      () => encodeReadableExport(
        arguments[1],
        arguments[2],
        arguments[3],
        arguments[4],
        progress,
      ),
    );

/// A human-readable archive, deliberately without a restore manifest or caches.
Future<int> encodeReadableExport(
  String snapshot,
  String home,
  String work,
  String output,
  SendPort progress,
) async {
  final db = sqlite3.open(snapshot, mode: OpenMode.readOnly);
  final encoder = ZipFileEncoder();
  var opened = false, done = 0;
  try {
    encoder.create(output, level: ZipFileEncoder.store);
    opened = true;
    encoder.addArchiveFile(
      ArchiveFile.bytes(
        'README.txt',
        utf8.encode(
          '念匣文本与音频导出（未加密）\n此文件供阅读和播放，不用于完整恢复。\n'
          '记录位于 notes/，音频位于 audio/；追加来源使用原记录标识注明。\n',
        ),
      ),
    );
    final count = db.select('SELECT count(*) n FROM records').first['n'] as int;
    var after = '';
    while (true) {
      checkBackupCancel(work);
      final rows = db.select(
        'SELECT * FROM records WHERE id>? ORDER BY id LIMIT 128',
        [after],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        checkBackupCancel(work);
        final record = rawRecord(rawRow(row));
        after = record.id;
        final text =
            '记录标识：${record.id}\n创建时间（UTC）：${record.createdAt.toIso8601String()}\n'
            '原时区：${record.timezone}（偏移 ${record.offsetMinutes} 分钟）\n'
            '${record.parentId == null ? '' : '追加来源：${record.parentId}\n'}'
            '${record.audio == null ? '' : '音频：../audio/${record.audio}\n'}\n'
            '${record.body}\n${record.transcript == null ? '' : '\n原始转写：\n${record.transcript}\n'}';
        encoder.addArchiveFile(
          ArchiveFile.bytes('notes/${record.id}.txt', utf8.encode(text)),
        );
        if (record.audio != null) {
          final audio = File(p.join(home, 'audio', record.audio!));
          await validateWave(audio);
          await encoder.addFile(
            audio,
            'audio/${record.audio}',
            ZipFileEncoder.store,
          );
        }
        done++;
        progress.send(count == 0 ? 1.0 : done / count);
      }
    }
    checkBackupCancel(work);
    await encoder.close();
    opened = false;
    return done;
  } finally {
    try {
      if (opened) await encoder.close();
    } finally {
      db.close();
    }
  }
}
