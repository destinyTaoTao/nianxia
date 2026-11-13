import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/derived_store.dart';
import 'package:nianxia/data/record_repository.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/domain/semantic_vector.dart';

List<double> referenceUnit(List<double> v) {
  final scale = v.fold<double>(0, (a, b) => math.max(a, b.abs()));
  final scaled = v.map((x) => x / scale).toList();
  final norm = math.sqrt(scaled.fold<double>(0, (a, b) => a + b * b));
  return scaled.map((x) => x / norm).toList();
}

void main() {
  test('source SQLite page cache has a portable two MiB connection budget', () {
    final home = Directory.systemTemp.createTempSync('nianxia-cache-budget-');
    final repo = RecordRepository(home);
    try {
      final size =
          repo.db.select('PRAGMA cache_size').single.values.single as int;
      final page =
          repo.db.select('PRAGMA page_size').single.values.single as int;
      final budget = size < 0 ? -size * 1024 : size * page;
      expect(budget, lessThanOrEqualTo(2 * 1024 * 1024));
    } finally {
      repo.close();
      home.deleteSync(recursive: true);
    }
  });
  test(
    'normalization keeps double precision in one bounded numeric buffer',
    () {
      final random = math.Random(17);
      for (final magnitude in [1.0, 1e300, 1e-300]) {
        final input = List.generate(
          512,
          (_) => (random.nextDouble() * 2 - 1) * magnitude,
        );
        final saved = [...input];
        final result = unitVector(input);
        expect(result, orderedEquals(referenceUnit(input)));
        expect(input, orderedEquals(saved));
        expect(
          result,
          isA<TypedData>(),
          reason: 'Avoid boxed values and backing slot lists',
        );
        expect((result as TypedData).lengthInBytes, 512 * 8);
        result[0] = 0;
        expect(input, orderedEquals(saved));
      }
    },
  );
  test(
    'decoded Float32 vectors have owned bounded payload and exact values',
    () {
      final encoded = DerivedCodec.encodeVector([0.123456789, -2.5, 1e-30])!;
      for (final offset in [0, 1, 4]) {
        final backing = Uint8List(encoded.length + offset + 7);
        backing.setRange(offset, offset + encoded.length, encoded);
        final slice = Uint8List.sublistView(
          backing,
          offset,
          offset + encoded.length,
        );
        final result = DerivedCodec.vector(slice, 3)!;
        final expected = List.generate(
          3,
          (i) => ByteData.sublistView(encoded).getFloat32(i * 4, Endian.little),
        );
        expect(result, orderedEquals(expected));
        expect(
          result,
          isA<TypedData>(),
          reason: 'Do not expand Float32 payload into boxed doubles',
        );
        expect((result as TypedData).lengthInBytes, encoded.length);
        slice.fillRange(0, slice.length, 0);
        expect(
          result,
          orderedEquals(expected),
          reason: 'Do not retain caller-owned BLOB aliases',
        );
        result[0] = 9;
        expect(slice, everyElement(0));
      }
    },
  );
  test('invalid and extreme vector contracts are unchanged', () {
    for (final v in <List<double>>[
      [],
      [0, 0],
      [double.nan],
      [double.infinity],
      List.filled(4097, 1),
    ]) {
      expect(() => unitVector(v), throwsA(isA<NotebookException>()));
    }
    expect(
      unitVector([double.minPositive, -double.minPositive]),
      orderedEquals(referenceUnit([double.minPositive, -double.minPositive])),
    );
    final invalid = ByteData(4)..setFloat32(0, double.infinity, Endian.little);
    expect(DerivedCodec.vector(invalid.buffer.asUint8List(), 1), isNull);
    expect(DerivedCodec.vector(Uint8List(3), 1), isNull);
    expect(DerivedCodec.vector(Uint8List(4), 0), isNull);
  });
}
