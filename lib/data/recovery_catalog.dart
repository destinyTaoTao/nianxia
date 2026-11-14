import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/capture_session.dart';
import '../domain/record.dart';
import '../domain/recovery_entry.dart';
import 'capture_store.dart';

class RecoveryItem {
  RecoveryItem(
    this.entry,
    this.files, {
    this.audio,
    this.draft,
    this.native = false,
    this.nativeFailure = false,
  });
  final RecoveryEntry entry;
  final List<(File, String)> files;
  final File? audio;
  final CaptureDraft? draft;
  final bool native;
  final bool nativeFailure;
}

/// Only known, non-linked descendants are resolved. UI never supplies a path.
class RecoveryCatalog {
  RecoveryCatalog(this.home);
  final Directory home;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );
  static bool validId(String id) =>
      id.length == 38 &&
      (id.startsWith('d:') || id.startsWith('q:')) &&
      _uuid.hasMatch(id.substring(2));
  Future<bool> _safe(String path, FileSystemEntityType type) async {
    if (await FileSystemEntity.type(path, followLinks: false) != type) {
      return false;
    }
    final relative = p.relative(path, from: home.path);
    final root = await home.resolveSymbolicLinks();
    final canonical = type == FileSystemEntityType.directory
        ? await Directory(path).resolveSymbolicLinks()
        : await File(path).resolveSymbolicLinks();
    return canonical == p.join(root, relative);
  }

  Future<RecoveryItem> resolve(String managedId) async {
    if (!validId(managedId)) throw const NotebookException('待恢复资料标识无效。');
    final id = managedId.substring(2);
    final files = <(File, String)>[];
    File? audio;
    CaptureDraft? draft;
    var known = true, native = false, nativeFailure = false;
    var kind = RecoveryKind.quarantinedFile;
    late File anchor;
    if (managedId.startsWith('q:')) {
      final directory = Directory(p.join(home.path, 'quarantine', id));
      if (!await _safe(directory.path, FileSystemEntityType.directory)) {
        throw const NotebookException('待恢复资料不可用。');
      }
      final children = await directory
          .list(followLinks: false)
          .take(2)
          .toList();
      if (children.length != 1 ||
          children.single is! File ||
          !await _safe(children.single.path, FileSystemEntityType.file)) {
        throw const NotebookException('隔离资料格式无法识别，原文件保留。');
      }
      anchor = File(children.single.path);
      audio = anchor;
      files.add((anchor, 'original.bin'));
    } else {
      kind = RecoveryKind.unfinishedCapture;
      anchor = File(p.join(home.path, 'drafts', '$id.json'));
      if (!await _safe(anchor.path, FileSystemEntityType.file)) {
        throw const NotebookException('恢复标记不可用，未删除任何资料。');
      }
      files.add((anchor, 'capture.json'));
      try {
        if (await anchor.length() > 65536) throw const FormatException();
        final j =
            jsonDecode(await anchor.readAsString()) as Map<String, dynamic>;
        if (j['id'] != id ||
            (j.containsKey('nativeCaptureVersion') &&
                j['nativeCaptureVersion'] != 1)) {
          throw const FormatException();
        }
        native = j['nativeCaptureVersion'] == 1;
        nativeFailure = native && j['nativeRecoveryFailed'] == true;
        final request = CaptureRequest(
          sessionId: id,
          mode: CaptureMode.record,
          createdAtUtc: DateTime.parse(j['createdAt'] as String),
          timezone: j['timezone'] as String,
          offsetMinutes: j['offsetMinutes'] as int,
          parentId: j['parentId'] as String?,
        );
        final bytes = native ? j['pcmBytes'] as int : null;
        if (bytes != null &&
            (bytes < 0 ||
                bytes == 0 && !nativeFailure ||
                bytes > 3840000 ||
                bytes.isOdd)) {
          throw const FormatException();
        }
        final primary = p.join(
          home.path,
          native ? 'native-captures' : 'drafts',
          '$id.wav',
        );
        final secondary = p.join(home.path, 'audio', '$id.wav');
        for (final path in [primary, secondary]) {
          if (await _safe(path, FileSystemEntityType.file)) {
            audio = File(path);
            files.add((
              audio,
              files.any((v) => v.$2 == 'audio.wav')
                  ? 'audio-copy.wav'
                  : 'audio.wav',
            ));
          }
        }
        draft = CaptureDraft(
          id: id,
          path: primary,
          createdAt: request.createdAtUtc,
          timezone: request.timezone,
          offsetMinutes: request.offsetMinutes,
          parentId: request.parentId,
          nativePcmBytes: bytes,
        );
      } catch (_) {
        known = false;
        kind = RecoveryKind.unrecognizedJournal;
      }
    }
    int? duration;
    if (audio != null) {
      try {
        duration = await validateWave(audio);
      } catch (_) {}
    }
    if (managedId.startsWith('q:') && duration != null) {
      files[0] = (anchor, 'audio.wav');
    }
    var size = 0;
    for (final f in files) {
      size += await f.$1.length();
    }
    final modified = (await anchor.stat()).modified.toUtc();
    final entry = RecoveryEntry(
      id: managedId,
      kind: kind,
      modifiedAt: modified,
      bytes: size,
      durationMs: duration,
      problem: !known
          ? RecoveryProblem.unknownFormat
          : audio == null
          ? RecoveryProblem.missingAudio
          : duration == null
          ? RecoveryProblem.invalidAudio
          : RecoveryProblem.interrupted,
      canDiscard: known,
    );
    return RecoveryItem(
      entry,
      files,
      audio: audio,
      draft: draft,
      native: native,
      nativeFailure: nativeFailure,
    );
  }

  Future<RecoveryPage> page({String? after, int limit = 40}) async {
    if (limit < 1 || limit > 40 || after != null && !validId(after)) {
      throw const NotebookException('恢复列表参数无效。');
    }
    final selected = SplayTreeSet<String>();
    for (final (name, prefix) in [('drafts', 'd:'), ('quarantine', 'q:')]) {
      final dir = Directory(p.join(home.path, name));
      if (!await _safe(dir.path, FileSystemEntityType.directory)) continue;
      await for (final entity in dir.list(followLinks: false)) {
        final base = p.basename(entity.path);
        final candidate =
            prefix +
            (prefix == 'd:' && base.endsWith('.json')
                ? base.substring(0, base.length - 5)
                : base);
        if (!validId(candidate) ||
            after != null && candidate.compareTo(after) <= 0 ||
            prefix == 'd:' && entity is! File ||
            prefix == 'q:' && entity is! Directory) {
          continue;
        }
        selected.add(candidate);
        if (selected.length > limit + 1) selected.remove(selected.last);
      }
    }
    final entries = <RecoveryEntry>[];
    for (final id in selected.take(limit)) {
      try {
        final item = await resolve(id);
        final flag = File(
          p.join(home.path, 'drafts', '${id.substring(2)}.discard'),
        );
        if (item.native &&
            item.audio == null &&
            await _safe(flag.path, FileSystemEntityType.file) &&
            await flag.length() == 2 &&
            await flag.readAsString() == 'v1') {
          continue;
        }
        entries.add(item.entry);
      } catch (_) {}
    }
    return RecoveryPage(
      entries,
      next: selected.length > limit ? selected.elementAt(limit - 1) : null,
    );
  }

  Future<File> export(RecoveryItem item, {bool audioOnly = false}) async {
    final root = await Directory(p.join(home.path, 'exports'))
        .create(recursive: true);
    if (!await _safe(root.path, FileSystemEntityType.directory)) {
      throw const NotebookException('导出目录不可用。');
    }
    final tag = const Uuid().v4();
    if (audioOnly) {
      if (!item.entry.canPlay || item.audio == null) {
        throw const NotebookException('此片段暂不能播放，可导出原始文件。');
      }
      return item.audio!.copy(p.join(root.path, 'recovery-$tag.wav'));
    }
    final output = p.join(root.path, 'recovery-$tag.zip');
    try {
      await _exportBundle(
        item.files.map((f) => (f.$1.path, f.$2)).toList(),
        output,
        {
          'version': 1,
          'id': item.entry.id,
          'kind': item.entry.kind.name,
          'modifiedAt': item.entry.modifiedAt.toIso8601String(),
        },
      );
      return File(output);
    } catch (_) {
      final file = File(output);
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }
}

Future<void> _exportBundle(
  List<(String, String)> files,
  String output,
  Map<String, Object> metadata,
) => Isolate.run(() async {
  final encoder = ZipFileEncoder();
  var open = false;
  try {
    encoder.create(output, level: ZipFileEncoder.store);
    open = true;
    encoder.addArchiveFile(
      ArchiveFile.bytes(
        'README.txt',
        utf8.encode('待恢复原始资料导出（未加密）\n此文件用于保留原始字节，不是完整备份。\n'),
      ),
    );
    encoder.addArchiveFile(
      ArchiveFile.bytes('recovery.json', utf8.encode(jsonEncode(metadata))),
    );
    for (final f in files) {
      await encoder.addFile(File(f.$1), f.$2, ZipFileEncoder.store);
    }
    await encoder.close();
    open = false;
  } finally {
    if (open) await encoder.close();
  }
});
