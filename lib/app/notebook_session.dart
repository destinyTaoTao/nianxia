import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/model_store.dart';
import '../platform/local_models.dart';
import 'background_tasks.dart';
import 'notebook.dart';

/// Owns startup/teardown of the notebook and its optional inference resources.
class NotebookSession {
  NotebookSession._(this.book, this.models, this.tasks);
  final Notebook book;
  final LocalModels models;
  final BackgroundTasks tasks;
  bool _closed = false;

  static Future<NotebookSession> open(
    Directory home, {
    required Future<String> Function() loadModelManifest,
  }) async {
    Notebook? book;
    ModelStore? store;
    LocalModels? models;
    BackgroundTasks? tasks;
    try {
      book = await Notebook.open(home);
      final manifest = ModelSpec.parse(await loadModelManifest());
      store = ModelStore(Directory(p.join(home.path, 'models')), manifest);
      models = LocalModels(store);
      tasks = BackgroundTasks(book, models);
      return NotebookSession._(book, models, tasks);
    } catch (_) {
      tasks?.dispose();
      if (models != null) {
        models.dispose();
      } else {
        store?.dispose();
      }
      await book?.close();
      rethrow;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    tasks.dispose();
    models.dispose();
    book.dispose();
  }

  Future<void> close() async {
    dispose();
    await book.close();
  }
}
