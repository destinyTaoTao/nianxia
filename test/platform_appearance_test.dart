import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/platform/appearance.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/capture_session_controller.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/native_recorder.dart';
import 'package:nianxia/ui/theme.dart';

import 'support/ui_native_capture.dart';
import 'support/async_storage_tester.dart';

import 'package:nianxia/ui/platform_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('appearance-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'reducedTransparencyForcesOpaqueSurface and unverified glass stays opaque',
    () {
      const value = PlatformAppearance(
        reduceTransparency: true,
        glassSupported: true,
      );
      expect(value.allowsGlass, isFalse);
      expect(
        const PlatformAppearance(glassSupported: false).allowsGlass,
        isFalse,
      );
      expect(
        const PlatformAppearance(
          increaseContrast: true,
          glassSupported: true,
        ).allowsGlass,
        isFalse,
      );
    },
  );

  testWidgets(
    'iosReduceMotionIndependentOfDisableAnimations updates system preference',
    (tester) async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'reduceMotion': true,
          'reduceTransparency': true,
          'increaseContrast': false,
          'glassSupported': false,
        },
      );
      final adapter = PlatformAppearanceAdapter(
        platform: TargetPlatform.iOS,
        channel: channel,
      );
      await adapter.start();
      addTearDown(adapter.dispose);
      expect(adapter.value.reduceMotion, isTrue);
      await tester.pumpWidget(
        MaterialApp(
          home: AppearanceScope(
            appearance: adapter.value,
            child: Builder(
              builder: (context) =>
                  Text('${PlatformControls.reduceMotion(context)}'),
            ),
          ),
        ),
      );
      expect(find.text('true'), findsOneWidget);
      expect(
        tester.platformDispatcher.accessibilityFeatures.disableAnimations,
        isFalse,
      );
      var changes = 0;
      adapter.addListener(() => changes++);
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', {
            'reduceMotion': false,
            'reduceTransparency': false,
            'increaseContrast': true,
            'glassSupported': false,
          }),
        ),
        (_) {},
      );
      expect(adapter.value.reduceMotion, isFalse);
      expect(adapter.value.increaseContrast, isTrue);
      expect(changes, 1);
    },
  );

  testWidgets('oldIosRetainsActions with opaque operation surface', (
    tester,
  ) async {
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppearanceScope(
          appearance: const PlatformAppearance(),
          child: Builder(
            builder: (context) => PlatformControls.operationSurface(
              context,
              FilledButton(
                onPressed: () => stops++,
                child: const Text('停止并保存'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('opaque-operation-surface')), findsOneWidget);
    await tester.tap(find.text('停止并保存'));
    expect(stops, 1);
  });

  test('malformed preference data retains conservative fallback', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'reduceMotion': 'yes'},
    );
    final adapter = PlatformAppearanceAdapter(
      platform: TargetPlatform.iOS,
      channel: channel,
    );
    await adapter.start();
    expect(adapter.value.glassSupported, isFalse);
    expect(adapter.value.reduceTransparency, isTrue);
    adapter.dispose();
  });
  testWidgets('largeTextKeepsStopReachable on a narrow viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() async {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.binding.setSurfaceSize(null);
    });
    final home = await tester.runAsync(
      () => Directory.systemTemp.createTemp('nx-appearance-'),
    );
    final book = (await tester.runAsync(() => Notebook.open(home!)))!;
    final runtime = UiCaptureRuntime();
    final capture = CaptureSessionController(
      UiCaptureEndpoint(book),
      book,
      runtime,
    );
    addTearDown(() async {
      capture.dispose();
      runtime.dispose();
      await tester.runAsync(() async {
        await book.close();
        await home!.delete(recursive: true);
      });
    });
    await tester.pumpWidget(NianxiaApp(book: book, captureSession: capture));
    await pumpStorageAndSettle(tester);
    await tester.tap(find.text('记一下'));
    await pumpStorageAndSettle(tester);
    expect(find.byType(NativeRecorderPanel), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('停止并保存'));
    await tester.pumpAndSettle();
    final stop = find.widgetWithText(FilledButton, '停止并保存');
    expect(tester.getSize(stop).height, greaterThanOrEqualTo(48));
    await tester.tap(stop);
    for (var i = 0; i < 100 && capture.savedId == null; i++) {
      await pumpStorageAndSettle(tester);
    }
    expect(capture.savedId, isNotNull);
    await tester.pumpWidget(const SizedBox());
    await pumpStorageAndSettle(tester);
  });
  test(
    'a late initial snapshot cannot overwrite a newer preference change',
    () async {
      final initial = Completer<Object?>();
      final entered = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (_) {
        entered.complete();
        return initial.future;
      });
      final adapter = PlatformAppearanceAdapter(
        platform: TargetPlatform.iOS,
        channel: channel,
      );
      final starting = adapter.start();
      await entered.future;
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', {
            'reduceMotion': true,
            'reduceTransparency': true,
            'increaseContrast': true,
            'glassSupported': false,
          }),
        ),
        (_) {},
      );
      initial.complete({
        'reduceMotion': false,
        'reduceTransparency': false,
        'increaseContrast': false,
        'glassSupported': false,
      });
      await starting;
      expect(adapter.value.reduceMotion, isTrue);
      expect(adapter.value.increaseContrast, isTrue);
      adapter.dispose();
    },
  );

  testWidgets(
    'native preferences update root media and transitions without remount',
    (tester) async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'reduceMotion': true,
          'reduceTransparency': true,
          'increaseContrast': false,
          'glassSupported': false,
        },
      );
      final adapter = PlatformAppearanceAdapter(
        platform: TargetPlatform.iOS,
        channel: channel,
      );
      await adapter.start();
      final home = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('nx-native-appearance-'),
      ))!;
      final book = (await tester.runAsync(() => Notebook.open(home)))!;
      addTearDown(() async {
        adapter.dispose();
        await tester.runAsync(() async {
          await book.close();
          await home.delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        NianxiaApp(book: book, appearanceAdapter: adapter),
      );
      await pumpStorageAndSettle(tester);
      expect(
        tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .themeAnimationDuration,
        Duration.zero,
      );
      final context = tester.element(find.text('记一下'));
      expect(MediaQuery.of(context).disableAnimations, isTrue);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      expect(
        PlatformControls.animationStyle(context),
        AnimationStyle.noAnimation,
      );
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', {
            'reduceMotion': false,
            'reduceTransparency': false,
            'increaseContrast': true,
            'glassSupported': false,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(MediaQuery.of(context).disableAnimations, isFalse);
      expect(MediaQuery.of(context).highContrast, isTrue);
      expect(
        Theme.of(context).colorScheme.onSurfaceVariant,
        const Color(0xffd4d4d4),
      );
      await tester.pumpWidget(const SizedBox());
      await pumpStorageAndSettle(tester);
    },
  );
  test('body and helper token contrast reaches 4.5 in both themes', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
    }

    for (final brightness in Brightness.values) {
      for (final high in [false, true]) {
        final theme = notebookTheme(brightness, highContrast: high);
        for (final surface in [
          theme.scaffoldBackgroundColor,
          theme.colorScheme.surfaceContainer,
        ]) {
          expect(
            contrast(theme.colorScheme.onSurface, surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(theme.colorScheme.onSurfaceVariant, surface),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    }
  });
}
