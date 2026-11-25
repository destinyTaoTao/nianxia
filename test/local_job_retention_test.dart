import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/local_job_store.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/domain/local_job.dart';
import 'package:nianxia/domain/record.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory home;
  late RecordRepository source;
  late LocalJobStore jobs;
  late Database cache;
  Record record(String id, {bool audio = false}) => Record(
    id: id,
    body: 'synthetic source retained',
    createdAt: DateTime.utc(2026),
    timezone: 'UTC',
    offsetMinutes: 0,
    audio: audio ? 'synthetic.wav' : null,
    transcription: audio ? 'pending' : 'none',
  );
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nx-job-retention-');
    source = RecordRepository(home);
    cache = sqlite3.open('${home.path}/jobs.sqlite');
    // An existing valid sidecar may use a smaller SQLite page size. Its actual
    // production 16384-page budget makes real SQLITE_FULL cheap to reproduce.
    cache.execute('PRAGMA page_size=512');
    cache.execute('PRAGMA application_id=${0x4e584a42}');
    cache.execute('PRAGMA user_version=1');
    jobs = LocalJobStore(source, home);
    expect(jobs.available, isTrue);
  });
  tearDown(() async {
    jobs.close();
    cache.close();
    source.close();
    await home.delete(recursive: true);
  });
  Future<LocalJob?> embedding() => jobs.claim({JobKind.embedding}, 'speech-v1');

  test('旧修订任务持续修剪，当前永久失败和三次上限在重启后仍保留', () async {
    source.insert(record('edited'));
    for (var revision = 1; revision <= 40; revision++) {
      final job = (await embedding())!;
      expect(job.sourceRevision, revision);
      await jobs.finish(job, JobOutcome.failedPermanent);
      if (revision != 40) source.edit('edited', 'revision $revision', revision);
    }
    expect(cache.select('SELECT COUNT(*) AS n FROM jobs').single['n'], 1);
    jobs.close();
    jobs = LocalJobStore(source, home);
    expect(await embedding(), isNull);
    expect(source.get('edited')!.revision, 40);
  });

  test('已完成任务不用保留历史，也不会在下一次认领时重复转写', () async {
    source.insert(record('audio', audio: true));
    final job = (await jobs.claim({JobKind.transcription}, 'speech-v1'))!;
    expect(
      source.transcript('audio', 1, 'committed original transcript'),
      isTrue,
    );
    await jobs.finish(job, JobOutcome.succeeded);
    expect(cache.select('SELECT COUNT(*) AS n FROM jobs').single['n'], 0);
    expect(await jobs.claim({JobKind.transcription}, 'speech-v1'), isNull);
    expect(source.get('audio')!.transcript, 'committed original transcript');
  });

  test('修剪删除记录和旧模型任务，但不撤销仍在途的租约', () async {
    source.insert(record('deleted'));
    final deleted = (await embedding())!;
    await jobs.finish(deleted, JobOutcome.cancelled);
    source.delete('deleted');
    source.insert(record('active'));
    final active = (await embedding())!;
    source.edit('active', 'edited during inference', 1);
    final current = (await embedding())!;
    expect(current.sourceRevision, 2);
    final row = cache.select('SELECT state,lease_token FROM jobs WHERE key=?', [
      active.key,
    ]).single;
    expect(row['state'], 'running');
    expect(row['lease_token'], active.leaseToken);
    expect(
      cache.select('SELECT 1 FROM jobs WHERE key=?', [deleted.key]),
      isEmpty,
    );
  });

  test('实际SQLite页预算耗尽不会永久禁用队列，空间恢复后可再次认领', () async {
    source.insert(record('available-after-full'));
    cache.execute('CREATE TABLE fill(payload BLOB)');
    cache.execute('''CREATE TRIGGER full_budget BEFORE INSERT ON jobs BEGIN
      INSERT INTO fill VALUES (zeroblob(9437184)); END''');
    expect(await embedding(), isNull);
    expect(jobs.available, isFalse);
    expect(
      source.get('available-after-full')!.body,
      'synthetic source retained',
    );
    cache.execute('DROP TRIGGER full_budget');
    expect((await embedding())?.sourceId, 'available-after-full');
    expect(jobs.available, isTrue);
  });

  test('只认领向量任务不能用缺省语音版本清除当前转写失败上限', () async {
    source.insert(record('audio-limit', audio: true));
    final speech = (await jobs.claim({JobKind.transcription}, 'speech-v1'))!;
    await jobs.finish(speech, JobOutcome.failedPermanent);
    final vector = (await jobs.claim({JobKind.embedding}, 'unversioned'))!;
    await jobs.finish(vector, JobOutcome.failedPermanent);
    expect(await jobs.claim({JobKind.transcription}, 'speech-v1'), isNull);
    expect(
      cache.select('SELECT state FROM jobs WHERE key=?', [
        speech.key,
      ]).single['state'],
      'failed',
    );
  });
}
