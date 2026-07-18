import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the input source the control flow configures on the backend, and
/// advertises systemAudio support so a `startWith(systemAudio)` reaches
/// `start()`. Engine methods are stubbed; only the input-source contract of
/// the [AudioIo] start/stop flow is under test.
class _RecordingImpl extends AudioIoImpl {
  final List<AudioIoInputSource> configuredSources = [];
  int startCount = 0;
  int stopCount = 0;

  AudioIoInputSource get lastConfiguredSource => configuredSources.last;

  @override
  bool get usePlatformImpl => true;
  @override
  Stream<List<double>>? get inputAudioStream => const Stream.empty();
  @override
  StreamSink<List<double>>? get outputAudioStream => null;

  @override
  void configureInputSource(AudioIoInputSource source) {
    configuredSources.add(source);
  }

  @override
  bool supportsInputSource(AudioIoInputSource source) => true;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }

  @override
  Future<void> clearOutput() async {}
  @override
  Map<String, dynamic> getFormat() => const {};
  @override
  Future<void> requestFrameDuration(double duration) async {}
  @override
  Future<double> getFrameDuration() async => 0;
  @override
  Sink<Uint8List>? pcm16OutputSink(int sourceRate) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('input source reset across sessions', () {
    test('startWith(systemAudio) -> stop -> start() reopens on microphone',
        () async {
      final backend = _RecordingImpl();
      final audio = AudioIo.withImpl(backend);

      await audio.startWith(
        const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
      );
      expect(backend.lastConfiguredSource, AudioIoInputSource.systemAudio);
      expect(audio.currentConfig?.inputSource, AudioIoInputSource.systemAudio);

      await audio.stop();
      expect(audio.currentConfig, isNull);

      // The legacy plain start() must reset the backend to the microphone
      // rather than silently reusing the retained systemAudio source.
      await audio.start();
      expect(backend.lastConfiguredSource, AudioIoInputSource.microphone);
      expect(audio.currentConfig, isNull);
    });

    test('startWith does not reset an explicitly configured source', () async {
      final backend = _RecordingImpl();
      final audio = AudioIo.withImpl(backend);

      await audio.startWith(
        const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
      );

      // start() is invoked inside startWith with _config already set, so the
      // configured source must survive to the backend unchanged.
      expect(backend.lastConfiguredSource, AudioIoInputSource.systemAudio);
    });
  });
}
