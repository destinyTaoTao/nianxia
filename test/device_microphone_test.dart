import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/platform/capture_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('流式采集的取消必须等待真实设备停止回执', () async {
    const channel = MethodChannel('com.llfbandit.record/messages');
    final requested = Completer<void>();
    final acknowledged = Completer<void>();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'hasPermission') return true;
      if (call.method == 'cancel' || call.method == 'stop') {
        if (!requested.isCompleted) requested.complete();
        await acknowledged.future;
      }
      return null;
    });
    final mic = DeviceMicrophone();
    await mic.allowed();
    var completed = false;
    final cancelling = mic.cancel().then((_) => completed = true);
    try {
      await requested.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        completed,
        isFalse,
        reason: 'The pinned SDK cancel future is not a device acknowledgement.',
      );
      expect(calls, contains('stop'));
      acknowledged.complete();
      await cancelling;
      expect(completed, isTrue);
    } finally {
      if (!acknowledged.isCompleted) acknowledged.complete();
      await cancelling;
      await mic.close();
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
  test('未进入设备阶段的适配器关闭不初始化原生录音器', () async {
    const channel = MethodChannel('com.llfbandit.record/messages');
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
    try {
      final mic = DeviceMicrophone();
      await mic.close();
      expect(calls, isEmpty);
    } finally {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });
}
