enum CaptureMode { record, query }

enum NativeCapturePhase {
  starting,
  recording,
  finalizing,
  finalized,
  failed,
  cancelled,
}

enum CaptureDisposition { importedRecord, queryCompleted, discardedRecord }

void validateCaptureId(String value) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw ArgumentError('录音会话标识无效。');
  }
}

class CaptureRequest {
  CaptureRequest({
    required this.sessionId,
    required this.mode,
    required this.createdAtUtc,
    required this.timezone,
    required this.offsetMinutes,
    this.parentId,
  }) {
    validateCaptureId(sessionId);
    if (parentId != null) validateCaptureId(parentId!);
    if (!createdAtUtc.isUtc ||
        timezone.isEmpty ||
        timezone.length > 100 ||
        offsetMinutes < -840 ||
        offsetMinutes > 840 ||
        parentId == sessionId ||
        mode == CaptureMode.query && parentId != null) {
      throw ArgumentError('录音会话元数据无效。');
    }
  }

  final String sessionId, timezone;
  final CaptureMode mode;
  final DateTime createdAtUtc;
  final int offsetMinutes;
  final String? parentId;

  Map<String, Object?> toMap() => {
    'wireVersion': 1,
    'sessionId': sessionId,
    'mode': mode.name,
    'createdAt': createdAtUtc.toIso8601String(),
    'timezone': timezone,
    'offsetMinutes': offsetMinutes,
    'parentId': parentId,
  };

  factory CaptureRequest.fromMap(Map<Object?, Object?> value) {
    try {
      if (value['wireVersion'] != 1) throw const FormatException();
      final mode = switch (value['mode']) {
        'record' => CaptureMode.record,
        'query' => CaptureMode.query,
        _ => throw const FormatException(),
      };
      final created = value['createdAt'] as String;
      if (created.length > 64) throw const FormatException();
      return CaptureRequest(
        sessionId: value['sessionId'] as String,
        mode: mode,
        createdAtUtc: DateTime.parse(created),
        timezone: value['timezone'] as String,
        offsetMinutes: value['offsetMinutes'] as int,
        parentId: value['parentId'] as String?,
      );
    } catch (_) {
      throw const FormatException('录音会话格式无法识别。');
    }
  }
}

class CaptureSnapshot {
  CaptureSnapshot._({
    required this.request,
    required this.phase,
    required this.sequence,
    required this.elapsedMs,
    required this.pcmBytes,
    required this.level,
    this.relativeAudioName,
    this.errorCode,
  });

  final CaptureRequest request;
  final NativeCapturePhase phase;
  final int sequence, elapsedMs, pcmBytes;
  final double level;
  final String? relativeAudioName, errorCode;
  String get sessionId => request.sessionId;

  factory CaptureSnapshot.fromMap(Map<Object?, Object?> value) {
    try {
      final request = CaptureRequest.fromMap(value);
      final phase = NativeCapturePhase.values
          .where((phase) => phase.name == value['phase'])
          .firstOrNull;
      final sequence = value['sequence'] as int;
      final elapsed = value['elapsedMs'] as int;
      final bytes = value['pcmBytes'] as int;
      final level = (value['level'] as num? ?? 0).toDouble();
      final name = value['relativeAudioName'] as String?;
      final error = value['errorCode'] as String?;
      if (phase == null ||
          sequence < 0 ||
          elapsed < 0 ||
          elapsed > 120000 ||
          bytes < 0 ||
          bytes > 3840000 ||
          bytes.isOdd ||
          !level.isFinite ||
          level < 0 ||
          level > 1 ||
          name != null && name != '${request.sessionId}.wav' ||
          error != null && !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(error) ||
          phase == NativeCapturePhase.finalized &&
              (bytes == 0 || name == null)) {
        throw const FormatException();
      }
      return CaptureSnapshot._(
        request: request,
        phase: phase,
        sequence: sequence,
        elapsedMs: elapsed,
        pcmBytes: bytes,
        level: level,
        relativeAudioName: name,
        errorCode: error,
      );
    } catch (_) {
      throw const FormatException('录音状态无效。');
    }
  }
}

class FinalizedCapture {
  FinalizedCapture(this.snapshot) {
    if (snapshot.phase != NativeCapturePhase.finalized) {
      throw const FormatException('录音尚未完成收尾。');
    }
  }
  final CaptureSnapshot snapshot;
}
