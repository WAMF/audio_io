import 'dart:typed_data';

import 'package:audio_io/src/output_ring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('capacity rounds up to a power of two', () {
    expect(OutputRing(1000).capacity, 1024);
    expect(OutputRing(1024).capacity, 1024);
    expect(OutputRing(1025).capacity, 2048);
  });

  test('write then unity-ratio read returns the same samples', () {
    final ring = OutputRing(16);
    ring.write([0.1, 0.2, 0.3, 0.4]);

    final out = Float32List(4);
    ring.readResampled(out, 4, 1);

    // Linear interpolation starts from the implicit previous sample (0),
    // then tracks the input exactly at unity ratio.
    expect(out[1], closeTo(0.1, 1e-6));
    expect(out[2], closeTo(0.2, 1e-6));
    expect(out[3], closeTo(0.3, 1e-6));
  });

  test('overflow drops the excess and counts it', () {
    final ring = OutputRing(4); // capacity 4
    final accepted = ring.write(List.filled(10, 1.0));

    expect(accepted, 4);
    expect(ring.droppedFrames, 6);
    expect(ring.available, 4);
  });

  test('underrun produces silence and recovers', () {
    final ring = OutputRing(8);
    final out = Float32List(4);
    ring.readResampled(out, 4, 1);
    expect(out, everyElement(0));

    ring.write([0.5, 0.5]);
    ring.readResampled(out, 2, 1);
    expect(out[1], closeTo(0.5, 1e-6));
  });

  test('downsampling ratio consumes proportionally more source frames', () {
    final ring = OutputRing(2048);
    ring.write(List<double>.generate(1088, (i) => i / 1088));

    final out = Float32List(1000);
    // 48000 source frames per 44100 output frames.
    ring.readResampled(out, 1000, 48000 / 44100);

    // ~1088 source frames consumed for 1000 output frames.
    expect(ring.available, lessThan(8));

    // Output remains monotonic - no discontinuities.
    for (var i = 2; i < 1000; i++) {
      expect(out[i], greaterThanOrEqualTo(out[i - 1]));
    }
  });

  test('reads spanning multiple writes are continuous', () {
    final ring = OutputRing(64);
    final first = Float32List(10);
    final second = Float32List(20);
    ring.write(List<double>.generate(20, (i) => i / 20));
    ring.readResampled(first, 10, 1);
    ring.write(List<double>.generate(20, (i) => (20 + i) / 20));
    ring.readResampled(second, 20, 1);

    final all = [...first, ...second];
    var previous = all[1];
    for (var i = 2; i < all.length; i++) {
      expect((all[i] - previous).abs(), lessThan(0.1));
      previous = all[i];
    }
  });
}
