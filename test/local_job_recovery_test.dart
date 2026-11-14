import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/local_job.dart';
import 'package:nianxia/domain/ports.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:crypto/crypto.dart';

import 'recording_search_test.dart' show writeWave;

class _JobSpeech implements Transcriber {
  int calls = 0;
  @override
  Future<String> transcribe(String path) async {
    calls++;
    return 'synthetic committed transcript';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-jobs-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    await book.close();
    await home.delete(recursive: true);
  });
  test('sourceCommittedBeforeJobAckDoesNotRepeatInference', () async {
    final draft = await book.beginCapture();
    await writeWave(draft.path);
    final saved = await book.finishCapture(draft);
    final job = await book.claimLocalJob(
      kinds: {JobKind.transcription},
      speechModelVersion: 'speech-v1',
    );
    expect(job, isNotNull);
    final speech = _JobSpeech();
    expect(await book.transcribe(saved.id, speech), isTrue);
    await book.close();
    book = await Notebook.open(home);
    expect(
      await book.claimLocalJob(
        kinds: {JobKind.transcription},
        speechModelVersion: 'speech-v1',
      ),
      isNull,
    );
    expect(speech.calls, 1);
    expect(
      (await book.get(saved.id))!.transcript,
      'synthetic committed transcript',
    );
  });
  test(
    'newRevisionInvalidatesOldLease without overwriting edited source',
    () async {
      final saved = await book.saveText('original synthetic');
      final job = await book.claimLocalJob(kinds: {JobKind.embedding});
      expect(job, isNotNull);
      await book.edit(saved.id, 'edited synthetic', expectedRevision: 1);
      await book.finishLocalJob(job!, outcome: JobOutcome.succeeded);
      final next = await book.claimLocalJob(kinds: {JobKind.embedding});
      expect(next!.sourceRevision, 2);
      expect(next.leaseToken, isNot(job.leaseToken));
      expect((await book.get(saved.id))!.body, 'edited synthetic');
    },
  );
  test('futureJobsStoreDoesNotBlockRecords and remains unchanged', () async {
    final file = File('${home.path}/jobs.sqlite');
    final db = sqlite3.open(file.path);
    db.execute('PRAGMA application_id=${0x4e584a42}');
    db.execute('PRAGMA user_version=2');
    db.execute('CREATE TABLE future(value TEXT)');
    db.execute('INSERT INTO future VALUES(?)', ['future sentinel']);
    db.close();
    final before = sha256.convert(await file.readAsBytes());
    final saved = await book.saveText('source remains usable');
    expect(await book.claimLocalJob(), isNull);
    expect((await book.get(saved.id))!.body, 'source remains usable');
    expect(sha256.convert(await file.readAsBytes()), before);
  });
  test('transient retry uses one and five second backoff then stops at three attempts', () async {
    await book.saveText('synthetic retry');
    final first = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
    await book.finishLocalJob(first, outcome: JobOutcome.failedTransient);
    expect(await book.claimLocalJob(kinds: {JobKind.embedding}), isNull);
    final db = sqlite3.open('${home.path}/jobs.sqlite');
    db.execute('UPDATE jobs SET next_attempt_at=0');
    db.close();
    final second = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
    expect(second.attempt, 2);
    await book.finishLocalJob(second, outcome: JobOutcome.failedTransient);
    final check = sqlite3.open('${home.path}/jobs.sqlite');
    final row = check.select('SELECT next_attempt_at FROM jobs WHERE key=?', [
      second.key,
    ]).single;
    expect(
      (row['next_attempt_at'] as int) -
          DateTime.now().toUtc().millisecondsSinceEpoch,
      greaterThan(4000),
    );
    check.execute('UPDATE jobs SET next_attempt_at=0');
    check.close();
    final third = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
    expect(third.attempt, 3);
    await book.finishLocalJob(third, outcome: JobOutcome.failedTransient);
    expect(await book.claimLocalJob(kinds: {JobKind.embedding}), isNull);
  });
  test('deleted source and hot model invalidate old leases; corrupt sidecar leaves originals available', () async {
    final saved = await book.saveText('synthetic delete');
    final old = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
    await book.setSearchModelVersion('replacement');
    await book.finishLocalJob(old, outcome: JobOutcome.succeeded);
    final current = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
    expect(current.modelGeneration, 'replacement');
    await book.delete(saved.id);
    await book.finishLocalJob(current, outcome: JobOutcome.failedTransient);
    expect(await book.claimLocalJob(), isNull);
    await book.close();
    await File('${home.path}/jobs.sqlite')
        .writeAsString('corrupt synthetic cache');
    book = await Notebook.open(home);
    final usable = await book.saveText('retained source');
    expect(await book.claimLocalJob(), isNull);
    expect((await book.get(usable.id))!.body, 'retained source');
  });
  test(
    'second storage owner cannot revoke an active lease in the same process',
    () async {
      await book.saveText('synthetic owned lease');
      final first = (await book.claimLocalJob(kinds: {JobKind.embedding}))!;
      final second = await Notebook.open(home);
      try {
        expect(await second.claimLocalJob(kinds: {JobKind.embedding}), isNull);
        expect((await second.records).length, 1);
      } finally {
        await second.close();
      }
      final check = sqlite3.open('${home.path}/jobs.sqlite');
      final row = check.select(
        'SELECT state,lease_token FROM jobs WHERE key=?',
        [first.key],
      ).single;
      expect(row['state'], 'running');
      expect(row['lease_token'], first.leaseToken);
      check.close();
    },
  );
}
