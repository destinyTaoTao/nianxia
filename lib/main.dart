import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:quick_actions/quick_actions.dart';

import 'app/background_tasks.dart';
import 'app/notebook.dart';
import 'data/model_store.dart';
import 'platform/local_models.dart';
import 'platform/capture_controller.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'SenseVoiceSmall / FunASR / Alibaba Group',
    ], await rootBundle.loadString('assets/licenses/FunASR-MODEL-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'BGE-small-zh-v1.5 / BAAI; INT8 conversion by Xenova',
    ], await rootBundle.loadString('assets/licenses/BGE-LICENSE.txt'));
  });
  runApp(const _Bootstrap());
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  Notebook? book;
  LocalModels? models;
  BackgroundTasks? tasks;
  String? error;
  final shortcut = ValueNotifier<String?>(null);
  static const bridge = MethodChannel('app.nianxia/system');
  @override
  void initState() {
    super.initState();
    bridge.setMethodCallHandler((call) async {
      if (call.method == 'launch' && call.arguments is String) {
        shortcut.value = call.arguments as String;
      } else if (call.method == 'screenOff') {
        CaptureController.screenTurnedOff();
      }
    });
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final initialAction = await bridge.invokeMethod<String>(
        'getLaunchAction',
      );
      if (initialAction != null) shortcut.value = initialAction;
      if (mounted) setState(() {});
      final root = Directory(
        p.join((await getApplicationSupportDirectory()).path, 'nianxia'),
      );
      await root.create(recursive: true);
      final protected = await bridge.invokeMethod<bool>('protectFiles', {
        'path': root.path,
      });
      if (protected != true) {
        throw const NotebookException('无法核验本地备份边界，尚未打开记录。');
      }
      final opened = await Notebook.open(root);
      final manifest = ModelSpec.parse(
        await rootBundle.loadString('assets/models.json'),
      );
      final store = ModelStore(
        Directory(p.join(root.path, 'models')),
        manifest,
      );
      final runtime = LocalModels(store);
      final background = BackgroundTasks(opened, runtime);
      if (!mounted) {
        background.dispose();
        opened.dispose();
        store.dispose();
        return;
      }
      setState(() {
        book = opened;
        models = runtime;
        tasks = background;
      });
      // Only system shortcuts are registered. No account, telemetry or model
      // download is started as a side effect of opening the app.
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
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is NotebookException
              ? e.message
              : '无法读取本地数据或核验存储设置。未重置或删除任何记录，请检查空间、权限后重试。',
        );
      }
    }
  }

  @override
  void dispose() {
    tasks?.dispose();
    models?.store.dispose();
    book?.dispose();
    shortcut.dispose();
    bridge.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (book != null) {
      return NianxiaApp(book: book!, models: models, shortcut: shortcut);
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: notebookTheme(Brightness.light),
      darkTheme: notebookTheme(Brightness.dark),
      home: Scaffold(
        backgroundColor: shortcut.value == 'capsule'
            ? Colors.transparent
            : null,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const NoteMark(size: 56),
                  const SizedBox(height: 24),
                  Text(error ?? '正在打开本地记录', textAlign: TextAlign.center),
                  const SizedBox(height: 20),
                  if (error == null)
                    const CircularProgressIndicator()
                  else
                    FilledButton(onPressed: load, child: const Text('重试')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
