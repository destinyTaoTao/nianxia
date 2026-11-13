import 'record.dart';

class RecordCursor {
  const RecordCursor(this.createdAt, this.id);
  final String createdAt, id;
}

/// A display projection. Body is limited to 600 SQLite characters; source
/// text, transcripts and derived payloads must be read through get/detail.
class RecordListEntry {
  const RecordListEntry(this.record, this.appendCount);
  final Record record;
  final int appendCount;
}

class RecordPage {
  const RecordPage(
    this.entries,
    this.next,
    this.generation, {
    this.reset = false,
  });
  final List<RecordListEntry> entries;
  final RecordCursor? next;
  final int generation;
  final bool reset;
}

class RecordDetail {
  const RecordDetail(this.record, this.children, this.childCount);
  final Record record;
  final RecordPage children;
  final int childCount;
}
