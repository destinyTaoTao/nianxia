import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/diagnostics_store.dart';
import '../domain/diagnostic_event.dart';
import '../domain/backup_operation.dart';
import '../domain/record.dart';

class DiagnosticExportPreview {
  DiagnosticExportPreview({
    required this.entries,
    required this.bytes,
    this.firstAt,
    this.lastAt,
    this.available = true,
    this.dropped = 0,
  });
  final int entries, bytes;
  final int dropped;
  final DateTime? firstAt, lastAt;
  final bool available;
  final List<String> includedFields = const [
    '时间范围',
    '阶段与耗时',
    '结果与安全错误码',
    '随机追踪标识',
    '软件与模型代际',
  ];
}

/// Optional, bounded diagnostics. Enqueue and all failure paths are non-throwing.
class LocalDiagnostics {
  LocalDiagnostics(
    this.directory, {
    DateTime Function()? clock,
    int maxBytes = 5 * 1024 * 1024,
    Duration maxAge = const Duration(days: 7),
  }) : clock = clock ?? DateTime.now,
       _store = DiagnosticsStore(
         directory,
         maxBytes: maxBytes.clamp(2048, 5 * 1024 * 1024),
         maxAge: maxAge > const Duration(days: 7)
             ? const Duration(days: 7)
             : maxAge,
       );
  final Directory directory;
  final DateTime Function() clock;
  final DiagnosticsStore _store;
  final Queue<DiagnosticEntry> _queue = Queue();
  Future<void>? _draining;
  Future<DiagnosticExportPreview>? _previewing;
  Future<File>? _exporting;
  Future<void>? _closing;
  bool _closed = false;
  int _dropped = 0;
  int get pending => _queue.length;
  int get dropped => _dropped;
  void _drop(int count) {
    _dropped = (_dropped + count).clamp(0, 2147483647);
  }

  Future<void> record(DiagnosticEvent event) {
    if (_closed || _queue.length >= 256) {
      _drop(1);
      return Future.value();
    }
    try {
      _queue.add(DiagnosticEntry(clock().toUtc(), event));
      _draining ??= Future.microtask(_drain);
    } catch (_) {
      _drop(1);
    }
    return Future.value();
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty) {
        final batch = <DiagnosticEntry>[];
        while (batch.length < 32 && _queue.isNotEmpty) {
          batch.add(_queue.removeFirst());
        }
        try {
          await _store.append(batch, clock());
        } catch (_) {
          _drop(batch.length);
        }
      }
    } finally {
      _draining = null;
      if (_queue.isNotEmpty) _draining = Future.microtask(_drain);
    }
  }

  Future<void> flush() async {
    while (_draining != null) {
      await _draining;
    }
  }

  Future<DiagnosticExportPreview> previewExport() {
    if (_closed) {
      return Future.value(
        DiagnosticExportPreview(
          entries: 0,
          bytes: 0,
          available: false,
          dropped: dropped,
        ),
      );
    }
    return _previewing ??= _previewExport().whenComplete(
      () => _previewing = null,
    );
  }

  Future<DiagnosticExportPreview> _previewExport() async {
    await flush();
    try {
      final entries = await _store.read(clock());
      final text = _exportText(entries);
      DateTime? firstAt, lastAt;
      for (final entry in entries) {
        if (firstAt == null || entry.at.isBefore(firstAt)) firstAt = entry.at;
        if (lastAt == null || entry.at.isAfter(lastAt)) lastAt = entry.at;
      }
      return DiagnosticExportPreview(
        entries: entries.length,
        bytes: utf8.encode(text).length,
        dropped: dropped,
        firstAt: firstAt,
        lastAt: lastAt,
      );
    } catch (_) {
      return DiagnosticExportPreview(
        entries: 0,
        bytes: 0,
        available: false,
        dropped: dropped,
      );
    }
  }

  String _exportText(List<DiagnosticEntry> entries) =>
      '${jsonEncode({'format': 'nianxia-diagnostics', 'version': 1, 'createdAt': clock().toUtc().millisecondsSinceEpoch, 'dropped': dropped, 'entries': entries.length})}\n${entries.map((e) => jsonEncode(e.toMap())).join('\n')}${entries.isEmpty ? '' : '\n'}';

  Future<File> export() {
    if (_closed) return Future.error(const NotebookException('诊断已关闭。'));
    return _exporting ??= _export().whenComplete(() => _exporting = null);
  }

  Future<File> _export() async {
    await flush();
    File? partial;
    try {
      final entries = await _store.read(clock());
      final output = await Directory(p.join(directory.path, 'exports'))
          .create(recursive: true);
      await _pruneExports(output);
      final file = File(
        p.join(output.path, 'diagnostics-${const Uuid().v4()}.jsonl'),
      );
      partial = File('${file.path}.partial');
      await partial.writeAsString(_exportText(entries), flush: true);
      return await partial.rename(file.path);
    } catch (_) {
      throw const NotebookException('诊断暂不可用，未影响原始资料。');
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (_) {
        /* Managed partial retained for cleanup. */
      }
    }
  }

  Future<void> _pruneExports(Directory output) async {
    final known = <(File, int)>[];
    final now = clock().toUtc().millisecondsSinceEpoch;
    await for (final item in output.list(followLinks: false).take(64)) {
      if (item is! File ||
          !RegExp(r'^diagnostics-[0-9a-f-]{36}\.jsonl$')
              .hasMatch(p.basename(item.path))) {
        continue;
      }
      try {
        final file = await item.open();
        String header;
        try {
          header = utf8
              .decode(await file.read(512), allowMalformed: true)
              .split('\n')
              .first;
        } finally {
          await file.close();
        }
        final value = jsonDecode(header);
        if (value is! Map ||
            value['format'] != 'nianxia-diagnostics' ||
            value['version'] != 1 ||
            value['createdAt'] is! int) {
          continue;
        }
        final created = value['createdAt'] as int;
        if (created > now || now - created > _store.maxAge.inMilliseconds) {
          await item.delete();
        } else {
          known.add((item, created));
        }
      } catch (_) {
        /* Unknown/future files are never copied or removed. */
      }
    }
    known.sort((a, b) => a.$2.compareTo(b.$2));
    for (final old in known.take((known.length - 4).clamp(0, known.length))) {
      try {
        await old.$1.delete();
      } catch (_) {}
    }
  }

  DiagnosticErrorCode _code(Object error) {
    if (error is FileSystemException) return DiagnosticErrorCode.ioFailure;
    if (error is FormatException) return DiagnosticErrorCode.format;
    if (error is TimeoutException) return DiagnosticErrorCode.timeout;
    if (error is BackupCipherFailure) {
      return switch (error.kind) {
        BackupCipherFailureKind.authentication =>
          DiagnosticErrorCode.authentication,
        BackupCipherFailureKind.resourceLimit => DiagnosticErrorCode.space,
        BackupCipherFailureKind.cancelled => DiagnosticErrorCode.closed,
        _ => DiagnosticErrorCode.unknown,
      };
    }
    return DiagnosticErrorCode.unknown;
  }

  Future<T> trace<T>(
    DiagnosticKind kind,
    Future<T> Function() action, {
    DiagnosticPhase phase = DiagnosticPhase.run,
    int? sourceRevision,
    int modelGeneration = 0,
    int attempt = 0,
    DiagnosticResult Function(T)? resultOf,
    DiagnosticResult Function(Object)? failureResultOf,
  }) async {
    final watch = Stopwatch()..start();
    DiagnosticTraceId? trace;
    void emit(
      DiagnosticResult result,
      DiagnosticErrorCode code, {
      DiagnosticResult Function()? classify,
    }) {
      try {
        result = classify?.call() ?? result;
        record(
          DiagnosticEvent(
            kind: kind,
            phase: phase,
            result: result,
            errorCode: result == DiagnosticResult.cancelled
                ? DiagnosticErrorCode.none
                : code,
            elapsedMs: watch.elapsedMilliseconds,
            sourceRevision: sourceRevision,
            modelGeneration: modelGeneration,
            attempt: attempt,
            traceId: trace ??= DiagnosticTraceId(),
          ),
        );
      } catch (_) {
        _drop(1);
      }
    }

    try {
      final result = await action();
      emit(
        DiagnosticResult.succeeded,
        DiagnosticErrorCode.none,
        classify: resultOf == null ? null : () => resultOf(result),
      );
      return result;
    } catch (error) {
      emit(
        DiagnosticResult.failed,
        _code(error),
        classify: failureResultOf == null ? null : () => failureResultOf(error),
      );
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await flush();
    for (final operation in [_previewing, _exporting]) {
      try {
        await operation;
      } catch (_) {
        /* Optional export cannot block source teardown. */
      }
    }
  }
}
