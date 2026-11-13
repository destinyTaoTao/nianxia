import 'dart:math' as math;
import 'dart:typed_data';

import 'record.dart';

/// The embedding seam accepts finite, nonzero vectors; callers need not know
/// the adapter's output magnitude. Scale first to avoid overflow/underflow.
List<double> unitVector(List<double> vector) {
  if (vector.isEmpty || vector.length > 4096) {
    throw const NotebookException('语义模型返回无效向量。');
  }
  var scale = 0.0;
  for (var i = 0; i < vector.length; i++) {
    final value = vector[i];
    if (!value.isFinite) {
      throw const NotebookException('语义模型返回无效向量。');
    }
    scale = math.max(scale, value.abs());
  }
  if (scale == 0) throw const NotebookException('语义模型返回无效向量。');
  // Keep double precision and summation order, without boxed values or a
  // second normalized list. The caller's vector remains untouched.
  final result = Float64List(vector.length);
  var squared = 0.0;
  for (var i = 0; i < result.length; i++) {
    final value = vector[i] / scale;
    result[i] = value;
    squared += value * value;
  }
  final norm = math.sqrt(squared);
  for (var i = 0; i < result.length; i++) {
    result[i] /= norm;
  }
  return result;
}
