import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioBufferStatus', () {
    test('creates with required parameters', () {
      const status = AudioBufferStatus(
        availableFrames: 512,
        capacityFrames: 2048,
      );

      expect(status.availableFrames, 512);
      expect(status.capacityFrames, 2048);
    });

    test('fillRatio calculates correctly', () {
      const status = AudioBufferStatus(
        availableFrames: 512,
        capacityFrames: 2048,
      );

      expect(status.fillRatio, 0.25);
    });

    test('fillRatio returns 0 when capacity is 0', () {
      const status = AudioBufferStatus(
        availableFrames: 0,
        capacityFrames: 0,
      );

      expect(status.fillRatio, 0);
    });

    test('fillRatio handles full buffer', () {
      const status = AudioBufferStatus(
        availableFrames: 2048,
        capacityFrames: 2048,
      );

      expect(status.fillRatio, 1.0);
    });

    test('fillRatio handles empty buffer', () {
      const status = AudioBufferStatus(
        availableFrames: 0,
        capacityFrames: 2048,
      );

      expect(status.fillRatio, 0.0);
    });

    test('fillRatio handles half-full buffer', () {
      const status = AudioBufferStatus(
        availableFrames: 1024,
        capacityFrames: 2048,
      );

      expect(status.fillRatio, 0.5);
    });
  });

  group('AudioIo', () {
    test('bufferStatus stream is accessible', () {
      expect(AudioIo.instance.bufferStatus, isA<Stream<AudioBufferStatus>>());
    });

    test('output sink is accessible', () {
      expect(AudioIo.instance.output, isA<Sink<List<double>>>());
    });

    test('input stream is accessible', () {
      expect(AudioIo.instance.input, isA<Stream<List<double>>>());
    });
  });
}
