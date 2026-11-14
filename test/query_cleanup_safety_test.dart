import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/ports.dart';

import 'recording_search_test.dart' show writeWave;

class _PendingQuery implements Transcriber {
  final entered = Completer<void>(), release = Completer<String>();
  @override
  Future<String> transcribe(String path) async {
    entered.complete();
    return release.future;
  }
}

void main() {
  test('query cleanup never deletes source audio introduced while recognition runs', () async {
    final home = await Directory.systemTemp.createTemp('nx-query-cleanup-');
    final book = await Notebook.open(home);
    final engine = _PendingQuery();
    Future<String>? work;
    try {
      final draft = await book.beginCapture(query: true);
      await writeWave(draft.path);
      work = book.transcribeQuery(draft, engine);
      await engine.entered.future;
      final source = File('${home.path}/audio/${draft.id}.wav');
      await writeWave(source.path);
      await book.repository.insert(
        Record(
          id: draft.id,
          body: 'synthetic restored source',
          createdAt: DateTime.now().toUtc(),
          timezone: 'UTC',
          offsetMinutes: 0,
          audio: '${draft.id}.wav',
          durationMs: 1000,
        ),
      );
      engine.release.complete('synthetic query');
      expect(await work, 'synthetic query');
      expect(await source.exists(), isTrue);
      expect(await File(draft.path).exists(), isFalse);
    } finally {
      if (!engine.release.isCompleted) {
        engine.release.complete('synthetic query');
      }
      if (work != null) {
        try {
          await work;
        } catch (_) {}
      }
      await book.close();
      await home.delete(recursive: true);
    }
  });
}
