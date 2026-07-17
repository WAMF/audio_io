import 'package:audio_io/audio_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioIoConfig.outputBufferDuration', () {
    test('defaults to null (each back end keeps its existing sizing)', () {
      const config = AudioIoConfig();
      expect(config.outputBufferDuration, isNull);
    });

    test('retains an explicit output buffer duration', () {
      const config = AudioIoConfig(outputBufferDuration: 0.5);
      expect(config.outputBufferDuration, 0.5);
    });

    test('is independent of the latency preset', () {
      const config = AudioIoConfig(
        latency: AudioIoLatency.Realtime,
        outputBufferDuration: 5,
      );
      expect(config.latency, AudioIoLatency.Realtime);
      expect(config.outputBufferDuration, 5);
    });
  });
}
