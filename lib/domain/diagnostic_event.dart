import 'package:uuid/uuid.dart';

enum DiagnosticKind {
  startup,
  capture,
  sourceWrite,
  transcription,
  embedding,
  search,
  backup,
  restore,
}

enum DiagnosticPhase { prepare, run, finalize, commit, cleanup }

enum DiagnosticResult { succeeded, failed, cancelled, stale, deferred }

enum DiagnosticErrorCode {
  none,
  ioFailure,
  space,
  authentication,
  permission,
  interruption,
  format,
  unavailable,
  timeout,
  closed,
  unknown,
}

class DiagnosticTraceId {
  DiagnosticTraceId() : value = const Uuid().v4();
  DiagnosticTraceId._(this.value);
  final String value;
}

class DiagnosticEvent {
  DiagnosticEvent({
    required this.kind,
    required this.phase,
    required this.result,
    this.errorCode = DiagnosticErrorCode.none,
    int elapsedMs = 0,
    int attempt = 0,
    int? sourceRevision,
    int softwareGeneration = const int.fromEnvironment(
      'FLUTTER_BUILD_NUMBER',
      defaultValue: 1,
    ),
    int modelGeneration = 0,
    DiagnosticTraceId? traceId,
  }) : traceId = traceId ?? DiagnosticTraceId(),
       elapsedMs = elapsedMs.clamp(0, 86400000),
       attempt = attempt.clamp(0, 3),
       sourceRevision =
           sourceRevision != null &&
               sourceRevision > 0 &&
               sourceRevision <= 2147483647
           ? sourceRevision
           : null,
       softwareGeneration = softwareGeneration.clamp(0, 2147483647),
       modelGeneration = modelGeneration.clamp(0, 2147483647);
  final DiagnosticKind kind;
  final DiagnosticPhase phase;
  final DiagnosticResult result;
  final DiagnosticErrorCode errorCode;
  final DiagnosticTraceId traceId;
  final int elapsedMs, attempt, softwareGeneration, modelGeneration;
  final int? sourceRevision;
  Map<String, Object?> toMap(DateTime at) => {
    'version': 1,
    'at': at.toUtc().millisecondsSinceEpoch,
    'kind': kind.name,
    'phase': phase.name,
    'traceId': traceId.value,
    'result': result.name,
    'errorCode': errorCode.name,
    'elapsedMs': elapsedMs,
    'attempt': attempt,
    'sourceRevision': sourceRevision,
    'softwareGeneration': softwareGeneration,
    'modelGeneration': modelGeneration,
  };
}

class DiagnosticEntry {
  DiagnosticEntry(this.at, this.event);
  final DateTime at;
  final DiagnosticEvent event;
  Map<String, Object?> toMap() => event.toMap(at);
  factory DiagnosticEntry.fromMap(Map<String, Object?> data) {
    const keys = {
      'version',
      'at',
      'kind',
      'phase',
      'traceId',
      'result',
      'errorCode',
      'elapsedMs',
      'attempt',
      'sourceRevision',
      'softwareGeneration',
      'modelGeneration',
    };
    if (data.length != keys.length ||
        data.keys.any((k) => !keys.contains(k)) ||
        data['version'] != 1) {
      throw const FormatException('诊断格式无效。');
    }
    T enumValue<T extends Enum>(String key, List<T> values) =>
        values.firstWhere(
          (v) => v.name == data[key],
          orElse: () => throw const FormatException('诊断枚举无效。'),
        );
    int integer(String key, int max) {
      final value = data[key];
      if (value is! int || value < 0 || value > max) {
        throw const FormatException('诊断计数无效。');
      }
      return value;
    }

    final timestamp = data['at'];
    final trace = data['traceId'];
    final revision = data['sourceRevision'];
    if (timestamp is! int ||
        timestamp.abs() > 8640000000000000 ||
        trace is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(trace) ||
        revision != null &&
            (revision is! int || revision < 1 || revision > 2147483647)) {
      throw const FormatException('诊断字段无效。');
    }
    return DiagnosticEntry(
      DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true),
      DiagnosticEvent(
        kind: enumValue('kind', DiagnosticKind.values),
        phase: enumValue('phase', DiagnosticPhase.values),
        result: enumValue('result', DiagnosticResult.values),
        errorCode: enumValue('errorCode', DiagnosticErrorCode.values),
        traceId: DiagnosticTraceId._(trace),
        elapsedMs: integer('elapsedMs', 86400000),
        attempt: integer('attempt', 3),
        sourceRevision: revision as int?,
        softwareGeneration: integer('softwareGeneration', 2147483647),
        modelGeneration: integer('modelGeneration', 2147483647),
      ),
    );
  }
}
