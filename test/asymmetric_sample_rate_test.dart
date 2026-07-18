import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/pcm16_adapters.dart';
import 'package:audio_io/src/push_resampler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AudioIoConfig sample-rate resolution', () {
    test('sampleRate is the shorthand that applies to both directions', () {
      const config = AudioIoConfig(sampleRate: AudioIoSampleRate.rate16000);

      expect(config.sampleRate, AudioIoSampleRate.rate16000);
      expect(config.inputSampleRate, AudioIoSampleRate.rate16000);
      expect(config.outputSampleRate, AudioIoSampleRate.rate16000);
    });

    test('the default rate (48 kHz) resolves for both directions', () {
      const config = AudioIoConfig();

      expect(config.inputSampleRate, AudioIoSampleRate.rate48000);
      expect(config.outputSampleRate, AudioIoSampleRate.rate48000);
    });

    test('asymmetric per-direction rates are retained independently', () {
      const config = AudioIoConfig(
        inputSampleRate: AudioIoSampleRate.rate16000,
        outputSampleRate: AudioIoSampleRate.rate24000,
      );

      expect(config.inputSampleRate, AudioIoSampleRate.rate16000);
      expect(config.outputSampleRate, AudioIoSampleRate.rate24000);
    });

    test('one explicit direction falls back to sampleRate for the other', () {
      const inputOnly = AudioIoConfig(
        sampleRate: AudioIoSampleRate.rate24000,
        inputSampleRate: AudioIoSampleRate.rate16000,
      );
      expect(inputOnly.inputSampleRate, AudioIoSampleRate.rate16000);
      expect(inputOnly.outputSampleRate, AudioIoSampleRate.rate24000);

      const outputOnly = AudioIoConfig(
        sampleRate: AudioIoSampleRate.rate16000,
        outputSampleRate: AudioIoSampleRate.rate24000,
      );
      expect(outputOnly.inputSampleRate, AudioIoSampleRate.rate16000);
      expect(outputOnly.outputSampleRate, AudioIoSampleRate.rate24000);
    });
  });

  group('Pcm16Adapters per-direction resampling', () {
    late StreamController<List<double>> engineInput;
    late StreamController<List<double>> engineOutput;
    late List<double> engineOutSamples;

    setUp(() {
      engineInput = StreamController<List<double>>.broadcast();
      engineOutSamples = <double>[];
      engineOutput = StreamController<List<double>>.broadcast()
        ..stream.listen(engineOutSamples.addAll);
    });

    tearDown(() {
      engineInput.close();
      engineOutput.close();
    });

    test(
        'a single stream rate resamples both directions symmetrically '
        '(sampleRate-only path)', () async {
      final adapters = Pcm16Adapters();
      final inputChunks = <Uint8List>[];
      adapters.inputBytes.listen(inputChunks.add);

      const streamRate = AudioIoSampleRate.rate16000; // both directions
      await adapters.wire(
        inputStreamRate: streamRate.hz,
        outputStreamRate: streamRate.hz,
        inputEngineRate: 48000,
        outputEngineRate: 48000,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
      );

      // Input: 48 kHz engine frame -> 16 kHz bytes (downsample by 3).
      final engineFrame = List<double>.filled(480, 0.5);
      engineInput.add(engineFrame);
      await Future<void>.delayed(Duration.zero);
      final inputSamples =
          inputChunks.fold<int>(0, (n, c) => n + c.length ~/ 2);
      // Reference resampler with the same single call is a deterministic
      // oracle for the exact emitted-sample count.
      final expectedIn =
          PushResampler(48000, streamRate.hz).process(engineFrame).length;
      expect(inputSamples, expectedIn);
      expect(inputSamples, lessThan(engineFrame.length)); // downsampled

      // Output: 16 kHz bytes -> 48 kHz engine (upsample by 3).
      final outSamples = Int16List(160); // 160 samples at 16 kHz
      adapters.outputBytes.add(outSamples.buffer.asUint8List());
      await Future<void>.delayed(Duration.zero);
      final expectedOut = PushResampler(streamRate.hz, 48000)
          .process(List<double>.filled(160, 0))
          .length;
      expect(engineOutSamples.length, expectedOut);
      expect(engineOutSamples.length, greaterThan(160)); // upsampled

      adapters.dispose();
    });

    test('asymmetric input/output rates resample per direction', () async {
      final adapters = Pcm16Adapters();
      final inputChunks = <Uint8List>[];
      adapters.inputBytes.listen(inputChunks.add);

      const inputRate = AudioIoSampleRate.rate16000; // mic delivered at 16 kHz
      const outputRate = AudioIoSampleRate.rate24000; // speaker fed at 24 kHz
      await adapters.wire(
        inputStreamRate: inputRate.hz,
        outputStreamRate: outputRate.hz,
        inputEngineRate: 48000,
        outputEngineRate: 48000,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
      );

      // Input direction uses inputRate (16 kHz): 48 kHz -> 16 kHz.
      final engineFrame = List<double>.filled(480, 0.25);
      engineInput.add(engineFrame);
      await Future<void>.delayed(Duration.zero);
      final inputSamples =
          inputChunks.fold<int>(0, (n, c) => n + c.length ~/ 2);
      final expectedIn =
          PushResampler(48000, inputRate.hz).process(engineFrame).length;
      expect(inputSamples, expectedIn, reason: 'input must use inputStreamRate');

      // Output direction uses outputRate (24 kHz): 24 kHz -> 48 kHz.
      final outSamples = Int16List(240); // 240 samples at 24 kHz
      adapters.outputBytes.add(outSamples.buffer.asUint8List());
      await Future<void>.delayed(Duration.zero);
      final expectedOut = PushResampler(outputRate.hz, 48000)
          .process(List<double>.filled(240, 0))
          .length;
      expect(engineOutSamples.length, expectedOut,
          reason: 'output must use outputStreamRate');

      // Prove the two directions were NOT wired at the same rate: if output
      // had (wrongly) reused the 16 kHz input rate, 240 in-samples would
      // upsample to ~720, not ~480.
      final wrongOut = PushResampler(inputRate.hz, 48000)
          .process(List<double>.filled(240, 0))
          .length;
      expect(engineOutSamples.length, isNot(wrongOut));

      adapters.dispose();
    });
  });
}
