import 'dart:async';

import 'package:nianxia/app/inference_runtime.dart';
import 'package:nianxia/app/notebook.dart';

import 'ui_native_capture.dart';

class SearchRuntime extends UiCaptureRuntime {
  final pending = <String, Completer<List<double>>>{};
  SearchRuntime({this.holdQueries = true});
  bool holdQueries;
  bool unavailable = false;
  @override
  Future<bool> ready(InferenceCapability capability) async =>
      capability == InferenceCapability.semantic;
  @override
  Future<List<double>> embed(String text, {required bool query}) async {
    if (unavailable) throw const NotebookException('model unavailable');
    if (!holdQueries) return [1, 0];
    return await pending
        .putIfAbsent(text, () => Completer<List<double>>())
        .future;
  }
}
