abstract interface class Transcriber {
  Future<String> transcribe(String path);
}

abstract interface class Embedder {
  /// Return a finite, nonzero vector of at most 4096 dimensions. Within a model
  /// generation, query and document vectors must share dimensions and space.
  /// The notebook normalizes magnitude before cosine comparison.
  Future<List<double>> embed(String text, {required bool query});
}

abstract interface class Organizer {
  Future<Map<String, dynamic>> organize(String text);
}
