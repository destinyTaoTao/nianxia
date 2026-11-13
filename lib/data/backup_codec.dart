// Backup payloads deliberately contain raw user fields only. Derived caches are
// never decoded here, including when a legacy archive contains damaged caches.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../domain/record.dart';
import 'capture_store.dart';

const backupChunkBytes = 4 * 1024 * 1024;
const backupManifestBytes = 16 * 1024 * 1024;
const backupEntryLimit = 1000000;
const backupAudioBytes = 3844096;
const rawKeys = [
  'id',
  'parentId',
  'body',
  'createdAt',
  'timezone',
  'offsetMinutes',
  'revision',
  'favorite',
  'audio',
  'durationMs',
  'transcript',
  'transcription',
];
final _uuid = RegExp(r'^[a-f0-9-]{36}$');
final _audio = RegExp(r'^[a-f0-9-]{36}\.wav$');
Never invalidBackup() =>
    throw const NotebookException('备份无效、损坏或格式不受支持，原有记录保持不变。');
void checkBackupCancel(String work) {
  if (File(p.join(work, 'cancel')).existsSync()) {
    throw const NotebookException('操作已取消，原有记录保持不变。');
  }
}

Map<String, dynamic> rawJson(Record r) => {
  'id': r.id,
  'parentId': r.parentId,
  'body': r.body,
  'createdAt': r.createdAt.toUtc().toIso8601String(),
  'timezone': r.timezone,
  'offsetMinutes': r.offsetMinutes,
  'revision': r.revision,
  'favorite': r.favorite,
  'audio': r.audio,
  'durationMs': r.durationMs,
  'transcript': r.transcript,
  'transcription': r.transcription,
};
Map<String, dynamic> rawRow(Row r) => {
  'id': r['id'],
  'parentId': r['parent_id'],
  'body': r['body'],
  'createdAt': r['created_at'],
  'timezone': r['timezone'],
  'offsetMinutes': r['offset_minutes'],
  'revision': r['revision'],
  'favorite': r['favorite'] == 1,
  'audio': r['audio'],
  'durationMs': r['duration_ms'],
  'transcript': r['transcript'],
  'transcription': r['transcription'],
};
Record rawRecord(Map<String, dynamic> j) {
  if (j.keys.length != rawKeys.length || !rawKeys.every(j.containsKey)) {
    invalidBackup();
  }
  final r = Record.fromJson({
    ...j,
    'organization': null,
    'organizationRevision': null,
  });
  if (!_uuid.hasMatch(r.id) ||
      (r.parentId != null && !_uuid.hasMatch(r.parentId!)) ||
      r.body.length > 100000 ||
      r.revision < 1 ||
      r.offsetMinutes.abs() > 840 ||
      r.timezone.length > 100 ||
      r.durationMs < 0 ||
      r.durationMs > 120000 ||
      (r.transcript?.length ?? 0) > 100000 ||
      !const [
        'none',
        'pending',
        'running',
        'done',
        'failed',
        'stale',
      ].contains(r.transcription) ||
      (r.audio == null
          ? r.body.trim().isEmpty || r.durationMs != 0
          : !_audio.hasMatch(r.audio!))) {
    invalidBackup();
  }
  return r;
}

String fingerprint(Map<String, dynamic> j, Object? audio) =>
    sha256.convert(utf8.encode(jsonEncode(j) + jsonEncode(audio))).toString();
Future<String> fileHash(File f) async =>
    (await sha256.bind(f.openRead()).first).toString();
Database openIncoming(String work) {
  final db = sqlite3.open(p.join(work, 'incoming.sqlite'));
  // This database contains disposable validated staging data, never originals.
  db.execute('PRAGMA synchronous=OFF');
  db.execute('PRAGMA journal_mode=MEMORY');
  return db;
}

void createIncoming(Database db) {
  db.execute(
    'CREATE TABLE incoming (id TEXT PRIMARY KEY,parent TEXT,json TEXT NOT NULL, fingerprint TEXT NOT NULL, legacy TEXT,audio TEXT UNIQUE, hash TEXT,new_audio TEXT,mapped TEXT,insert_row INTEGER NOT NULL DEFAULT 0)',
  );
  db.execute('CREATE INDEX incoming_parent ON incoming(parent,id)');
}

Iterable<Row> incomingPages(
  Database db, {
  bool rootsOnly = false,
  bool childrenOnly = false,
}) sync* {
  var last = '';
  final clause = rootsOnly
      ? 'AND parent IS NULL'
      : childrenOnly
      ? 'AND parent IS NOT NULL'
      : '';
  while (true) {
    final rows = db.select(
      'SELECT * FROM incoming WHERE id > ? $clause ORDER BY id LIMIT 16',
      [last],
    );
    if (rows.isEmpty) break;
    for (final row in rows) {
      last = row['id'] as String;
      yield row;
    }
  }
}

Future<int> encodeBackup(
  String snapshot,
  String home,
  String work,
  String output,
  SendPort progress,
) async {
  final db = sqlite3.open(snapshot, mode: OpenMode.readOnly);
  final encoder = ZipFileEncoder();
  var opened = false;
  try {
    final count = db.select('SELECT count(*) n FROM records').first['n'] as int;
    final audioCount =
        db
                .select(
                  'SELECT count(*) n FROM records WHERE audio IS NOT NULL',
                )
                .first['n']
            as int;
    // At most one audio and two chunk entries per record. The metadata itself
    // is bounded independently so every successful export is readable by v2.
    if (audioCount + (count + 255) ~/ 256 * 2 + 1 > backupEntryLimit) {
      invalidBackup();
    }
    encoder.create(output, level: ZipFileEncoder.store);
    opened = true;
    final chunks = <Map<String, dynamic>>[];
    var envelopes = <Map<String, dynamic>>[];
    var bytes = 2, done = 0, chunk = 0, descriptorBytes = 1024;
    Future<void> flush() async {
      if (envelopes.isEmpty) return;
      final name = 'chunks/${chunk.toString().padLeft(8, '0')}.json';
      final payload = utf8.encode(jsonEncode(envelopes));
      final text = utf8.encode(
        envelopes
            .map((e) {
              final j = e['record'] as Map;
              return '${j['createdAt']} (${j['timezone']})\n${j['body']}\n${j['parentId'] == null ? '' : '追加到 ${j['parentId']}\n'}';
            })
            .join('\n'),
      );
      if (payload.length > backupChunkBytes || text.length > backupChunkBytes) {
        invalidBackup();
      }
      final textName = 'text/${chunk.toString().padLeft(8, '0')}.txt';
      final descriptor = {
        'path': name,
        'bytes': payload.length,
        'sha256': sha256.convert(payload).toString(),
        'records': envelopes.length,
        'text': {
          'path': textName,
          'bytes': text.length,
          'sha256': sha256.convert(text).toString(),
        },
      };
      descriptorBytes += utf8.encode(jsonEncode(descriptor)).length + 1;
      if (descriptorBytes > backupManifestBytes) invalidBackup();
      chunks.add(descriptor);
      encoder.addArchiveFile(
        ArchiveFile.bytes(name, payload)..compression = CompressionType.none,
      );
      encoder.addArchiveFile(
        ArchiveFile.bytes(textName, text)..compression = CompressionType.none,
      );
      envelopes = [];
      bytes = 2;
      chunk++;
    }

    var last = '';
    while (true) {
      final rows = db.select(
        'SELECT id,parent_id,body,created_at,timezone,offset_minutes,revision,favorite,audio,duration_ms,transcript,transcription FROM records WHERE id > ? ORDER BY id LIMIT 128',
        [last],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        checkBackupCancel(work);
        final j = rawRow(row);
        final r = rawRecord(j);
        last = r.id;
        Map<String, dynamic>? meta;
        if (r.parentId != null &&
            db.select(
              'SELECT id FROM records WHERE id=? AND parent_id IS NULL',
              [r.parentId],
            ).isEmpty) {
          invalidBackup();
        }
        if (r.audio != null) {
          final f = File(p.join(home, 'audio', r.audio!));
          if (await validateWave(f) != r.durationMs) invalidBackup();
          meta = {
            'name': r.audio,
            'bytes': await f.length(),
            'sha256': await fileHash(f),
          };
          await encoder.addFile(f, 'audio/${r.audio}', ZipFileEncoder.store);
        }
        final envelope = {'record': j, 'audio': meta};
        final size = utf8.encode(jsonEncode(envelope)).length + 1;
        if (size + 2 > backupChunkBytes) invalidBackup();
        if (envelopes.length >= 256 || bytes + size > backupChunkBytes) {
          await flush();
        }
        envelopes.add(envelope);
        bytes += size;
        done++;
        if (done % 64 == 0 || done == count) progress.send(done / count);
      }
    }
    await flush();
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'nianxia',
        'version': 2,
        'minimumReader': 2,
        'records': count,
        'audio': audioCount,
        'chunks': chunks,
      }),
    );
    if (manifest.length > backupManifestBytes ||
        chunk * 2 + audioCount + 1 > backupEntryLimit) {
      invalidBackup();
    }
    encoder.addArchiveFile(
      ArchiveFile.bytes('manifest.json', manifest)
        ..compression = CompressionType.none,
    );
    checkBackupCancel(work);
    await encoder.close();
    opened = false;
    return count;
  } finally {
    try {
      if (opened) await encoder.close();
    } finally {
      db.close();
    }
  }
}

Future<int> decodeBackup(String source, String work, SendPort progress) async {
  final input = InputFileStream(source);
  final db = openIncoming(work);
  createIncoming(db);
  try {
    final length = await File(source).length();
    final names = <String>{};
    var total = 0;
    for (final h in ZipDirectory().headers(input, verify: true, files: false)) {
      checkBackupCancel(work);
      final name = h.filename;
      final allowed =
          name == 'manifest.json' ||
          name == 'records.txt' ||
          RegExp(r'^audio/[a-f0-9-]{36}\.wav$').hasMatch(name) ||
          RegExp(r'^(chunks/[0-9]{8}\.json|text/[0-9]{8}\.txt)$')
              .hasMatch(name);
      final limit = name.startsWith('audio/')
          ? backupAudioBytes
          : name == 'manifest.json' || name == 'records.txt'
          ? backupManifestBytes
          : backupChunkBytes;
      total += h.uncompressedSize;
      final mode = (h.externalFileAttributes >> 16) & 0xf000;
      if (names.length >= backupEntryLimit ||
          !names.add(name) ||
          !allowed ||
          h.compressionMethod != 0 ||
          h.compressedSize < 0 ||
          h.uncompressedSize < 0 ||
          h.compressedSize != h.uncompressedSize ||
          h.generalPurposeBitFlag & 1 != 0 ||
          !const [0, 0x8000].contains(mode) ||
          h.uncompressedSize > limit ||
          total > length) {
        invalidBackup();
      }
    }
    if (!names.contains('manifest.json')) invalidBackup();
    var extracted = 0;
    Future<void> extract(ZipFileHeader header) async {
      checkBackupCancel(work);
      final limit = header.filename.startsWith('audio/')
          ? backupAudioBytes
          : header.filename == 'manifest.json' ||
                header.filename == 'records.txt'
          ? backupManifestBytes
          : backupChunkBytes;
      // The user-selected source may be replaced while this multi-pass reader
      // is running. Never grant a later header new names or larger budgets.
      if (!names.contains(header.filename) ||
          header.compressionMethod != 0 ||
          header.uncompressedSize < 0 ||
          header.uncompressedSize > limit ||
          header.compressedSize != header.uncompressedSize) {
        invalidBackup();
      }
      final entry = header.file;
      // Check the local header as well as the central directory. Only STORE
      // payloads are allowed, even if the two headers disagree about encoding.
      if (entry == null ||
          entry.flags & 1 != 0 ||
          entry.compressionMethod != CompressionType.none ||
          entry.unsupportedMethod != null) {
        invalidBackup();
      }
      entry.verify = true;
      entry.throwOnError = true;
      final dest = File(p.join(work, header.filename));
      await dest.parent.create(recursive: true);
      final out = OutputFileStream(dest.path);
      try {
        entry.decompress(out); // Size + CRC checked by the verified reader.
      } finally {
        await out.close();
      }
      if (await dest.length() != header.uncompressedSize) invalidBackup();
      progress.send(++extracted / names.length * 0.4);
    }

    // Keep only one ZIP header alive at a time, never an Archive for the whole
    // notebook. Read the manifest before writing any note or audio payload.
    for (final h in ZipDirectory().headers(input, verify: true)) {
      if (h.filename == 'manifest.json') {
        await extract(h);
        break;
      }
    }
    final manifest = jsonDecode(
      await File(p.join(work, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    if (manifest['format'] != 'nianxia') invalidBackup();
    final version = manifest['version'];
    final expected = <String>{'manifest.json'};
    if (version == 1) {
      if (length > 512 * 1024 * 1024 ||
          manifest['records'] is! List ||
          manifest['audio'] is! Map ||
          (manifest['records'] as List).length > 10000) {
        invalidBackup();
      }
      for (final key in (manifest['audio'] as Map).keys) {
        if (key is! String || !_audio.hasMatch(key)) invalidBackup();
        expected.add('audio/$key');
      }
      if (names.contains('records.txt')) expected.add('records.txt');
    } else if (version == 2) {
      if (manifest['minimumReader'] != 2 ||
          manifest['records'] is! int ||
          manifest['audio'] is! int ||
          manifest['chunks'] is! List) {
        invalidBackup();
      }
      for (final meta in manifest['chunks'] as List) {
        if (meta is! Map || meta['text'] is! Map) invalidBackup();
        final chunk = meta['path'], text = (meta['text'] as Map)['path'];
        if (chunk is! String ||
            text is! String ||
            !RegExp(r'^chunks/[0-9]{8}\.json$').hasMatch(chunk) ||
            !RegExp(r'^text/[0-9]{8}\.txt$').hasMatch(text) ||
            !expected.add(chunk) ||
            !expected.add(text)) {
          invalidBackup();
        }
      }
    } else {
      invalidBackup();
    }
    if (!names.containsAll(expected)) invalidBackup();
    for (final h in ZipDirectory().headers(input, verify: true)) {
      checkBackupCancel(work);
      if (h.filename != 'manifest.json' &&
          !h.filename.startsWith('audio/') &&
          expected.contains(h.filename)) {
        await extract(h);
      }
    }
    if (version == 2) {
      for (final meta in manifest['chunks'] as List) {
        final chunk = File(p.join(work, (meta as Map)['path'] as String));
        if (await chunk.length() != meta['bytes'] ||
            await fileHash(chunk) != meta['sha256']) {
          invalidBackup();
        }
        final rows = jsonDecode(await chunk.readAsString());
        if (rows is! List ||
            rows.isEmpty ||
            rows.length > 256 ||
            rows.length != meta['records']) {
          invalidBackup();
        }
        for (final envelope in rows) {
          if (envelope is! Map || envelope['record'] is! Map<String, dynamic>) {
            invalidBackup();
          }
          final r = rawRecord(envelope['record'] as Map<String, dynamic>);
          if (r.audio != null && !expected.add('audio/${r.audio}')) {
            invalidBackup();
          }
        }
      }
    }
    // Reject unreferenced entries before doing audio I/O. The manifest and
    // bounded record chunks establish exactly which media can be extracted.
    if (names.length != expected.length || !names.containsAll(expected)) {
      invalidBackup();
    }
    for (final h in ZipDirectory().headers(input, verify: true)) {
      checkBackupCancel(work);
      if (h.filename.startsWith('audio/')) await extract(h);
    }
    final referenced = <String>{'manifest.json'};
    var count = 0, audioCount = 0;
    Future<void> add(
      Map<String, dynamic> raw,
      Object? meta, {
      Map<String, dynamic>? legacy,
    }) async {
      checkBackupCancel(work);
      final r = rawRecord(raw);
      String? hash;
      if (r.audio != null) {
        if (meta is! Map ||
            meta['bytes'] is! int ||
            meta['sha256'] is! String ||
            (version == 2 && meta['name'] != r.audio)) {
          invalidBackup();
        }
        final name = 'audio/${r.audio}';
        if (!referenced.add(name) || !names.contains(name)) invalidBackup();
        final f = File(p.join(work, name));
        hash = await fileHash(f);
        if (await f.length() != meta['bytes'] ||
            hash != meta['sha256'] ||
            await validateWave(f) != r.durationMs) {
          invalidBackup();
        }
        audioCount++;
      } else if (meta != null) {
        invalidBackup();
      }
      final v2Meta = meta == null
          ? null
          : {
              'name': r.audio,
              'bytes': (meta as Map)['bytes'],
              'sha256': meta['sha256'],
            };
      db.execute(
        'INSERT INTO incoming(id,parent,json,fingerprint,legacy,audio,hash) VALUES(?,?,?,?,?,?,?)',
        [
          r.id,
          r.parentId,
          jsonEncode(raw),
          fingerprint(raw, v2Meta),
          legacy == null ? null : fingerprint(legacy, meta),
          r.audio,
          hash,
        ],
      );
      count++;
    }

    if (version == 1) {
      if (length > 512 * 1024 * 1024 ||
          manifest['records'] is! List ||
          manifest['audio'] is! Map) {
        invalidBackup();
      }
      final rows = manifest['records'] as List;
      if (rows.length > 10000) invalidBackup();
      for (final value in rows) {
        final legacy = Map<String, dynamic>.from(value as Map);
        final raw = {for (final k in rawKeys) k: legacy[k]};
        await add(
          raw,
          raw['audio'] == null
              ? null
              : (manifest['audio'] as Map)[raw['audio']],
          legacy: legacy,
        );
      }
      if ((manifest['audio'] as Map).length != audioCount) invalidBackup();
      if (names.contains('records.txt')) referenced.add('records.txt');
    } else if (version == 2) {
      if (manifest['minimumReader'] != 2 ||
          manifest['records'] is! int ||
          manifest['audio'] is! int ||
          manifest['chunks'] is! List) {
        invalidBackup();
      }
      for (final value in manifest['chunks'] as List) {
        final meta = Map<String, dynamic>.from(value as Map);
        Future<File> verified(Map meta, RegExp pattern) async {
          final name = meta['path'];
          if (name is! String ||
              !pattern.hasMatch(name) ||
              !referenced.add(name) ||
              !names.contains(name)) {
            invalidBackup();
          }
          final f = File(p.join(work, name));
          if (await f.length() != meta['bytes'] ||
              await fileHash(f) != meta['sha256']) {
            invalidBackup();
          }
          return f;
        }

        final f = await verified(meta, RegExp(r'^chunks/[0-9]{8}\.json$'));
        await verified(meta['text'] as Map, RegExp(r'^text/[0-9]{8}\.txt$'));
        final rows = jsonDecode(await f.readAsString()) as List;
        if (rows.isEmpty ||
            rows.length > 256 ||
            rows.length != meta['records']) {
          invalidBackup();
        }
        for (final value in rows) {
          final e = Map<String, dynamic>.from(value as Map);
          if (e.length != 2) invalidBackup();
          await add(Map<String, dynamic>.from(e['record'] as Map), e['audio']);
        }
      }
      if (count != manifest['records'] || audioCount != manifest['audio']) {
        invalidBackup();
      }
    } else {
      invalidBackup();
    }
    if (referenced.length != names.length || !names.containsAll(referenced)) {
      invalidBackup();
    }
    if (db
        .select(
          'SELECT c.id FROM incoming c LEFT JOIN incoming p ON c.parent=p.id WHERE c.parent IS NOT NULL AND (p.id IS NULL OR p.parent IS NOT NULL) LIMIT 1',
        )
        .isNotEmpty) {
      invalidBackup();
    }
    checkBackupCancel(work);
    return count;
  } finally {
    db.close();
    await input.close();
  }
}

// Top-level isolate entry wrappers capture only sendable scalar arguments.
Future<int> runBackupCodec(List<String> arguments, SendPort progress) =>
    Isolate.run(
      () => arguments.first == 'encode'
          ? encodeBackup(
              arguments[1],
              arguments[2],
              arguments[3],
              arguments[4],
              progress,
            )
          : decodeBackup(arguments[1], arguments[2], progress),
    );
Future<String> hashBackupFile(String path) =>
    Isolate.run(() => fileHash(File(path)));
Future<int> estimateBackupSpace(String snapshot, String home) =>
    Isolate.run(() async {
      final db = sqlite3.open(snapshot, mode: OpenMode.readOnly);
      try {
        var size = await File(snapshot).length() * 8 + 32 * 1024 * 1024;
        var last = '';
        while (true) {
          final rows = db.select(
            'SELECT id,audio FROM records WHERE audio IS NOT NULL AND id>? ORDER BY id LIMIT 128',
            [last],
          );
          if (rows.isEmpty) break;
          for (final row in rows) {
            last = row['id'] as String;
            size += await File(p.join(home, 'audio', row['audio'] as String))
                .length();
          }
        }
        return size;
      } finally {
        db.close();
      }
    });
