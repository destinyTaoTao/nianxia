import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/platform/organizer.dart';
import 'package:nianxia/platform/calendar.dart';

class CapturingTransport implements CloudTransport {
  CapturingTransport(this.response, {this.status = 200, this.wait});
  final String response;
  final int status;
  final Future<void>? wait;
  final requests = <Map<String, dynamic>>[];
  @override
  Future<CloudResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    requests.add({
      'url': uri.toString(),
      'headers': headers,
      'body': jsonDecode(body),
    });
    if (wait != null) {
      await wait;
    }
    return CloudResponse(status, response);
  }
}

String result({String evidence = '暂时不做同步'}) => jsonEncode({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {
        'content': jsonEncode({
          'title': '同步边界',
          'points': [
            {'text': '暂时不做同步', 'evidence': evidence},
          ],
          'tasks': [],
        }),
      },
    },
  ],
});
void main() {
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-cloud-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    book.dispose();
    await home.delete(recursive: true);
  });
  test('逐次确认只发送单条正文，结果独立绑定修订，编辑后过期', () async {
    final r = await book.saveText('暂时不做同步');
    await book.saveText('其他私密笔记不应被发送');
    final consent = book.prepareOrganization(r.id);
    final wire = CapturingTransport(result());
    expect(
      await book.organize(
        consent,
        DeepSeekOrganizer(key: 'test-secret', transport: wire),
      ),
      isTrue,
    );
    final sent = jsonEncode(wire.requests.single['body']);
    expect(sent, contains('暂时不做同步'));
    expect(sent, isNot(contains('其他私密笔记')));
    expect(sent, isNot(contains('test-secret')));
    expect(
      wire.requests.single['url'],
      'https://api.deepseek.com/chat/completions',
    );
    expect(book.get(r.id)!.body, '暂时不做同步');
    await book.edit(r.id, '暂时不做同步，先观察', expectedRevision: r.revision);
    expect(book.get(r.id)!.organizationStale, isTrue);
    await expectLater(
      book.organize(
        consent,
        DeepSeekOrganizer(key: 'test-secret', transport: wire),
      ),
      throwsA(isA<NotebookException>()),
    );
    expect(wire.requests.length, 1);
  });
  test('并发删除和重复点击不会复活记录或重放付费请求', () async {
    final r = await book.saveText('暂时不做同步');
    final consent = book.prepareOrganization(r.id);
    final gate = Completer<void>();
    final wire = CapturingTransport(result(), wait: gate.future);
    final engine = DeepSeekOrganizer(key: 'test-secret', transport: wire);
    final work = book.organize(consent, engine);
    await expectLater(
      book.organize(consent, engine),
      throwsA(isA<NotebookException>()),
    );
    await book.delete(r.id);
    gate.complete();
    expect(await work, isFalse);
    expect(book.records, isEmpty);
    expect(wire.requests.length, 1);
  });
  test('错误、重定向、空白、截断和无来源结果均失败且不自动重试', () async {
    for (final wire in [
      CapturingTransport('', status: 429),
      CapturingTransport('', status: 302),
      CapturingTransport('not json'),
      CapturingTransport(result(evidence: '无中生有')),
      CapturingTransport('{"choices":[{"finish_reason":"length"}]}'),
      CapturingTransport(
        '{"choices":[{"finish_reason":"stop","message":{"content":"  "}}]}',
      ),
    ]) {
      final r = await book.saveText('暂时不做同步');
      await expectLater(
        book.organize(
          book.prepareOrganization(r.id),
          DeepSeekOrganizer(key: 'test-secret', transport: wire),
        ),
        throwsA(isA<NotebookException>()),
      );
      expect(book.get(r.id)!.organization, isNull);
      expect(wire.requests.length, 1);
    }
  });
  test('日历校验明确时段和提醒，不把打开编辑器当保存', () {
    final event = CalendarEvent(
      title: '检查试用反馈',
      start: DateTime(2026, 11, 9, 9),
      end: DateTime(2026, 11, 9, 10),
      reminderMinutes: 15,
    );
    expect(event.validate(), isNull);
    expect(event.toMap()['reminderMinutes'], 15);
    expect(
      CalendarEvent(title: '', start: event.start, end: event.end).validate(),
      isNotNull,
    );
    expect(
      CalendarEvent(title: '测试', start: event.end, end: event.start).validate(),
      isNotNull,
    );
    expect(CalendarOutcome.unknown.message, contains('未确认'));
  });
}
