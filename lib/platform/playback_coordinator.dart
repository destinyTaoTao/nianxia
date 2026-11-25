import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../app/notebook.dart';
import '../app/diagnostics.dart';
import '../domain/diagnostic_event.dart';
import 'capture_device_fence.dart';

abstract interface class PlaybackOutput implements Listenable {
  bool get playing;
  bool get completed;
  Duration get position;
  Object? get failure;
  Future<void> load(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> close();
}

class _DeviceOutput extends ChangeNotifier implements PlaybackOutput {
  final player = AudioPlayer();
  final subscriptions = <StreamSubscription<Object?>>[];
  bool closed = false;
  bool mayBeAudible = false, muted = false;
  int intent = 0;
  @override
  Object? failure;
  _DeviceOutput() {
    subscriptions.addAll([
      player.playerStateStream.listen((_) => changed()),
      player.positionStream.listen((_) => changed()),
      player.errorStream.listen((e) {
        failure = e;
        changed();
      }),
    ]);
  }
  void changed() {
    if (!closed) notifyListeners();
  }

  @override
  bool get playing => mayBeAudible || player.playing;
  @override
  bool get completed => player.processingState == ProcessingState.completed;
  @override
  Duration get position => player.position;
  @override
  Future<void> load(String path) async {
    failure = null;
    await player.setFilePath(path);
  }

  @override
  Future<void> play() async {
    final epoch = ++intent;
    failure = null;
    if (muted) {
      await player.setVolume(1);
      if (closed || epoch != intent) return;
      muted = false;
    }
    if (closed || epoch != intent) return;
    mayBeAudible = true;
    await player.play();
  }

  Future<void> confirmSilence() async {
    if (!mayBeAudible && !player.playing) return;
    try {
      if (player.playing) {
        await player.pause();
      } else {
        // pause() changes just_audio's local flag even when the device rejects
        // it. A retry needs a real acknowledgement, not that cached flag.
        await player.setVolume(0);
        muted = true;
      }
      mayBeAudible = false;
    } catch (e) {
      mayBeAudible = true;
      failure = e;
      rethrow;
    }
  }

  @override
  Future<void> pause() async {
    intent++;
    await confirmSilence();
  }

  @override
  Future<void> stop() async {
    intent++;
    await confirmSilence();
    // stop() swallows native disposal errors in the pinned just_audio version.
    // A pause/mute acknowledgement above is the capture safety boundary.
    await player.stop();
  }

  @override
  Future<void> seek(Duration position) {
    failure = null;
    return player.seek(position);
  }

  @override
  Future<void> close() async {
    closed = true;
    intent++;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    try {
      await player.dispose();
    } finally {
      dispose();
    }
  }
}

/// One on-demand output per open notebook, shared by routes and capture owners.
class PlaybackCoordinator extends ChangeNotifier {
  PlaybackCoordinator._(this.book, this._output) {
    _output?.addListener(outputChanged);
    book.captureChanges.addListener(captureChanged);
    CaptureDeviceFence.changes.addListener(changed);
  }
  static final _owners = Expando<PlaybackCoordinator>();
  // Failed stop acknowledgements outlive widgets and notebook replacement.
  // The next playback/capture retries the same device before doing anything.
  static final _pendingStops = <PlaybackCoordinator>{};
  static PlaybackCoordinator retain(
    Notebook book, {
    PlaybackOutput? output,
    LocalDiagnostics? diagnostics,
  }) {
    final owner = _owners[book] ??= PlaybackCoordinator._(book, output);
    if (output != null && !identical(owner._output, output)) {
      throw StateError('This notebook already has a playback output.');
    }
    owner.references++;
    owner.diagnostics ??= diagnostics;
    return owner;
  }

  final Notebook book;
  LocalDiagnostics? diagnostics;
  PlaybackOutput? _output;
  int references = 0, generation = 0, preparing = 0;
  bool closed = false, busy = false, notificationQueued = false;
  Object? currentOwner;
  String? loadedPath, error;
  Future<void> _tail = Future.value();
  Future<void>? _stopping, _closeWork;
  bool _disposed = false;
  PlaybackOutput get output {
    return _output ??= (_DeviceOutput()..addListener(outputChanged));
  }

  bool get blocked =>
      closed ||
      book.isClosed ||
      book.captureActive ||
      preparing > 0 ||
      CaptureDeviceFence.occupied;
  bool owns(Object owner) => identical(owner, currentOwner);
  bool get playing =>
      error == null && _output?.playing == true && _output?.completed != true;
  Duration get position => _output?.position ?? Duration.zero;
  void changed() {
    if (closed || notificationQueued) return;
    notificationQueued = true;
    // Invalidate synchronously; notify after route disposal unlocks the tree.
    scheduleMicrotask(() {
      notificationQueued = false;
      if (!closed) notifyListeners();
    });
  }

  void captureChanged() {
    if (book.captureActive) {
      unawaited(stop().catchError((Object _) {}));
    } else {
      changed();
    }
  }

  void outputChanged() {
    if (_output?.failure != null && !busy && currentOwner != null) {
      error = '无法回放，请检查原音频是否完整。';
    }
    changed();
  }

  Future<void> toggle(Object owner, String path) {
    if (blocked) return Future.value();
    final retry = error != null || _output?.failure != null;
    final epoch = ++generation;
    final same = !retry && owns(owner) && loadedPath == path;
    final pause = same && playing;
    currentOwner = owner;
    busy = true;
    error = null;
    changed();
    final work = _tail.then((_) async {
      if (closed || epoch != generation || blocked) return;
      try {
        await _drainStops();
        if (closed || epoch != generation || blocked) return;
        final device = output;
        if (pause) {
          await device.pause();
        } else {
          if (!same) await device.stop();
          if (closed || epoch != generation || blocked) return;
          if (retry) loadedPath = null;
          if (loadedPath != path) {
            // setFilePath replaces the device playlist before load completes.
            // A failed or interrupted switch must not retain the old identity.
            loadedPath = null;
            await book.withMediaLease(() => device.load(path));
            loadedPath = path;
          } else if (!same || device.completed) {
            await device.seek(Duration.zero);
          }
          if (closed || epoch != generation || blocked) return;
          // just_audio's play future completes at EOF, not when play begins.
          unawaited(
            device.play().catchError((Object _) {
              if (!closed && epoch == generation) {
                error = '无法回放，请检查原音频是否完整。';
                changed();
              }
            }),
          );
        }
      } catch (_) {
        if (!closed && epoch == generation) error = '无法回放，请检查原音频是否完整。';
      } finally {
        if (!closed && epoch == generation) {
          busy = false;
          changed();
        }
      }
    });
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> seek(Object owner, Duration value) async {
    if (!owns(owner) || loadedPath == null || blocked || busy) return;
    final epoch = generation;
    error = null;
    changed();
    try {
      await output.seek(value);
    } catch (_) {
      if (!closed && epoch == generation) {
        error = '无法调整回放位置，请重试。';
        changed();
      }
    }
  }

  Future<void> stop({Object? owner}) {
    if (closed || owner != null && !owns(owner)) return Future.value();
    generation++;
    currentOwner = null;
    busy = false;
    changed();
    // A pending load must not hold up stop; its generation can no longer play.
    return _confirmStop();
  }

  Future<void> _confirmStop() {
    if (_stopping != null) return _stopping!;
    _pendingStops.add(this);
    final work = stopOutput();
    _stopping = work;
    void clear() {
      if (identical(_stopping, work)) _stopping = null;
    }

    unawaited(
      work.then<void>((_) {
        if (!closed) _pendingStops.remove(this);
        clear();
      }, onError: (Object _, StackTrace _) => clear()),
    );
    return work;
  }

  static Future<void> _drainStops() async {
    for (final owner in _pendingStops.toList()) {
      if (owner.closed) {
        await owner._close();
      } else {
        await owner._confirmStop();
      }
    }
  }

  Future<void> stopOutput() async {
    try {
      await _output?.stop();
    } catch (_) {
      error = '原音频暂时无法停止，请停止回放后再录音。';
      changed();
      throw NotebookException(error!);
    }
  }

  static Future<T> startCapture<T>(
    Notebook book,
    Future<T> Function() start,
  ) async {
    final owner = retain(book);
    owner.preparing++;
    owner.changed();
    try {
      await CaptureDeviceFence.beforeStart();
      await _drainStops();
      await owner.stop();
      return await start();
    } finally {
      owner.preparing--;
      owner.changed();
      await owner.release();
    }
  }

  Future<void> release() {
    if (references <= 0) return Future.value();
    if (--references > 0) return Future.value();
    if (identical(_owners[book], this)) _owners[book] = null;
    return _close();
  }

  Future<void> _close() {
    if (_disposed) return Future.value();
    if (_closeWork != null) return _closeWork!;
    if (!closed) {
      closed = true;
      generation++;
      book.captureChanges.removeListener(captureChanged);
      CaptureDeviceFence.changes.removeListener(changed);
      _output?.removeListener(outputChanged);
    }
    _pendingStops.add(this);
    final work = _finishClose();
    _closeWork = work;
    unawaited(
      work.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_closeWork, work)) _closeWork = null;
        },
      ),
    );
    return work;
  }

  Future<void> _finishClose() async {
    await _confirmStop();
    // Do not dispose a device whose silence has not been acknowledged. Its
    // player must remain addressable when stop is retried after a route closes.
    try {
      await _output?.close();
    } catch (_) {
      // Silence is already acknowledged. Decoder-release failure is a cleanup
      // diagnostic, not permission to forget an unconfirmed audible device.
      await diagnostics?.record(
        DiagnosticEvent(
          kind: DiagnosticKind.playback,
          phase: DiagnosticPhase.cleanup,
          result: DiagnosticResult.failed,
          errorCode: DiagnosticErrorCode.unavailable,
        ),
      );
    }
    _pendingStops.remove(this);
    _disposed = true;
    dispose();
  }
}
