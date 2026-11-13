import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/platform/native_capture.dart';

import 'support/native_capture_fake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.nianxia/capture');
  const id = '11111111-1111-4111-8111-111111111111';
  late ControlledNativeCaptureEndpoint endpoint;
  late NativeCaptureBridge bridge;
  late StreamController<Object?> events;
  CaptureRequest request([String sessionId = id]) => CaptureRequest(
    sessionId: sessionId,
    mode: CaptureMode.record,
    createdAtUtc: DateTime.utc(2026, 11, 14),
    timezone: 'Asia/Shanghai',
    offsetMinutes: 480,
  );

  setUp(() {
    endpoint = ControlledNativeCaptureEndpoint();
    events = StreamController<Object?>.broadcast(sync: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, endpoint.handle);
    bridge = NativeCaptureBridge(commands: channel, eventSource: events.stream);
  });
  tearDown(() async {
    await bridge.close();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('端口保留原生返回的现有会话，不把重复开始伪装成新会话', () async {
    final first = await bridge.start(request());
    final second = await bridge.start(
      request('22222222-2222-4222-8222-222222222222'),
    );
    expect(first.sessionId, id);
    expect(second.sessionId, id);
  });

  test('无效ID在调用原生前拒绝，未知协议和越界音频不能进入会话', () async {
    expect(() => request('../private'), throwsArgumentError);
    await bridge.start(request());
    for (final mutation in <Map<String, Object?>>[
      {'wireVersion': 2},
      {'relativeAudioName': '../private.wav'},
      {'pcmBytes': 3},
      {'pcmBytes': 3840002},
      {'elapsedMs': 120001},
      {'level': double.nan},
    ]) {
      expect(
        () => CaptureSnapshot.fromMap({...endpoint.active!, ...mutation}),
        throwsFormatException,
        reason: mutation.keys.single,
      );
    }
  });

  test('已claim的原生拒绝安全映射为业务错误且不泄露原始异常', () async {
    await bridge.start(request());
    await bridge.stop(id);
    final clip = await bridge.claim(id);
    expect(clip.snapshot.pcmBytes, 64);
    await expectLater(
      bridge.cancel(id),
      throwsA(
        isA<NotebookException>().having(
          (e) => e.message,
          'safe message',
          isNot(contains('private-path-sentinel')),
        ),
      ),
    );
    await bridge.acknowledge(id, disposition: CaptureDisposition.importedRecord);
    expect(
      (endpoint.calls.last.arguments as Map)['disposition'],
      'importedRecord',
    );
  });

  test('乱序事件和旧会话事件不能替换当前状态，关闭订阅不停止录音', () async {
    final observed = <CaptureSnapshot>[];
    final subscription = bridge.events.listen(observed.add);
    await bridge.start(request());
    events.add({...endpoint.active!, 'sequence': 3, 'elapsedMs': 100});
    events.add({...endpoint.active!, 'sequence': 2, 'elapsedMs': 50});
    events.add({
      ...endpoint.active!,
      'sessionId': '22222222-2222-4222-8222-222222222222',
      'sequence': 99,
    });
    await Future<void>.delayed(Duration.zero);
    expect(observed.map((event) => event.sequence).toList(), [1, 3]);
    await subscription.cancel();
    await bridge.close();
    expect(endpoint.calls.any((call) => call.method == 'cancel'), isFalse);
    expect(endpoint.calls.any((call) => call.method == 'stop'), isFalse);
  });

  test('原生pending回复超出请求上限时拒绝跨边界无限列表', () async {
    await bridge.start(request());
    await bridge.stop(id);
    endpoint.pendingReply = [endpoint.active, endpoint.active];
    await expectLater(bridge.pending(limit: 1), throwsFormatException);
  });
}
