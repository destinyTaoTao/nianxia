import 'dart:async';
import 'dart:io';

import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/domain/capture_session.dart';
import 'package:nianxia/platform/native_capture.dart';

import '../recording_search_test.dart' show writeWave;
import '../native_capture_handoff_test.dart' show HandoffRuntime;

import 'package:nianxia/app/inference_runtime.dart';

class UiCaptureRuntime extends HandoffRuntime {
  @override
  Future<bool> ready(InferenceCapability capability) async =>
      capability == InferenceCapability.speech;
}

class UiCaptureEndpoint implements NativeCapturePort {
  UiCaptureEndpoint(this.book);
  final Notebook book;
  CaptureSnapshot? value;
  int starts = 0, cancels = 0;
  final updates = StreamController<CaptureSnapshot>.broadcast();
  CaptureSnapshot snapshot(
    CaptureRequest request,
    NativeCapturePhase phase, {
    int bytes = 0,
  }) => CaptureSnapshot.fromMap({
    ...request.toMap(),
    'phase': phase.name,
    'sequence': (value?.sequence ?? 0) + 1,
    'elapsedMs': bytes == 0 ? 0 : 1000,
    'pcmBytes': bytes,
    'level': 0.1,
    if (phase == NativeCapturePhase.finalized)
      'relativeAudioName': '${request.sessionId}.wav',
  });
  String path(CaptureRequest request) =>
      '${book.home.path}/native-captures/${request.mode == CaptureMode.query ? 'queries/' : ''}${request.sessionId}.wav';
  @override
  Future<CaptureSnapshot> start(CaptureRequest request) async {
    starts++;
    value = snapshot(request, NativeCapturePhase.recording);
    updates.add(value!);
    return value!;
  }

  @override
  Future<CaptureSnapshot?> current() async => value;
  @override
  Future<List<CaptureSnapshot>> pending({
    String? after,
    int limit = 32,
  }) async => [];
  @override
  Future<CaptureSnapshot> stop(String id) async {
    if (value!.phase == NativeCapturePhase.finalized) return value!;
    final file = File(path(value!.request));
    await file.parent.create(recursive: true);
    await writeWave(file.path);
    value = snapshot(
      value!.request,
      NativeCapturePhase.finalized,
      bytes: 32000,
    );
    updates.add(value!);
    return value!;
  }

  @override
  Future<void> cancel(String id) async {
    cancels++;
    if (value != null) {
      final file = File(path(value!.request));
      if (await file.exists()) await file.delete();
      value = snapshot(value!.request, NativeCapturePhase.cancelled);
      updates.add(value!);
    }
  }

  @override
  Future<FinalizedCapture> claim(String id) async => FinalizedCapture(value!);
  @override
  Future<void> acknowledge(
    String id, {
    required CaptureDisposition disposition,
  }) async {
    value = null;
  }

  @override
  Stream<CaptureSnapshot> get events => updates.stream;
  @override
  Future<void> close() async {
    await updates.close();
  }
}
