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

class _AvailabilityStore extends ModelStore {
  _AvailabilityStore(Directory home) : super(home, []);
  bool broken = false;
  @override
  Future<bool> ready(String id) async {
    if (broken) throw const FileSystemException('temporarily unreadable');
    return id == 'bge';
  }
}

class _FailOnceModels extends LocalModels {
  _FailOnceModels(super.store);
  final attempted = Completer<void>();
  bool fail = true;
  @override
  Future<List<double>> embed(String text, {required bool query}) async {
    if (!attempted.isCompleted) attempted.complete();
    if (fail) throw StateError('old generation failed');
    return [1, 0];
  }
}

void main() {
  test('切换模型代际后重新索引上一代失败的同修订记录', () async {
    final home = await Directory.systemTemp.createTemp(
      'nianxia-jobs-generation-',
    );
    final book = await Notebook.open(home);
    final models = _FailOnceModels(_AvailabilityStore(home));
    final record = await book.saveText('原文');
    await book.setSearchModelVersion('old');
    final tasks = BackgroundTasks(book, models);
    try {
      await models.attempted.future;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      models.fail = false;
      await book.setSearchModelVersion('new');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect((await book.get(record.id))!.vectorRevision, record.revision);
    } finally {
      tasks.dispose();
      models.dispose();
      await book.close();
      await home.delete(recursive: true);
    }
  });

  test('就绪检查I/O失败被调度器收口，状态恢复后可继续处理', () async {
    final home = await Directory.systemTemp.createTemp('nianxia-jobs-ready-');
    final book = await Notebook.open(home);
    final store = _AvailabilityStore(home)..broken = true;
    final models = _FailOnceModels(store)..fail = false;
    final record = await book.saveText('原文');
    final tasks = BackgroundTasks(book, models);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 350));
      store.broken = false;
      store.notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect((await book.get(record.id))!.vectorRevision, record.revision);
    } finally {
      tasks.dispose();
      models.dispose();
      await book.close();
      await home.delete(recursive: true);
    }
  });

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
      expect((await book.get(second.id))!.body, '已识别的想法');
    } finally {
      tasks?.dispose();
      await book.close();
      models.store.dispose();
      await home.delete(recursive: true);
    }
  });
}
