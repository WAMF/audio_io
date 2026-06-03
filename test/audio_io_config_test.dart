import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/audio_io.dart';

void main() {
  group('AudioIoConfig', () {
    test('defaults to rejecting a web sample-rate mismatch', () {
      const config = AudioIoConfig();
      expect(config.allowSampleRateMismatch, isFalse);
      expect(config.sampleRate, AudioIoSampleRate.rate48000);
      expect(config.format, AudioIoFormat.float64);
    });

    test('allowSampleRateMismatch can be opted into', () {
      const config = AudioIoConfig(
        sampleRate: AudioIoSampleRate.rate16000,
        format: AudioIoFormat.pcm16,
        allowSampleRateMismatch: true,
      );
      expect(config.allowSampleRateMismatch, isTrue);
      expect(config.sampleRate.hz, 16000);
      expect(config.format.value, AudioIoFormat.pcm16.value);
    });

    test('frameDurationMs is validated to the 20-100 ms range', () {
      expect(() => AudioIoConfig(frameDurationMs: 50), returnsNormally);
      expect(
        () => AudioIoConfig(frameDurationMs: 10),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => AudioIoConfig(frameDurationMs: 200),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
