import 'audio_io_input_source.dart';

/// Stable string values carried by [AudioIoException.code].
///
/// Lives in `src/` (rather than the public `audio_io.dart`) so the platform
/// implementations under `lib/src/` can raise typed errors without importing
/// the public library, which would be a circular import — the same reason
/// [AudioIoInputSource] lives here. Re-exported from `audio_io.dart`.
class AudioIoErrorCodes {
  const AudioIoErrorCodes._();

  static const microphonePermissionDenied = 'MICROPHONE_PERMISSION_DENIED';

  /// The requested [AudioIoInputSource] is not available on this platform /
  /// audio backend — e.g. [AudioIoInputSource.systemAudio] on Linux (where
  /// WASAPI loopback does not exist) or on a non-Chromium browser (where
  /// `getDisplayMedia` returns no audio track).
  static const systemAudioUnsupported = 'SYSTEM_AUDIO_UNSUPPORTED';
}

/// Error raised by `AudioIo` for typed, recoverable audio failures.
///
/// Defined in `src/` so platform implementations can construct it directly;
/// re-exported from `audio_io.dart` for consumers.
class AudioIoException implements Exception {
  AudioIoException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final dynamic details;

  bool get isPermissionDenied =>
      code == AudioIoErrorCodes.microphonePermissionDenied;

  /// True when the failure is a system-audio input source that the current
  /// platform / backend cannot provide.
  bool get isSystemAudioUnsupported =>
      code == AudioIoErrorCodes.systemAudioUnsupported;

  @override
  String toString() => 'AudioIoException($code): $message';
}
