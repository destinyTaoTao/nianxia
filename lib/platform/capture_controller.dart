import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:record/record.dart';

import '../app/notebook.dart';
import '../domain/diagnostic_event.dart';
import '../data/pcm_wave_writer.dart';
import 'local_models.dart';
import 'playback_coordinator.dart';
import 'capture_device_fence.dart';

abstract interface class MicrophoneInput {
  Future<bool> allowed();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
  Future<void> cancel();
  Future<void> close();
  Stream<double> get levels;
  Stream<void> get interruptions;
}

class DeviceMicrophone implements MicrophoneInput {
  AudioRecorder? _recorder;
  AudioRecorder get recorder => _recorder ??= AudioRecorder();
  @override
  Future<bool> allowed() => recorder.hasPermission();
  @override
  Future<Stream<Uint8List>> start() => recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      audioInterruption: AudioInterruptionMode.pause,
    ),
  );
  @override
  Future<void> stop() async {
    await _recorder?.stop();
  }

  @override
  Future<void> cancel() async {
    // The pinned platform_interface 2.1.0 cancel() drops its native Future.
    // Streaming owns no plugin file: stop acknowledges device release, while
    // Notebook remains responsible for discarding our private PCM/WAV.
    await _recorder?.stop();
  }

  @override
  Future<void> close() async => _recorder?.dispose();
  @override
  Stream<double> get levels => recorder
      .onAmplitudeChanged(const Duration(milliseconds: 150))
      .map((v) => ((v.current + 60) / 60).clamp(0, 1));
  @override
  Stream<void> get interruptions => recorder
      .onStateChanged()
      .where((v) => v != RecordState.record)
      .map((_) {});
}

enum _DeviceStop { stopped, recovered, unconfirmed }

class CaptureController extends ChangeNotifier with WidgetsBindingObserver {
  CaptureController(
    this.book, {
    this.models,
    this.query = false,
    this.parentId,
    MicrophoneInput? microphone,
  }) : microphone = microphone ?? DeviceMicrophone() {
    WidgetsBinding.instance.addObserver(this);
    _screenOff.addListener(_onScreenOff);
  }
  static final _screenOff = ChangeNotifier();

  /// Entry point for the protected Android screen-off broadcast.
  static void screenTurnedOff() => _screenOff.notifyListeners();
  final Notebook book;
  final LocalModels? models;
  final bool query;
  final String? parentId;
  final MicrophoneInput microphone;
  final Stopwatch _watch = Stopwatch();
  CaptureDraft? draft;
  Record? saved;
  String? queryText, error;
  String state = 'starting';
  double amplitude = 0;
  Timer? _timer;
  PcmWaveWriter? _writer;
  Future<void>? _closingWriter;
  StreamSubscription<double>? _amplitude;
  StreamSubscription<void>? _states;
  StreamSubscription<Uint8List>? _pcm;
  bool _disposed = false;
  bool _startInterrupted = false;
  Future<void>? _starting;
  Future<void>? _finishing;
  Future<void>? _discarding;
  Future<_DeviceStop>? _stoppingDevice;
  bool _deviceMayBeActive = false, _deviceClosed = false;
  bool _ownsCaptureLease = false;
  DiagnosticTraceId? _diagnosticTrace;
  bool _queryCleanupFailed = false;

  void _recordOutcome(
    DiagnosticPhase phase,
    DiagnosticResult result,
    Stopwatch watch, {
    DiagnosticErrorCode code = DiagnosticErrorCode.none,
  }) {
    final diagnostics = book.diagnostics;
    if (diagnostics == null) return;
    try {
      diagnostics.record(
        DiagnosticEvent(
          kind: DiagnosticKind.capture,
          phase: phase,
          result: result,
          errorCode: result == DiagnosticResult.cancelled
              ? DiagnosticErrorCode.none
              : code,
          elapsedMs: watch.elapsedMilliseconds,
          traceId: _diagnosticTrace ??= DiagnosticTraceId(),
        ),
      );
    } catch (_) {
      // Optional instrumentation cannot affect device release or source saves.
    }
  }

  void _recordTerminal(Stopwatch watch) {
    _recordOutcome(
      DiagnosticPhase.finalize,
      state == 'done' ? DiagnosticResult.succeeded : DiagnosticResult.failed,
      watch,
      code: state == 'done'
          ? DiagnosticErrorCode.none
          : _deviceMayBeActive
          ? DiagnosticErrorCode.interruption
          : _queryCleanupFailed
          ? DiagnosticErrorCode.ioFailure
          : DiagnosticErrorCode.unknown,
    );
  }

  Future<_DeviceStop> _stopDevice() {
    if (!_deviceMayBeActive) return Future.value(_DeviceStop.stopped);
    return _stoppingDevice ??= _tryStopDevice().whenComplete(
      () => _stoppingDevice = null,
    );
  }

  Future<_DeviceStop> _tryStopDevice() async {
    var attempt = 0;
    for (final action in [
      microphone.stop,
      microphone.cancel,
      microphone.close,
    ]) {
      try {
        await action();
        if (attempt == 2) _deviceClosed = true;
        _deviceMayBeActive = false;
        CaptureDeviceFence.released(this);
        return attempt == 0 ? _DeviceStop.stopped : _DeviceStop.recovered;
      } catch (_) {
        // A failed/late method call is not acknowledgement of device release.
      }
      attempt++;
    }
    return _DeviceStop.unconfirmed;
  }

  static const _stopUnconfirmed = '麦克风尚未确认停止，请重试停止或退出应用后重试。';

  Future<_DeviceStop> _requireStopped() async {
    final result = await _stopDevice();
    if (result == _DeviceStop.unconfirmed) {
      throw const NotebookException(_stopUnconfirmed);
    }
    return result;
  }

  void _releaseLeaseIfStopped() {
    if (!_deviceMayBeActive && _ownsCaptureLease) {
      _ownsCaptureLease = false;
      book.captureActive = false;
      models?.setCaptureActive(false);
    }
  }

  Future<void> _retryDeviceRelease() async {
    if (!_deviceMayBeActive) return;
    if (!_disposed && active) {
      throw const NotebookException('另一段录音尚未结束，请先处理当前录音。');
    }
    await _requireStopped();
    _releaseLeaseIfStopped();
  }

  bool get active =>
      state == 'recording' || state == 'starting' || state == 'saving';
  int get elapsed => _watch.elapsedMilliseconds.clamp(0, 120000);
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _closeWriter() {
    if (_closingWriter != null) return _closingWriter!;
    final writer = _writer;
    _writer = null;
    if (writer == null) return Future.value();
    return _closingWriter = writer.close().whenComplete(
      () => _closingWriter = null,
    );
  }

  Future<void> _cleanQuery() async {
    try {
      if (query && draft != null) {
        final file = File(draft!.path);
        if (await file.exists()) await file.delete();
      }
    } on FileSystemException {
      _queryCleanupFailed = true;
      queryText = null;
      state = 'failed';
      error = _deviceMayBeActive
          ? '$_stopUnconfirmed 临时查询资料也未清理，请保留现场后重试。'
          : '语音查询临时资料清理未完成，可改用文字，重新打开应用后将重试清理。';
    }
  }

  Future<void> start() {
    if (_disposed || state != 'starting') return _starting ?? Future.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final watch = Stopwatch()..start();
    try {
      if (book.captureActive && CaptureDeviceFence.canRetryRelease) {
        await CaptureDeviceFence.beforeStart();
        _ensureStartAllowed();
      }
      if (book.captureActive) {
        throw const NotebookException('另一段录音尚未结束，请先处理当前录音。');
      }
      _ownsCaptureLease = true;
      book.captureActive = true;
      if (!await _recordingScreenAvailable()) {
        throw const NotebookException('请先解锁并保持屏幕亮起，再开始录音。');
      }
      _ensureStartAllowed();
      if (query &&
          (models == null || !await models!.store.ready('sensevoice'))) {
        throw const NotebookException('语音模型未就绪，请先输入文字查找，或在设置下载模型。');
      }
      if (!await microphone.allowed()) {
        throw const NotebookException('没有麦克风权限。可改用文字，或到系统设置允许麦克风。');
      }
      _ensureStartAllowed();
      final stream = await PlaybackCoordinator.startCapture(book, () async {
        _ensureStartAllowed();
        draft = await book.beginCapture(parentId: parentId, query: query);
        _ensureStartAllowed();
        models?.setCaptureActive(true);
        _writer = await PcmWaveWriter.open(
          draft!.path,
          onLimit: () {
            if (!_disposed && state == 'recording') {
              finish();
            }
          },
          onFailure: () {
            if (!_disposed && state == 'recording') {
              finish();
            }
          },
        );
        _ensureStartAllowed();
        CaptureDeviceFence.hold(
          this,
          _retryDeviceRelease,
          canRetry: () => _disposed || !active,
        );
        _deviceMayBeActive = true;
        return microphone.start();
      });
      _ensureStartAllowed();
      state = 'recording';
      _watch.start();
      _pcm = stream.listen(
        (bytes) => _writer?.add(bytes),
        onError: (_) {
          if (!_disposed) finish();
        },
        onDone: () {
          if (!_disposed && state == 'recording') {
            finish();
          }
        },
      );
      _amplitude = microphone.levels.listen(
        (value) {
          amplitude = value;
          _notify();
        },
        onError: (_) {
          amplitude = 0;
          _notify();
        },
      );
      _states = microphone.interruptions.listen(
        (_) {
          if (state == 'recording') finish();
        },
        onError: (Object _, StackTrace _) {
          if (state == 'recording') finish();
        },
      );
      _recordOutcome(
        DiagnosticPhase.prepare,
        DiagnosticResult.succeeded,
        watch,
      );
      // Wall-clock fallback for interruptions and no-data device failures. The
      // sample writer independently enforces the exact persisted two-minute cap.
      _timer = Timer.periodic(const Duration(milliseconds: 150), (_) {
        if (elapsed >= 120000) {
          finish();
        } else {
          _notify();
        }
      });
      _notify();
    } catch (e) {
      final stopped = await _stopDevice();
      try {
        await _closeWriter();
      } catch (_) {}
      if (state != 'discarding' && state != 'cancelled') {
        state = 'failed';
        error = stopped == _DeviceStop.unconfirmed
            ? _stopUnconfirmed
            : e is NotebookException
            ? e.message
            : '无法开始录音，请检查麦克风权限和剩余空间。';
      }
      await _cleanQuery();
      _releaseLeaseIfStopped();
      _recordOutcome(
        DiagnosticPhase.prepare,
        !_deviceMayBeActive && (_startInterrupted || _disposed)
            ? DiagnosticResult.cancelled
            : DiagnosticResult.failed,
        watch,
        code: _deviceMayBeActive
            ? DiagnosticErrorCode.interruption
            : DiagnosticErrorCode.unavailable,
      );
      _notify();
    }
  }

  void _ensureStartAllowed() {
    if (_disposed || _startInterrupted || state != 'starting') {
      throw const NotebookException('录音启动被中断，未继续采集。请返回后重新呼出，或改用文字。');
    }
  }

  Future<void> finish() => _finishing ??= _finish();

  Future<void> _finish() async {
    if (_disposed) return;
    if (state == 'starting') {
      await discard();
      return;
    }
    if (state != 'recording') {
      return;
    }
    final watch = Stopwatch()..start();
    state = 'saving';
    _watch.stop();
    _timer?.cancel();
    _notify();
    try {
      final stop = await _requireStopped();
      if (stop == _DeviceStop.recovered) {
        throw const NotebookException('停止录音时发生错误，有效片段可恢复。');
      }
      await _pcm?.cancel();
      await _closeWriter();
      models?.setCaptureActive(false);
      if (query) {
        queryText = await book.transcribeQuery(draft!, models!);
        if (queryText!.trim().isEmpty) {
          throw const NotebookException('没有识别到查询，请改用文字。');
        }
      } else {
        saved = await book.finishCapture(draft!);
      }
      state = 'done';
    } catch (e) {
      await _pcm?.cancel();
      try {
        await _closeWriter();
      } catch (_) {}
      state = 'failed';
      error = e is NotebookException
          ? e.message
          : '录音保存或转写失败。有效录音片段会在下次启动检查恢复。';
      if (!query &&
          draft != null &&
          !book.recoveryDrafts.any((d) => d.id == draft!.id)) {
        book.recoveryDrafts.add(draft!);
        book.changed();
      }
    } finally {
      // Stop failure happens before transcribeQuery; cleanup must cover that
      // path too. Closing the writer first keeps no live handle on query audio.
      if (query) {
        try {
          await _pcm?.cancel();
          await _closeWriter();
        } catch (_) {}
        await _cleanQuery();
      }
      _releaseLeaseIfStopped();
      _recordTerminal(watch);
      _notify();
    }
  }

  Future<void> retry({bool standalone = false}) async {
    if (_disposed || state != 'failed' || draft == null || query) {
      return;
    }
    final watch = Stopwatch()..start();
    state = 'saving';
    _notify();
    try {
      await _requireStopped();
      await _pcm?.cancel();
      await _closeWriter();
      saved = await book.finishCapture(
        draft!,
        recovering: true,
        standalone: standalone,
      );
      state = 'done';
      error = null;
    } catch (e) {
      state = 'failed';
      error = e is NotebookException ? e.message : '仍无法保存，请检查剩余空间。';
    } finally {
      _releaseLeaseIfStopped();
      _recordTerminal(watch);
      _notify();
    }
  }

  Future<void> discard() async {
    if (_discarding != null) return _discarding;
    final work = _discard();
    _discarding = work;
    try {
      await work;
    } finally {
      _discarding = null;
    }
  }

  Future<void> _discard() async {
    if (state == 'saving' || state == 'done' || state == 'cancelled') {
      return;
    }
    final watch = Stopwatch()..start();
    _startInterrupted = true;
    state = 'discarding';
    _timer?.cancel();
    _watch.stop();
    _notify();
    try {
      await _starting;
      await _requireStopped();
      if (draft != null && !query) {
        await book.captures
            .marker(draft!.id)
            .writeAsString('{"discarded":true}', flush: true);
      }
      await _pcm?.cancel();
      try {
        await _closeWriter();
      } catch (_) {}
      if (draft != null) {
        await book.cancelCapture(draft!);
      }
      state = 'cancelled';
    } catch (_) {
      state = 'failed';
      error = _deviceMayBeActive ? _stopUnconfirmed : '丢弃未完成，请重试。';
    } finally {
      _releaseLeaseIfStopped();
      _recordOutcome(
        DiagnosticPhase.cleanup,
        state == 'cancelled'
            ? DiagnosticResult.cancelled
            : DiagnosticResult.failed,
        watch,
        code: state == 'cancelled'
            ? DiagnosticErrorCode.none
            : DiagnosticErrorCode.unknown,
      );
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (this.state == 'starting' &&
        (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached)) {
      // Permission prompts may briefly be inactive; a genuinely backgrounded
      // launch must never resume microphone startup after its future completes.
      _startInterrupted = true;
    }
    // Android re-delivering an intent and system prompts can be inactive while
    // still visible. Native audio interruptions handle actual focus loss;
    // stop when the application becomes hidden rather than on that transition.
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        this.state == 'recording') {
      finish();
    }
  }

  Future<bool> _recordingScreenAvailable() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      final available = await const MethodChannel('app.nianxia/system')
          .invokeMethod<bool>('recordingScreenAvailable')
          .timeout(const Duration(milliseconds: 500));
      if (available == null) {
        throw const FormatException('Missing screen state');
      }
      return available;
    } catch (_) {
      throw const NotebookException('无法核验屏幕状态，请重新打开录音。');
    }
  }

  void _onScreenOff() {
    if (_disposed) return;
    if (state == 'starting') _startInterrupted = true;
    if (state == 'recording') unawaited(finish());
  }

  Future<void> _release() async {
    // Stop is requested before unsubscribing: some adapters need that request
    // to acknowledge stream cancellation. Neither depends on the other's reply.
    final stopping = _stopDevice();
    try {
      await _pcm?.cancel();
    } catch (_) {
      // Device acknowledgement and the private writer still need cleanup.
    }
    try {
      await _closeWriter();
    } catch (_) {
      // Retain the source/recovery state even when finalizing the file fails.
    }
    try {
      await stopping;
      await _starting;
      await _finishing;
      await _discarding;
    } catch (_) {
      // Disposal still has to confirm the physical device after an operation fails.
    }
    try {
      await _requireStopped();
      await _pcm?.cancel();
      if (!_deviceClosed) {
        await microphone.close();
        _deviceClosed = true;
      }
      await _closeWriter();
    } catch (_) {
    } finally {
      await _cleanQuery();
      _releaseLeaseIfStopped();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _screenOff.removeListener(_onScreenOff);
    _timer?.cancel();
    for (final cancel in [_amplitude?.cancel, _states?.cancel]) {
      if (cancel == null) continue;
      final watch = Stopwatch()..start();
      unawaited(
        Future<void>.sync(cancel).catchError((Object _) {
          _recordOutcome(
            DiagnosticPhase.cleanup,
            DiagnosticResult.failed,
            watch,
            code: DiagnosticErrorCode.unavailable,
          );
        }),
      );
    }
    unawaited(_release());
    super.dispose();
  }
}
