import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/domain/record.dart';

void main() {
  late Directory home;
  late RecordRepository repo;
  setUp(() {
    home = Directory.systemTemp.createTempSync('nianxia-derived-');
    repo = RecordRepository(home);
    repo.insert(
      Record(
        id: 'note',
        body: '原文',
        createdAt: DateTime.utc(2026),
        timezone: 'UTC',
        offsetMinutes: 0,
      ),
    );
  });
  tearDown(() {
    repo.close();
    home.deleteSync(recursive: true);
  });

  test('legal JSON with invalid organization fields is discarded on read', () {
    for (final payload in [
      {'title': 1, 'points': [], 'tasks': []},
      {'title': 'missing lists'},
      {
        'title': 'bad point',
        'points': [1],
        'tasks': [],
      },
      {
        'title': 'bad task',
        'points': [],
        'tasks': [
          {'title': 'task'},
        ],
      },
    ]) {
      repo.db.execute(
        'INSERT OR REPLACE INTO record_organizations VALUES(?,1,1,?,?)',
        ['note', 'organization-v1', jsonEncode(payload)],
      );
      expect(repo.get('note')!.organization, isNull, reason: '$payload');
      expect(repo.all().single.body, '原文');
    }
  });

  test('invalid input vector cannot poison original record', () {
    expect(repo.embedding('note', 1, [double.nan]), isFalse);
    expect(repo.get('note')!.body, '原文');
    expect(repo.get('note')!.vector, isNull);
  });

  test('v1 bad derived JSON cannot block raw listing or get', () {
    repo.close();
    File('${home.path}/records.sqlite').deleteSync();
    final db = sqlite3.open('${home.path}/records.sqlite');
    db.execute(File('test/fixtures/schema_v1.sql').readAsStringSync());
    db.close();
    repo = RecordRepository(home);
    expect(repo.all().length, 2);
    expect(repo.get('child')!.body, '追加');
    expect(repo.get('child')!.organization, isNull);
    expect(repo.get('child')!.vector, isNull);
  });

  test('CAS and model generations reject stale work and remove vectors', () {
    repo.ensureIndexVersion('model-one');
    expect(repo.embedding('note', 1, [0.3, 0.4]), isTrue);
    repo.edit('note', '编辑', 1);
    expect(repo.embedding('note', 1, [1, 2]), isFalse);
    expect(repo.derived('note', 1, {'title': '旧'}), isFalse);
    expect(repo.embedding('note', 2, [1, 2]), isTrue);
    repo.ensureIndexVersion('model-two');
    expect(repo.get('note')!.vector, isNull);
    repo.delete('note');
    expect(repo.embedding('note', 2, [1, 2]), isFalse);
  });
  test('unknown codecs, malformed JSON and vectors degrade without hiding raw data', () {
    expect(
      repo.derived('note', 1, {'title': '正常', 'points': [], 'tasks': []}),
      isTrue,
    );
    expect(repo.embedding('note', 1, [0.1, 0.2, 0.3]), isTrue);
    repo.db.execute("UPDATE record_organizations SET payload='[1,2]'");
    repo.db.execute('UPDATE record_embeddings SET format_version=999');
    expect(repo.all().single.body, '原文');
    expect(repo.get('note')!.organization, isNull);
    expect(repo.get('note')!.vectorRevision, isNull);
    repo.db.execute(
      'UPDATE record_embeddings SET format_version=1, dimension=999999',
    );
    expect(repo.get('note')!.vector, isNull);
    repo.embedding('note', 1, [1, 2]);
    repo.db.execute("UPDATE record_embeddings SET payload=x'0000807f00000000'");
    expect(repo.get('note')!.vector, isNull); // IEEE positive infinity.
    expect(repo.get('note')!.body, '原文');
    repo.db.execute('UPDATE record_organizations SET format_version=999');
    expect(repo.get('note')!.organization, isNull);
  });

  test('list omits payload but retains vector revision; Float32 keeps score ordering', () {
    repo.ensureIndexVersion('one');
    repo.embedding('note', 1, [0.123456789, -0.2, 0.5]);
    final listed = repo.all().single;
    expect(listed.vector, isNull);
    expect(listed.vectorRevision, 1);
    final loaded = repo.all(includeVectors: true).single.vector!;
    expect(loaded[0], closeTo(0.123456789, 1e-7));
    expect(loaded[1], closeTo(-0.2, 1e-7));
    expect(loaded[2], 0.5);
    double dot(List<double> vector) =>
        vector[0] * 0.3 + vector[1] * -0.1 + vector[2] * 0.8;
    expect(dot(loaded), greaterThan(dot([0.1, -0.1, 0.4])));
  });

  test('model switch rejects delayed generation and deletes cache on record cascade', () {
    repo.ensureIndexVersion('one');
    repo.ensureOrganizationVersion('cloud-one');
    repo.ensureIndexVersion('two');
    repo.ensureOrganizationVersion('cloud-two');
    expect(repo.embedding('note', 1, [1], modelVersion: 'one'), isFalse);
    expect(
      repo.derived('note', 1, {'title': '旧'}, modelVersion: 'cloud-one'),
      isFalse,
    );
    expect(repo.embedding('note', 1, [1], modelVersion: 'two'), isTrue);
    expect(
      repo.derived('note', 1, {
        'title': '新',
        'points': [],
        'tasks': [],
      }, modelVersion: 'cloud-two'),
      isTrue,
    );
    repo.delete('note');
    expect(repo.db.select('SELECT record_id FROM record_embeddings'), isEmpty);
    expect(
      repo.db.select('SELECT record_id FROM record_organizations'),
      isEmpty,
    );
  });

  test('vector dimensions and Float32 overflow are bounded', () {
    for (final vector in [
      <double>[],
      List<double>.filled(4097, 1),
      [double.infinity],
      [1e100],
    ]) {
      expect(repo.embedding('note', 1, vector), isFalse);
    }
    expect(repo.get('note')!.body, '原文');
  });

  test(
    'unserializable derived values never prevent insertion of original text',
    () {
      repo.insert(
        Record(
          id: 'bad-organization',
          body: '不能丢失',
          createdAt: DateTime.utc(2026),
          timezone: 'UTC',
          offsetMinutes: 0,
          organizationRevision: 1,
          organization: {'bad': double.nan},
        ),
      );
      expect(repo.get('bad-organization')!.body, '不能丢失');
      expect(repo.derived('note', 1, {'bad': double.infinity}), isFalse);
    },
  );
}
