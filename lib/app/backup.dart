import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'notebook.dart';
import '../data/backup_codec.dart';
import '../data/readable_export.dart';
import '../domain/backup_operation.dart';
import '../platform/backup_cipher.dart';
import 'diagnostics.dart';
import '../domain/diagnostic_event.dart';

export '../domain/restore_report.dart';
import '../domain/restore_report.dart';

class BackupService {
  BackupService(
    this.book, {
    this.cipher,
    this.diagnostics,
    Future<int?> Function(String path)? availableBytes,
  }) : availableBytes = availableBytes ?? _availableStorage;
  final Notebook book;
  final BackupCipher? cipher;
  final LocalDiagnostics? diagnostics;
  final Future<int?> Function(String path) availableBytes;
  bool _cancelled = false;
  String? _work;
  bool get cancelled => _cancelled || book.isClosed;
  set cancelled(bool value) {
    _cancelled = value;
    if (value) _signalCancel();
  }

  void _signalCancel() {
    final work = _work;
    if (work == null) return;
    try {
      File(p.join(work, 'cancel')).writeAsStringSync('cancel');
    } on FileSystemException {
      /* Commit guard remains authoritative. */
    }
  }

  static final _busy = Expando<bool>();
  // Frozen legacy-reader budgets. Version 2 has bounded chunks and entries,
  // rather than a whole-library size or record-count limit.
  static const maxBytes = 512 * 1024 * 1024;
  static const maxRecords = 10000;
  static Future<int?> _availableStorage(String path) async {
    try {
      return await const MethodChannel('app.nianxia/system')
          .invokeMethod<int>('availableStorageBytes', {'path': path});
    } on MissingPluginException {
      return null;
    }
  }

  void _check() {
    if (cancelled) throw const NotebookException('操作已取消，原有记录保持不变。');
  }

  Future<void> _space(int needed) async {
    final free = await availableBytes(book.home.path);
    if (free != null && free < needed) {
      throw const NotebookException('可用空间不足，请释放空间后重试。原有记录保持不变。');
    }
  }

  Future<T> _exclusive<T>(
    Future<T> Function() work, {
    DiagnosticKind kind = DiagnosticKind.backup,
  }) async {
    if (_busy[book] == true) throw const NotebookException('已有备份操作正在执行。');
    _busy[book] = true;
    _cancelled = false;
    final cancellation = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (cancelled) _signalCancel();
    });
    try {
      Future<T> action() => book.withMediaLease(work);
      return await (diagnostics?.trace(kind, action) ?? action());
    } on NotebookException {
      rethrow;
    } on BackupCipherFailure {
      rethrow;
    } on BackupPasswordRequired {
      rethrow;
    } catch (_) {
      throw const NotebookException('备份无效、损坏或空间不足，原有记录保持不变。');
    } finally {
      cancellation.cancel();
      _work = null;
      _busy[book] = false;
    }
  }

  Future<int> _worker(
    String work,
    List<String> arguments,
    void Function(double)? progress,
  ) async {
    final updates = ReceivePort();
    Object? progressError;
    StackTrace? progressStack;
    final subscription = updates.listen((value) {
      if (progressError != null) return;
      try {
        progress?.call(value as double);
      } catch (error, stack) {
        progressError = error;
        progressStack = stack;
      }
    });
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (cancelled || progressError != null) {
        try {
          File(p.join(work, 'cancel')).writeAsStringSync('cancel');
        } on FileSystemException {
          // A full/blocked staging directory cannot turn cancellation into an
          // unhandled timer error. The final commit guard remains authoritative.
        }
      }
    });
    try {
      final result = await (arguments.first == 'readable'
          ? runReadableExport(arguments, updates.sendPort)
          : runBackupCodec(arguments, updates.sendPort));
      await Future<void>.delayed(Duration.zero);
      final error = progressError;
      if (error != null) Error.throwWithStackTrace(error, progressStack!);
      _check();
      return result;
    } finally {
      timer.cancel();
      await subscription.cancel();
      updates.close();
    }
  }

  Future<File> export({void Function(double)? progress}) =>
      _exclusive(() => _exportPlain(progress));

  Future<File> _exportPlain(
    void Function(double)? progress, {
    bool reserveCipher = false,
    bool readable = false,
  }) async {
    final exports = await Directory(p.join(book.home.path, 'exports'))
        .create(recursive: true);
    final work = await exports.createTemp('backup-');
    final output = File(
      p.join(exports.path, 'nianxia-${const Uuid().v4()}.zip'),
    );
    try {
      await _space(32 * 1024 * 1024);
      final snapshot = p.join(work.path, 'snapshot.sqlite');
      _work = work.path;
      await book.repository.snapshotTo(snapshot);
      final home = book.home.path, workPath = work.path;
      final estimated = await estimateBackupSpace(snapshot, home);
      await _space(
        reserveCipher ? estimated * 2 + 32 * 1024 * 1024 : estimated,
      );
      _check();
      final partial = p.join(work.path, 'backup.partial');
      await _worker(workPath, [
        readable ? 'readable' : 'encode',
        snapshot,
        home,
        workPath,
        partial,
      ], progress);
      _check();
      return await File(partial).rename(output.path);
    } finally {
      // No cancellable worker remains. Stop writing the cancel marker
      // before recursive deletion can enumerate/remove this directory.
      _work = null;
      await _cleanWork(work);
    }
  }

  Future<File> exportReadable({void Function(double)? progress}) =>
      _exclusive(() => _exportPlain(progress, readable: true));

  Future<void> _convertCipher(
    String input,
    String output,
    Uint8List password, {
    required bool encrypt,
    void Function(double)? progress,
  }) async {
    final adapter = cipher;
    if (adapter == null) throw const NotebookException('密码备份适配器尚未完成验收。');
    _check();
    final cancel = BackupCancel();
    final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (cancelled) cancel.cancel();
    });
    try {
      if (encrypt) {
        await adapter.encrypt(
          inputPath: input,
          outputPath: output,
          passwordUtf8: password,
          policy: KdfPolicy(),
          cancel: cancel,
          progress: progress,
        );
      } else {
        await adapter.decrypt(
          inputPath: input,
          outputPath: output,
          passwordUtf8: password,
          policy: KdfPolicy(),
          cancel: cancel,
          progress: progress,
        );
      }
    } finally {
      timer.cancel();
    }
    _check();
  }

  Future<File> exportEncrypted({
    required Uint8List passwordUtf8,
    void Function(double)? progress,
  }) => _exclusive(() async {
    if (cipher == null) throw const NotebookException('密码备份适配器尚未完成验收。');
    final plain = await _exportPlain(
      progress == null ? null : (v) => progress(v * .5),
      reserveCipher: true,
    );
    Directory? work;
    try {
      work = await plain.parent.createTemp('encrypted-');
      _work = work.path;
      final encrypted = p.join(work.path, 'archive.age');
      await _convertCipher(
        plain.path,
        encrypted,
        passwordUtf8,
        encrypt: true,
        progress: progress == null ? null : (v) => progress(.5 + v * .5),
      );
      _check();
      return await File(encrypted).rename(
        p.join(plain.parent.path, 'nianxia-${const Uuid().v4()}.zip.age'),
      );
    } finally {
      _work = null;
      try {
        await plain.delete();
      } on FileSystemException {
        book.recoveryWarnings++;
      }
      if (work != null) await _cleanWork(work);
    }
  });

  Future<RestoreReport> restore(
    File source, {
    Uint8List? passwordUtf8,
    void Function(double)? progress,
  }) => _exclusive(() async {
    final imports = await Directory(p.join(book.home.path, 'imports'))
        .create(recursive: true);
    final work = await imports.createTemp('restore-');
    _work = work.path;
    try {
      var payload = source;
      final handle = await source.open();
      final bool encrypted;
      try {
        encrypted = String.fromCharCodes(await handle.read(20))
            .startsWith('age-encryption.org/');
      } finally {
        await handle.close();
      }
      await _space(
        await source.length() * (encrypted ? 12 : 3) + 64 * 1024 * 1024,
      );
      if (encrypted) {
        if (passwordUtf8 == null) throw const BackupPasswordRequired();
        final copy = await source.copy(
          p.join(work.path, 'encrypted-input.age'),
        );
        payload = File(p.join(work.path, 'authenticated.zip'));
        await _convertCipher(
          copy.path,
          payload.path,
          passwordUtf8,
          encrypt: false,
        );
        _check();
      }
      await _worker(work.path, [
        'decode',
        payload.path,
        work.path,
      ], progress == null ? null : (value) => progress(value * 0.5));
      _check();
      await book.repository.prepareRestore(
        work.path,
        progress: (value) {
          try {
            progress?.call(0.5 + value * 0.5);
          } catch (_) {
            cancelled = true;
            rethrow;
          }
        },
      );
      // Deliver progress/cancellation before granting the worker permission to
      // enter the final atomic transaction. After COMMIT a late cancel cannot
      // turn a successful restore into an apparent rollback.
      progress?.call(1);
      await Future<void>.delayed(Duration.zero);
      _check();
      final report = await book.repository.mergeRestore(work.path);
      book.changed();
      return report;
    } finally {
      _work = null;
      if (await File(p.join(work.path, 'incoming.sqlite')).exists()) {
        try {
          book.recoveryWarnings += await book.repository.cleanupRestore(
            work.path,
          );
        } catch (_) {
          book.recoveryWarnings++;
        }
      }
      await _cleanWork(work);
    }
  }, kind: DiagnosticKind.restore);
  Future<void> _cleanWork(Directory work) async {
    try {
      await work.delete(recursive: true);
    } on FileSystemException {
      // Keep a valid committed archive/import successful; startup retries the
      // task-owned directory cleanup without resetting the original notebook.
      book.recoveryWarnings++;
    }
  }
}
