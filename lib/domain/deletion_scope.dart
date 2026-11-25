/// The exact in-memory source range approved by a deletion confirmation.
/// No source body or audio path crosses the storage seam in this receipt.
class DeletionScope {
  const DeletionScope({
    required this.id,
    required this.parentId,
    required this.count,
    required this.digest,
  });
  final String id;
  final String? parentId;
  final int count;
  final String digest;
}
