import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/data/derived_store.dart';
import 'package:nianxia/domain/record.dart';
import 'package:nianxia/domain/semantic_vector.dart';

import 'vector_allocation_test.dart' show referenceUnit;

double fromBits(String hex) {
  final bytes = ByteData(8)
    ..setUint32(0, int.parse(hex.substring(0, 8), radix: 16), Endian.big)
    ..setUint32(4, int.parse(hex.substring(8), radix: 16), Endian.big);
  return bytes.getFloat64(0, Endian.big);
}

String bits(double value) {
  final bytes = ByteData(8)..setFloat64(0, value, Endian.big);
  return '${bytes.getUint32(0, Endian.big).toRadixString(16).padLeft(8, '0')}'
      '${bytes.getUint32(4, Endian.big).toRadixString(16).padLeft(8, '0')}';
}

void main() {
  test(
    'normalization preserves literal Float64 signed-zero and boundary bits',
    () {
      const fixtures = <(List<String>, List<String>)>[
        (
          ['4008000000000000', '4010000000000000'],
          ['3fe3333333333333', '3fe999999999999a'],
        ),
        (
          ['8000000000000000', '0000000000000000', '3ff0000000000000'],
          ['8000000000000000', '0000000000000000', '3ff0000000000000'],
        ),
        (
          [
            '0000000000000001',
            '8000000000000001',
            '8000000000000000',
            '0000000000000000',
          ],
          [
            '3fe6a09e667f3bcc',
            'bfe6a09e667f3bcc',
            '8000000000000000',
            '0000000000000000',
          ],
        ),
        (
          ['000fffffffffffff', '800fffffffffffff'],
          ['3fe6a09e667f3bcc', 'bfe6a09e667f3bcc'],
        ),
        (
          ['0010000000000000', '8010000000000000'],
          ['3fe6a09e667f3bcc', 'bfe6a09e667f3bcc'],
        ),
        (
          ['7fefffffffffffff', 'ffefffffffffffff'],
          ['3fe6a09e667f3bcc', 'bfe6a09e667f3bcc'],
        ),
        (
          [
            '7fefffffffffffff',
            '0000000000000001',
            '8000000000000001',
            '8000000000000000',
            '0000000000000000',
          ],
          [
            '3ff0000000000000',
            '0000000000000000',
            '8000000000000000',
            '8000000000000000',
            '0000000000000000',
          ],
        ),
      ];
      for (final (inputBits, expected) in fixtures) {
        final input = inputBits.map(fromBits).toList();
        expect(unitVector(input).map(bits), orderedEquals(expected));
        expect(input.map(bits), orderedEquals(inputBits));
      }
    },
  );

  test(
    'normalization matches legacy Float64 bits across finite exponent patterns',
    () {
      final random = math.Random(20261113);
      for (var trial = 0; trial < 140; trial++) {
        final length = [1, 2, 3, 4, 511, 512, 513][trial % 7];
        final input = <double>[];
        while (input.length < length) {
          final hi = random.nextInt(0x100000000);
          final lo = random.nextInt(0x100000000);
          final b = ByteData(8)
            ..setUint32(0, hi, Endian.big)
            ..setUint32(4, lo, Endian.big);
          final value = b.getFloat64(0, Endian.big);
          if (value.isFinite) input.add(value);
        }
        if (input.every((v) => v == 0)) input[0] = 1;
        final before = input.map(bits).toList();
        expect(
          unitVector(input).map(bits),
          orderedEquals(referenceUnit(input).map(bits)),
          reason: 'trial=$trial length=$length',
        );
        expect(input.map(bits), orderedEquals(before));
      }
    },
  );

  test(
    'Float32 codec round-trips signed-zero subnormal and finite boundary bytes',
    () {
      const words = [
        0x00000000,
        0x80000000,
        0x00000001,
        0x80000001,
        0x007fffff,
        0x807fffff,
        0x00800000,
        0x80800000,
        0x3f800000,
        0xbf800000,
        0x7f7fffff,
        0xff7fffff,
      ];
      final raw = ByteData(words.length * 4);
      for (var i = 0; i < words.length; i++) {
        raw.setUint32(i * 4, words[i], Endian.little);
      }
      final expected = Uint8List.fromList(raw.buffer.asUint8List());
      for (final offset in [0, 1, 2, 3, 4]) {
        final backing = Uint8List(expected.length + offset + 9)
          ..fillRange(0, expected.length + offset + 9, 0x55);
        backing.setRange(offset, offset + expected.length, expected);
        final slice = Uint8List.sublistView(
          backing,
          offset,
          offset + expected.length,
        );
        final output = DerivedCodec.vector(slice, words.length)!;
        expect(
          DerivedCodec.encodeVector(output),
          orderedEquals(expected),
          reason: 'offset=$offset',
        );
        expect(slice, orderedEquals(expected));
        slice.fillRange(0, slice.length, 0);
        expect(
          DerivedCodec.encodeVector(output),
          orderedEquals(expected),
          reason: 'owned buffer offset=$offset',
        );
      }
    },
  );

  test('all-zero and nonfinite bit patterns reject without mutating input', () {
    for (final hex in [
      '0000000000000000',
      '8000000000000000',
      '7ff0000000000000',
      'fff0000000000000',
      '7ff8000000000001',
      '7ff0000000000001',
      'fff8000000001234',
    ]) {
      final input = [fromBits(hex)];
      final original = input.map(bits).toList();
      expect(() => unitVector(input), throwsA(isA<NotebookException>()));
      expect(input.map(bits), orderedEquals(original));
    }
    for (final word in [
      0x7f800000,
      0xff800000,
      0x7fc00001,
      0x7f800001,
      0xffc01234,
    ]) {
      final bytes = ByteData(4)..setUint32(0, word, Endian.little);
      final raw = bytes.buffer.asUint8List();
      final saved = Uint8List.fromList(raw);
      expect(DerivedCodec.vector(raw, 1), isNull);
      expect(
        DerivedCodec.encodeVector([bytes.getFloat32(0, Endian.little)]),
        isNull,
      );
      expect(raw, orderedEquals(saved));
    }
  });
}
