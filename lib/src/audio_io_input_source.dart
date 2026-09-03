/// Where the input audio stream is captured from.
///
/// Lives in `src/` (rather than the public `audio_io.dart`) so the
/// platform implementations under `lib/src/` can reference it without
/// importing the public library, which would be a circular import. It is
/// re-exported from `audio_io.dart` for consumers.
///
/// The enum index is part of the native contract (the FFI back ends key
/// their device topology off it), so new values are only ever appended.
enum AudioIoInputSource {
  /// The default microphone / capture endpoint (existing behaviour).
  microphone,

  /// The system audio mix — what is currently playing out of the machine
  /// (meetings, media, other apps). Implemented on Windows via WASAPI
  /// loopback (#33), on macOS via Core Audio process taps (#32), and on the
  /// web via `getDisplayMedia` (#34). The host process is excluded from the
  /// capture where the platform supports it, so an app playing TTS through
  /// the output stream does not hear itself.
  systemAudio,

  /// The microphone and the system audio mix summed into one mono stream —
  /// for a voice assistant that must keep hearing its user while it also
  /// listens to a meeting playing on the machine. macOS only (the
  /// AVAudioEngine mixer sums the microphone and the process tap); other
  /// back ends report it unsupported.
  microphoneAndSystemAudio;

  /// True when the source includes the machine's audio mix.
  bool get includesSystemAudio => this != AudioIoInputSource.microphone;

  /// True when the source includes the microphone.
  bool get includesMicrophone => this != AudioIoInputSource.systemAudio;
}
