import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/recovery.dart';
import 'package:nianxia/ui/theme.dart';

import 'support/async_storage_tester.dart';

void main() {
  late Directory home;
  late Notebook book;
  late File original;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-recovery-ui-');
    book = await Notebook.open(home);
    final q = await Directory(
      '${home.path}/quarantine/11111111-1111-4111-8111-111111111111',
    ).create(recursive: true);
    original = File('${q.path}/original.bin');
    await original.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await home.delete(recursive: true);
    });
  });
  testWidgets(
    'recoveryDiscardNeedsConfirmation and cancellation preserves original',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: notebookTheme(Brightness.dark),
          home: RecoveryScreen(book: book),
        ),
      );
      await pumpStorageAndSettle(tester);
      expect(find.text('隔离片段'), findsOneWidget);
      await tester.tap(find.text('丢弃'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, original.exists), isTrue);
      await tester.tap(find.text('取消'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, original.exists), isTrue);
      await tester.tap(find.text('丢弃'));
      await pumpStorageAndSettle(tester);
      await tester.tap(find.text('确认丢弃'));
      await pumpStorageAndSettle(tester);
      expect(await storageRead(tester, original.exists), isFalse);
      expect(find.text('没有待恢复资料'), findsOneWidget);
    },
  );
  testWidgets('future journal offers export and never a discard action', (
    tester,
  ) async {
    await storageRead(tester, () async {
      await original.delete();
      await book.captures
          .marker('22222222-2222-4222-8222-222222222222')
          .writeAsString('{"nativeCaptureVersion":99}');
    });
    await tester.pumpWidget(MaterialApp(home: RecoveryScreen(book: book)));
    await pumpStorageAndSettle(tester);
    expect(find.text('无法识别的恢复标记'), findsOneWidget);
    expect(find.text('丢弃'), findsNothing);
    expect(find.text('导出原始资料'), findsOneWidget);
  });
}
