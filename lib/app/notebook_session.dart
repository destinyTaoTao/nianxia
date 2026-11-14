import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/model_store.dart';
import '../platform/local_models.dart';
import 'background_tasks.dart';
import 'notebook.dart';
import 'diagnostics.dart';
import '../domain/diagnostic_event.dart';

import 'dart:async';

/// Owns startup/teardown of the notebook and its optional inference resources.
class NotebookSession {
  NotebookSession._(this.book, this.models, this.tasks, this.diagnostics);
  final Notebook book;
  final LocalModels models;
  final BackgroundTasks tasks;
  final LocalDiagnostics diagnostics;
  bool _closed = false;

  static Future<NotebookSession> open(
    Directory home, {
    required Future<String> Function() loadModelManifest,
  }) async {
    Notebook? book;
    ModelStore? store;
    LocalModels? models;
    BackgroundTasks? tasks;
    final diagnostics = LocalDiagnostics(
      Directory(p.join(home.path, 'diagnostics')),
    );
    try {
      return await diagnostics.trace(DiagnosticKind.startup, () async {
        final openedBook = await Notebook.open(home);
        book = openedBook;
        final manifest = ModelSpec.parse(await loadModelManifest());
        final openedStore = ModelStore(
          Directory(p.join(home.path, 'models')),
          manifest,
        );
        store = openedStore;
        final openedModels = LocalModels(openedStore);
        models = openedModels;
        final openedTasks = BackgroundTasks(
          openedBook,
          openedModels,
          diagnostics: diagnostics,
        );
        tasks = openedTasks;
        return NotebookSession._(
          openedBook,
          openedModels,
          openedTasks,
          diagnostics,
        );
      }, phase: DiagnosticPhase.prepare);
    } catch (_) {
      tasks?.dispose();
      final openedModels = models;
      if (openedModels != null) {
        openedModels.dispose();
      } else {
        store?.dispose();
      }
      await book?.close();
      await diagnostics.close();
      rethrow;
    }
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    tasks.dispose();
    models.dispose();
    book.dispose();
    unawaited(diagnostics.close());
  }

  Future<void> close() async {
    dispose();
    await book.close();
    await diagnostics.close();
  }
}
