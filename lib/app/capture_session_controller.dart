import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/capture_session.dart';
import '../platform/native_capture.dart';
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
    snapshot = value;
    book.captureActive = {
      NativeCapturePhase.starting,
      NativeCapturePhase.recording,
      NativeCapturePhase.finalizing,
    }.contains(value.phase);
    _notify();
  }

  Future<CaptureSnapshot> start({
    required CaptureMode mode,
    String? parentId,
  }) => _serial(() async {
    final current = await port.current();
    if (current != null &&
        {
          NativeCapturePhase.starting,
          NativeCapturePhase.recording,
          NativeCapturePhase.finalizing,
        }.contains(current.phase)) {
      _set(current);
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
    final now = book.clock();
    lastError = null;
    savedId = null;
    final value = await port.start(
      CaptureRequest(
        sessionId: const Uuid().v4(),
        mode: mode,
        createdAtUtc: now.toUtc(),
        timezone: now.timeZoneName,
        offsetMinutes: now.timeZoneOffset.inMinutes,
        parentId: parentId,
      ),
    );
    _set(value);
    return value;
  });
  Future<void> stop() => _serial(() async {
    final old = snapshot ?? await port.current();
    if (old == null) return;
    if (_committed.contains(old.sessionId)) return;
    final done = old.phase == NativeCapturePhase.finalized
        ? old
        : await port.stop(old.sessionId);
    _set(done);
    if (done.request.mode == CaptureMode.record) await _import(done);
  });
  Future<void> _import(CaptureSnapshot value) async {
    if (_committed.contains(value.sessionId)) return;
    final clip = await port.claim(value.sessionId);
    final saved = await book.acceptNativeCapture(clip);
    savedId = saved.id;
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
    if (current != null) _set(current);
    String? after;
    while (true) {
      final pending = await port.pending(after: after);
      for (final value in pending) {
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
  Future<String> finishQuery() => _serial(() async {
    if (!await _queryForeground()) {
      throw const NotebookException('请解锁并返回应用后继续语音查找。');
    }
    final value = snapshot;
    if (value == null ||
        value.request.mode != CaptureMode.query ||
        value.phase != NativeCapturePhase.finalized) {
      throw const NotebookException('查询尚未完成录音。');
    }
    final clip = await port.claim(value.sessionId);
    try {
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
      return await book.transcribeQuery(
        CaptureDraft(
          id: value.sessionId,
          path: file.path,
          createdAt: value.request.createdAtUtc,
          timezone: value.request.timezone,
          offsetMinutes: value.request.offsetMinutes,
          query: true,
        ),
        runtime,
      );
    } finally {
      try {
        await port.acknowledge(
          value.sessionId,
          disposition: CaptureDisposition.queryCompleted,
        );
      } catch (_) {
        book.recoveryWarnings++;
      }
    }
  });
  Future<void> discard() => _serial(() async {
    final value = snapshot;
    if (value == null) return;
    if (await book.get(value.sessionId) != null) {
      throw const NotebookException('录音已经保存，请从记录详情删除。');
    }
    await port.cancel(value.sessionId);
    book.captureActive = false;
    _notify();
  });
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events.cancel());
    unawaited(port.close());
    super.dispose();
  }
}
