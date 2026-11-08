import 'dart:convert';
import 'dart:collection';

class Record {
  const Record({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.timezone,
    required this.offsetMinutes,
    this.parentId,
    this.revision = 1,
    this.favorite = false,
    this.audio,
    this.durationMs = 0,
    this.transcript,
    this.transcription = 'none',
    this.organization,
    this.organizationRevision,
    this.vector,
    this.vectorRevision,
  });
  final String id, body, timezone, transcription;
  final String? parentId, audio, transcript;
  final DateTime createdAt;
  final int offsetMinutes, revision, durationMs;
  final bool favorite;
  final Map<String, dynamic>? organization;
  final int? organizationRevision, vectorRevision;
  final List<double>? vector;
  DateTime get recordedLocal =>
      createdAt.toUtc().add(Duration(minutes: offsetMinutes));
  bool get organizationStale =>
      organization != null && organizationRevision != revision;
  String get title =>
      body.trim().isEmpty ? '语音记录' : body.trim().split('\n').first;
  Map<String, dynamic> toJson() => {
    'id': id, 'parentId': parentId, 'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(), 'timezone': timezone,
    'offsetMinutes': offsetMinutes, 'revision': revision, 'favorite': favorite,
    'audio': audio, 'durationMs': durationMs, 'transcript': transcript,
    'transcription': transcription,
    // Derived content is inspectable; indexes and jobs are rebuilt on restore.
    'organization': organization, 'organizationRevision': organizationRevision,
  };
  factory Record.fromJson(Map<String, dynamic> j) => Record(
    id: j['id'] as String,
    parentId: j['parentId'] as String?,
    body: j['body'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String).toUtc(),
    timezone: j['timezone'] as String,
    offsetMinutes: j['offsetMinutes'] as int,
    revision: j['revision'] as int,
    favorite: j['favorite'] as bool,
    audio: j['audio'] as String?,
    durationMs: j['durationMs'] as int,
    transcript: j['transcript'] as String?,
    transcription: j['transcription'] as String,
    organization: j['organization'] as Map<String, dynamic>?,
    organizationRevision: j['organizationRevision'] as int?,
  );
  String get canonical => jsonEncode(toJson());
}

class NotebookException implements Exception {
  const NotebookException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SearchHit {
  const SearchHit(this.record, this.snippet, this.score);
  final Record record;
  final String snippet;
  final double score;
}

class SearchResults extends UnmodifiableListView<SearchHit> {
  SearchResults(super.source, {this.semanticUsed = false, this.fallbackReason});
  final bool semanticUsed;
  final String? fallbackReason;
}
