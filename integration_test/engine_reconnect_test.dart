import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/capture_store.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/native_capture.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'support/isolated_validation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('actual engine destruction retains process microphone owner', (
    tester,
  ) async {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('VALIDATION_RUN_ID');
    const channel = MethodChannel('app.nianxia/capture');
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'validation-ui', runId),
    );
    final checkpoint = File(p.join(root.path, 'engine-checkpoint.json'));
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('独立引擎重连验证'),
      ),
    );
    final bridge = NativeCaptureBridge();
    Notebook? book;
    String? ownedId;
    var completed = false;
    try {
      if (!await checkpoint.exists()) {
        await channel.invokeMethod<void>('setValidationWorkspace', {
          'runId': runId,
        });
        var status = (await channel.invokeMapMethod<String, int>(
          'validationEngineState',
          {'runId': runId},
        ))!;
        final visibleDeadline = DateTime.now().add(const Duration(seconds: 10));
        while (status['foreground'] != 1 &&
            DateTime.now().isBefore(visibleDeadline)) {
          await tester.pump(const Duration(milliseconds: 50));
          status = (await channel.invokeMapMethod<String, int>(
            'validationEngineState',
            {'runId': runId},
          ))!;
        }
        expect(status['foreground'], 1);
        final id = const Uuid().v4();
        ownedId = id;
        await bridge.start(
          CaptureRequest(
            sessionId: id,
            mode: CaptureMode.record,
            createdAtUtc: DateTime.now().toUtc(),
            timezone: 'UTC',
            offsetMinutes: 0,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 1300));
        final before = (await bridge.current())!;
        expect(before.pcmBytes, greaterThan(0));
        await checkpoint.writeAsString(
          jsonEncode({
            'sessionId': id,
            'pid': pid,
            'pcmBytes': before.pcmBytes,
            ...status,
          }),
          flush: true,
        );
        await channel.invokeMethod<void>('recreateValidationEngine', {
          'runId': runId,
        });
        // This isolate must disappear, not merely unsubscribe from the bridge.
        await Future<void>.delayed(const Duration(seconds: 100));
        throw StateError('Original engine was not destroyed');
      }
      final old =
          jsonDecode(await checkpoint.readAsString()) as Map<String, dynamic>;
      ownedId = old['sessionId'] as String;
      validateCaptureId(ownedId);
      final status = (await channel.invokeMapMethod<String, int>(
        'validationEngineState',
        {'runId': runId},
      ))!;
      expect(
        pid,
        old['pid'],
        reason: 'Process must survive engine replacement',
      );
      expect(status['engineIdentity'], isNot(old['engineIdentity']));
      expect(status['ownerIdentity'], old['ownerIdentity']);
      expect(status['detachCount'], greaterThan(old['detachCount'] as int));
      final current = (await bridge.current())!;
      expect(current.sessionId, ownedId);
      expect(current.phase, NativeCapturePhase.recording);
      expect(current.pcmBytes, greaterThan(old['pcmBytes'] as int));
      await bridge.stop(ownedId);
      book = await Notebook.open(Directory(p.join(root.path, 'nianxia')));
      final saved = await book.acceptNativeCapture(await bridge.claim(ownedId));
      await bridge.acknowledge(
        ownedId,
        disposition: CaptureDisposition.importedRecord,
      );
      expect((await book.records).length, 1);
      final audio = File(book.audioPath(saved));
      expect(await validateWave(audio), greaterThan(1000));
      // Reopening cannot duplicate the imported source.
      await book.close();
      book = await Notebook.open(Directory(p.join(root.path, 'nianxia')));
      expect((await book.records).single.id, ownedId);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: {
          'sameProcess': 1,
          'differentEngine': 1,
          'sameNativeOwner': 1,
          'transportDetachObserved': 1,
          'pcmContinued': 1,
          'recordedBytes': await audio.length(),
          'sourceRowsAfterReopen': 1,
        },
      );
      completed = true;
    } catch (_) {
      binding.reportData = await writeValidationResult(passed: false);
      rethrow;
    } finally {
      await bridge.close();
      await book?.close();
      if (completed) {
        await channel.invokeMethod<void>('endValidationWorkspace', {
          'runId': runId,
        });
        await root.delete(recursive: true); // This nonce's fixture only.
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
