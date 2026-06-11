import 'dart:math' as math;

import 'package:audio_io/src/push_resampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PushResampler', () {
    test('identity rate copies input exactly', () {
      final resampler = PushResampler(48000, 48000);
      final input = List<double>.generate(480, (i) => math.sin(i * 0.1));
      final output = resampler.process(input);

      expect(output.length, 480);
      for (var i = 0; i < input.length; i++) {
        expect(output[i], closeTo(input[i], 1e-6));
      }
    });

    test('output count converges to the rate ratio across chunks', () {
      final resampler = PushResampler(48000, 44100);
      var produced = 0;
      const chunks = 1000;
      const chunkSize = 480;
      for (var c = 0; c < chunks; c++) {
        produced += resampler.process(List.filled(chunkSize, 0.5)).length;
      }

      const expected = chunks * chunkSize * 44100 / 48000;
      expect((produced - expected).abs(), lessThanOrEqualTo(1));
    });

    test('upsampling produces the rate ratio too', () {
      final resampler = PushResampler(48000, 96000);
      var produced = 0;
      for (var c = 0; c < 100; c++) {
        produced += resampler.process(List.filled(480, 0.25)).length;
      }
      expect((produced - 96000).abs(), lessThanOrEqualTo(2));
    });

    test('preserves a sine wave across chunk boundaries', () {
      final resampler = PushResampler(48000, 44100);
      const freq = 440.0;
      const seconds = 0.5;
      const totalIn = (48000 * seconds);

      final output = <double>[];
      var index = 0;
      while (index < totalIn) {
        final chunk = List<double>.generate(
          480,
          (i) => math.sin(2 * math.pi * freq * (index + i) / 48000),
        );
        output.addAll(resampler.process(chunk));
        index += 480;
      }

      // Skip the first sample (interpolated against the initial zero) and
      // verify there are no discontinuities anywhere in the output: the
      // largest sample-to-sample step of a 440 Hz sine at 44.1 kHz is
      // 2*pi*440/44100 ~= 0.063.
      var maxStep = 0.0;
      for (var i = 2; i < output.length; i++) {
        maxStep = math.max(maxStep, (output[i] - output[i - 1]).abs());
      }
      expect(maxStep, lessThan(0.08));
    });

    test('flat signal stays flat through resampling', () {
      final resampler = PushResampler(48000, 44100);
      resampler.process(List.filled(48, 1.0));
      final output = resampler.process(List.filled(480, 1.0));
      for (final sample in output) {
        expect(sample, closeTo(1.0, 1e-6));
      }
    });
  });
}
