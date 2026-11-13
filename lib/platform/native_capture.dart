import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/capture_session.dart';
import '../domain/record.dart';

abstract interface class NativeCapturePort {
  Future<CaptureSnapshot> start(CaptureRequest request);
  Future<CaptureSnapshot?> current();
  Future<List<CaptureSnapshot>> pending({String? after, int limit = 32});
  Future<CaptureSnapshot> stop(String id);
  Future<void> cancel(String id);
  Future<FinalizedCapture> claim(String id);
  Future<void> acknowledge(String id, {required CaptureDisposition disposition});
  Stream<CaptureSnapshot> get events;

  /// Releases this client's subscriptions, never the native recording owner.
  Future<void> close();
}

class NativeCaptureBridge implements NativeCapturePort {
  NativeCaptureBridge({MethodChannel? commands, Stream<Object?>? eventSource})
    : _commands = commands ?? const MethodChannel('app.nianxia/capture'),
      _eventSource =
          eventSource ??
          const EventChannel('app.nianxia/capture_events').receiveBroadcastStream() {
    _events = StreamController<CaptureSnapshot>.broadcast(onListen: _listen);
  }

  final MethodChannel _commands;
  final Stream<Object?> _eventSource;
  late final StreamController<CaptureSnapshot> _events;
  StreamSubscription<Object?>? _subscription;
  CaptureSnapshot? _latest;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Stream<CaptureSnapshot> get events => _events.stream;

  void _listen() {
    if (_subscription != null || _closed) return;
    _subscription = _eventSource.listen(
      (value) {
        if (_closed) return;
        try {
          final snapshot = _decode(value);
          if (_latest != null && snapshot.sessionId != _latest!.sessionId) return;
          _remember(snapshot);
        } catch (_) {
          _events.addError(const FormatException('录音状态无效。'));
        }
      },
      onError: (_) {
        if (!_closed) {
          _events.addError(const NotebookException('录音状态连接中断，请返回应用核对。'));
        }
      },
    );
  }

  CaptureSnapshot _decode(Object? value) {
    if (value is! Map) throw const FormatException('录音状态无效。');
    return CaptureSnapshot.fromMap(Map<Object?, Object?>.from(value));
  }

  CaptureSnapshot _remember(CaptureSnapshot snapshot) {
    final previous = _latest;
    if (previous == null ||
        previous.sessionId != snapshot.sessionId ||
        snapshot.sequence > previous.sequence) {
      _latest = snapshot;
      if (!_closed) _events.add(snapshot);
    }
    return _latest!;
  }

  Future<Object?> _call(String method, [Map<String, Object?>? args]) async {
    if (_closed) throw const NotebookException('录音状态连接已关闭。');
    try {
      return await _commands.invokeMethod<Object?>(method, args);
    } on PlatformException catch (error) {
      throw NotebookException(
        error.code == 'capture_claimed'
            ? '录音正在完成保存，请稍后重试。'
            : '无法操作录音会话，请返回应用核对后重试。',
      );
    } on MissingPluginException {
      throw const NotebookException('当前平台的录音会话尚不可用。');
    }
  }

  @override
  Future<CaptureSnapshot> start(CaptureRequest request) async =>
      _remember(_decode(await _call('start', request.toMap())));

  @override
  Future<CaptureSnapshot?> current() async {
    final value = await _call('current');
    if (value == null) return null;
    return _remember(_decode(value));
  }

  @override
  Future<List<CaptureSnapshot>> pending({String? after, int limit = 32}) async {
    if (after != null) validateCaptureId(after);
    if (limit < 1 || limit > 32) throw ArgumentError('录音分页大小无效。');
    final result = await _call('pending', {'after': after, 'limit': limit});
    if (result is! List || result.length > limit) {
      throw const FormatException('待恢复录音列表无效。');
    }
    return result.map(_decode).toList(growable: false);
  }

  @override
  Future<CaptureSnapshot> stop(String id) async {
    validateCaptureId(id);
    return _remember(_decode(await _call('stop', {'sessionId': id})));
  }

  @override
  Future<void> cancel(String id) async {
    validateCaptureId(id);
    await _call('cancel', {'sessionId': id});
  }

  @override
  Future<FinalizedCapture> claim(String id) async {
    validateCaptureId(id);
    return FinalizedCapture(_decode(await _call('claim', {'sessionId': id})));
  }

  @override
  Future<void> acknowledge(
    String id, {
    required CaptureDisposition disposition,
  }) async {
    validateCaptureId(id);
    await _call('acknowledge', {
      'sessionId': id,
      'disposition': disposition.name,
    });
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _subscription?.cancel();
    await _events.close();
  }
}
