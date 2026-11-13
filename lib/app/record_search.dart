import '../data/storage.dart';
import '../data/record_search_store.dart';
import '../domain/ports.dart';
import '../domain/record.dart';
import '../domain/semantic_vector.dart';

/// Inference stays at the adapter seam; all scanning and ranking execute beside
/// the database in its owning isolate.
class RecordSearch {
  RecordSearch(this.repository, {required this.isClosed});
  final Storage repository;
  final bool Function() isClosed;
  static String normalize(String text) => RecordSearchStore.normalize(text);
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
