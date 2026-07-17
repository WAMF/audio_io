/// Raised by the native/FFI transport when the engine reports that the
/// requested input source cannot be provided on this operating system or audio
/// backend.
///
/// The chief case is WASAPI process-excluded loopback (system audio on
/// Windows), which requires Windows 11 / Windows Server 2022 (build 20348) or
/// newer; on older Windows the native device fails to initialise. The public
/// [AudioIo] API catches this and rethrows it as an `AudioIoException` whose
/// `isSystemAudioUnsupported` is true, so callers see one typed error
/// regardless of how far down the stack the limitation was detected.
class InputSourceUnsupportedException implements Exception {
  const InputSourceUnsupportedException(this.message);

  final String message;

  @override
  String toString() => 'InputSourceUnsupportedException: $message';
}
