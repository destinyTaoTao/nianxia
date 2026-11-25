import 'dart:collection';
import 'dart:convert';

import 'record.dart';

class SearchQuery {
  SearchQuery({required this.text, this.from, this.to}) {
    if (text.length > 10000 ||
        from != null &&
            to != null &&
            DateTime(
              from!.year,
              from!.month,
              from!.day,
            ).isAfter(DateTime(to!.year, to!.month, to!.day))) {
      throw const NotebookException('查找内容或日期范围无效。');
    }
  }
  final String text;
  final DateTime? from, to;
  String get identity => jsonEncode([
    text,
    from == null ? null : [from!.year, from!.month, from!.day],
    to == null ? null : [to!.year, to!.month, to!.day],
  ]);
}

class SearchCancellation {
  bool _requested = false;
  bool get requested => _requested;
  final Set<void Function()> _listeners = {};
  void cancel() {
    if (_requested) return;
    _requested = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void Function() listen(void Function() callback) {
    if (_requested) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }
}

enum MatchKind { keyword, semantic }

class SearchHitSummary {
  SearchHitSummary({
    required this.id,
    required this.title,
    required this.snippet,
    required this.createdAt,
    required this.timezone,
    required this.offsetMinutes,
    required this.hasAudio,
    required this.durationMs,
    required this.kind,
    this.parentId,
    this.parentTitle,
  });
  final String id, title, snippet, timezone;
  final DateTime createdAt;
  final int offsetMinutes, durationMs;
  final bool hasAudio;
  final String? parentId;
  final String? parentTitle;
  final MatchKind kind;
  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'snippet': snippet,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'timezone': timezone,
    'offsetMinutes': offsetMinutes,
    'parentId': parentId,
    'parentTitle': parentTitle,
    'hasAudio': hasAudio,
    'durationMs': durationMs,
    'kind': kind.name,
  };
}

/// Consumers retain and return this cursor unchanged. Its keys contain no query or body.
class SearchCursor {
  const SearchCursor({
    required this.queryId,
    required this.score,
    required this.createdAt,
    required this.id,
    required this.generation,
    required this.model,
  });
  final String queryId, id, model;
  final int createdAt;
  final double score;
  final int generation;
  Map<String, Object> toMap() => {
    'version': 1,
    'queryId': queryId,
    'score': score,
    'createdAt': createdAt,
    'id': id,
    'generation': generation,
    'model': model,
  };
}

class SearchPage {
  SearchPage(
    List<SearchHitSummary> entries, {
    this.next,
    this.reset = false,
    this.semanticApproximate = false,
    this.fallbackReason,
    this.knownTotal,
  }) : entries = UnmodifiableListView(List.of(entries));
  final List<SearchHitSummary> entries;
  final SearchCursor? next;
  final bool reset, semanticApproximate;
  final String? fallbackReason;
  final int? knownTotal;
  Map<String, Object?> toMap() => {
    'entries': entries.map((e) => e.toMap()).toList(),
    'next': next?.toMap(),
    'reset': reset,
    'semanticApproximate': semanticApproximate,
    'fallbackReason': fallbackReason,
    'knownTotal': knownTotal,
  };
}
