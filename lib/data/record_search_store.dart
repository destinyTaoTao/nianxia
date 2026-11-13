import 'dart:math' as math;

import '../domain/record.dart';
import '../domain/semantic_vector.dart';
import 'record_repository.dart';

class RecordSearchStore {
  RecordSearchStore(this.repository);
  final RecordRepository repository;

  static String normalize(String text) => String.fromCharCodes(
    text.runes.map(
      (c) => c == 0x3000 ? 32 : (c >= 0xff01 && c <= 0xff5e ? c - 0xfee0 : c),
    ),
  ).toLowerCase().trim();

  Future<SearchResults> scan(
    String q,
    DateTime? from,
    DateTime? to,
    List<double>? vector,
    String model,
    String? fallback,
    bool semanticRequested, {
    int? semanticLimit,
    bool indexingPending = false,
    Object Function()? sourceGeneration,
    void Function(SearchHit)? onKeywordHit,
    bool Function()? cancelled,
  }) async {
    final hits = <SearchHit>[];
    final semanticHits = <SearchHit>[];
    Object version() =>
        sourceGeneration?.call() ?? repository.contentGeneration;
    var generation = version();
    var semanticUsed = false;
    var pending = 0;
    int compare(SearchHit a, SearchHit b) => a.score != b.score
        ? b.score.compareTo(a.score)
        : b.record.createdAt.compareTo(a.record.createdAt);
    String? after;
    final start = from == null
        ? null
        : DateTime(from.year, from.month, from.day);
    final end = to == null ? null : DateTime(to.year, to.month, to.day);
    while (true) {
      if (cancelled?.call() == true) throw const NotebookException('查找已取消。');
      if (generation != version()) {
        hits.clear();
        semanticHits.clear();
        pending = 0;
        after = null;
        semanticUsed = false;
        generation = version();
      }
      if (vector != null && model != repository.indexModelVersion) {
        // Earlier pages may contain scores from the old generation. Restart
        // once as keyword-only rather than mix two embedding spaces.
        return scan(
          q,
          from,
          to,
          null,
          model,
          '语义模型已切换，已使用关键词查找。',
          semanticRequested,
          semanticLimit: semanticLimit,
          indexingPending: indexingPending,
          sourceGeneration: sourceGeneration,
          onKeywordHit: onKeywordHit,
          cancelled: cancelled,
        );
      }
      final page = repository.searchPage(
        after: after,
        includeVectors: vector != null,
      );
      if (page.isEmpty) break;
      for (final r in page) {
        final local = r.recordedLocal;
        final date = DateTime(local.year, local.month, local.day);
        if (start != null && date.isBefore(start) ||
            end != null && date.isAfter(end)) {
          continue;
        }
        final text = normalize(r.body);
        final exact = text.contains(q);
        var score = exact ? 2.0 : 0.0;
        if (vector != null &&
            r.vectorRevision == r.revision &&
            r.vector?.length == vector.length) {
          try {
            final document = unitVector(r.vector!);
            semanticUsed = true;
            pending++;
            var cosine = 0.0;
            for (var i = 0; i < document.length; i++) {
              cosine += document[i] * vector[i];
            }
            // Calibrated synthetic smoke cutoff, not a confidence score.
            if (cosine >= 0.60) score += cosine.clamp(-1.0, 1.0);
          } on NotebookException {
            // Invalid derived data cannot prevent keyword retrieval.
          }
        }
        if (score <= 0) continue;
        final at = math.max(0, text.indexOf(q) - 30);
        final snippetEnd = math.min(r.body.length, at + 150);
        final hit = SearchHit(
          r.withoutVector,
          r.body.substring(math.min(at, r.body.length), snippetEnd),
          score,
        );
        if (exact && onKeywordHit != null) {
          onKeywordHit(hit);
        } else if (exact || semanticLimit == null) {
          hits.add(hit);
        } else if (semanticHits.length < semanticLimit ||
            compare(hit, semanticHits.last) < 0) {
          if (semanticHits.length == semanticLimit) semanticHits.removeLast();
          semanticHits.add(hit);
          semanticHits.sort(compare);
        }
      }
      after = page.last.id;
      // Let capture, cancellation, edits and lifecycle events run between pages.
      await Future<void>.delayed(Duration.zero);
    }
    hits.addAll(semanticHits);
    hits.sort(compare);
    return SearchResults(
      hits,
      semanticUsed: semanticUsed,
      pendingSemanticRecords: indexingPending ? pending : 0,
      fallbackReason:
          fallback ??
          (semanticRequested && !semanticUsed ? '语义索引尚未就绪，显示关键词结果。' : null),
    );
  }
}
