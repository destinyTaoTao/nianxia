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
  NotebookSession._(
    this.book,
    this.models,
    this.tasks,
    this.diagnostics,
    this.modelNotice,
  ) {
    maintenance = Future<void>.delayed(Duration.zero, () async {
      if (book.isClosed) return;
      try {
        await book.runMaintenance();
      } catch (_) {
        if (!book.isClosed) book.recoveryWarnings++;
      }
    });
  }
  final String? modelNotice;
  late final Future<void> maintenance;
  final Notebook book;
  final LocalModels models;
  final BackgroundTasks tasks;
  final LocalDiagnostics diagnostics;
  bool _closed = false;
  Future<void>? _closing;

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
        final openedBook = await Notebook.open(
          home,
          deferMaintenance: true,
          diagnostics: diagnostics,
        );
        book = openedBook;
        List<ModelSpec> manifest;
        String? modelNotice;
        try {
          manifest = ModelSpec.parse(await loadModelManifest());
        } catch (_) {
          manifest = [];
          modelNotice = '模型目录暂不可用，仍可记录和关键词查找。请重新打开应用重试。';
        }
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
          modelNotice,
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
    _closing = _closeResources();
    unawaited(_closing!.catchError((Object _) {}));
  }

  Future<void> close() {
    dispose();
    return _closing!;
  }

  Future<void> _closeResources() async {
    try {
      await maintenance;
    } finally {
      try {
        await models.close();
      } finally {
        try {
          await book.close();
        } finally {
          await diagnostics.close();
        }
      }
    }
  }
}
