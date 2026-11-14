import 'package:flutter/foundation.dart';

import '../domain/ports.dart';

enum InferenceCapability { speech, semantic }

/// The scheduler's seam: readiness, generation and inference, without model
/// paths, downloads, platform channels or native runtime details.
abstract interface class InferenceRuntime
    implements Transcriber, Embedder, Listenable {
  String? get searchModelVersion;
  String? get speechModelVersion;
  void setCaptureActive(bool active);
  Future<void> close();
  Future<bool> ready(InferenceCapability capability);
  @override
  Future<String> transcribe(String path, {bool foreground = true});
}
