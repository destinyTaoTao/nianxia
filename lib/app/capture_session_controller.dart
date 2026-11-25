import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/capture_session.dart';
import '../domain/diagnostic_event.dart';
import '../platform/native_capture.dart';
import '../platform/playback_coordinator.dart';
import 'inference_runtime.dart';
import 'notebook.dart';

/// Prototype coordinator. The native owner survives this observer's disposal.
class CaptureSessionController extends ChangeNotifier {
  CaptureSessionController(
    this.port,
    this.book,
    this.runtime, {
    Future<bool> Function()? queryForeground,
  }) : _queryForeground = queryForeground ?? _screenAvailable {
    _events = port.events.listen(
      (value) {
        if (_disposed ||
            snapshot?.sessionId != value.sessionId ||
            value.sequence <= (snapshot?.sequence ?? -1)) {
          return;
        }
        _set(value);
        if (value.phase == NativeCapturePhase.failed &&
            value.request.mode == CaptureMode.record) {
          unawaited(
            _serial(() => _retainFailed(value)).catchError((Object _) {
              // A queued event may outlive this observer; native owns the clip.
            }),
          );
        }
        if (value.phase == NativeCapturePhase.finalized &&
            value.request.mode == CaptureMode.record) {
          unawaited(
            _serial(() => _import(value)).catchError((Object _) {
              lastError = '录音已结束，尚未完成保存，请返回应用重试。';
              _notify();
            }),
          );
        }
      },
      onError: (Object _) {
        lastError = '录音状态连接中断，请返回应用核对。';
        _notify();
      },
    );
  }
  final NativeCapturePort port;
  final Notebook book;
  final InferenceRuntime runtime;
  final Future<bool> Function() _queryForeground;
  late final StreamSubscription<CaptureSnapshot> _events;
  CaptureSnapshot? snapshot;
  String? savedId, lastError;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  final Set<String> _committed = {};
  final Set<String> _discardIntents = {};
  String? _diagnosticSession;
  NativeCapturePhase? _diagnosticPhase;
  DiagnosticTraceId? _diagnosticTrace;

  void _recordCapturePhase(
    String sessionId,
    NativeCapturePhase phase,
    int elapsedMs,
  ) {
    final diagnostics = book.diagnostics;
    if (diagnostics == null) return;
    if (_diagnosticSession == sessionId && _diagnosticPhase == phase) return;
    try {
      if (_diagnosticSession != sessionId) {
        _diagnosticTrace = DiagnosticTraceId();
      }
      _diagnosticSession = sessionId;
      _diagnosticPhase = phase;
      diagnostics.record(
        DiagnosticEvent(
          kind: DiagnosticKind.capture,
          phase: switch (phase) {
            NativeCapturePhase.starting => DiagnosticPhase.prepare,
            NativeCapturePhase.recording => DiagnosticPhase.run,
            NativeCapturePhase.cancelled => DiagnosticPhase.cleanup,
            _ => DiagnosticPhase.finalize,
          },
          result: switch (phase) {
            NativeCapturePhase.cancelled => DiagnosticResult.cancelled,
            NativeCapturePhase.failed => DiagnosticResult.failed,
            NativeCapturePhase.finalizing => DiagnosticResult.deferred,
            _ => DiagnosticResult.succeeded,
          },
          errorCode: phase == NativeCapturePhase.failed
              ? DiagnosticErrorCode.unknown
              : DiagnosticErrorCode.none,
          elapsedMs: elapsedMs,
          traceId: _diagnosticTrace,
        ),
      );
    } catch (_) {
      // No native/source identifier, state payload or error message is logged.
    }
  }

  static Future<bool> _screenAvailable() async {
    try {
      return await const MethodChannel('app.nianxia/system')
              .invokeMethod<bool>('recordingScreenAvailable') ==
          true;
    } catch (_) {
      return false;
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      if (_disposed) throw const NotebookException('录音页面已关闭。');
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _set(CaptureSnapshot value) {
    _recordCapturePhase(value.sessionId, value.phase, value.elapsedMs);
    snapshot = value;
    book.captureActive = {
      NativeCapturePhase.starting,
      NativeCapturePhase.recording,
      NativeCapturePhase.finalizing,
    }.contains(value.phase);
    runtime.setCaptureActive(book.captureActive);
    _notify();
  }

  void _clearCurrent() {
    snapshot = null;
    savedId = null;
    book.captureActive = false;
    runtime.setCaptureActive(false);
    _notify();
  }

  Future<void> _retainFailed(CaptureSnapshot value) async {
    try {
      await book.retainFailedNative(value);
      lastError = '录音未能完成，恢复资料已登记，请在待恢复资料中核对。';
    } catch (_) {
      book.recoveryWarnings++;
      lastError = '录音未能完成，且无法登记恢复资料，请保留现场后重试。';
    }
    _notify();
  }

  Future<CaptureSnapshot> start({
    required CaptureMode mode,
    String? parentId,
    bool Function()? startAllowed,
    bool reuseCurrent = true,
  }) => _serial(() async {
    final current = await port.current();
    if (current != null &&
        ({
              NativeCapturePhase.starting,
              NativeCapturePhase.recording,
              NativeCapturePhase.finalizing,
            }.contains(current.phase) ||
            current.request.mode == mode &&
                {
                  NativeCapturePhase.finalized,
                  NativeCapturePhase.failed,
                }.contains(current.phase) &&
                (mode == CaptureMode.query ||
                    await book.get(current.sessionId) == null))) {
      _set(current);
      if (!reuseCurrent) {
        throw const NotebookException('请先处理已有录音，再开始按住说话。');
      }
      return current;
    }
    if (mode == CaptureMode.query &&
        !await runtime.ready(InferenceCapability.speech)) {
      throw const NotebookException('语音模型尚未就绪，请使用文字查找。');
    }
    if (parentId != null) {
      final parent = await book.get(parentId);
      if (parent == null || parent.parentId != null) {
        throw const NotebookException('原记录不可用，请选择原记录追加。');
      }
    }
    void requireStartAllowed() {
      if (startAllowed != null && !startAllowed()) {
        throw const NotebookException('录音页面已离开，未继续启动录音。');
      }
    }

    requireStartAllowed();
    final now = book.clock();
    lastError = null;
    savedId = null;
    final request = CaptureRequest(
      sessionId: const Uuid().v4(),
      mode: mode,
      createdAtUtc: now.toUtc(),
      timezone: now.timeZoneName,
      offsetMinutes: now.timeZoneOffset.inMinutes,
      parentId: parentId,
    );
    late final CaptureSnapshot value;
    var abandonedHandled = false;
    try {
      value = await PlaybackCoordinator.startCapture(book, () {
        requireStartAllowed();
        return port.start(request);
      });
      if (startAllowed != null && !startAllowed()) {
        _set(value);
        if (value.phase == NativeCapturePhase.starting ||
            value.phase == NativeCapturePhase.recording ||
            value.request.mode == CaptureMode.query) {
          await port.cancel(request.sessionId);
          _clearCurrent();
        } else if (value.phase == NativeCapturePhase.finalized &&
            value.request.mode == CaptureMode.record) {
          await _import(value);
        }
        abandonedHandled = true;
        throw const NotebookException('录音页面已离开，未继续启动录音。');
      }
    } catch (error, stack) {
      if (abandonedHandled) Error.throwWithStackTrace(error, stack);
      try {
        final actual = await port.current();
        if (actual?.sessionId == request.sessionId) {
          _set(actual!);
          if (startAllowed != null && !startAllowed()) {
            lastError = '录音页面已离开，结束录音未完成，请返回应用处理当前录音。';
            _notify();
          }
          if ({
            NativeCapturePhase.starting,
            NativeCapturePhase.recording,
            NativeCapturePhase.finalizing,
          }.contains(actual.phase)) {
            if (startAllowed == null || startAllowed()) return actual;
            lastError = '录音页面已离开，结束录音未完成，请返回应用处理当前录音。';
            _notify();
          }
          if (actual.request.mode == CaptureMode.record &&
              actual.phase == NativeCapturePhase.failed) {
            await book.retainFailedNative(actual);
          }
        }
      } catch (_) {
        /* Preserve the original start error and any native state. */
      }
      Error.throwWithStackTrace(error, stack);
    }
    _set(value);
    return value;
  });
  Future<void> stop({String? expectedSessionId}) => _serial(() async {
    final old = snapshot ?? await port.current();
    if (expectedSessionId != null && old?.sessionId != expectedSessionId) {
      throw const NotebookException('录音会话已变化，请返回核对。');
    }
    if (old == null) return;
    if (_committed.contains(old.sessionId)) return;
    final done = old.phase == NativeCapturePhase.finalized
        ? old
        : await port.stop(old.sessionId);
    _set(done);
    if (done.request.mode == CaptureMode.record) await _import(done);
  });
  Future<void> saveStandalone({String? expectedSessionId}) => _serial(() async {
    final value = snapshot;
    if (expectedSessionId != null && value?.sessionId != expectedSessionId) {
      throw const NotebookException('录音会话已变化，请返回核对。');
    }
    if (value == null ||
        value.phase != NativeCapturePhase.finalized ||
        value.request.mode != CaptureMode.record) {
      throw const NotebookException('尚无可保存的录音片段。');
    }
    await _import(value, standalone: true);
  });
  Future<void> _import(CaptureSnapshot value, {bool standalone = false}) async {
    if (_discardIntents.contains(value.sessionId) ||
        await book.nativeCaptureDiscarded(value.sessionId)) {
      if (await book.get(value.sessionId) != null) {
        throw const NotebookException('片段已成为记录，不能继续丢弃。');
      }
      await book.requestNativeDiscard(value.sessionId);
      await port.claim(value.sessionId);
      await port.acknowledge(
        value.sessionId,
        disposition: CaptureDisposition.discardedRecord,
      );
      await book.completeNativeDiscard(value.sessionId);
      _discardIntents.remove(value.sessionId);
      if (snapshot?.sessionId == value.sessionId) _clearCurrent();
      return;
    }
    if (_committed.contains(value.sessionId)) return;
    final clip = await port.claim(value.sessionId);
    final saved = await book.acceptNativeCapture(clip, standalone: standalone);
    if (snapshot?.sessionId == saved.id) savedId = saved.id;
    _committed.add(saved.id);
    if (_committed.length > 32) _committed.remove(_committed.first);
    // SQLite committed. A failed acknowledgement is cleanup debt, not data loss.
    try {
      await port.acknowledge(
        value.sessionId,
        disposition: CaptureDisposition.importedRecord,
      );
    } catch (_) {
      book.recoveryWarnings++;
    }
    _notify();
  }

  Future<void> reconnect() => _serial(() async {
    final current = await port.current();
    if (current != null) {
      _set(current);
    } else {
      _clearCurrent();
    }
    String? discardedAfter;
    while (true) {
      final ids = await book.pendingNativeDiscards(after: discardedAfter);
      for (final id in ids) {
        try {
          if (await book.get(id) != null) {
            throw const NotebookException('片段已成为记录，不能继续丢弃。');
          }
          if (await book.nativeDiscardRequiresCancel(id)) {
            await port.cancel(id);
          } else {
            await port.acknowledge(
              id,
              disposition: CaptureDisposition.discardedRecord,
            );
          }
          await book.completeNativeDiscard(id);
          _discardIntents.remove(id);
          if (snapshot?.sessionId == id) _clearCurrent();
        } catch (_) {
          book.recoveryWarnings++;
          lastError = '部分丢弃片段尚未完成清理，请稍后重试。';
        }
      }
      if (ids.length < 32) break;
      discardedAfter = ids.last;
    }
    String? after;
    while (true) {
      final pending = await port.pending(after: after);
      for (final value in pending) {
        if (value.request.mode == CaptureMode.record &&
            value.phase == NativeCapturePhase.failed) {
          await _retainFailed(value);
        }
        if (value.request.mode == CaptureMode.record &&
            value.phase == NativeCapturePhase.finalized) {
          _committed.remove(value.sessionId);
          try {
            await _import(value);
          } catch (_) {
            // Keep the failing clip/journal for explicit recovery; every other
            // finalized clip still gets its independent import attempt.
            book.recoveryWarnings++;
            lastError = '部分录音尚未完成保存，请核对待恢复资料。';
            _notify();
          }
        }
      }
      if (pending.length < 32) break;
      after = pending.last.sessionId;
    }
  });
  final _queries = <String, Future<String>>{};
  Future<String> finishQuery({String? expectedSessionId}) {
    final id = expectedSessionId ?? snapshot?.sessionId;
    if (id != null && _queries.containsKey(id)) return _queries[id]!;
    if (_queries.length >= 64) {
      return Future.error(const NotebookException('查询任务正在处理中，请稍后重试。'));
    }
    final work = _finishQuery(expectedSessionId: expectedSessionId);
    if (id != null) {
      _queries[id] = work;
      void release() {
        if (identical(_queries[id], work)) _queries.remove(id);
      }

      unawaited(
        work.then<void>(
          (_) => release(),
          onError: (Object _, StackTrace _) => release(),
        ),
      );
    }
    return work;
  }

  Future<String> _finishQuery({String? expectedSessionId}) async {
    String? claimedId;
    try {
      final draft = await _serial(() async {
        if (!await _queryForeground()) {
          throw const NotebookException('请解锁并返回应用后继续语音查找。');
        }
        final value = snapshot;
        if (expectedSessionId != null &&
            value?.sessionId != expectedSessionId) {
          throw const NotebookException('查询会话已变化，请重新发起。');
        }
        if (value == null ||
            value.request.mode != CaptureMode.query ||
            value.phase != NativeCapturePhase.finalized) {
          throw const NotebookException('查询尚未完成录音。');
        }
        final clip = await port.claim(value.sessionId);
        claimedId = value.sessionId;
        if (await book.get(value.sessionId) != null) {
          throw const NotebookException('查询标识与已有记录冲突。');
        }
        final file = File(
          p.join(
            book.home.path,
            'native-captures',
            'queries',
            '${value.sessionId}.wav',
          ),
        );
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await file.resolveSymbolicLinks() !=
                p.join(
                  await book.home.resolveSymbolicLinks(),
                  'native-captures',
                  'queries',
                  '${value.sessionId}.wav',
                ) ||
            await file.length() != 44 + clip.snapshot.pcmBytes) {
          throw const NotebookException('查询音频无效。');
        }

        return CaptureDraft(
          id: value.sessionId,
          path: file.path,
          createdAt: value.request.createdAtUtc,
          timezone: value.request.timezone,
          offsetMinutes: value.request.offsetMinutes,
          query: true,
        );
      });
      // Inference owns no global capture-control lock. A new recording can
      // begin while this already-authorized local query is being recognized.
      if (_disposed) throw const NotebookException('查询已结束。');
      return await book.transcribeQuery(draft, runtime);
    } finally {
      final id = claimedId;
      if (id != null) {
        try {
          await port.acknowledge(
            id,
            disposition: CaptureDisposition.queryCompleted,
          );
        } catch (_) {
          book.recoveryWarnings++;
        }
        if (!_disposed && snapshot?.sessionId == id) _clearCurrent();
      }
    }
  }

  Future<void> discard({String? sessionId}) => _serial(() async {
    final id = sessionId ?? snapshot?.sessionId;
    if (id == null) return;
    validateCaptureId(id);
    if (await book.get(id) != null) {
      throw const NotebookException('录音已经保存，请从记录详情删除。');
    }
    final record =
        snapshot?.sessionId == id &&
        snapshot?.request.mode == CaptureMode.record;
    if (record) {
      _discardIntents.add(id);
      await book.requestNativeDiscard(id);
    }
    await port.cancel(id);
    if (record ||
        _discardIntents.contains(id) ||
        await book.nativeCaptureDiscarded(id)) {
      await book.completeNativeDiscard(id);
      _discardIntents.remove(id);
    }
    _recordCapturePhase(
      id,
      NativeCapturePhase.cancelled,
      snapshot?.elapsedMs ?? 0,
    );
    if (snapshot?.sessionId == id) _clearCurrent();
  });
  Future<void> _closePortAfterQuery() async {
    try {
      await Future.wait(
        _queries.values.toList().map((work) async {
          try {
            await work;
          } catch (_) {}
        }),
      );
    } catch (_) {
      /* Query cleanup still joins before transport closes. */
    }
    await port.close();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events.cancel());
    unawaited(_closePortAfterQuery());
    super.dispose();
  }
}
