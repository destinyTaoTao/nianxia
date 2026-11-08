import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/background_tasks.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/local_models.dart';

import 'recording_search_test.dart' show writeWave;

class ReadyStore extends ModelStore {
  ReadyStore(Directory home) : super(home, []);
  @override
  Future<bool> ready(String id) async => id == 'sensevoice';
}

class ControlledModels extends LocalModels {
  ControlledModels(super.store);
  final started = Completer<void>(), release = Completer<void>();
  @override
  Future<String> transcribeFile(String path, {bool foreground = true}) async {
    if (!started.isCompleted) {
      started.complete();
      await release.future;
    }
    return '已识别的想法';
  }
}

void main() {
  test('模型处理中保存的新录音会接续转写，不必重启应用', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-jobs-');
    final book = await Notebook.open(home);
    final models = ControlledModels(ReadyStore(home));
    BackgroundTasks? tasks;
    try {
      var draft = await book.beginCapture();
      await writeWave(draft.path);
      await book.finishCapture(draft);
      tasks = BackgroundTasks(book, models);
      await models.started.future;
      draft = await book.beginCapture();
      await writeWave(draft.path);
      final second = await book.finishCapture(draft);
      models.release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(book.get(second.id)!.body, '已识别的想法');
    } finally {
      tasks?.dispose();
      book.dispose();
      models.store.dispose();
      await home.delete(recursive: true);
    }
  });
}
