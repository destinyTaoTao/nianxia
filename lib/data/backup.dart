import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../app/notebook.dart';
import 'capture_store.dart';

class RestoreReport {
  const RestoreReport(this.added, this.skipped, this.conflicts);
  final int added, skipped, conflicts;
}

class BackupService {
  BackupService(this.book);
  final Notebook book;
  bool cancelled = false;
  static final _busy = Expando<bool>();
  static const maxBytes = 512 * 1024 * 1024;
  static const maxRecords = 10000;
  void _check() {
    if (cancelled) {
      throw const NotebookException('操作已取消，原有记录保持不变。');
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() work) async {
    if (_busy[book] == true) {
      throw const NotebookException('已有备份操作正在执行。');
    }
    _busy[book] = true;
    cancelled = false;
    try {
      return await work();
    } finally {
      _busy[book] = false;
    }
  }

  Future<File> export({
    void Function(double)? progress,
  }) => _exclusive(() async {
    final snapshot = book.records;
    if (snapshot.length > maxRecords) {
      throw const NotebookException('记录超过 10,000 条，当前格式无法生成可恢复的备份。');
    }
    final dir = await Directory(p.join(book.home.path, 'exports'))
        .create(recursive: true);
    final id = const Uuid().v4();
    final partial = File(p.join(dir.path, '$id.partial'));
    final output = File(p.join(dir.path, 'nianxia-$id.zip'));
    final encoder = ZipFileEncoder();
    var opened = false;
    try {
      final audio = <String, Map<String, dynamic>>{};
      var total = 0;
      for (final r in snapshot) {
        if (r.audio != null) {
          _check();
          final f = File(book.audioPath(r));
          final length = await f.length();
          total += length;
          if (total > maxBytes - 16 * 1024 * 1024) {
            throw const NotebookException('备份超过 512 MB，请分批导出或减少内容。');
          }
          audio[r.audio!] = {
            'bytes': length,
            'sha256': (await sha256.bind(f.openRead()).first).toString(),
          };
        }
      }
      final manifest = jsonEncode({
        'format': 'nianxia',
        'version': 1,
        'records': snapshot.map((r) => r.toJson()).toList(),
        'audio': audio,
      });
      if (utf8.encode(manifest).length > 16 * 1024 * 1024) {
        throw const NotebookException('备份元数据超过限制。');
      }
      encoder.create(partial.path, level: ZipFileEncoder.store);
      opened = true;
      encoder.addArchiveFile(
        ArchiveFile.string('manifest.json', manifest)
          ..compression = CompressionType.none,
      );
      // This readable view and all audio are a whitelist, not a directory scan.
      final text = snapshot
          .map(
            (r) =>
                '${r.createdAt.toIso8601String()} (${r.timezone})\n${r.body}\n${r.parentId == null ? '' : '追加到 ${r.parentId}\n'}',
          )
          .join('\n');
      if (utf8.encode(text).length > 16 * 1024 * 1024 ||
          total + utf8.encode(manifest).length + utf8.encode(text).length >
              maxBytes) {
        throw const NotebookException('备份内容超过 512 MB 或文本大小限制，未生成备份。');
      }
      encoder.addArchiveFile(
        ArchiveFile.string('records.txt', text)
          ..compression = CompressionType.none,
      );
      for (var i = 0; i < snapshot.length; i++) {
        _check();
        final r = snapshot[i];
        if (r.audio != null) {
          await encoder.addFile(
            File(book.audioPath(r)),
            'audio/${r.audio}',
            ZipFileEncoder.store,
          );
        }
        progress?.call((i + 1) / snapshot.length);
      }
      _check();
      await encoder.close();
      opened = false;
      _check();
      // Include ZIP headers and the readable text in the restore size boundary.
      if (await partial.length() > maxBytes) {
        throw const NotebookException('完整备份超过 512 MB，未生成备份。');
      }
      _check();
      await partial.rename(output.path);
      return output;
    } finally {
      if (opened) {
        await encoder.close();
      }
      if (await partial.exists()) {
        await partial.delete();
      }
    }
  });
  Future<RestoreReport> restore(
    File source, {
    void Function(double)? progress,
  }) => _exclusive(() async {
    final stage = await Directory(p.join(book.home.path, 'imports'))
        .create(recursive: true);
    final work = await stage.createTemp('restore-');
    final moved = <File>[];
    var committed = false;
    try {
      final sourcePath = source.path;
      final workPath = work.path;
      final manifest = await _extractOffThread(sourcePath, workPath);
      _check();
      final rows = (manifest['records'] as List).cast<Map<String, dynamic>>();
      final hashes = <String, String>{};
      final audioNames = <String, String>{};
      for (var i = 0; i < rows.length; i++) {
        _check();
        final j = rows[i];
        final oldAudio = j['audio'] as String?;
        hashes[j['id'] as String] = sha256
            .convert(
              utf8.encode(
                jsonEncode(j) +
                    jsonEncode(
                      oldAudio == null
                          ? null
                          : (manifest['audio'] as Map)[oldAudio],
                    ),
              ),
            )
            .toString();
        if (oldAudio != null) {
          final name = '${const Uuid().v4()}.wav';
          final dest = File(p.join(book.home.path, 'audio', name));
          await File(p.join(work.path, 'audio', oldAudio)).copy(dest.path);
          moved.add(dest);
          audioNames[j['id'] as String] = name;
        }
        progress?.call((i + 1) / rows.length);
      }
      _check();
      final existingAudioHashes = <String, String>{};
      final candidates = <String>{};
      for (final j in rows) {
        final id = j['id'] as String;
        candidates.add(id);
        final mapped = book.repository.restoredId(hashes[id]!);
        if (mapped != null) {
          candidates.add(mapped);
        }
      }
      for (final id in candidates) {
        final r = book.get(id);
        if (r?.audio == null || existingAudioHashes.containsKey(r!.audio)) {
          continue;
        }
        final file = File(book.audioPath(r));
        if (await file.exists()) {
          existingAudioHashes[r.audio!] =
              (await sha256.bind(file.openRead()).first).toString();
        }
      }
      bool sameContent(
        Record r,
        Map<String, dynamic> incoming,
        String? parent,
      ) {
        if (r.parentId != parent ||
            (r.audio == null) != (incoming['audio'] == null)) {
          return false;
        }
        final local = Map<String, dynamic>.of(r.toJson()),
            remote = Map<String, dynamic>.of(incoming);
        for (final key in [
          'id',
          'parentId',
          'audio',
          'organization',
          'organizationRevision',
          'transcription',
        ]) {
          local.remove(key);
          remote.remove(key);
        }
        if (jsonEncode(local) != jsonEncode(remote)) {
          return false;
        }
        if (r.audio != null) {
          return existingAudioHashes[r.audio!] ==
              ((manifest['audio'] as Map)[incoming['audio']] as Map)['sha256'];
        }
        return true;
      }

      // Hashing existing audio yields to the UI; honor cancellation up to the
      // synchronous transaction boundary, before any records become visible.
      _check();
      final report = book.repository.transaction(() {
        final map = <String, String>{};
        final inserts = <String>{};
        var conflicts = 0;
        var skipped = 0;
        // Roots first, then direct append entries. A child of a conflicting root
        // must be copied even if its own ID/content matches the local child.
        final ordered = [
          ...rows.where((j) => j['parentId'] == null),
          ...rows.where((j) => j['parentId'] != null),
        ];
        for (final j in ordered) {
          final id = j['id'] as String;
          final parent = j['parentId'] as String?;
          final restoredId = book.repository.restoredId(hashes[id]!);
          final restored = restoredId == null ? null : book.get(restoredId);
          final existing = book.get(id);
          final expectedParent = parent == null ? null : map[parent];
          final matching = [
            ?restored,
            ?existing,
          ].where((r) => sameContent(r, j, expectedParent));
          if (matching.isNotEmpty) {
            map[id] = matching.first.id;
            skipped++;
            continue;
          }
          final parentChanged = parent != null && expectedParent != parent;
          final conflict = existing != null || restored != null;
          map[id] = conflict || parentChanged ? const Uuid().v4() : id;
          final contentConflict =
              [
                ?restored,
                ?existing,
              ].any((r) => !sameContent(r, j, r.parentId)) ||
              (!parentChanged &&
                  [
                    ?restored,
                    ?existing,
                  ].any((r) => r.parentId != expectedParent));
          if (contentConflict) {
            conflicts++;
          }
          inserts.add(id);
        }
        for (final j in ordered) {
          final id = j['id'] as String;
          if (inserts.contains(id)) {
            final copy = Map<String, dynamic>.of(j)
              ..['id'] = map[id]
              ..['parentId'] = (j['parentId'] == null
                  ? null
                  : map[j['parentId']])
              ..['audio'] = audioNames[id]
              ..['organization'] = null
              ..['organizationRevision'] = null
              ..['transcription'] =
                  (j['audio'] != null && j['transcript'] == null
                  ? 'pending'
                  : j['audio'] != null
                  ? 'done'
                  : 'none');
            book.repository.insert(Record.fromJson(copy));
          }
          book.repository.markRestored(hashes[id]!, map[id]!);
        }
        return RestoreReport(inserts.length, skipped, conflicts);
      });
      committed = true;
      book.changed();
      return report;
    } on NotebookException {
      rethrow;
    } catch (_) {
      throw const NotebookException('备份无效、损坏或空间不足，未覆盖原有记录。');
    } finally {
      // Copies unused by skipped records are never left as orphan audio.
      final used = book.records.map((r) => r.audio).toSet();
      for (final f in moved) {
        if ((!committed || !used.contains(p.basename(f.path))) &&
            await f.exists()) {
          await f.delete();
        }
      }
      await work.delete(recursive: true);
    }
  });
}

Future<Map<String, dynamic>> _extractBackup(String source, String work) async {
  final file = File(source);
  if (await file.length() > BackupService.maxBytes) {
    throw const NotebookException('备份超过 512 MB。');
  }
  final input = InputFileStream(source);
  try {
    final directory = ZipDirectory();
    final names = <String>{};
    var total = 0;
    for (final h in directory.headers(input, verify: true, files: false)) {
      final name = h.filename;
      if (names.length >= 10002 ||
          !names.add(name) ||
          h.compressionMethod != 0 ||
          h.compressedSize != h.uncompressedSize ||
          h.generalPurposeBitFlag & 1 != 0 ||
          ((h.externalFileAttributes >> 16) & 0xf000) == 0xa000 ||
          !(name == 'manifest.json' ||
              name == 'records.txt' ||
              RegExp(r'^audio/[a-f0-9-]{36}\.wav$').hasMatch(name))) {
        throw const NotebookException('备份格式不受支持或包含不安全条目。');
      }
      total += h.uncompressedSize;
      final limit = name.startsWith('audio/') ? 3844096 : 16 * 1024 * 1024;
      if (h.uncompressedSize > limit || total > BackupService.maxBytes) {
        throw const NotebookException('备份内容超过大小限制。');
      }
    }
    if (!names.contains('manifest.json')) {
      throw const NotebookException('缺少备份清单。');
    }
    final archive = ZipDecoder().decodeStream(input, verify: true);
    for (final entry in archive.files) {
      if (!entry.isFile || entry.isSymbolicLink || entry.isHardLink) {
        throw const NotebookException('备份包含不安全链接。');
      }
      final dest = File(p.join(work, entry.name));
      await dest.parent.create(recursive: true);
      final output = OutputFileStream(dest.path);
      try {
        entry.writeContent(output);
      } finally {
        await output.close();
      }
      if (await dest.length() != entry.size) {
        throw const NotebookException('备份内容不完整。');
      }
    }
    final manifest = jsonDecode(
      await File(p.join(work, 'manifest.json')).readAsString(),
    ) as Map<String, dynamic>;
    if (manifest['format'] != 'nianxia' ||
        manifest['version'] != 1 ||
        manifest['records'] is! List ||
        manifest['audio'] is! Map) {
      throw const NotebookException('备份版本或结构不受支持。');
    }
    final rows = (manifest['records'] as List).cast<Map<String, dynamic>>();
    if (rows.length > BackupService.maxRecords) {
      throw const NotebookException('备份记录过多。');
    }
    final byId = <String, Record>{};
    final referenced = <String>{};
    for (final j in rows) {
      final r = Record.fromJson(j);
      if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(r.id) ||
          byId.containsKey(r.id) ||
          r.body.length > 100000 ||
          r.revision < 1 ||
          r.offsetMinutes.abs() > 840 ||
          r.timezone.length > 100 ||
          r.durationMs < 0 ||
          r.durationMs > 120000 ||
          r.transcript != null && r.transcript!.length > 100000) {
        throw const NotebookException('记录字段无效。');
      }
      if (r.audio != null) {
        if (!RegExp(r'^[a-f0-9-]{36}\.wav$').hasMatch(r.audio!) ||
            !referenced.add(r.audio!)) {
          throw const NotebookException('音频关系无效。');
        }
        final meta = (manifest['audio'] as Map)[r.audio];
        final f = File(p.join(work, 'audio', r.audio!));
        if (meta is! Map ||
            !await f.exists() ||
            await f.length() != meta['bytes'] ||
            (await sha256.bind(f.openRead()).first).toString() !=
                meta['sha256']) {
          throw const NotebookException('音频引用或校验失败。');
        }
        final duration = await validateWave(f);
        if (duration != r.durationMs) {
          throw const NotebookException('音频时长不匹配。');
        }
      } else if (r.body.trim().isEmpty) {
        throw const NotebookException('记录内容为空。');
      }
      byId[r.id] = r;
    }
    for (final r in byId.values) {
      if (r.parentId != null &&
          (byId[r.parentId] == null || byId[r.parentId]!.parentId != null)) {
        throw const NotebookException('追加关系无效。');
      }
    }
    if ((manifest['audio'] as Map).length != referenced.length ||
        names.where((n) => n.startsWith('audio/')).length !=
            referenced.length) {
      throw const NotebookException('备份存在多余或缺失音频。');
    }
    return manifest;
  } finally {
    await input.close();
  }
}

Future<Map<String, dynamic>> _extractOffThread(String source, String work) =>
    Isolate.run(() => _extractBackup(source, work));
