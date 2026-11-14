import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/ports.dart';
import '../domain/local_job.dart';
import 'inference_runtime.dart';
import 'notebook.dart';
import 'diagnostics.dart';
import '../domain/diagnostic_event.dart';

class BackgroundTasks {
  BackgroundTasks(this.book, this.models, {this.diagnostics}) {
    book.addListener(schedule);
    book.captureChanges.addListener(schedule);
    models.addListener(schedule);
    schedule();
  }
  final Notebook book;
  final InferenceRuntime models;
  final LocalDiagnostics? diagnostics;
  bool _running = false, _disposed = false, _again = false;
  Timer? _timer;
  void schedule() {
    if (_disposed || book.isClosed) return;
    if (_running) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), _drain);
  }

  Future<void> _drain() async {
    if (_disposed || _running || book.isClosed) return;
    _running = true;
    _again = false;
    var retry = false;
    final kinds = <JobKind>{};
    try {
      models.setCaptureActive(book.captureActive);
      if (book.captureActive) return;
      final configured = models.searchModelVersion;
      if (configured != null &&
          configured != await book.repository.indexModelVersion) {
        await book.setSearchModelVersion(configured);
      }
      kinds.addAll(<JobKind>{
        if (await models.ready(InferenceCapability.speech))
          JobKind.transcription,
        if (await models.ready(InferenceCapability.semantic)) JobKind.embedding,
      });
      // Yield to foreground between bounded claims. Original commits happen
      // before the sidecar acknowledgement; reconciliation makes that idempotent.
      while (!_disposed &&
          !book.isClosed &&
          !book.captureActive &&
          kinds.isNotEmpty) {
        final job = await book.claimLocalJob(
          kinds: kinds,
          speechModelVersion: models.speechModelVersion ?? 'unversioned',
        );
        if (job == null) {
          final available = await book.repository.localJobsAvailable;
          if (!available && book.backgroundNotice == null) {
            book.setBackgroundNotice('后台处理暂不可用，可在记录详情手动重试，重新打开应用后再检查。');
            try {
              diagnostics?.record(
                DiagnosticEvent(
                  kind: DiagnosticKind.startup,
                  phase: DiagnosticPhase.prepare,
                  result: DiagnosticResult.deferred,
                  errorCode: DiagnosticErrorCode.unavailable,
                ),
              );
            } catch (_) {}
          } else if (available) {
            book.setBackgroundNotice(null);
          }
          retry = true;
          break;
        }
        if (_disposed || book.isClosed) return;
        if (book.captureActive) {
          await book.finishLocalJob(job, outcome: JobOutcome.failedTransient);
          break;
        }
        var outcome = JobOutcome.stale;
        try {
          Future<bool> action() => job.kind == JobKind.transcription
              ? book.transcribe(job.sourceId, _BackgroundTranscriber(models))
              : book.index(job.sourceId, models);
          final accepted =
              await (diagnostics?.trace(
                    job.kind == JobKind.transcription
                        ? DiagnosticKind.transcription
                        : DiagnosticKind.embedding,
                    action,
                    sourceRevision: job.sourceRevision,
                    attempt: job.attempt,
                    modelGeneration: job.modelGeneration == 'unversioned'
                        ? 0
                        : int.parse(
                            sha256
                                .convert(utf8.encode(job.modelGeneration))
                                .toString()
                                .substring(0, 7),
                            radix: 16,
                          ),
                  ) ??
                  action());
          outcome = accepted ? JobOutcome.succeeded : JobOutcome.stale;
        } on NotebookException {
          outcome = JobOutcome.failedPermanent;
        } on FileSystemException {
          outcome = JobOutcome.failedPermanent;
        } catch (_) {
          outcome = JobOutcome.failedTransient;
          retry = true;
        }
        if (!_disposed && !book.isClosed) {
          await book.finishLocalJob(job, outcome: outcome);
        }
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      retry = true;
    } finally {
      _running = false;
      if (!_disposed && !book.isClosed) {
        if (_again) {
          schedule();
        } else if (retry) {
          DateTime? next;
          try {
            next = await book.repository.nextLocalJobAttempt(kinds);
          } catch (_) {}
          if (next != null && !_disposed && !book.isClosed) {
            final delay = next.difference(DateTime.now().toUtc());
            _timer = Timer(
              delay.isNegative ? const Duration(milliseconds: 250) : delay,
              _drain,
            );
          }
        }
      }
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    book.removeListener(schedule);
    book.captureChanges.removeListener(schedule);
    models.removeListener(schedule);
  }
}

class _BackgroundTranscriber implements Transcriber {
  _BackgroundTranscriber(this.models);
  final InferenceRuntime models;
  @override
  Future<String> transcribe(String path) =>
      models.transcribe(path, foreground: false);
}
