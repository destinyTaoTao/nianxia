import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/app/notebook.dart';

import 'recording_search_test.dart' show writeWave;

// A second adapter at the runtime seam, independent of native engine classes.
class _Runtime extends ChangeNotifier implements InferenceRuntime {
  final priorities = <bool>[];
  @override
  String get searchModelVersion => 'replacement-model-v1';
  @override
  Future<bool> ready(InferenceCapability capability) async => true;
  @override
  Future<String> transcribe(String path, {bool foreground = true}) async {
    priorities.add(foreground);
    return '替换实现的转写';
  }

  @override
  Future<List<double>> embed(String text, {required bool query}) async => [
    1,
    0,
  ];
}

void main() {
  test('调度器可替换推理Adapter，真实SQLite落地转写与索引', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-runtime-');
    final book = await Notebook.open(home);
    final runtime = _Runtime();
    BackgroundTasks? tasks;
    try {
      final draft = await book.beginCapture();
      await writeWave(draft.path);
      final saved = await book.finishCapture(draft);
      final completed = Completer<void>();
      book.addListener(() async {
        final r = (await book.get(saved.id))!;
        if (!completed.isCompleted && r.vectorRevision == r.revision) {
          completed.complete();
        }
      });
      tasks = BackgroundTasks(book, runtime);
      await completed.future.timeout(const Duration(seconds: 3));
      final actual = (await book.get(saved.id))!;
      expect(actual.body, '替换实现的转写');
      expect(actual.transcript, '替换实现的转写');
      expect(actual.vectorRevision, actual.revision);
      expect(runtime.priorities, [false]);
    } finally {
      tasks?.dispose();
      runtime.dispose();
      await book.close();
      await home.delete(recursive: true);
    }
  });
}
