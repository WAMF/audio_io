/// Where the audio transport (device polling, ring buffer I/O, and the
/// copies between native memory and Dart) runs.
enum AudioIoThreading {
  /// Transport runs on the main isolate. Default, and the only mode where
  /// audio delivery is unaffected by isolate spawn support.
  mainIsolate,

  /// Transport runs on a dedicated audio isolate so device polling and
  /// buffer copies are immune to main-isolate jank (heavy builds, GC).
  ///
  /// Supported on the FFI back ends (Android, Windows, Linux); other
  /// platforms fall back to [mainIsolate] behavior. The [Stream] / [Sink]
  /// API still surfaces on the main isolate — listener callbacks run
  /// there, so heavy DSP should still be moved off the listener if it
  /// competes with UI work.
  audioIsolate,
}
