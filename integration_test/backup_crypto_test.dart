import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nianxia/domain/backup_operation.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';

// Experimental adapter intentionally stays outside the production package.
// ignore: avoid_relative_lib_imports
import '../tool/spikes/backup_crypto/lib/age_cipher_spike.dart';
import 'support/isolated_validation.dart';

Future<String> hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Future<void> fixture(File file, int bytes) async {
  final sink = file.openWrite();
  final chunk = Uint8List.fromList(List.generate(65536, (i) => i % 251));
  while (bytes > 0) {
    final count = bytes < chunk.length ? bytes : chunk.length;
    sink.add(chunk.sublist(0, count));
    bytes -= count;
    await sink.flush();
  }
  await sink.close();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('隔离应用的标准密码容器资源和失败边界', (tester) async {
    await requireIsolatedValidation();
    const testCase = String.fromEnvironment('VALIDATION_CASE');
    if (testCase != 'cipher-smoke' &&
        testCase != 'cipher-resources' &&
        testCase != 'backup-matrix') {
      throw StateError('备份链矩阵尚未接入，不能用容器冒烟代替。');
    }
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('标准加密容器隔离验证'),
      ),
    );
    final work = await Directory.systemTemp.createTemp('age-synthetic-');
    final cipher = AgeCipherSpike(
      Platform.isAndroid
          ? 'libnianxia_age_spike.so'
          : 'unavailable-ios-binding',
    );
    final password = Uint8List.fromList(utf8.encode(' 合成夹具中文🔒e\u0301 '));
    final metrics = <String, num>{};
    try {
      DynamicLibrary.open('libnianxia_age_spike.so');
      if (testCase == 'backup-matrix') {
        await _backupChain(work, cipher, password, metrics);
        binding.reportData = await writeValidationResult(
          passed: true,
          metrics: metrics,
        );
        return;
      }
      final bad = File('${work.path}/bad')
        ..writeAsStringSync(
          'age-encryption.org/v1\n-> scrypt AAAAAAAAAAAAAAAAAAAAAA 30\nAAAA\n--- AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n',
        );
      await expectLater(
        cipher.decrypt(
          inputPath: bad.path,
          outputPath: '${work.path}/bad-output',
          passwordUtf8: password,
          policy: KdfPolicy(),
          cancel: BackupCancel(),
        ),
        throwsA(
          isA<BackupCipherFailure>().having(
            (e) => e.kind,
            'kind',
            BackupCipherFailureKind.resourceLimit,
          ),
        ),
      );
      expect(cipher.lastKdfStarted, 0);
      metrics['rejectedHeaderKdfStarts'] = cipher.lastKdfStarted;
      final sizes = testCase == 'cipher-resources' ? [1, 64, 512] : [1];
      for (final mib in sizes) {
        final plain = File('${work.path}/plain');
        await fixture(plain, mib * 1024 * 1024);
        final expected = await hash(plain);
        for (final n in testCase == 'cipher-resources' ? [16, 17, 18] : [18]) {
          final encrypted = File('${work.path}/encrypted');
          final decoded = File('${work.path}/decoded');
          var heartbeat = 0;
          var peakRss = ProcessInfo.currentRss;
          var longestTick = 0;
          final clock = Stopwatch()..start();
          var lastTick = clock.elapsedMilliseconds;
          final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
            heartbeat++;
            final now = clock.elapsedMilliseconds;
            final gap = now - lastTick;
            if (gap > longestTick) longestTick = gap;
            lastTick = now;
            final rss = ProcessInfo.currentRss;
            if (rss > peakRss) peakRss = rss;
          });
          final watch = Stopwatch()..start();
          try {
            await cipher.encrypt(
              inputPath: plain.path,
              outputPath: encrypted.path,
              passwordUtf8: password,
              policy: KdfPolicy(writeLogN: n),
              cancel: BackupCancel(),
            );
            metrics['encryptMs_${mib}MiB_n$n'] = watch.elapsedMilliseconds;
            watch.reset();
            await cipher.decrypt(
              inputPath: encrypted.path,
              outputPath: decoded.path,
              passwordUtf8: password,
              policy: KdfPolicy(),
              cancel: BackupCancel(),
            );
            metrics['decryptMs_${mib}MiB_n$n'] = watch.elapsedMilliseconds;
          } finally {
            timer.cancel();
          }
          expect(await hash(decoded), expected);
          expect(heartbeat, greaterThan(0));
          metrics['peakSampledRss_${mib}MiB_n$n'] = peakRss;
          metrics['mainTimerMaxGapMs_${mib}MiB_n$n'] = longestTick;
          await encrypted.delete();
          await decoded.delete();
        }
        await plain.delete();
      }
      final plain = File('${work.path}/cancel-plain');
      await fixture(plain, 1048576);
      final cancel = BackupCancel();
      final cancellationWatch = Stopwatch();
      await expectLater(
        cipher.encrypt(
          inputPath: plain.path,
          outputPath: '${work.path}/cancelled',
          passwordUtf8: password,
          policy: KdfPolicy(),
          cancel: cancel,
          progress: (_) {
            if (!cancel.requested) {
              cancellationWatch.start();
              cancel.cancel();
            }
          },
        ),
        throwsA(
          isA<BackupCipherFailure>().having(
            (e) => e.kind,
            'kind',
            BackupCipherFailureKind.cancelled,
          ),
        ),
      );
      metrics['cancelJoinMs'] = cancellationWatch.elapsedMilliseconds;
      expect(File('${work.path}/cancelled').existsSync(), isFalse);
      expect(File('${work.path}/cancelled.partial').existsSync(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(File('${work.path}/cancelled.partial').existsSync(), isFalse);
      binding.reportData = await writeValidationResult(
        passed: true,
        metrics: metrics,
      );
    } catch (_) {
      metrics['failureStage'] = cipher.lastNativeStage;
      metrics['failureKdfStarts'] = cipher.lastKdfStarted;
      binding.reportData = await writeValidationResult(
        passed: false,
        metrics: metrics,
      );
      rethrow;
    } finally {
      password.fillRange(0, password.length, 0);
      await work.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<void> _backupChain(
  Directory work,
  AgeCipherSpike cipher,
  Uint8List password,
  Map<String, num> metrics,
) async {
  final source = await Notebook.open(Directory('${work.path}/source'));
  final target = await Notebook.open(Directory('${work.path}/target'));
  final watch = Stopwatch()..start();
  try {
    final parent = await source.saveText('synthetic parent 中文');
    final child = await source.saveText(
      'synthetic append',
      parentId: parent.id,
    );
    final draft = await source.beginCapture(parentId: parent.id);
    final data = ByteData(32044);
    final bytes = data.buffer.asUint8List();
    void tag(int offset, String value) =>
        bytes.setRange(offset, offset + value.length, value.codeUnits);
    tag(0, 'RIFF');
    data.setUint32(4, 32036, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, 16000, Endian.little);
    data.setUint32(28, 32000, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, 32000, Endian.little);
    await File(draft.path).writeAsBytes(bytes, flush: true);
    final recording = await source.finishCapture(draft);
    final archive = await BackupService(
      source,
      cipher: cipher,
    ).exportEncrypted(passwordUtf8: password);
    final ciphertext = await archive.readAsBytes();
    ciphertext[ciphertext.length - 1] ^= 1;
    final broken = File('${work.path}/broken.age');
    await broken.writeAsBytes(ciphertext);
    await expectLater(
      BackupService(
        target,
        cipher: cipher,
      ).restore(broken, passwordUtf8: password),
      throwsA(isA<BackupCipherFailure>()),
    );
    expect(await target.records, isEmpty);
    final restored = await BackupService(
      target,
      cipher: cipher,
    ).restore(archive, passwordUtf8: password);
    expect(restored.added, 3);
    expect((await target.get(child.id))!.parentId, parent.id);
    final saved = (await target.get(recording.id))!;
    expect(saved.parentId, parent.id);
    expect(
      await hash(File(target.audioPath(saved))),
      await hash(File(source.audioPath(recording))),
    );
    expect((await target.get(parent.id))!.canonical, parent.canonical);
    expect(
      (await BackupService(
        target,
        cipher: cipher,
      ).restore(archive, passwordUtf8: password)).skipped,
      3,
    );
    metrics['backupChainMs'] = watch.elapsedMilliseconds;
    metrics['restoredRecords'] = restored.added;
    metrics['audioBytes'] = await File(target.audioPath(saved)).length();
  } finally {
    await source.close();
    await target.close();
  }
}
