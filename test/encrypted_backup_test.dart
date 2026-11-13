import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';
import 'package:nianxia/domain/backup_operation.dart';
import 'package:nianxia/platform/backup_cipher.dart';

class ControlledCipher implements BackupCipher {
  BackupCipherFailure? failure;
  int decryptions = 0;
  Completer<void>? started, release;
  @override
  Future<void> encrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  }) async {
    await File(outputPath).writeAsBytes([
      ...('age-encryption.org/v1\n').codeUnits,
      ...await File(inputPath).readAsBytes(),
    ]);
  }

  @override
  Future<void> decrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  }) async {
    decryptions++;
    started?.complete();
    if (release != null) await release!.future;
    if (cancel.requested) {
      throw const BackupCipherFailure(BackupCipherFailureKind.cancelled);
    }
    if (failure != null) throw failure!;
    final data = await File(inputPath).readAsBytes();
    await File(outputPath)
        .writeAsBytes(data.sublist('age-encryption.org/v1\n'.length));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home, other;
  late Notebook book, source;
  late ControlledCipher cipher;
  final password = Uint8List.fromList([112, 119]);
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-encrypted-');
    other = await Directory.systemTemp.createTemp('nx-encrypted-source-');
    book = await Notebook.open(home);
    source = await Notebook.open(other);
    cipher = ControlledCipher();
  });
  tearDown(() async {
    await book.close();
    await source.close();
    await home.delete(recursive: true);
    await other.delete(recursive: true);
  });
  test(
    'authFailureDoesNotOpenRestoreTransaction and no plain ZIP fallback',
    () async {
      final original = await book.saveText('existing synthetic');
      await source.saveText('incoming synthetic');
      final archive = await BackupService(
        source,
        cipher: cipher,
      ).exportEncrypted(passwordUtf8: password);
      cipher.failure = const BackupCipherFailure(
        BackupCipherFailureKind.authentication,
      );
      await expectLater(
        BackupService(
          book,
          cipher: cipher,
        ).restore(archive, passwordUtf8: password),
        throwsA(isA<BackupCipherFailure>()),
      );
      expect((await book.records).map((r) => r.canonical), [
        original.canonical,
      ]);
      expect(cipher.decryptions, 1);
    },
  );
  test(
    'magic determines encrypted input and missing password remains typed',
    () async {
      await source.saveText('fixture');
      final archive = await BackupService(
        source,
        cipher: cipher,
      ).exportEncrypted(passwordUtf8: password);
      final renamed = await archive.rename('${archive.path}.unknown');
      await expectLater(
        BackupService(book, cipher: cipher).restore(renamed),
        throwsA(isA<BackupPasswordRequired>()),
      );
      expect(cipher.decryptions, 0);
      expect(
        (await BackupService(
          book,
          cipher: cipher,
        ).restore(renamed, passwordUtf8: password)).added,
        1,
      );
    },
  );
  test(
    'cancelBeforeFinalNeverMerges and cleanup waits for worker join',
    () async {
      await source.saveText('fixture');
      final archive = await BackupService(
        source,
        cipher: cipher,
      ).exportEncrypted(passwordUtf8: password);
      cipher.started = Completer();
      cipher.release = Completer();
      final service = BackupService(book, cipher: cipher);
      var finished = false;
      final operation = service
          .restore(archive, passwordUtf8: password)
          .whenComplete(() => finished = true);
      final assertion = expectLater(
        operation,
        throwsA(isA<BackupCipherFailure>()),
      );
      await cipher.started!.future;
      service.cancelled = true;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(finished, isFalse);
      expect(await Directory('${home.path}/imports').list().isEmpty, isFalse);
      cipher.release!.complete();
      await assertion;
      expect(await book.records, isEmpty);
      expect(await Directory('${home.path}/imports').list().isEmpty, isTrue);
    },
  );
  test('lateCancelAfterCommitReportsSuccess', () async {
    await source.saveText('fixture');
    final archive = await BackupService(
      source,
      cipher: cipher,
    ).exportEncrypted(passwordUtf8: password);
    final service = BackupService(book, cipher: cipher);
    book.addListener(() => service.cancelled = true);
    expect((await service.restore(archive, passwordUtf8: password)).added, 1);
    expect((await book.records).length, 1);
  });
  test(
    'encrypted export reserves both ZIP and cipher before conversion',
    () async {
      await source.saveText('fixture');
      var checks = 0;
      final service = BackupService(
        source,
        cipher: cipher,
        availableBytes: (_) async {
          checks++;
          return checks == 1 ? 1000000000 : 50 * 1024 * 1024;
        },
      );
      await expectLater(
        service.exportEncrypted(passwordUtf8: password),
        throwsA(isA<NotebookException>()),
      );
      expect(checks, greaterThanOrEqualTo(2));
      expect((await source.records).length, 1);
    },
  );
}
