import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// Replaces only the microphone boundary. PCM saving, ASR and UI stay real.
class FixtureRecordPlatform extends RecordPlatform {
  FixtureRecordPlatform(this.path);
  String path;
  bool delivered = false;
  final _sessions = <String, _Session>{};

  Future<void> drained() async {
    await Future.wait(
      _sessions.values.map((session) => session.disposed.future),
    );
  }

  @override
  Future<void> create(String recorderId) async {
    _sessions[recorderId] = _Session();
  }

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      true;

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) async {
    if (config.encoder != AudioEncoder.pcm16bits ||
        config.sampleRate != 16000 ||
        config.numChannels != 1) {
      throw StateError('Fixture requires 16 kHz mono PCM16');
    }
    final pcm = await readPcmWave(path);
    final session = _sessions[recorderId]!;
    session.recording = true;
    delivered = false;
    var offset = 0;
    session.timer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      final end = math.min(offset + 640, pcm.length);
      session.audio.add(Uint8List.sublistView(pcm, offset, end));
      offset = end;
      if (offset == pcm.length) {
        delivered = true;
        timer.cancel();
        // Keep the microphone open until the user presses Stop.
      }
    });
    return session.audio.stream;
  }

  @override
  Future<String?> stop(String recorderId) async {
    final session = _sessions[recorderId]!;
    session.recording = false;
    session.timer?.cancel();
    await session.audio.close();
    return null;
  }

  @override
  Future<void> cancel(String recorderId) async => stop(recorderId);

  @override
  Future<void> dispose(String recorderId) async {
    final session = _sessions[recorderId]!;
    session.timer?.cancel();
    if (!session.audio.isClosed) await session.audio.close();
    await session.states.close();
    _sessions.remove(recorderId);
    session.disposed.complete();
  }

  @override
  Future<bool> isRecording(String recorderId) async =>
      _sessions[recorderId]?.recording ?? false;

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -20, max: -10);

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      _sessions[recorderId]!.states.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected microphone call: ${invocation.memberName}',
  );
}

class _Session {
  final disposed = Completer<void>();
  final audio = StreamController<Uint8List>();
  final states = StreamController<RecordState>.broadcast();
  bool recording = false;
  Timer? timer;
}

Future<Uint8List> readPcmWave(String path) async {
  final bytes = await File(path).readAsBytes();
  final data = ByteData.sublistView(bytes);
  if (ascii.decode(bytes.sublist(0, 4)) != 'RIFF' ||
      ascii.decode(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('Not a WAV fixture');
  }
  var validFormat = false;
  for (var offset = 12; offset + 8 <= bytes.length;) {
    final chunk = ascii.decode(bytes.sublist(offset, offset + 4));
    final size = data.getUint32(offset + 4, Endian.little);
    final begin = offset + 8;
    if (begin + size > bytes.length) {
      throw const FormatException('Truncated WAV');
    }
    if (chunk == 'fmt ') {
      validFormat =
          data.getUint16(begin, Endian.little) == 1 &&
          data.getUint16(begin + 2, Endian.little) == 1 &&
          data.getUint32(begin + 4, Endian.little) == 16000 &&
          data.getUint16(begin + 14, Endian.little) == 16;
    }
    if (chunk == 'data') {
      if (!validFormat) throw const FormatException('Unsupported WAV fixture');
      return Uint8List.sublistView(bytes, begin, begin + size);
    }
    offset = begin + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('Missing PCM data');
}
