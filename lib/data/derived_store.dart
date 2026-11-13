import 'dart:convert';
import 'dart:typed_data';

/// Cache codecs are deliberately bounded. A cache miss never hides user data.
class DerivedCodec {
  static const formatVersion = 1;
  static const maxDimensions = 4096;
  static const maxOrganizationBytes = 1024 * 1024;

  static Map<String, dynamic>? organization(Object? value) {
    if (value is! String || value.length > maxOrganizationBytes) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> && _organizationShape(decoded)
          ? decoded
          : null;
    } on FormatException {
      return null;
    }
  }

  // Validate the stored format's types independently of current source text:
  // an older, well-formed organization may still be shown as stale after edits.
  static bool _organizationShape(Map<String, dynamic> value) {
    final points = value['points'];
    final tasks = value['tasks'];
    return value['title'] is String &&
        points is List &&
        tasks is List &&
        points.every(
          (item) =>
              item is Map<String, dynamic> &&
              item['text'] is String &&
              item['evidence'] is String,
        ) &&
        tasks.every(
          (item) =>
              item is Map<String, dynamic> &&
              item['title'] is String &&
              item['evidence'] is String &&
              item['timeText'] is String &&
              item['location'] is String,
        );
  }

  static String? encodeOrganization(Map<String, dynamic> value) {
    if (!_organizationShape(value)) return null;
    try {
      final encoded = jsonEncode(value);
      return utf8.encode(encoded).length <= maxOrganizationBytes
          ? encoded
          : null;
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  static Uint8List? encodeVector(List<double> vector) {
    if (vector.isEmpty || vector.length > maxDimensions) return null;
    final bytes = ByteData(vector.length * 4);
    for (var i = 0; i < vector.length; i++) {
      if (!vector[i].isFinite) return null;
      bytes.setFloat32(i * 4, vector[i], Endian.little);
      if (!bytes.getFloat32(i * 4, Endian.little).isFinite) return null;
    }
    return bytes.buffer.asUint8List();
  }

  static List<double>? vector(Object? value, Object? dimension) {
    if (value is! Uint8List ||
        dimension is! int ||
        dimension < 1 ||
        dimension > maxDimensions ||
        value.length != dimension * 4) {
      return null;
    }
    final bytes = ByteData.sublistView(value);
    // Stored values are already Float32. Keep them in one owned numeric
    // buffer: a generic double list boxes every value, while a view would
    // alias the caller's BLOB and change its mutation/lifetime contract.
    final vector = Float32List(dimension);
    for (var i = 0; i < dimension; i++) {
      final number = bytes.getFloat32(i * 4, Endian.little);
      if (!number.isFinite) return null;
      vector[i] = number;
    }
    return vector;
  }

  static Uint8List? legacyVector(Object? value) {
    if (value is! String || value.length > maxDimensions * 32) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! List ||
          decoded.isEmpty ||
          decoded.length > maxDimensions ||
          decoded.any((v) => v is! num)) {
        return null;
      }
      return encodeVector(decoded.map((v) => (v as num).toDouble()).toList());
    } on FormatException {
      return null;
    }
  }
}
