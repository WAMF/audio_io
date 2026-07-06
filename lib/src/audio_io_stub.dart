import 'dart:async';
import 'dart:typed_data';

import 'audio_io_threading.dart';

/// Stub implementation for platform detection
abstract class AudioIoImpl {
  bool get usePlatformImpl;
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;

  Future<void> start();
  Future<void> stop();

  /// Discards audio queued for playback but not yet rendered.
  Future<void> clearOutput();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<double> getFrameDuration();

  /// Selects where the audio transport runs for the next [start].
  /// Platforms without dedicated-isolate support ignore this.
  void configureThreading(AudioIoThreading threading) {}

  /// Direct PCM16 output ingestion at [sourceRate], bypassing the Dart-side
  /// decode/resample adapters when the back end can do both natively (the
  /// web AudioWorklet decodes and resamples on the audio rendering thread).
  /// Returns null when unsupported; callers then use the adapter path.
  Sink<Uint8List>? pcm16OutputSink(int sourceRate) => null;
}

AudioIoImpl createAudioIoImpl() => throw UnsupportedError(
    'Cannot create audio implementation on this platform');
