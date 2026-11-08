import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// A sample-count boundary, independent of wall-clock timer or device stop
// latency. The UI announces the two-minute cap before capture starts.
class PcmWaveWriter {
  PcmWaveWriter._(this.file, {required this.onLimit, required this.onFailure});
  static const maxDataBytes = 16000 * 2 * 120;
  final RandomAccessFile file;
  final void Function() onLimit, onFailure;
  Future<void> _writes = Future.value();
  int _bytes = 0;
  bool _closed = false;
  Object? _failure;
  static Future<PcmWaveWriter> open(
    String path, {
    required void Function() onLimit,
    required void Function() onFailure,
  }) async {
    final file = await File(path).open(mode: FileMode.write);
    final writer = PcmWaveWriter._(
      file,
      onLimit: onLimit,
      onFailure: onFailure,
    );
    await file.writeFrom(_header(0));
    await file.flush();
    return writer;
  }

  static Uint8List _header(int bytes) {
    final b = ByteData(44);
    void tag(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        b.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    b.setUint32(4, 36 + bytes, Endian.little);
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
    b.setUint32(40, bytes, Endian.little);
    return b.buffer.asUint8List();
  }

  void add(Uint8List chunk) {
    if (_closed || _failure != null || _bytes >= maxDataBytes) {
      return;
    }
    final available = maxDataBytes - _bytes;
    final count = chunk.length < available ? chunk.length : available;
    // PCM16 device chunks must be whole samples. Never join a dangling byte
    // onto the next chunk and silently reinterpret corrupted PCM.
    if (count.isOdd) {
      _failure = const FileSystemException('Incomplete PCM sample');
      onFailure();
      return;
    }
    final data = Uint8List.fromList(chunk.sublist(0, count));
    _bytes += count;
    _writes = _writes
        .then((_) async {
          await file.writeFrom(data);
        })
        .catchError((Object error) {
          _failure = error;
          onFailure();
        });
    if (_bytes == maxDataBytes) {
      onLimit();
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    try {
      await _writes;
      if (_failure != null) {
        throw _failure!;
      }
      await file.setPosition(0);
      await file.writeFrom(_header(_bytes));
      await file.flush();
    } finally {
      await file.close();
    }
  }
}
