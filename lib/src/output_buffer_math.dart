/// Pure sizing math for the output playback buffer, shared by the web back
/// end and unit tests. Kept free of `dart:js_interop`/`package:web` so it can
/// be exercised on the Dart VM (`flutter test`) without a browser.
library;

/// Frame capacity for the Web AudioWorklet output ring, sized to hold
/// [requestedSeconds] of audio at [contextSampleRate].
///
/// The worklet drains a single-producer/single-consumer ring whose read and
/// write positions are masked with `capacity - 1`, so the capacity must be a
/// power of two. It also never drops below [defaultCapacity] (65536 frames,
/// ~1.37 s at 48 kHz) — the fixed size the worklet used before
/// `outputBufferDuration` was configurable — so honouring the option can only
/// grow the ring, never shrink it below the previously proven default.
///
/// A null/non-positive [requestedSeconds] (or a non-positive
/// [contextSampleRate]) yields [defaultCapacity] unchanged.
int outputWorkletCapacityFrames(
  double? requestedSeconds,
  double contextSampleRate, {
  int defaultCapacity = 65536,
}) {
  var capacity = defaultCapacity;
  if (requestedSeconds != null &&
      requestedSeconds > 0 &&
      contextSampleRate > 0) {
    final target = (requestedSeconds * contextSampleRate).ceil();
    while (capacity < target) {
      capacity <<= 1;
    }
  }
  return capacity;
}
