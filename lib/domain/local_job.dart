enum JobKind { transcription, embedding }

enum JobState { pending, running, succeeded, failed, cancelled, stale }

enum JobOutcome {
  succeeded,
  failedTransient,
  failedPermanent,
  stale,
  cancelled,
}

/// Rebuildable execution metadata. User content is held only by the source.
class LocalJob {
  const LocalJob({
    required this.key,
    required this.kind,
    required this.sourceId,
    required this.sourceRevision,
    required this.modelGeneration,
    required this.state,
    required this.attempt,
    required this.nextAttemptAt,
    required this.leaseToken,
    this.errorCode,
  });
  final String key, sourceId, modelGeneration, leaseToken;
  final JobKind kind;
  final int sourceRevision, attempt;
  final JobState state;
  final DateTime nextAttemptAt;
  final String? errorCode;
}
