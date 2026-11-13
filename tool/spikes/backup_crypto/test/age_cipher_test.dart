import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/domain/backup_operation.dart';

// Experimental adapter intentionally stays outside the production package.
// ignore: avoid_relative_lib_imports
import '../lib/age_cipher_spike.dart';

void main() {
  late Directory work;
  late AgeCipherSpike cipher;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('nx-age-contract-');
    cipher = AgeCipherSpike(
      Platform.environment['NIANXIA_AGE_LIBRARY'] ?? 'tool/spikes/backup_crypto/native/target/debug/libnianxia_age_spike.dylib',
    );
  });
  tearDown(() async => work.delete(recursive: true));
  Uint8List password() => Uint8List.fromList(utf8.encode(' 中文🔒e\u0301 '));
  test('rejectWorkFactorBeforeKdf', () async {
    final input = File('${work.path}/bad')
      ..writeAsStringSync(
        'age-encryption.org/v1\n-> scrypt AAAAAAAAAAAAAAAAAAAAAA 30\nAAAA\n--- AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n',
      );
    await expectLater(
      cipher.decrypt(
        inputPath: input.path,
        outputPath: '${work.path}/out',
        passwordUtf8: password(),
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
    expect(File('${work.path}/out').existsSync(), isFalse);
  });
  test('missingFinalChunkNeverReportsSuccess', () async {
    final input = File('${work.path}/plain')
      ..writeAsBytesSync(List.filled(150000, 42));
    await cipher.encrypt(
      inputPath: input.path,
      outputPath: '${work.path}/encrypted',
      passwordUtf8: password(),
      policy: KdfPolicy(writeLogN: 16),
      cancel: BackupCancel(),
    );
    final bytes = await File('${work.path}/encrypted').readAsBytes();
    final broken = File('${work.path}/broken')
      ..writeAsBytesSync(bytes.sublist(0, bytes.length - 1));
    var restored = false;
    Future<void> restoreOnlyOnSuccess() async {
      await cipher.decrypt(
        inputPath: broken.path,
        outputPath: '${work.path}/out',
        passwordUtf8: password(),
        policy: KdfPolicy(),
        cancel: BackupCancel(),
      );
      restored = true;
    }

    await expectLater(
      restoreOnlyOnSuccess(),
      throwsA(isA<BackupCipherFailure>()),
    );
    expect(restored, isFalse);
    expect(File('${work.path}/out').existsSync(), isFalse);
    expect(File('${work.path}/out.partial').existsSync(), isFalse);
  });
  test('cancelRequestedBeforeStartNeverCreatesOutput', () async {
    final input = File('${work.path}/plain')..writeAsStringSync('fixture');
    final cancel = BackupCancel()..cancel();
    await expectLater(
      cipher.encrypt(
        inputPath: input.path,
        outputPath: '${work.path}/out',
        passwordUtf8: password(),
        policy: KdfPolicy(),
        cancel: cancel,
      ),
      throwsA(
        isA<BackupCipherFailure>().having(
          (e) => e.kind,
          'kind',
          BackupCipherFailureKind.cancelled,
        ),
      ),
    );
    expect(File('${work.path}/out').existsSync(), isFalse);
  });
}
