/// Where the input audio stream is captured from.
///
/// Lives in `src/` (rather than the public `audio_io.dart`) so the
/// platform implementations under `lib/src/` can reference it without
/// importing the public library, which would be a circular import. It is
/// re-exported from `audio_io.dart` for consumers.
enum AudioIoInputSource {
  /// The default microphone / capture endpoint (existing behaviour).
  microphone,

  /// The system audio mix — what is currently playing out of the machine
  /// (meetings, media, other apps). Implemented on Windows via WASAPI
  /// loopback (#33); planned on macOS via Core Audio process taps (#32).
  /// The host process is excluded from the capture where the platform
  /// supports it, so an app playing TTS through the output stream does not
  /// hear itself.
  systemAudio,
}
