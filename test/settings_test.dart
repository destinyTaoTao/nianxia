import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';

import 'support/async_storage_tester.dart';

class ControlledPicker extends FilePickerPlatform {
  Future<PlatformFile?> Function() select = () async => null;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) => select();
}

void main() {
  late Directory home;
  late Notebook book;
  late FilePickerPlatform originalPicker;
  late ControlledPicker picker;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-settings-');
    book = await Notebook.open(home);
    await book.saveText('必须保留的内容');
    originalPicker = FilePickerPlatform.instance;
    picker = ControlledPicker();
    FilePickerPlatform.instance = picker;
  });
  tearDown(() async {
    FilePickerPlatform.instance = originalPicker;
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });

  Future<void> openRestore(WidgetTester tester) async {
    await tester.tap(find.text('恢复备份'));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('选择备份'));
    await tester.pump();
  }

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.byTooltip('设置'));
    await pumpStorageAndSettle(tester);
    await tester.scrollUntilVisible(
      find.text('恢复备份'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }

  testWidgets('选取备份失败有明确反馈，可重试并取消，已有记录不变', (tester) async {
    picker.select = () async => throw PlatformException(code: 'picker_failed');
    await launch(tester);
    await openRestore(tester);
    await pumpStorageAndSettle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('操作失败，请检查权限'), findsOneWidget);
    picker.select = () async => null;
    await openRestore(tester);
    await pumpStorageAndSettle(tester);
    expect(find.text('已取消选择备份'), findsOneWidget);
    expect(
      (await storageRead(tester, () => book.records)).single.body,
      '必须保留的内容',
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '恢复备份'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('等待系统选取备份时禁止重复恢复和导出，取消后可继续操作', (tester) async {
    final selection = Completer<PlatformFile?>();
    picker.select = () => selection.future;
    await launch(tester);
    await openRestore(tester);
    await tester.pump(const Duration(milliseconds: 400));
    for (final label in ['恢复备份', '完整备份（未加密）']) {
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, label))
            .onPressed,
        isNull,
      );
    }
    selection.complete(null);
    await pumpStorageAndSettle(tester);
    expect(find.text('已取消选择备份'), findsOneWidget);
    expect(
      (await storageRead(tester, () => book.records)).single.body,
      '必须保留的内容',
    );
  });
}
