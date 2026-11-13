import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/capture_store.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/native_capture.dart';

import 'capture_faults.dart';

Future<Map<String, num>> runCaptureKillScenario(String testCase) async {
  final bridge = NativeCaptureBridge();
  Notebook? book;
  try {
    final checkpoint = await readCaptureFaultCheckpoint();
    final current = await bridge.current();
    final home = Directory(
      p.join((await getApplicationSupportDirectory()).path, 'nianxia'),
    );
    book = await Notebook.open(home);
    if (checkpoint == null) {
      expect(current?.phase == NativeCapturePhase.recording, isFalse);
      final query = testCase == 'process-kill-query';
      final now = DateTime.now();
      final id = const Uuid().v4();
      final value = await bridge.start(
        CaptureRequest(
          sessionId: id,
          mode: query ? CaptureMode.query : CaptureMode.record,
          createdAtUtc: now.toUtc(),
          timezone: now.timeZoneName,
          offsetMinutes: now.timeZoneOffset.inMinutes,
        ),
      );
      expect(value.sessionId, id);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect((await bridge.current())!.pcmBytes, greaterThan(0));
      var phase = query ? 'query-active' : 'active';
      if (testCase == 'kill-after-finalize' ||
          testCase == 'kill-after-source-commit') {
        await bridge.stop(id);
        phase = 'finalized';
        if (testCase == 'kill-after-source-commit') {
          await book.acceptNativeCapture(await bridge.claim(id));
          expect(await book.get(id), isNotNull);
          phase = 'source-committed';
        }
      }
      await writeCaptureFaultCheckpoint(phase, id);
      await Future<void>.delayed(const Duration(seconds: 110));
      throw StateError('强杀动作未发生，不能冒充已恢复');
    }
    final id = checkpoint['sessionId'] as String;
    validateCaptureId(id);
    expect(current, isNull, reason: '进程重启不能自动重新打开麦克风');
    final query = testCase == 'process-kill-query';
    if (query) {
      expect(await book.get(id), isNull);
      expect(
        File(p.join(home.path, 'native-captures', 'queries', '$id.wav'))
            .existsSync(),
        isFalse,
      );
      expect((await bridge.pending()).where((s) => s.sessionId == id), isEmpty);
      return {
        'queryRows': 0,
        'queryAudioRemaining': 0,
        'automaticMicRestarts': 0,
      };
    }
    final clip = await bridge.claim(id);
    expect(clip.snapshot.phase, NativeCapturePhase.finalized);
    final saved = await book.acceptNativeCapture(clip);
    await bridge.acknowledge(
      id,
      disposition: CaptureDisposition.importedRecord,
    );
    expect((await book.records).where((r) => r.id == id).length, 1);
    final file = File(book.audioPath(saved));
    final duration = await validateWave(file);
    expect(duration, greaterThan(0));
    final bytes = await file.length();
    await book.delete(
      id,
    ); // Cleanup ONLY the UUID created by this disposable fixture.
    expect(await book.get(id), isNull);
    return {
      'sourceMatchesBeforeCleanup': 1,
      'recordedMs': duration,
      'waveBytes': bytes,
      'automaticMicRestarts': 0,
    };
  } finally {
    await bridge.close();
    await book?.close();
  }
}
