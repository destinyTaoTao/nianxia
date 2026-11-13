import '../data/storage.dart';
import '../data/record_search_store.dart';
import '../domain/ports.dart';
import '../domain/record.dart';
import '../domain/semantic_vector.dart';
import '../domain/search_page.dart';

import 'dart:async';

import 'package:uuid/uuid.dart';

/// Inference stays at the adapter seam; all scanning and ranking execute beside
/// the database in its owning isolate.
class RecordSearch {
  RecordSearch(this.repository, {required this.isClosed});
  final Storage repository;
  final bool Function() isClosed;
  static String normalize(String text) => RecordSearchStore.normalize(text);
  Future<SearchPage> searchPage(
    SearchQuery query, {
    SearchCursor? after,
    Embedder? embedder,
    SearchCancellation? cancellation,
    int limit = 40,
  }) async {
    if (cancellation?.requested == true) {
      throw const NotebookException('查找已取消。');
    }
    if (isClosed() || normalize(query.text).isEmpty) return SearchPage([]);
    List<double>? vector;
    String? fallback, model;
    if (after == null) {
      model = await repository.indexModelVersion;
      if (embedder != null) {
        try {
          vector = unitVector(await embedder.embed(query.text, query: true));
        } catch (_) {
          fallback = '语义查找暂不可用，已使用关键词查找。';
        }
      }
    }
    if (cancellation?.requested == true) {
      throw const NotebookException('查找已取消。');
    }
    if (isClosed()) return SearchPage([]);
    final requestId = after?.queryId ?? const Uuid().v4();
    final pending = repository.searchPage(
      query,
      requestId: requestId,
      after: after,
      vector: vector,
      model: model,
      fallback: fallback,
      semanticRequested: embedder != null,
      limit: limit,
    );
    final detach = cancellation?.listen(
      () => unawaited(
        repository.cancelSearch(requestId).catchError((Object _) {}),
      ),
    );
    try {
      final result = await pending;
      if (cancellation?.requested == true) {
        throw const NotebookException('查找已取消。');
      }
      return isClosed() ? SearchPage([]) : result;
    } finally {
      detach?.call();
    }
  }

  Future<SearchResults> search(
    String query, {
    DateTime? from,
    DateTime? to,
    Embedder? embedder,
  }) async {
    final q = normalize(query);
    if (q.isEmpty || isClosed()) return SearchResults([]);
    final model = await repository.indexModelVersion;
    List<double>? vector;
    String? fallback;
    if (embedder != null) {
      try {
        vector = unitVector(await embedder.embed(query, query: true));
      } catch (_) {
        fallback = '语义查找暂不可用，已使用关键词查找。';
      }
    }
    if (isClosed()) return SearchResults([]);
    return repository.search(
      q,
      from: from,
      to: to,
      vector: vector,
      model: model,
      fallback: fallback,
      semanticRequested: embedder != null,
    );
  }
}
