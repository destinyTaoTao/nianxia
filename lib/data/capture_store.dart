import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/record.dart';
import '../domain/capture_session.dart';

class CaptureDraft {
  const CaptureDraft({
    required this.id,
    required this.path,
    required this.createdAt,
    required this.timezone,
    required this.offsetMinutes,
    this.parentId,
    this.query = false,
    this.nativePcmBytes,
  });
  final String id, path, timezone;
  final String? parentId;
  final DateTime createdAt;
  final int offsetMinutes;
  final bool query;
  final int? nativePcmBytes;
  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'timezone': timezone,
    'offsetMinutes': offsetMinutes,
    'parentId': parentId,
    if (nativePcmBytes != null) ...{
      'nativeCaptureVersion': 1,
      'pcmBytes': nativePcmBytes,
    },
  };
}

// The recorder is configured to PCM16 mono/16kHz. Only this explicit format is
// repaired after a crash; arbitrary corrupt audio is never reported as saved.
Future<int> validateWave(File file, {bool repair = false}) async {
  if (!await file.exists()) {
    throw const NotebookException('录音文件不存在，未保存成功。');
  }
  final length = await file.length();
  if (length < 46 || length > 3844096) {
    throw const NotebookException('音频为空、损坏或超过两分钟，原文件保留以供恢复。');
  }
  final f = await file.open(mode: repair ? FileMode.append : FileMode.read);
  try {
    await f.setPosition(0);
    final prefix = await f.read(12);
    String tag(List<int> data) => ascii.decode(data, allowInvalid: true);
    if (tag(prefix.sublist(0, 4)) != 'RIFF' ||
        tag(prefix.sublist(8, 12)) != 'WAVE') {
      throw const NotebookException('录音格式无效，原文件保留。');
    }
    var position = 12;
    bool pcm = false;
    int? dataOffset, dataSize, dataSizeOffset;
    while (position + 8 <= length && position < 4096) {
      await f.setPosition(position);
      final chunk = await f.read(8);
      final name = tag(chunk.sublist(0, 4));
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      if (name == 'fmt ') {
        if (size < 16 || size > 64 || position + 8 + size > length) {
          throw const NotebookException('音频格式块损坏。');
        }
        final fmt = ByteData.sublistView(await f.read(16));
        pcm =
            fmt.getUint16(0, Endian.little) == 1 &&
            fmt.getUint16(2, Endian.little) == 1 &&
            fmt.getUint32(4, Endian.little) == 16000 &&
            fmt.getUint16(12, Endian.little) == 2 &&
            fmt.getUint16(14, Endian.little) == 16;
      }
      if (name == 'data') {
        dataOffset = position + 8;
        dataSize = size;
        dataSizeOffset = position + 4;
        break;
      }
      if (size > 4096 || position + 8 + size > length) {
        throw const NotebookException('音频头损坏，未保存成功。');
      }
      position += 8 + size + (size.isOdd ? 1 : 0);
    }
    if (!pcm || dataOffset == null || dataSize == null) {
      throw const NotebookException('录音格式不受支持，原文件保留。');
    }
    final actual = length - dataOffset;
    if (actual <= 0 || actual.isOdd || actual > 3840000) {
      throw const NotebookException('音频长度无效或超过两分钟。');
    }
    final riffSize = ByteData.sublistView(prefix).getUint32(4, Endian.little);
    if (dataSize != actual || riffSize != length - 8) {
      if (!repair) {
        throw const NotebookException('录音尚未完整关闭，请重试保存。');
      }
      final sizeBytes = ByteData(4)..setUint32(0, length - 8, Endian.little);
      await f.setPosition(4);
      await f.writeFrom(sizeBytes.buffer.asUint8List());
      sizeBytes.setUint32(0, actual, Endian.little);
      await f.setPosition(dataSizeOffset!);
      await f.writeFrom(sizeBytes.buffer.asUint8List());
      await f.flush();
    }
    return actual * 1000 ~/ 32000;
  } finally {
    await f.close();
  }
}

class CaptureStore {
  CaptureStore(this.home);
  final Directory home;
  String audio(String name) => p.join(home.path, 'audio', name);
  File marker(String id) => File(p.join(home.path, 'drafts', '$id.json'));
  CaptureDraft nativeDraft(FinalizedCapture clip) {
    final request = clip.snapshot.request;
    if (request.mode != CaptureMode.record) {
      throw const NotebookException('查询不能保存为记录。');
    }
    return CaptureDraft(
      id: request.sessionId,
      path: p.join(home.path, 'native-captures', '${request.sessionId}.wav'),
      createdAt: request.createdAtUtc,
      timezone: request.timezone,
      offsetMinutes: request.offsetMinutes,
      parentId: request.parentId,
      nativePcmBytes: clip.snapshot.pcmBytes,
    );
  }

  Future<void> persistNative(FinalizedCapture clip) =>
      persist(nativeDraft(clip));
  Future<void> persist(CaptureDraft draft) async {
    if (!draft.query) {
      await marker(draft.id)
          .writeAsString(jsonEncode(draft.toJson()), flush: true);
    }
  }

  Future<void> discard(CaptureDraft draft) async {
    // Tombstone the journal before deleting files, so a failed cleanup cannot
    // cause a discarded recording to be recovered on the next launch.
    if (!draft.query) {
      await marker(draft.id).writeAsString('{"discarded":true}', flush: true);
    }
    for (final path in [
      draft.path,
      if (!draft.query) audio('${draft.id}.wav'),
    ]) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    final journal = marker(draft.id);
    if (!draft.query && await journal.exists()) {
      await journal.delete();
    }
  }
}
