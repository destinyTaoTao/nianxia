// All data is synthetic in a marked temporary notebook. Never opens user storage.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/data/search_index.dart';
import 'package:nianxia/data/search_paging_store.dart';
import 'package:nianxia/domain/search_page.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final at = args.indexOf(name);
    return at < 0 ? null : args[at + 1];
  }

  final count = int.parse(option('--records') ?? '100000');
  if (count < 1 || count > 1000000) {
    throw ArgumentError('records must be 1..1000000');
  }
  final output = option('--output');
  final home = await Directory.systemTemp.createTemp('nx-paging-synthetic-');
  await File(p.join(home.path, 'SYNTHETIC_FIXTURE'))
      .writeAsString('Generated non-user records only\n');
  final source = RecordRepository(home);
  SearchIndex? index;
  SearchPagingStore? pages;
  var peakRss = ProcessInfo.currentRss;
  final timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
    final value = ProcessInfo.currentRss;
    if (value > peakRss) peakRss = value;
  });
  Future<String> sourceHash() async {
    source.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    return (await sha256
            .bind(File(p.join(home.path, 'records.sqlite')).openRead())
            .first)
        .toString();
  }

  try {
    final setup = Stopwatch()..start();
    source.db.execute('BEGIN');
    final insert = source.db.prepare(
      'INSERT INTO records(id,parent_id,body,created_at,timezone,offset_minutes,revision,favorite,audio,duration_ms,transcript,transcription) VALUES(?,NULL,?,?,\'UTC\',0,1,0,NULL,0,NULL,\'none\')',
    );
    try {
      for (var i = 0; i < count; i++) {
        insert.execute([
          '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          'marker benchmark $i ${List.filled(16, '长正文🔒').join()}',
          '2026-11-14T00:00:00.000Z',
        ]);
      }
      source.db.execute('COMMIT');
    } finally {
      insert.close();
    }
    final before = await sourceHash();
    setup.stop();
    index = SearchIndex(source, home);
    final prepare = Stopwatch()..start();
    await index.waitForIndexing();
    prepare.stop();
    pages = SearchPagingStore(source, index, home);
    final query = SearchQuery(text: 'marker');
    final firstWatch = Stopwatch()..start();
    var page = await pages.page(query, requestId: 'benchmark-query');
    firstWatch.stop();
    var returned = page.entries.length;
    var pageCount = 1;
    var maxPayload = utf8.encode(jsonEncode(page.toMap())).length;
    final seen = <String>{...page.entries.map((e) => e.id)};
    final traversal = Stopwatch()..start();
    while (page.next != null) {
      page = await pages.page(
        query,
        requestId: 'benchmark-query',
        after: page.next,
      );
      if (page.reset) {
        throw StateError('Unexpected stable-fixture cursor reset');
      }
      if (page.entries.any((e) => !seen.add(e.id))) {
        throw StateError('Duplicate summary');
      }
      returned += page.entries.length;
      pageCount++;
      final bytes = utf8.encode(jsonEncode(page.toMap())).length;
      if (bytes > maxPayload) maxPayload = bytes;
    }
    traversal.stop();
    final after = await sourceHash();
    if (returned != count || before != after) {
      throw StateError('Incomplete traversal or changed source');
    }
    var scratch = 0;
    await for (final f in Directory(
      p.join(home.path, 'search-pages'),
    ).list(recursive: true, followLinks: false)) {
      if (f is File) scratch += await f.length();
    }
    final report = {
      'executionDate': DateTime.now().toUtc().toIso8601String(),
      'platform': Platform.operatingSystem,
      'mode': 'Dart host JIT synthetic full-keyword match',
      'records': count,
      'setupMs': setup.elapsedMilliseconds,
      'indexPreparationMs': prepare.elapsedMilliseconds,
      'firstPageMs': firstWatch.elapsedMilliseconds,
      'remainingPagesMs': traversal.elapsedMilliseconds,
      'totalTraversalMs':
          firstWatch.elapsedMilliseconds + traversal.elapsedMilliseconds,
      'pages': pageCount,
      'returned': returned,
      'maxPagePayloadBytes': maxPayload,
      'sampledProcessPeakRss': peakRss,
      'scratchBytes': scratch,
      'sourceSha256Before': before,
      'sourceSha256After': after,
      'passed': true,
      'scope': '20ms sampled whole host process; no Flutter UI/models/phone acceptance',
    };
    if (output != null) {
      await File(output).parent.create(recursive: true);
      await File(output).writeAsString('${jsonEncode(report)}\n');
    }
    stdout.writeln(jsonEncode(report));
  } finally {
    timer.cancel();
    pages?.close();
    await index?.close();
    source.close();
    await home.delete(recursive: true);
  }
}
