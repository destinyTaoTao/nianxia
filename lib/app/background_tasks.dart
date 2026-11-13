import 'dart:async';

import '../domain/ports.dart';
import 'inference_runtime.dart';
import 'notebook.dart';

class BackgroundTasks {
  BackgroundTasks(this.book, this.models) {
    book.addListener(schedule);
    models.addListener(schedule);
    schedule();
  }
  final Notebook book;
  final InferenceRuntime models;
  bool _running = false, _disposed = false, _again = false;
  Timer? _timer;
  final Map<String, (int, String)> _failedIndex = {};
  void schedule() {
    if (_disposed || book.isClosed) return;
    if (_running) {
      _again = true;
      return;
    }
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 250), _drain);
  }

  Future<void> _drain() async {
    if (_disposed || _running || book.isClosed) return;
    _running = true;
    _again = false;
    try {
      final configured = models.searchModelVersion;
      if (configured != null &&
          configured != await book.repository.indexModelVersion) {
        await book.setSearchModelVersion(configured);
      }
      if (_disposed || book.isClosed) return;
      if (await models.ready(InferenceCapability.speech)) {
        var after = '';
        while (!_disposed && !book.isClosed) {
          final batch = await book.repository.pendingJobs(
            transcription: true,
            after: after,
          );
          if (_disposed || book.isClosed || batch.isEmpty) break;
          for (final r in batch) {
            if (_disposed || book.isClosed) return;
            try {
              await book.transcribe(r.id, _BackgroundTranscriber(models));
            } catch (_) {
              /* Failure state is persisted in the record. */
            }
          }
          after = batch.last.id;
        }
      }
      if (_disposed || book.isClosed) return;
      if (await models.ready(InferenceCapability.semantic)) {
        final version = await book.repository.indexModelVersion;
        _failedIndex.removeWhere((_, failed) => failed.$2 != version);
        var after = '';
        while (!_disposed && !book.isClosed) {
          final batch = await book.repository.pendingJobs(
            transcription: false,
            after: after,
          );
          if (_disposed || book.isClosed || batch.isEmpty) break;
          for (final r in batch) {
            if (_disposed || book.isClosed) return;
            if (_failedIndex[r.id] == (r.revision, version)) continue;
            try {
              await book.index(r.id, models);
            } catch (_) {
              // Retry suppression is ephemeral and bounded, never a full copy
              // of the notebook or a permanent ban on a future model version.
              if (_failedIndex.length >= 512) {
                _failedIndex.remove(_failedIndex.keys.first);
              }
              _failedIndex[r.id] = (r.revision, version);
            }
          }
          after = batch.last.id;
        }
      }
    } catch (_) {
      // Readiness/storage failures retry on the next availability/data event.
    } finally {
      _running = false;
      if (_again && !_disposed && !book.isClosed) schedule();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    book.removeListener(schedule);
    models.removeListener(schedule);
  }
}

class _BackgroundTranscriber implements Transcriber {
  _BackgroundTranscriber(this.models);
  final InferenceRuntime models;
  @override
  Future<String> transcribe(String path) =>
      models.transcribe(path, foreground: false);
}
