import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:record/record.dart';

import '../app/notebook.dart';
import '../data/pcm_wave_writer.dart';
import 'local_models.dart';

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
  final AudioRecorder recorder = AudioRecorder();
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
    await recorder.stop();
  }

  @override
  Future<void> cancel() => recorder.cancel();
  @override
  Future<void> close() => recorder.dispose();
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
  StreamSubscription<double>? _amplitude;
  StreamSubscription<void>? _states;
  StreamSubscription<Uint8List>? _pcm;
  bool _disposed = false;
  bool _startInterrupted = false;
  bool get active =>
      state == 'recording' || state == 'starting' || state == 'saving';
  int get elapsed => _watch.elapsedMilliseconds.clamp(0, 120000);
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _closeWriter() async {
    final writer = _writer;
    _writer = null;
    await writer?.close();
  }

  Future<void> _cleanQuery() async {
    if (query && draft != null) {
      final file = File(draft!.path);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> start() async {
    book.captureActive = true;
    try {
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
      draft = await book.beginCapture(parentId: parentId, query: query);
      _ensureStartAllowed();
      models?.queue.paused = true;
      _writer = await PcmWaveWriter.open(
        draft!.path,
        onLimit: () {
          if (state == 'recording') {
            finish();
          }
        },
        onFailure: () {
          if (state == 'recording') {
            finish();
          }
        },
      );
      _ensureStartAllowed();
      final stream = await microphone.start();
      _ensureStartAllowed();
      state = 'recording';
      _watch.start();
      _pcm = stream.listen(
        (bytes) => _writer?.add(bytes),
        onError: (_) {
          finish();
        },
        onDone: () {
          if (state == 'recording') {
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
      _states = microphone.interruptions.listen((_) {
        if (state == 'recording') {
          finish();
        }
      });
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
      try {
        await microphone.stop();
      } catch (_) {}
      try {
        await _closeWriter();
      } catch (_) {}
      await _cleanQuery();
      book.captureActive = false;
      state = 'failed';
      error = e is NotebookException ? e.message : '无法开始录音，请检查麦克风权限和剩余空间。';
      models?.queue.paused = false;
      _notify();
    }
  }

  void _ensureStartAllowed() {
    if (_disposed || _startInterrupted || state != 'starting') {
      throw const NotebookException('录音启动被中断，未继续采集。请返回后重新呼出，或改用文字。');
    }
  }

  Future<void> finish() async {
    if (state != 'recording') {
      return;
    }
    state = 'saving';
    _watch.stop();
    _timer?.cancel();
    _notify();
    try {
      await microphone.stop();
      await _pcm?.cancel();
      await _closeWriter();
      models?.queue.paused = false;
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
      try {
        await microphone.cancel();
      } catch (_) {}
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
      book.captureActive = false;
      models?.queue.paused = false;
      _notify();
    }
  }

  Future<void> retry() async {
    if (draft == null || query) {
      return;
    }
    state = 'saving';
    _notify();
    try {
      try {
        await microphone.stop();
      } catch (_) {}
      await _pcm?.cancel();
      await _closeWriter();
      saved = await book.finishCapture(draft!, recovering: true);
      state = 'done';
      error = null;
    } catch (e) {
      state = 'failed';
      error = e is NotebookException ? e.message : '仍无法保存，请检查剩余空间。';
    }
    _notify();
  }

  Future<void> discard() async {
    if (state == 'saving' || state == 'done' || state == 'cancelled') {
      return;
    }
    state = 'discarding';
    _timer?.cancel();
    _watch.stop();
    _notify();
    try {
      if (draft != null && !query) {
        await book.captures
            .marker(draft!.id)
            .writeAsString('{"discarded":true}', flush: true);
      }
      await microphone.cancel();
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
      error = '丢弃未完成，请重试。';
    } finally {
      book.captureActive = false;
      models?.queue.paused = false;
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
    try {
      await _pcm?.cancel();
      await microphone.close();
      await _closeWriter();
    } catch (_) {
    } finally {
      await _cleanQuery();
    }
  }

  @override
  void dispose() {
    book.captureActive = false;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _screenOff.removeListener(_onScreenOff);
    _timer?.cancel();
    _amplitude?.cancel();
    _states?.cancel();
    unawaited(_release());
    models?.queue.paused = false;
    super.dispose();
  }
}
