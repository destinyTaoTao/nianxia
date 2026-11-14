import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart' show XFile;
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/domain/backup_operation.dart';
import 'package:nianxia/domain/diagnostic_event.dart';
import 'package:nianxia/ui/settings.dart';
import 'package:nianxia/ui/backup_password.dart';

import 'encrypted_backup_test.dart' show ControlledCipher;
import 'settings_test.dart' show ControlledPicker;
import 'support/async_storage_tester.dart';

final class _Picked extends PlatformFile {
  _Picked(this.file);
  final File file;
  @override
  String get name => 'renamed.backup';
  @override
  Uri get uri => Uri.file(file.path);
  @override
  XFile get xFile => XFile(file.path);
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class _Cipher extends ControlledCipher {
  List<int>? seen;
  @override
  Future<void> decrypt({
    required String inputPath,
    required String outputPath,
    required Uint8List passwordUtf8,
    required KdfPolicy policy,
    required BackupCancel cancel,
    void Function(double)? progress,
  }) {
    seen = List.of(passwordUtf8);
    return super.decrypt(
      inputPath: inputPath,
      outputPath: outputPath,
      passwordUtf8: passwordUtf8,
      policy: policy,
      cancel: cancel,
      progress: progress,
    );
  }
}

void main() {
  late Directory home;
  late Notebook book;
  late Notebook source;
  late FilePickerPlatform old;
  late ControlledPicker picker;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-password-ui-');
    book = await Notebook.open(home);
    source = await Notebook.open(Directory('${home.path}/source'));
    old = FilePickerPlatform.instance;
    picker = ControlledPicker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() async {
    FilePickerPlatform.instance = old;
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await source.close();
      await book.close();
      await home.delete(recursive: true);
    });
  });
  testWidgets(
    'restoreNeedsPasswordAndShowsConflictSummary without trimming password',
    (tester) async {
      const password = '  密码 AbC123中文+  ';
      final cipher = _Cipher();
      late File archive;
      await storageRead(tester, () async {
        final original = await book.saveText('synthetic original retained');
        await source.repository.insert(
          Record.fromJson({
            ...original.toJson(),
            'body': 'synthetic incoming conflict',
          }),
        );
        archive = await BackupService(source, cipher: cipher).exportEncrypted(
          passwordUtf8: Uint8List.fromList(utf8.encode(password)),
        );
      });
      picker.select = () async => _Picked(archive);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            book: book,
            themeMode: ThemeMode.dark,
            onTheme: (_) async => true,
            backupService: BackupService(book, cipher: cipher),
          ),
        ),
      );
      await pumpStorageAndSettle(tester);
      await tester.scrollUntilVisible(
        find.text('恢复备份'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('恢复备份'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('恢复备份'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('选择备份'));
      for (
        var i = 0;
        i < 60 && find.byKey(const Key('backup-password')).evaluate().isEmpty;
        i++
      ) {
        await pumpStorageAndSettle(tester);
      }
      expect(find.byKey(const Key('backup-password')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('backup-password')),
        password,
      );
      await tester.tap(find.text('继续恢复'));
      for (var i = 0; i < 90; i++) {
        await pumpStorageAndSettle(tester);
        if (find.textContaining('恢复完成：').evaluate().isNotEmpty) break;
      }
      expect(find.textContaining('冲突 1'), findsOneWidget);
      expect(cipher.seen, utf8.encode(password));
      expect((await storageRead(tester, () => book.records)).length, 2);
    },
  );
  testWidgets('diagnostic export requires content preview before sharing', (
    tester,
  ) async {
    final diag = LocalDiagnostics(Directory('${home.path}/diagnostics'));
    addTearDown(diag.close);
    await storageRead(
      tester,
      () => diag.record(
        DiagnosticEvent(
          kind: DiagnosticKind.backup,
          phase: DiagnosticPhase.finalize,
          result: DiagnosticResult.succeeded,
        ),
      ),
    );
    var shares = 0;
    const channel = MethodChannel('dev.fluttercommunity.plus/share');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async {
      shares++;
      return '';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(
          book: book,
          themeMode: ThemeMode.dark,
          onTheme: (_) async => true,
          diagnostics: diag,
        ),
      ),
    );
    await pumpStorageAndSettle(tester);
    await tester.scrollUntilVisible(
      find.text('预览诊断导出'),
      350,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('预览诊断导出'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('预览诊断导出'));
    await pumpStorageAndSettle(tester);
    expect(find.textContaining('不包含正文、查询、音频、密钥或密码'), findsOneWidget);
    expect(shares, 0);
    expect(find.textContaining('阶段与耗时'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await pumpStorageAndSettle(tester);
    expect(shares, 0);
  });
  testWidgets('new backup password confirms exact text and rejects mismatch', (
    tester,
  ) async {
    Uint8List? accepted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              accepted = await requestBackupPassword(context, creating: true);
            },
            child: const Text('start'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('start'));
    await pumpStorageAndSettle(tester);
    await tester.enterText(
      find.byKey(const Key('backup-password')),
      '  密码 AbC123中文+  ',
    );
    await tester.enterText(
      find.byKey(const Key('backup-password-confirmation')),
      'different password',
    );
    await tester.tap(find.text('生成密码备份'));
    await pumpStorageAndSettle(tester);
    expect(find.text('两次密码不一致，请重新确认。'), findsOneWidget);
    expect(accepted, isNull);
    await tester.enterText(
      find.byKey(const Key('backup-password-confirmation')),
      '  密码 AbC123中文+  ',
    );
    await tester.tap(find.text('生成密码备份'));
    await pumpStorageAndSettle(tester);
    expect(accepted, utf8.encode('  密码 AbC123中文+  '));
    accepted?.fillRange(0, accepted!.length, 0);
  });
  testWidgets(
    'cancelBeforePickerReturns never begins restore after selection arrives',
    (tester) async {
      late File archive;
      await storageRead(tester, () async {
        await book.saveText('synthetic retained');
        await source.saveText('synthetic incoming');
        archive = await BackupService(source).export();
      });
      final selection = Completer<PlatformFile?>();
      picker.select = () => selection.future;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(
            book: book,
            themeMode: ThemeMode.dark,
            onTheme: (_) async => true,
          ),
        ),
      );
      await pumpStorageAndSettle(tester);
      await tester.scrollUntilVisible(
        find.text('恢复备份'),
        350,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('恢复备份'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('恢复备份'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('选择备份'));
      await tester.pump();
      await tester.ensureVisible(find.text('取消操作'));
      await tester.pump();
      await tester.tap(find.text('取消操作'));
      await tester.pump();
      selection.complete(_Picked(archive));
      for (var i = 0; i < 60; i++) {
        await pumpStorageAndSettle(tester);
        if (find.text('取消操作').evaluate().isEmpty) break;
      }
      expect((await storageRead(tester, () => book.records)).length, 1);
      expect(find.textContaining('已取消恢复'), findsOneWidget);
    },
  );
}
