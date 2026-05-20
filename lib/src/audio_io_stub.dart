import 'dart:async';
import 'dart:typed_data';

abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;
  Stream<Uint8List>? get inputBytesStream;
  StreamSink<Uint8List>? get outputBytesSink;

  Future<void> start({int sampleRate = 48000, int format = 0});
  Future<void> stop();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
