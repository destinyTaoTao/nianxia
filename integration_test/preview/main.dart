// Hands-on product composition; intentionally has no testWidgets/test driver.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/app/diagnostics.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:nianxia/ui/app.dart';

import '../support/isolated_validation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await requireIsolatedValidation();
    const runId = String.fromEnvironment('UI_PREVIEW_RUN_ID');
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(runId)) {
      throw StateError('Missing isolated preview identity');
    }
    final identity = (await const MethodChannel('app.nianxia/system')
        .invokeMapMethod<String, Object?>('validationIdentity'))!;
    final root = Directory(
      p.join(identity['cacheRoot'] as String, 'continuous-preview', runId),
    );
    final diagnostics = LocalDiagnostics(
      Directory(p.join(root.path, 'diagnostics')),
    );
    final book = await Notebook.open(
      Directory(p.join(root.path, 'source')),
      diagnostics: diagnostics,
    );
    final manifest = ModelSpec.parse(
      await rootBundle.loadString('assets/models.json'),
    );
    final store = ModelStore(Directory(p.join(root.path, 'models')), manifest);
    final seeded = File(p.join(root.path, 'seeded'));
    if (!await seeded.exists()) {
      final parent = await book.saveText(
        '先记住想法的条件\n先保留原话，之后再核对下一步。不要把犹豫自动改成结论。',
      );
      await book.saveText('先测试最短闭环，再扩大功能范围。', parentId: parent.id);
      await book.saveText('离线也应该能记下和查回。', parentId: parent.id);
      await book.saveText('周末散步\n带相机去公园，走累了就回家。');
      await book.saveText('数据库查询\n先检查慢查询，再决定是否增加索引。');
      await seeded.writeAsString('synthetic-v1', flush: true);
    }
    // Optional emulator bootstrap reads only the designated public model cache.
    // On a phone without these fixtures, Settings prepares its own private models.
    final fixtures = ModelStore(
      Directory('/data/local/tmp/nianxia-models'),
      manifest,
    );
    for (final spec in manifest) {
      if (await store.ready(spec.id) || !await fixtures.ready(spec.id)) {
        continue;
      }
      final target = await store.directory(spec).create(recursive: true);
      for (final file in spec.files) {
        await File(fixtures.file(spec.id, file.name))
            .copy(p.join(target.path, file.name));
      }
      await File(p.join(target.path, '.ready'))
          .writeAsString('verified-public-fixture', flush: true);
      if (!await store.ready(spec.id)) {
        throw StateError('Preview model verification failed');
      }
    }
    fixtures.dispose();
    final models = LocalModels(store);
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks(
        ['SenseVoiceSmall / FunASR / Alibaba Group'],
        await rootBundle.loadString('assets/licenses/FunASR-MODEL-LICENSE.txt'),
      );
      yield LicenseEntryWithLineBreaks([
        'BGE-small-zh-v1.5 / BAAI; INT8 conversion by Xenova',
      ], await rootBundle.loadString('assets/licenses/BGE-LICENSE.txt'));
    });
    BackgroundTasks(book, models, diagnostics: diagnostics);
    // Ordinary capture remains the default. No experimental native capability
    // is enabled by this manual composition.
    final shortcut = ValueNotifier<String?>(null);
    const system = MethodChannel('app.nianxia/system');
    system.setMethodCallHandler((call) async {
      if (call.method == 'launch' && call.arguments is String) {
        shortcut.value = call.arguments as String;
      } else if (call.method == 'screenOff') {
        CaptureController.screenTurnedOff();
      }
    });
    shortcut.value = await system.invokeMethod<String>('getLaunchAction');
    runApp(
      NianxiaApp(
        book: book,
        models: models,
        diagnostics: diagnostics,
        shortcut: shortcut,
      ),
    );
    try {
      const actions = QuickActions();
      await actions.initialize(
        (type) => shortcut.value = type == 'capture' ? 'capsule' : type,
      );
      await actions.setShortcutItems(const [
        ShortcutItem(
          type: 'capture',
          localizedTitle: '记一下',
          icon: 'shortcut_capture',
        ),
        ShortcutItem(
          type: 'search',
          localizedTitle: '找一下',
          icon: 'shortcut_search',
        ),
      ]);
    } on PlatformException {
      // Optional shortcuts cannot prevent a usable private notebook.
    } on MissingPluginException {
      // Optional on unsupported surfaces too.
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        File(p.join(root.path, 'ready.json')).writeAsString(
          jsonEncode({
            'applicationId': identity['applicationId'],
            'runId': runId,
            'sourceDigest': const String.fromEnvironment(
              'UI_PREVIEW_SOURCE_DIGEST',
            ),
            'ready': true,
            'ordinaryCapture': true,
          }),
          flush: true,
        ),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('独立体验环境尚未就绪。请保留现场检查。'))),
      ),
    );
  }
}
