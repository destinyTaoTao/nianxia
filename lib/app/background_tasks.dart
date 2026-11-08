import 'dart:async';

import '../domain/ports.dart';
import '../platform/local_models.dart';
import 'notebook.dart';

class BackgroundTasks {
  BackgroundTasks(this.book, this.models) {
    for (final model in models.store.models.where((m) => m.id == 'bge')) {
      book.setSearchModelVersion('${model.version}:bert-cls-l2-w480-o32-v1');
    }
    book.addListener(schedule);
    models.store.addListener(schedule);
    schedule();
  }
  final Notebook book;
  final LocalModels models;
  bool _running = false, _disposed = false, _again = false;
  Timer? _timer;
  final Map<String, int> _failedIndex = {};
  void schedule() {
    if (_disposed) {
      return;
    }
    if (_running) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), _drain);
  }

  Future<void> _drain() async {
    if (_disposed || _running) {
      return;
    }
    _running = true;
    _again = false;
    try {
      if (await models.store.ready('sensevoice')) {
        for (final r in book.records.where(
          (r) => r.transcription == 'pending',
        )) {
          if (_disposed) {
            return;
          }
          try {
            await book.transcribe(r.id, _BackgroundTranscriber(models));
          } catch (_) {
            /* Persistent failure state is visible in record detail. */
          }
        }
      }
      if (await models.store.ready('bge')) {
        for (final r in book.records.where(
          (r) =>
              r.body.isNotEmpty &&
              r.vectorRevision != r.revision &&
              _failedIndex[r.id] != r.revision,
        )) {
          if (_disposed) {
            return;
          }
          try {
            await book.index(r.id, models);
          } catch (_) {
            _failedIndex[r.id] = r.revision;
          }
        }
      }
    } finally {
      _running = false;
      if (_again && !_disposed) {
        schedule();
      }
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    book.removeListener(schedule);
    models.store.removeListener(schedule);
  }
}

class _BackgroundTranscriber implements Transcriber {
  _BackgroundTranscriber(this.models);
  final LocalModels models;
  @override
  Future<String> transcribe(String path) =>
      models.transcribeFile(path, foreground: false);
}
