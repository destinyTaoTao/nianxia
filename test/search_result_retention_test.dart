import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/search_page.dart';

Future<void> _collect(Uri service) async {
  final socket = await WebSocket.connect(service.toString());
  final reply = Completer<void>();
  final subscription = socket.listen(
    (message) {
      final data = jsonDecode(message as String) as Map<String, dynamic>;
      if (data['id'] != 1) return;
      if (data.containsKey('error')) {
        reply.completeError(StateError('VM collection request failed'));
      } else {
        reply.complete();
      }
    },
    onError: (Object error) {
      if (!reply.isCompleted) {
        reply.completeError(StateError('VM connection failed'));
      }
    },
  );
  try {
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'getAllocationProfile',
        'params': {
          'isolateId': developer.Service.getIsolateId(Isolate.current),
          'gc': true,
        },
      }),
    );
    await reply.future.timeout(const Duration(seconds: 10));
  } finally {
    await subscription.cancel();
    await socket.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('已完成的搜索结果在资料库仍打开时可以回收', () async {
    final service = (await developer.Service.getInfo()).serverWebSocketUri;
    if (service == null) {
      markTestSkipped(
        'Run this heap gate with flutter test --enable-vmservice --no-dds',
      );
      return;
    }
    final home = await Directory.systemTemp.createTemp('nx-search-retention-');
    final book = await Notebook.open(home);
    Future<WeakReference<Object>> search(bool paged) async {
      final Object result = paged
          ? await book.searchPage(SearchQuery(text: 'retention marker'))
          : await book.search('retention marker');
      return WeakReference(result);
    }

    try {
      await book.saveText('synthetic retention marker');
      final references = <WeakReference<Object>>[];
      for (var i = 0; i < 48; i++) {
        references.add(await search(i.isEven));
      }
      await _collect(service);
      await _collect(service);
      final retained = references
          .where((reference) => reference.target != null)
          .length;
      debugPrint(
        'Search result heap retention: $retained/${references.length}',
      );
      expect(book.isClosed, isFalse);
      expect(retained, lessThanOrEqualTo(2));
    } finally {
      await book.close();
      await home.delete(recursive: true);
    }
  });
}
