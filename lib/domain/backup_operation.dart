enum BackupCipherFailureKind {
  authentication,
  resourceLimit,
  invalidContainer,
  cancelled,
  ioFailure,
}

class BackupCipherFailure implements Exception {
  const BackupCipherFailure(this.kind);
  final BackupCipherFailureKind kind;
  @override
  String toString() => kind == BackupCipherFailureKind.authentication
      ? '密码不正确，或备份已损坏。'
      : '备份处理失败（${kind.name}）。';
}

class BackupPasswordRequired implements Exception {
  const BackupPasswordRequired();
  @override
  String toString() => '此备份需要密码。';
}

class KdfPolicy {
  KdfPolicy({
    this.writeLogN = 18,
    this.maxReadLogN = 18,
    this.maxHeaderBytes = 65536,
  }) {
    if (writeLogN < 16 ||
        writeLogN > 18 ||
        maxReadLogN < 16 ||
        maxReadLogN > 18 ||
        maxHeaderBytes < 128 ||
        maxHeaderBytes > 65536) {
      throw const BackupCipherFailure(BackupCipherFailureKind.resourceLimit);
    }
  }
  final int writeLogN;
  final int maxReadLogN;
  final int maxHeaderBytes;
}

/// A request is monotonic. Completion waits for the worker, including an ongoing KDF.
class BackupCancel {
  bool _requested = false;
  bool get requested => _requested;
  void cancel() => _requested = true;
}
