import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/domain/backup_operation.dart';

void main() {
  test('KDF policy defaults are explicit and invalid budgets fail closed', () {
    final policy = KdfPolicy();
    expect(policy.writeLogN, 18);
    expect(policy.maxReadLogN, 18);
    expect(policy.maxHeaderBytes, 65536);
    for (final n in [-1, 0, 15, 19, 30, 1000000]) {
      expect(
        () => KdfPolicy(writeLogN: n),
        throwsA(isA<BackupCipherFailure>()),
      );
      expect(
        () => KdfPolicy(maxReadLogN: n),
        throwsA(isA<BackupCipherFailure>()),
      );
    }
    expect(
      () => KdfPolicy(maxHeaderBytes: 65537),
      throwsA(isA<BackupCipherFailure>()),
    );
  });
  test(
    'cancel request remains monotonic and separate from worker completion',
    () {
      final cancel = BackupCancel();
      expect(cancel.requested, isFalse);
      cancel.cancel();
      cancel.cancel();
      expect(cancel.requested, isTrue);
    },
  );
  test('authentication message does not distinguish wrong password from corrupt ciphertext', () {
    expect(
      const BackupCipherFailure(BackupCipherFailureKind.authentication)
          .toString(),
      '密码不正确，或备份已损坏。',
    );
    expect(const BackupPasswordRequired().toString(), '此备份需要密码。');
  });
}
