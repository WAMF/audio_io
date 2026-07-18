import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/output_buffer_math.dart';
import 'package:flutter_test/flutter_test.dart';

bool _isPowerOfTwo(int n) => n > 0 && (n & (n - 1)) == 0;

void main() {
  group('AudioIoConfig.outputBufferDuration', () {
    test('defaults to null (each back end keeps its existing sizing)', () {
      const config = AudioIoConfig();
      expect(config.outputBufferDuration, isNull);
    });

    test('retains an explicit output buffer duration', () {
      const config = AudioIoConfig(outputBufferDuration: 0.5);
      expect(config.outputBufferDuration, 0.5);
    });

    test('is independent of the latency preset', () {
      const config = AudioIoConfig(
        latency: AudioIoLatency.Realtime,
        outputBufferDuration: 5,
      );
      expect(config.latency, AudioIoLatency.Realtime);
      expect(config.outputBufferDuration, 5);
    });
  });

  // Guards the web AudioWorklet (primary browser back end) output ring
  // sizing. Before this, the worklet path ignored outputBufferDuration and
  // hardcoded a 65536-frame ring (~1.37 s at 48 kHz), so multi-second pushes
  // truncated even though the ScriptProcessor fallback honoured the duration.
  // The capacity is now computed here (and passed to the worklet via
  // processorOptions), so it is unit-testable on the VM; wiring the worklet
  // to consume it is exercised end-to-end in a real Chromium browser.
  group('outputWorkletCapacityFrames (browser worklet ring sizing)', () {
    const defaultCapacity = 65536; // ~1.37 s at 48 kHz

    test('null duration keeps the historical default capacity', () {
      expect(outputWorkletCapacityFrames(null, 48000), defaultCapacity);
    });

    test('a duration below the default does not shrink the ring', () {
      // 0.5 s @ 48 kHz = 24000 frames < 65536, so the proven floor holds.
      expect(outputWorkletCapacityFrames(0.5, 48000), defaultCapacity);
    });

    test('a multi-second duration grows the ring to fit (regression)', () {
      // 5 s @ 48 kHz = 240000 frames; next power of two is 262144. The old
      // fixed 65536 ring would have truncated this to ~1.37 s.
      final capacity = outputWorkletCapacityFrames(5, 48000);
      expect(capacity, 262144);
      expect(capacity, greaterThanOrEqualTo((5 * 48000).ceil()));
    });

    test('sizing follows the actual context rate, not the 48 kHz contract',
        () {
      // 5 s @ 44.1 kHz = 220500 frames; next power of two is 262144.
      expect(outputWorkletCapacityFrames(5, 44100), 262144);
    });

    test('the capacity is always a power of two (masked ring indexing)', () {
      for (final seconds in <double?>[null, 0.1, 0.5, 1, 2, 3, 5, 10, 30]) {
        for (final rate in <double>[44100, 48000, 96000]) {
          expect(_isPowerOfTwo(outputWorkletCapacityFrames(seconds, rate)),
              isTrue,
              reason: 'seconds=$seconds rate=$rate must yield a power of two');
        }
      }
    });

    test('capacity is monotonic in the requested duration', () {
      var previous = 0;
      for (final seconds in <double>[0.5, 1, 2, 5, 10, 20]) {
        final capacity = outputWorkletCapacityFrames(seconds, 48000);
        expect(capacity, greaterThanOrEqualTo(previous));
        previous = capacity;
      }
    });

    test('a non-positive context rate falls back to the default', () {
      expect(outputWorkletCapacityFrames(5, 0), defaultCapacity);
    });
  });
}
