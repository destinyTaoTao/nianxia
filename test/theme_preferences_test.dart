import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/home.dart';
import 'package:nianxia/ui/settings.dart';
import 'package:nianxia/ui/theme.dart';
import 'package:nianxia/ui/common.dart';

import 'support/storage_probe.dart';
import 'support/async_storage_tester.dart';

void main() {
  late Directory root;
  late Notebook book;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('nx-theme-preferences-');
    book = await Notebook.open(root);
  });
  tearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await book.close();
      await root.delete(recursive: true);
    });
  });
  testWidgets('成功保存后的首帧直接呈现目标主题，不经过整页混色', (tester) async {
    await tester.pumpWidget(
      NianxiaApp(book: book, initialTheme: ThemeMode.dark),
    );
    await pumpStorageAndSettle(tester);
    final home = tester.widget<HomePage>(find.byType(HomePage));
    final saved = await storageRead(
      tester,
      () => Future<bool>.value(home.onTheme(ThemeMode.light)),
    );
    expect(saved, isTrue);
    await tester.pump();
    expect(
      Theme.of(tester.element(find.byType(HomePage))).scaffoldBackgroundColor,
      const Color(0xffffffff),
    );
    expect(book.themeMode, 'light');
  });
  testWidgets('目标背景色生效时，内容面板也同步到目标色', (tester) async {
    await tester.pumpWidget(
      NianxiaApp(book: book, initialTheme: ThemeMode.dark),
    );
    await pumpStorageAndSettle(tester);
    final change = tester.widget<HomePage>(find.byType(HomePage)).onTheme;
    await tester.tap(find.byTooltip('设置'));
    await pumpStorageAndSettle(tester);
    await storageRead(
      tester,
      () => Future<bool>.value(change(ThemeMode.light)),
    );
    await tester.pump();
    final physical = find.descendant(
      of: find.byType(PaperSurface).first,
      matching: find.byType(PhysicalShape),
    );
    expect(tester.widget<PhysicalShape>(physical).color, Colors.white);
    final body = find.text(
      '记录、音频、转写和查找保存在设备上，无需账号。模型下载完成后可离线记查。应用数据未声明加密；请保护设备访问权限。',
    );
    expect(
      DefaultTextStyle.of(tester.element(body)).style.color,
      const Color(0xff181818),
    );
    await pumpStorageAndSettle(tester);
  });
  testWidgets('新安装默认跟随系统，系统变化立即生效且不写成显式偏好', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    expect(
      Theme.of(tester.element(find.byType(HomePage))).brightness,
      Brightness.light,
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(
      Theme.of(tester.element(find.byType(HomePage))).brightness,
      Brightness.dark,
    );
    expect(book.themeMode, isNull);
  });
  for (final saved in ThemeMode.values) {
    testWidgets('已有${saved.name}偏好升级后保留', (tester) async {
      await storageRead(tester, () => book.saveThemeMode(saved.name));
      await tester.pumpWidget(NianxiaApp(book: book));
      await pumpStorageAndSettle(tester);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        saved,
      );
      expect(book.themeMode, saved.name);
    });
  }
  testWidgets('外观只在设置选择，同亮度的系统偏好更新也同步当前选择', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      NianxiaApp(book: book, initialTheme: ThemeMode.light),
    );
    await pumpStorageAndSettle(tester);
    final home = tester.widget<HomePage>(find.byType(HomePage));
    expect(find.byTooltip('切换深色主题'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await pumpStorageAndSettle(tester);
    await storageRead(
      tester,
      () => Future<bool>.value(home.onTheme(ThemeMode.system)),
    );
    await pumpStorageAndSettle(tester);
    final group = tester.widget<RadioGroup<ThemeMode>>(
      find.byType(RadioGroup<ThemeMode>),
    );
    expect(group.groupValue, ThemeMode.system);
    expect(find.byType(DropdownButtonFormField<ThemeMode>), findsNothing);
  });
  testWidgets('窄屏大字体可选择外观，保存中保留旧选择并阻止重复输入', (tester) async {
    tester.view.physicalSize = const Size(320, 740);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final release = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        theme: notebookTheme(Brightness.light),
        home: SettingsPage(
          book: book,
          themeMode: ThemeMode.dark,
          onTheme: (value) async {
            await release.future;
            await book.saveThemeMode(value.name);
            return true;
          },
        ),
      ),
    );
    await pumpStorageAndSettle(tester);
    final semantics = tester.ensureSemantics();
    try {
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    } finally {
      semantics.dispose();
    }
    await tester.tap(find.byKey(const Key('theme-choice-light')));
    await tester.pump();
    expect(
      tester
          .widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>))
          .groupValue,
      ThemeMode.dark,
    );
    expect(book.themeMode, isNull);
    expect(
      tester
          .widget<RadioListTile<ThemeMode>>(
            find.byKey(const Key('theme-choice-system')),
          )
          .enabled,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('theme-choice-system')));
    release.complete();
    await pumpStorageAndSettle(tester);
    expect(book.themeMode, 'light');
    expect(
      tester
          .widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>))
          .groupValue,
      ThemeMode.light,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('快速连续选择按接受顺序保存，失败不改变最后成功的偏好', (tester) async {
    await tester.pumpWidget(
      NianxiaApp(book: book, initialTheme: ThemeMode.dark),
    );
    await pumpStorageAndSettle(tester);
    final change = tester.widget<HomePage>(find.byType(HomePage)).onTheme;
    final results = await storageRead(
      tester,
      () async => Future.wait([
        Future<bool>.value(change(ThemeMode.light)),
        Future<bool>.value(change(ThemeMode.system)),
        Future<bool>.value(change(ThemeMode.dark)),
      ]),
    );
    await tester.pump();
    expect(results, everyElement(isTrue));
    expect(book.themeMode, 'dark');
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    StorageProbe(book).execute(
      "CREATE TRIGGER fail_theme19 BEFORE INSERT ON metadata WHEN NEW.key='theme_mode' BEGIN SELECT RAISE(ABORT,'theme fault'); END",
    );
    final failed = await storageRead(
      tester,
      () => Future<bool>.value(change(ThemeMode.light)),
    );
    await tester.pump();
    expect(failed, isFalse);
    expect(book.themeMode, 'dark');
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    StorageProbe(book).execute('DROP TRIGGER fail_theme19');
    await tester.pumpWidget(const SizedBox.shrink());
    await storageRead(tester, () async {
      await book.close();
      book = await Notebook.open(root);
    });
    await tester.pumpWidget(NianxiaApp(book: book));
    await pumpStorageAndSettle(tester);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });
}
