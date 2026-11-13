import 'dart:typed_data';

import '../domain/backup_operation.dart';

/// Success means a complete authenticated container was consumed or finalized.
/// Implementations own their partial output; failure must never publish it.
abstract interface class BackupCipher {
  Future<void> encrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  });
  Future<void> decrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  });
}
