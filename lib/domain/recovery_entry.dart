enum RecoveryKind { unfinishedCapture, quarantinedFile, unrecognizedJournal }

enum RecoveryProblem { interrupted, invalidAudio, missingAudio, unknownFormat }

class RecoveryEntry {
  const RecoveryEntry({
    required this.id,
    required this.kind,
    required this.modifiedAt,
    required this.bytes,
    required this.problem,
    required this.canDiscard,
    this.durationMs,
  });
  final String id;
  final RecoveryKind kind;
  final DateTime modifiedAt;
  final int bytes;
  final int? durationMs;
  final RecoveryProblem problem;
  final bool canDiscard;
  bool get canPlay => durationMs != null;
}

class RecoveryPage {
  RecoveryPage(List<RecoveryEntry> entries, {this.next})
    : entries = List.unmodifiable(entries);
  final List<RecoveryEntry> entries;
  final String? next;
}
