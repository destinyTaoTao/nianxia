abstract interface class Transcriber {
  Future<String> transcribe(String path);
}

abstract interface class Embedder {
  Future<List<double>> embed(String text, {required bool query});
}

abstract interface class Organizer {
  Future<Map<String, dynamic>> organize(String text);
}
