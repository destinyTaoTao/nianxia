import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/search_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'search summaries use Unicode scalar budgets and no raw/derived payload',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-search-summary-');
      final book = await Notebook.open(home);
      try {
        await book.saveText('marker ${List.filled(1000, '🔒中').join()}');
        final result = await book.searchPage(SearchQuery(text: 'marker'));
        final entry = result.entries.single;
        expect(entry.title.runes.length, lessThanOrEqualTo(120));
        expect(entry.snippet.runes.length, lessThanOrEqualTo(150));
        final payload = entry.toMap();
        for (final field in ['body', 'transcript', 'organization', 'vector']) {
          expect(payload.containsKey(field), isFalse);
        }
        expect(entry.kind, MatchKind.keyword);
      } finally {
        await book.close();
        await home.delete(recursive: true);
      }
    },
  );
}
