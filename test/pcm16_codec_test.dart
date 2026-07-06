import 'dart:math';
import 'dart:typed_data';

import 'package:audio_io/src/pcm16_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pcm16 codec', () {
    test('encodes doubles to little-endian signed 16-bit', () {
      final bytes = float64ToPcm16Bytes([0, 1.0, -1.0]);
      final view = ByteData.sublistView(bytes);

      expect(bytes.length, 6);
      expect(view.getInt16(0, Endian.little), 0);
      expect(view.getInt16(2, Endian.little), 32767);
      expect(view.getInt16(4, Endian.little), -32767);
    });

    test('clamps out-of-range samples to full scale', () {
      final bytes = float64ToPcm16Bytes([2.0, -2.0]);
      final view = ByteData.sublistView(bytes);

      expect(view.getInt16(0, Endian.little), 32767);
      expect(view.getInt16(2, Endian.little), -32767);
    });

    test('decodes little-endian signed 16-bit back to doubles', () {
      final data = ByteData(6)
        ..setInt16(0, 0, Endian.little)
        ..setInt16(2, 32767, Endian.little)
        ..setInt16(4, -32767, Endian.little);

      final samples = pcm16BytesToFloat64(data.buffer.asUint8List());

      expect(samples, [0.0, 1.0, -1.0]);
    });

    test('decodes an unaligned byte view identically to an aligned one', () {
      // The fast path views the bytes as an Int16List, which requires a
      // 2-byte-aligned offset; an odd-offset view must take the ByteData
      // fallback and produce identical samples.
      final backing = Uint8List(7);
      final aligned = ByteData.sublistView(backing, 0)
        ..setInt16(1, 12345, Endian.little)
        ..setInt16(3, -32767, Endian.little)
        ..setInt16(5, 255, Endian.little);
      expect(aligned, isNotNull);
      final unaligned = Uint8List.sublistView(backing, 1);
      final alignedCopy = Uint8List.fromList(unaligned);

      expect(pcm16BytesToFloat64(unaligned), pcm16BytesToFloat64(alignedCopy));
      expect(pcm16BytesToFloat64(unaligned),
          [12345 / pcm16FullScale, -1.0, 255 / pcm16FullScale]);
    });

    test('round-trips a sine wave within one LSB', () {
      final input = List<double>.generate(
        256,
        (i) => sin(2 * pi * i / 256),
      );

      final restored = pcm16BytesToFloat64(float64ToPcm16Bytes(input));

      expect(restored.length, input.length);
      const tolerance = 1 / pcm16FullScale;
      for (var i = 0; i < input.length; i++) {
        expect((restored[i] - input[i]).abs(), lessThanOrEqualTo(tolerance));
      }
    });
  });
}
