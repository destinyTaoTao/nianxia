// Developer-only hands-on app. Every build uses the isolated .test package ID.
// Its banner identifies the selected PCM fixture; ASR/search remain real.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';
import 'package:nianxia/ui/app.dart';
import 'package:nianxia/ui/theme.dart';

import '../integration_test/support/fixture_record_platform.dart';
import '../integration_test/support/test_sandbox.dart';

const fixtures = '/data/local/tmp/nianxia-models';
const topics = ['数据库查询', '周末散步', '产品原型', '番茄炒蛋'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireModelTestSandbox();
  final home = Directory(
    p.join((await getApplicationSupportDirectory()).path, 'manual-demo'),
  );
  final book = await Notebook.open(home);
  final store = ModelStore(
    Directory(fixtures),
    ModelSpec.parse(await rootBundle.loadString('assets/models.json')),
  );
  final models = LocalModels(store);
  if (!await store.ready('sensevoice') || !await store.ready('bge')) {
    throw StateError('Prepare the trusted model fixtures first.');
  }
  final seeded = File(p.join(home.path, 'demo-seeded-v1'));
  if (!await seeded.exists()) {
    await BackupService(book).restore(File('$fixtures/manual-demo.zip'));
    await seeded.writeAsString('1', flush: true);
  }
  final microphone = FixtureRecordPlatform('$fixtures/voice-demo-query-1.wav');
  RecordPlatform.instance = microphone;
  final tasks = BackgroundTasks(book, models);
  runApp(
    _Demo(book: book, models: models, tasks: tasks, microphone: microphone),
  );
}

class _Demo extends StatefulWidget {
  const _Demo({
    required this.book,
    required this.models,
    required this.tasks,
    required this.microphone,
  });
  final Notebook book;
  final LocalModels models;
  final BackgroundTasks tasks;
  final FixtureRecordPlatform microphone;
  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  int selected = 0;
  bool active = false;
  bool delivered = false;
  Timer? refresh;
  @override
  void initState() {
    super.initState();
    refresh = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (mounted &&
          (active != widget.book.captureActive ||
              delivered != widget.microphone.delivered)) {
        setState(() {
          active = widget.book.captureActive;
          delivered = widget.microphone.delivered;
        });
      }
    });
  }

  @override
  void dispose() {
    refresh?.cancel();
    widget.tasks.dispose();
    widget.book.dispose();
    widget.models.store.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: notebookTheme(Brightness.dark),
    home: Scaffold(
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('测试 · 预置音频输入')),
                      DropdownButton<int>(
                        value: selected,
                        items: [
                          for (var i = 0; i < topics.length; i++)
                            DropdownMenuItem(value: i, child: Text(topics[i])),
                        ],
                        onChanged: widget.book.captureActive
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  selected = value;
                                  widget.microphone.path =
                                      '$fixtures/voice-demo-query-${value + 1}.wav';
                                  widget.microphone.delivered = false;
                                });
                              },
                      ),
                    ],
                  ),
                  Text(
                    widget.book.captureActive && widget.microphone.delivered
                        ? '音频输入完成，可点“停止”。'
                        : '点“语音查找”或“记一下”，等音频输入完成后停止。',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFB4B4B4),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Builder(
              builder: (context) => MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: NianxiaApp(book: widget.book, models: widget.models),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
