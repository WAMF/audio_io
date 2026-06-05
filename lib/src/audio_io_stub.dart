import 'dart:async';

/// Stub implementation for platform detection
abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;
  Stream<AudioBufferStatus>? get bufferStatusStream;

  Future<void> start();
  Future<void> stop();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();
}

class AudioBufferStatus {
  const AudioBufferStatus({
    required this.availableFrames,
    required this.capacityFrames,
  });

  final int availableFrames;
  final int capacityFrames;

  int get availableForWriting => capacityFrames - availableFrames;

  double get fillRatio =>
      capacityFrames > 0 ? availableFrames / capacityFrames : 0;
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
