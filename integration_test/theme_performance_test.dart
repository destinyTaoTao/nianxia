import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/settings.dart';
import 'package:nianxia/ui/theme.dart';
import 'package:path/path.dart' as p;

import 'support/isolated_validation.dart';

Future<void> main() async {
  // Use production frame scheduling. LiveTest's fullyLive policy continuously
  // repaints idle views, contaminating frame counts and emulator raster timings.
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final tester = LiveWidgetController(binding);
  await requireIsolatedValidation();
  const runId = String.fromEnvironment('VALIDATION_RUN_ID');
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(runId)) {
    throw StateError('Invalid isolated run identity');
  }
  final identity = (await const MethodChannel('app.nianxia/system')
      .invokeMapMethod<String, Object?>('validationIdentity'))!;
  final root = await Directory(
    p.join(identity['cacheRoot'] as String, 'theme-performance', runId),
  ).create(recursive: true);
  final book = await Notebook.open(
    Directory(p.join(root.path, 'source')),
    clock: () => DateTime(2026, 11, 16, 10, 24),
  );
  final timings = <ui.FrameTiming>[];
  void collect(List<ui.FrameTiming> values) => timings.addAll(values);
  SchedulerBinding.instance.addTimingsCallback(collect);
  try {
    for (var i = 0; i < 100; i++) {
      await book.saveText('合成想法 $i\n先验证最短闭环，再扩大功能范围。');
    }
    await book.saveThemeMode('dark');
    runApp(NianxiaApp(book: book));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    final colors = {
      ThemeMode.light: notebookTheme(Brightness.light).scaffoldBackgroundColor,
      ThemeMode.dark: notebookTheme(Brightness.dark).scaffoldBackgroundColor,
    };
    await Future<void>.delayed(const Duration(seconds: 1));
    final idleStart = developer.Timeline.now;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final idleEnd = developer.Timeline.now;
    final samples = <Map<String, Object?>>[];
    final controls = <Map<String, Object?>>[];
    final inkControls = <Map<String, Object?>>[];
    final dropdown = find.byType(DropdownButtonFormField<ThemeMode>);
    final hasMenu = dropdown.evaluate().isNotEmpty;
    for (final scenario in ['selection', 'callback', 'same-choice']) {
      for (var i = 0; i < 30; i++) {
        final target = scenario == 'same-choice'
            ? ThemeMode.dark
            : (i.isEven ? ThemeMode.light : ThemeMode.dark);
        final field = hasMenu
            ? dropdown
            : find.byKey(Key('theme-choice-${target.name}'));
        await tester.ensureVisible(field);
        if (hasMenu && scenario != 'callback') await tester.tap(field);
        await tester.pumpAndSettle();
        final choice = hasMenu
            ? find.text(target == ThemeMode.light ? '浅色' : '深色').last
            : field;
        final began = developer.Timeline.now;
        int? firstBrightness, fullColor;
        final trace = <String, Object?>{};
        final observations = <Map<String, Object?>>[];
        Timer? poll;
        if (const bool.fromEnvironment('THEME_TIMING_TRACE')) {
          trace['lifecycle'] = binding.lifecycleState?.name;
          trace['phaseAtInput'] = binding.schedulerPhase.name;
          poll = Timer.periodic(const Duration(milliseconds: 5), (_) {
            final elapsed = developer.Timeline.now - began;
            trace['firstPollUs'] ??= elapsed;
            if (book.themeMode == target.name) {
              trace['persistedPollUs'] ??= elapsed;
            }
            final value = Theme.of(tester.element(find.byType(SettingsPage)));
            if (value.brightness ==
                (target == ThemeMode.light
                    ? Brightness.light
                    : Brightness.dark)) {
              trace['brightnessPollUs'] ??= elapsed;
              if (value.scaffoldBackgroundColor == colors[target]) {
                trace['canvasPollUs'] ??= elapsed;
              }
            }
          });
        }
        var observing = true;
        void observe(Duration _) {
          if (!observing) return;
          final theme = Theme.of(tester.element(find.byType(SettingsPage)));
          if (poll != null) {
            observations.add({
              'atUs': developer.Timeline.now - began,
              'brightness': theme.brightness.name,
            });
          }
          final expected = target == ThemeMode.light
              ? Brightness.light
              : Brightness.dark;
          if (theme.brightness == expected) {
            firstBrightness ??= developer.Timeline.now;
            if (theme.scaffoldBackgroundColor == colors[target]) {
              fullColor ??= developer.Timeline.now;
            }
          }
          if (fullColor == null) {
            binding.addPostFrameCallback(observe);
          }
        }

        binding.addPostFrameCallback(observe);
        if (scenario != 'callback') {
          await tester.tap(choice);
        } else if (!hasMenu) {
          tester
              .widget<RadioGroup<ThemeMode>>(find.byType(RadioGroup<ThemeMode>))
              .onChanged(target);
        } else {
          tester.widget<DropdownButtonFormField<ThemeMode>>(field).onChanged!(
            target,
          );
        }
        // Production scheduler renders only requested vsync frames.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
        poll?.cancel();
        observing = false;
        if (firstBrightness == null ||
            fullColor == null ||
            book.themeMode != target.name ||
            firstBrightness! > began + 600000 ||
            fullColor! > began + 600000) {
          final observed = Theme.of(tester.element(find.byType(SettingsPage)));
          await File(p.join(root.path, 'sample-failure.json')).writeAsString(
            jsonEncode({
              'scenario': scenario,
              'index': i,
              'target': target.name,
              'persisted': book.themeMode,
              'observedBrightness': observed.brightness.name,
              'observedCanvas': observed.scaffoldBackgroundColor.toARGB32(),
              'expectedCanvas': colors[target]!.toARGB32(),
              'trace': trace,
              'observations': observations,
              'brightnessUs': firstBrightness == null
                  ? null
                  : firstBrightness! - began,
              'canvasUs': fullColor == null ? null : fullColor! - began,
              'completedSamples': samples,
              'completedControls': controls,
              'capturedFrames': timings
                  .map(
                    (frame) => {
                      'startUs': frame.timestampInMicroseconds(
                        ui.FramePhase.buildStart,
                      ),
                      'buildUs': frame.buildDuration.inMicroseconds,
                      'rasterUs': frame.rasterDuration.inMicroseconds,
                      'totalUs': frame.totalSpan.inMicroseconds,
                    },
                  )
                  .toList(),
            }),
            flush: true,
          );
          throw StateError(
            'Theme did not reach persisted target in sample window',
          );
        }
        (scenario == 'selection'
                ? samples
                : scenario == 'callback'
                ? controls
                : inkControls)
            .add({
              'index': i,
              'target': target.name,
              if (trace.isNotEmpty) 'trace': trace,
              if (observations.isNotEmpty) 'observations': observations,
              'startUs': began,
              'windowEndUs': began + 600000,
              'brightnessUs': firstBrightness! - began,
              'canvasUs': fullColor! - began,
            });
        await tester.pumpAndSettle();
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    for (final sample in [...samples, ...controls, ...inkControls]) {
      final start = sample['startUs'] as int,
          end = sample['windowEndUs'] as int;
      final frames = timings.where((f) {
        final t = f.timestampInMicroseconds(ui.FramePhase.buildStart);
        return t >= start && t <= end;
      }).toList();
      if (frames.isEmpty) {
        throw StateError('No real frame timing in selection window');
      }
      sample['frames'] = frames
          .map(
            (f) => {
              'buildUs': f.buildDuration.inMicroseconds,
              'rasterUs': f.rasterDuration.inMicroseconds,
              'totalUs': f.totalSpan.inMicroseconds,
              'rasterEndOffsetUs':
                  f.timestampInMicroseconds(ui.FramePhase.rasterFinish) - start,
              'startOffsetUs':
                  f.timestampInMicroseconds(ui.FramePhase.buildStart) - start,
            },
          )
          .toList();
      sample.remove('startUs');
      sample.remove('windowEndUs');
    }
    final storageUs = <int>[], factoryUs = <int>[];
    for (var i = 0; i < 30; i++) {
      var watch = Stopwatch()..start();
      await book.saveThemeMode('dark');
      storageUs.add(watch.elapsedMicroseconds);
      watch = Stopwatch()..start();
      notebookTheme(Brightness.light);
      notebookTheme(Brightness.dark);
      factoryUs.add(watch.elapsedMicroseconds);
    }
    final data = {
      'runId': runId,
      'scheduler': 'production',
      'interaction': hasMenu ? 'dropdown' : 'inline-radio',
      'idleFrames': timings.where((f) {
        final t = f.timestampInMicroseconds(ui.FramePhase.buildStart);
        return t >= idleStart && t <= idleEnd;
      }).length,
      'profile': const bool.fromEnvironment('dart.vm.profile'),
      'release': const bool.fromEnvironment('dart.vm.product'),
      'refreshRate': binding.platformDispatcher.views.first.display.refreshRate,
      'sourceRows': 100,
      'modelTasks': 0,
      'switchCount': 30,
      'windowMs': 600,
      'samples': samples,
      'callbackControl': controls,
      'sameChoiceControl': inkControls,
      'storageOnlyUs': storageUs,
      'themePairConstructionUs': factoryUs,
    };
    await File(p.join(root.path, 'timings.json'))
        .writeAsString(jsonEncode(data), flush: true);
    await writeValidationResult(
      passed: true,
      metrics: {
        'switchCount': 30,
        'sourceRows': 100,
        'refreshRate':
            binding.platformDispatcher.views.first.display.refreshRate,
      },
    );
  } catch (_) {
    await writeValidationResult(passed: false);
    rethrow;
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(collect);
    runApp(const SizedBox.shrink());
    await tester.pump();
    await book.close();
    final source = Directory(p.join(root.path, 'source'));
    if (await source.exists()) await source.delete(recursive: true);
  }
}
