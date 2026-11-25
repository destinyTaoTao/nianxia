import 'package:flutter/foundation.dart';

import '../domain/record.dart';

class _DeviceGuard {
  const _DeviceGuard(this.release, this.canRetry);
  final Future<void> Function() release;
  final bool Function() canRetry;
}

/// Process-local physical-device guards, not recording sessions. An uncertain
/// device outlives its widget/book until its adapter acknowledges release.
class CaptureDeviceFence {
  static final _holders = <Object, _DeviceGuard>{};
  static final _changes = ValueNotifier<bool>(false);
  static Listenable get changes => _changes;
  static bool get occupied => _holders.isNotEmpty;
  static bool get canRetryRelease =>
      occupied && _holders.values.every((guard) => guard.canRetry());

  static void hold(
    Object owner,
    Future<void> Function() retryRelease, {
    required bool Function() canRetry,
  }) {
    if (_holders.isNotEmpty && !_holders.containsKey(owner)) {
      throw const NotebookException('另一段录音尚未确认结束，请先停止或重试。');
    }
    _holders[owner] = _DeviceGuard(retryRelease, canRetry);
    _changes.value = occupied;
  }

  static void released(Object owner) {
    if (_holders.remove(owner) != null) _changes.value = occupied;
  }

  static Future<void> beforeStart() async {
    for (final guard in _holders.values.toList(growable: false)) {
      await guard.release();
    }
  }
}
