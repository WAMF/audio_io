import 'dart:async';
import 'dart:typed_data';

abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;
  Stream<Uint8List>? get inputBytesStream;
  StreamSink<Uint8List>? get outputBytesSink;

  /// Starts capture/playback. [allowSampleRateMismatch] only affects the
  /// web implementation, where the browser controls the AudioContext rate
  /// and the requested rate cannot be guaranteed (see [AudioIoImpl]
  /// docs / web impl). Native backends honour [sampleRate] via the device
  /// and ignore this flag.
  Future<void> start({
    int sampleRate = 48000,
    int format = 0,
    bool allowSampleRateMismatch = false,
  });
  Future<void> stop();

  /// Discards audio queued for playback but not yet rendered.
  Future<void> clearOutput();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
