import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/search_page.dart';

void main() {
  test('同页父摘要与命中片段有界，不改变分页排名和完整原文', () async {
    final root = await Directory.systemTemp.createTemp('nx-origin-projection-');
    final book = await Notebook.open(root);
    try {
      final parent = await book.saveText('${'原' * 300}\n${'文' * 80000}');
      for (var i = 0; i < 95; i++) {
        await book.saveText('标记$i ${'宽' * 6000}', parentId: parent.id);
      }
      final first = await book.searchPage(SearchQuery(text: '标记'));
      expect(first.entries, hasLength(40));
      expect(first.next, isNotNull);
      expect(first.entries.first.toMap()['parentTitle'], isNotNull);
      final ids = <String>[];
      var page = first;
      while (true) {
        for (final hit in page.entries) {
          final map = hit.toMap();
          ids.add(hit.id);
          expect(
            (map['parentTitle'] as String).runes.length,
            lessThanOrEqualTo(120),
          );
          expect(hit.title.runes.length, lessThanOrEqualTo(120));
          expect(hit.snippet.runes.length, lessThanOrEqualTo(150));
          expect(map.containsKey('body'), isFalse);
          expect(map.containsKey('audio'), isFalse);
        }
        expect(utf8.encode(jsonEncode(page.toMap())).length, lessThan(100000));
        if (page.next == null) break;
        page = await book.searchPage(SearchQuery(text: '标记'), after: page.next);
      }
      expect(ids.toSet(), hasLength(95));
      expect((await book.get(parent.id))!.body, parent.body);
    } finally {
      await book.close();
      await root.delete(recursive: true);
    }
  });
}
