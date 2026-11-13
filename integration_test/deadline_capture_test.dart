import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/data/capture_store.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('原生两分钟期限在后台自动结束，无Flutter停止调用', (tester) async {
    await requireIsolatedValidation();
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('原生两分钟期限隔离验证'),
      ),
    );
    final bridge = NativeCaptureBridge();
    final id = const Uuid().v4();
    var started = false;
    try {
      final now = DateTime.now();
      final watch = Stopwatch()..start();
      final start = await bridge.start(
        CaptureRequest(
          sessionId: id,
          mode: CaptureMode.record,
          createdAtUtc: now.toUtc(),
          timezone: now.timeZoneName,
          offsetMinutes: now.timeZoneOffset.inMinutes,
        ),
      );
      started = true;
      expect(start.sessionId, id);
      await const MethodChannel('app.nianxia/system')
          .invokeMethod<void>('dismissCapsule');
      CaptureSnapshot? current;
      while (watch.elapsedMilliseconds < 130000) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        current = await bridge.current();
        if (current?.phase == NativeCapturePhase.finalized ||
            current?.phase == NativeCapturePhase.failed) {
          break;
        }
      }
      expect(current?.phase, NativeCapturePhase.finalized);
      expect(current!.errorCode, isNull);
      expect(
        current.elapsedMs >= 120000 || current.pcmBytes == 3840000,
        isTrue,
        reason: '必须由原生期限或样本上限自动收尾',
      );
      final file = File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'nianxia',
          'native-captures',
          '$id.wav',
        ),
      );
      final duration = await validateWave(file);
      expect(duration, greaterThan(110000));
      expect(duration, lessThanOrEqualTo(120000));
      final metrics = {
        'actualElapsedMs': watch.elapsedMilliseconds,
        'nativeElapsedMs': current.elapsedMs,
        'recordedMs': duration,
        'pcmBytes': current.pcmBytes,
      };
      await bridge.cancel(id);
      expect(file.existsSync(), isFalse);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: metrics,
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      if (started) {
        try {
          await bridge.cancel(id);
        } catch (_) {}
      }
      await bridge.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
