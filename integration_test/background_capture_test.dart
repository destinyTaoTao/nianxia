import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/data/capture_store.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'support/isolated_validation.dart';
import 'support/capture_kill_scenario.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('原生记录会话在应用隐藏后继续采集并完成有效WAV', (tester) async {
    await requireIsolatedValidation();
    const testCase = String.fromEnvironment('VALIDATION_CASE');
    if (const {
      'process-kill-active',
      'process-kill-query',
      'kill-after-finalize',
      'kill-after-source-commit',
    }.contains(testCase)) {
      try {
        final metrics = await runCaptureKillScenario(testCase);
        binding.reportData = await writeValidationResult(
          passed: true,
          metrics: metrics,
        );
      } catch (_) {
        binding.reportData = await writeValidationResult(passed: false);
        rethrow;
      }
      return;
    }
    if (testCase != 'background-smoke' && testCase != 'capture-matrix') {
      throw StateError('此录音故障用例尚未实现，不能用普通冒烟代替。');
    }
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('独立录音验证，仅测试包'),
      ),
    );
    final bridge = NativeCaptureBridge();
    final id = const Uuid().v4();
    var started = false;
    try {
      final startTime = Stopwatch()..start();
      final start = await bridge.start(
        CaptureRequest(
          sessionId: id,
          mode: CaptureMode.record,
          createdAtUtc: DateTime.now().toUtc(),
          timezone: 'Asia/Shanghai',
          offsetMinutes: 480,
        ),
      );
      startTime.stop();
      started = true;
      expect(start.phase, NativeCapturePhase.recording);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      const screenOff =
          String.fromEnvironment('VALIDATION_CASE') == 'capture-matrix';
      final before = (await bridge.current())!.pcmBytes;
      if (screenOff) {
        await writeRecordingCheckpoint();
        await Future<void>.delayed(const Duration(milliseconds: 4000));
        expect(
          await const MethodChannel('app.nianxia/system')
              .invokeMethod<bool>('recordingScreenAvailable'),
          isFalse,
          reason: '必须实际熄屏，不能只隐藏 Activity',
        );
      } else {
        await const MethodChannel('app.nianxia/system')
            .invokeMethod<void>('dismissCapsule');
        await Future<void>.delayed(const Duration(milliseconds: 1800));
      }
      final background = await bridge.current();
      expect(background?.phase, NativeCapturePhase.recording);
      expect(background!.pcmBytes, greaterThan(0));
      expect(background.pcmBytes, greaterThan(before));
      final stopping = Stopwatch()..start();
      final done = await bridge.stop(id);
      stopping.stop();
      expect(done.phase, NativeCapturePhase.finalized);
      final directory = await getApplicationSupportDirectory();
      final file = File(
        p.join(directory.path, 'nianxia', 'native-captures', '$id.wav'),
      );
      final duration = await validateWave(file);
      expect(duration, greaterThanOrEqualTo(2000));
      expect(duration, lessThanOrEqualTo(120000));
      expect(done.pcmBytes, await file.length() - 44);
      await bridge.cancel(id); // This test never claims a record was committed.
      expect(await file.exists(), isFalse);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'startMs': startTime.elapsedMilliseconds,
          'nativeFinalizeMs': stopping.elapsedMilliseconds,
          'recordedMs': duration,
          'pcmBytes': done.pcmBytes,
        },
      );
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      if (started) {
        try {
          await bridge.cancel(id);
        } catch (_) {
          // No external files or production data are cleaned by this fixture.
        }
      }
      await bridge.close();
    }
  });
}
