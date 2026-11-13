// Experimental adapter. No production constructor imports this library.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:nianxia/domain/backup_operation.dart';
import 'package:nianxia/platform/backup_cipher.dart';

typedef _CreateC = Uint64 Function(
  Pointer<Uint8>,
  UintPtr,
  Pointer<Uint8>,
  UintPtr,
  Pointer<Uint8>,
  UintPtr,
  Uint8,
  Uint8,
  Uint8,
  UintPtr,
);
typedef _Create = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  int,
  int,
  int,
  int,
);

class _Bindings {
  _Bindings(String path) : library = DynamicLibrary.open(path);
  final DynamicLibrary library;
  late final alloc = library
      .lookupFunction<
        Pointer<Uint8> Function(UintPtr),
        Pointer<Uint8> Function(int)
      >('nx_age_alloc');
  late final release = library
      .lookupFunction<
        Void Function(Pointer<Uint8>, UintPtr),
        void Function(Pointer<Uint8>, int)
      >('nx_age_release');
  late final create = library.lookupFunction<_CreateC, _Create>(
    'nx_age_create',
  );
  late final run = library
      .lookupFunction<Int32 Function(Uint64), int Function(int)>('nx_age_run');
  late final cancel = library
      .lookupFunction<Void Function(Uint64), void Function(int)>(
        'nx_age_cancel',
      );
  late final free = library
      .lookupFunction<Int32 Function(Uint64), int Function(int)>('nx_age_free');
  late final bytes = library
      .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
        'nx_age_bytes',
      );
  late final kdf = library
      .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
        'nx_age_kdf_started',
      );
  late final stage = library
      .lookupFunction<Uint64 Function(Uint64), int Function(int)>(
        'nx_age_stage',
      );
}

int _run(String path, int handle) => _Bindings(path).run(handle);
Future<int> _runWorker(String path, int handle) =>
    Isolate.run(() => _run(path, handle));

class AgeCipherSpike implements BackupCipher {
  AgeCipherSpike(this.libraryPath);
  final String libraryPath;
  int lastKdfStarted = 0;
  int lastProcessedBytes = 0;
  int lastNativeStage = 0;
  @override
  Future<void> encrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  }) => _convert(
    inputPath,
    outputPath,
    passwordUtf8,
    policy,
    cancel,
    true,
    progress,
  );
  @override
  Future<void> decrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  }) => _convert(
    inputPath,
    outputPath,
    passwordUtf8,
    policy,
    cancel,
    false,
    progress,
  );
  Future<void> _convert(
    String input,
    String output,
    Uint8List password,
    KdfPolicy policy,
    BackupCancel cancellation,
    bool encrypt,
    void Function(double)? progress,
  ) async {
    if (cancellation.requested) {
      throw const BackupCipherFailure(BackupCipherFailureKind.cancelled);
    }
    if (password.isEmpty || password.length > 4096) {
      throw const BackupCipherFailure(BackupCipherFailureKind.invalidContainer);
    }
    final int total;
    final _Bindings api;
    try {
      total = await File(input).length();
      api = _Bindings(libraryPath);
    } catch (_) {
      throw const BackupCipherFailure(BackupCipherFailureKind.ioFailure);
    }
    final values = <List<int>>[
      utf8.encode(input),
      utf8.encode(output),
      password,
    ];
    final pointers = <Pointer<Uint8>>[];
    var handle = 0;
    try {
      for (final value in values) {
        final ptr = api.alloc(value.length);
        if (ptr == nullptr) {
          throw const BackupCipherFailure(
            BackupCipherFailureKind.resourceLimit,
          );
        }
        pointers.add(ptr);
        ptr.asTypedList(value.length).setAll(0, value);
      }
      handle = api.create(
        pointers[0],
        values[0].length,
        pointers[1],
        values[1].length,
        pointers[2],
        password.length,
        encrypt ? 1 : 0,
        policy.writeLogN,
        policy.maxReadLogN,
        policy.maxHeaderBytes,
      );
    } finally {
      for (var i = 0; i < pointers.length; i++) {
        api.release(pointers[i], values[i].length);
      }
    }
    if (handle == 0) {
      throw const BackupCipherFailure(BackupCipherFailureKind.invalidContainer);
    }
    final library = libraryPath;
    final operation = handle;
    final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (cancellation.requested) api.cancel(operation);
      try {
        progress?.call(
          total == 0 ? 0 : (api.bytes(operation) / total).clamp(0, .99),
        );
      } catch (_) {
        cancellation.cancel();
        api.cancel(operation);
      }
    });
    try {
      if (cancellation.requested) api.cancel(handle);
      final code = await _runWorker(library, operation);
      lastKdfStarted = api.kdf(handle);
      lastNativeStage = api.stage(handle);
      lastProcessedBytes = api.bytes(handle);
      if (code != 0) {
        final kind = switch (code) {
          1 => BackupCipherFailureKind.authentication,
          2 => BackupCipherFailureKind.resourceLimit,
          3 => BackupCipherFailureKind.invalidContainer,
          4 => BackupCipherFailureKind.cancelled,
          _ => BackupCipherFailureKind.ioFailure,
        };
        throw BackupCipherFailure(kind);
      }
      try {
        progress?.call(1);
      } catch (_) {
        /* Notification cannot undo a published output. */
      }
    } finally {
      timer.cancel();
      // Await above is the join: free must never race a worker still using the handle.
      if (api.free(handle) != 0) {
        throw const BackupCipherFailure(BackupCipherFailureKind.ioFailure);
      }
    }
  }
}
