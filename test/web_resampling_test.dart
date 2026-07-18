import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_io/src/pcm16_codec.dart';
import 'package:audio_io/src/pcm16_adapters.dart';
import 'package:audio_io/src/push_resampler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for issue #8 — Dart-side resampling for the Web
/// AudioContext sample-rate mismatch.
///
/// The Web Audio API only exposes audio at the browser's native
/// `AudioContext.sampleRate` (typically 48 kHz), which cannot be changed
/// programmatically. `audio_io` bridges the caller's requested rate and the
/// browser rate with two cooperating resamplers that share one arithmetic:
///
///  * the JS `AudioWorkletProcessor`s in `audio_io_web.dart` (`AudioIoOutput`
///    / `AudioIoInput`) convert between the browser rate and the 48 kHz
///    engine contract on the audio rendering thread, and
///  * the Dart [Pcm16Adapters] / [PushResampler] convert between the 48 kHz
///    contract and the caller's requested PCM16 rate on the main isolate.
///
/// The worklet JS is a line-for-line mirror of [PushResampler]'s phase
/// arithmetic (see the `push()` / `process()` loops in `_workletSource`) but
/// cannot run under `flutter test` (it needs a real browser). These tests
/// pin the shared arithmetic and the Dart wiring that back the three web
/// acceptance criteria, so a regression on either side is caught in CI:
///
///  * AC: `start()` accepts any supported rate without throwing, resampling
///    transparently when the browser rate differs.
///  * AC: input PCM16 bytes are emitted at the *requested* rate, not the
///    browser rate (mic -> `inputBytes`).
///  * AC: output PCM16 bytes written at the *requested* rate are up/downsampled
///    to the browser rate on the way to the speakers (`outputBytes` -> worklet).
void main() {
  // Representative web rate pairs: a 48 kHz browser context (the common case)
  // against the two realtime-voice rates the package advertises (16 kHz for
  // Gemini Live / OpenAI Realtime input, 24 kHz for output), plus the
  // 44.1 kHz browser context that makes the equal-rate assumption fail.
  const browser48k = 48000;
  const browser44k = 44100;
  const rate16k = 16000;
  const rate24k = 24000;

  group('PushResampler — web browser<->requested rate pairs', () {
    // The worklet output path resamples requested -> browser; the worklet
    // input path resamples browser -> requested. Both are PushResampler with
    // the corresponding (source, target) pair, so the ratio invariant below
    // covers both directions.

    test('down-sampling emits fewer samples at the target ratio (48k->16k)',
        () {
      final resampler = PushResampler(browser48k, rate16k);
      var produced = 0;
      const chunks = 500;
      const chunkFrames = 480;
      for (var c = 0; c < chunks; c++) {
        produced += resampler.process(List.filled(chunkFrames, 0.3)).length;
      }
      const expected = chunks * chunkFrames * rate16k / browser48k;
      expect((produced - expected).abs(), lessThanOrEqualTo(1));
      expect(produced, lessThan(chunks * chunkFrames)); // fewer -> downsampled
    });

    test('down-sampling to 24 kHz emits ~half the samples (48k->24k)', () {
      final resampler = PushResampler(browser48k, rate24k);
      var produced = 0;
      const chunks = 500;
      const chunkFrames = 480;
      for (var c = 0; c < chunks; c++) {
        produced += resampler.process(List.filled(chunkFrames, -0.2)).length;
      }
      const expected = chunks * chunkFrames * rate24k / browser48k;
      expect((produced - expected).abs(), lessThanOrEqualTo(1));
    });

    test('up-sampling emits more samples at the target ratio (16k->48k)', () {
      final resampler = PushResampler(rate16k, browser48k);
      var produced = 0;
      const chunks = 500;
      const chunkFrames = 160; // 10 ms at 16 kHz
      for (var c = 0; c < chunks; c++) {
        produced += resampler.process(List.filled(chunkFrames, 0.4)).length;
      }
      const expected = chunks * chunkFrames * browser48k / rate16k;
      // Residual phase at the end can carry up to one input sample's worth of
      // output (ceil(target/source) == 3 for 48k/16k).
      expect((produced - expected).abs(), lessThanOrEqualTo(3));
      expect(produced, greaterThan(chunks * chunkFrames)); // more -> upsampled
    });

    test('up-sampling from a 24 kHz stream to a 48 kHz browser (24k->48k)', () {
      final resampler = PushResampler(rate24k, browser48k);
      var produced = 0;
      const chunks = 500;
      const chunkFrames = 240; // 10 ms at 24 kHz
      for (var c = 0; c < chunks; c++) {
        produced += resampler.process(List.filled(chunkFrames, 0.1)).length;
      }
      const expected = chunks * chunkFrames * browser48k / rate24k;
      expect((produced - expected).abs(), lessThanOrEqualTo(2));
    });

    test('equal browser/requested rate is an exact passthrough (48k==48k)',
        () {
      final resampler = PushResampler(browser48k, browser48k);
      final input = List<double>.generate(480, (i) => math.sin(i * 0.05));
      final output = resampler.process(input);
      expect(output.length, input.length);
      for (var i = 0; i < input.length; i++) {
        expect(output[i], closeTo(input[i], 1e-6));
      }
    });

    test('a DC level is preserved through resampling (no gain error)', () {
      // The mismatch case that actually reaches the browser: 44.1 kHz context.
      final resampler = PushResampler(browser44k, rate16k);
      resampler.process(List.filled(441, 0.75)); // prime the phase/prev state
      final steady = resampler.process(List.filled(4410, 0.75));
      expect(steady, isNotEmpty);
      for (final sample in steady) {
        expect(sample, closeTo(0.75, 1e-6));
      }
    });

    test('a sine wave stays continuous across chunk boundaries (44.1k->16k)',
        () {
      final resampler = PushResampler(browser44k, rate16k);
      const freq = 300.0;
      final output = <double>[];
      var index = 0;
      const total = browser44k ~/ 2; // 0.5 s
      while (index < total) {
        final chunk = List<double>.generate(
          441,
          (i) => math.sin(2 * math.pi * freq * (index + i) / browser44k),
        );
        output.addAll(resampler.process(chunk));
        index += 441;
      }
      // Largest sample-to-sample step of a 300 Hz sine at 16 kHz is
      // 2*pi*300/16000 ~= 0.118; allow a small margin for interpolation.
      var maxStep = 0.0;
      for (var i = 2; i < output.length; i++) {
        maxStep = math.max(maxStep, (output[i] - output[i - 1]).abs());
      }
      expect(maxStep, lessThan(0.14));
    });
  });

  group('Pcm16Adapters — web input path (mic -> inputBytes at requested rate)',
      () {
    // On web the input worklet resamples the browser rate to the 48 kHz
    // contract before the Float64 `input` stream, so the adapter always sees a
    // 48 kHz engine rate here and must resample the *contract* down to the
    // requested PCM16 rate. This is the second, Dart-side stage of the web
    // input path — the stage that guarantees `inputBytes` is at the requested
    // rate rather than the browser (or contract) rate.
    late StreamController<List<double>> engineInput;
    late StreamController<List<double>> engineOutput;

    setUp(() {
      engineInput = StreamController<List<double>>.broadcast();
      engineOutput = StreamController<List<double>>.broadcast();
    });

    tearDown(() {
      engineInput.close();
      engineOutput.close();
    });

    Future<int> inputSamplesFor(int requestedRate) async {
      final adapters = Pcm16Adapters();
      final chunks = <Uint8List>[];
      adapters.inputBytes.listen(chunks.add);
      await adapters.wire(
        inputStreamRate: requestedRate,
        outputStreamRate: requestedRate,
        inputEngineRate: browser48k, // worklet delivers the 48 kHz contract
        outputEngineRate: browser48k,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
      );
      final engineFrame = List<double>.filled(480, 0.5); // 10 ms at 48 kHz
      engineInput.add(engineFrame);
      await Future<void>.delayed(Duration.zero);
      adapters.dispose();
      return chunks.fold<int>(0, (n, c) => n + c.length ~/ 2);
    }

    test('16 kHz request downsamples the 48 kHz contract frame', () async {
      final samples = await inputSamplesFor(rate16k);
      final expected =
          PushResampler(browser48k, rate16k).process(List.filled(480, 0)).length;
      expect(samples, expected);
      expect(samples, lessThan(480)); // requested rate < contract -> fewer
    });

    test('24 kHz request downsamples by half', () async {
      final samples = await inputSamplesFor(rate24k);
      final expected =
          PushResampler(browser48k, rate24k).process(List.filled(480, 0)).length;
      expect(samples, expected);
    });

    test('48 kHz request passes the contract frame through unchanged',
        () async {
      final samples = await inputSamplesFor(browser48k);
      expect(samples, 480); // equal rate -> passthrough, byte-for-byte count
    });
  });

  group('Pcm16Adapters — web output path (outputBytes at requested rate)', () {
    // On web the output PCM16 sink is the AudioWorklet itself: `AudioIoWeb`
    // returns a direct sink from `pcm16OutputSink(requestedRate)` and the
    // adapter forwards the caller's bytes to it UNTOUCHED, so the requested ->
    // browser resampling happens on the rendering thread (mirrored by the
    // 48k<->requested PushResampler tests above). These tests pin that the
    // adapter takes the direct path and hands the worklet the caller's bytes
    // at the requested rate, and that the fallback (no worklet) Dart path
    // upsamples the requested rate to the 48 kHz contract instead.
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

    test('worklet path forwards requested-rate bytes to the direct sink '
        'untouched (no Dart resample)', () async {
      // Models AudioIoWeb handing PCM16 straight to the output worklet, which
      // resamples requested -> browser on the rendering thread.
      final direct = <Uint8List>[];
      final adapters = Pcm16Adapters();
      await adapters.wire(
        inputStreamRate: rate24k,
        outputStreamRate: rate24k,
        inputEngineRate: browser48k,
        outputEngineRate: browser48k,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
        directOutputBytes: _CollectingSink(direct.add),
      );

      final requestedBytes = float64ToPcm16Bytes(
        List<double>.generate(240, (i) => math.sin(i * 0.02)),
      ); // 240 samples == 10 ms at 24 kHz
      adapters.outputBytes.add(requestedBytes);
      await Future<void>.delayed(Duration.zero);

      // Bytes reach the worklet verbatim at the requested rate...
      expect(direct, hasLength(1));
      expect(direct.single, equals(requestedBytes));
      // ...and the Dart engine-output path is bypassed entirely.
      expect(engineOutSamples, isEmpty);

      adapters.dispose();
    });

    test('fallback (no worklet) upsamples requested rate to the 48 kHz '
        'contract feed', () async {
      // Models the ScriptProcessor fallback: no direct sink, so the adapter
      // decodes + resamples requested -> contract in Dart before the engine.
      final adapters = Pcm16Adapters();
      await adapters.wire(
        inputStreamRate: rate24k,
        outputStreamRate: rate24k,
        inputEngineRate: browser48k,
        outputEngineRate: browser48k,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
      );

      final requestedBytes =
          Int16List(240).buffer.asUint8List(); // 240 samples at 24 kHz
      adapters.outputBytes.add(requestedBytes);
      await Future<void>.delayed(Duration.zero);

      final expected = PushResampler(rate24k, browser48k)
          .process(List<double>.filled(240, 0))
          .length;
      expect(engineOutSamples.length, expected);
      expect(engineOutSamples.length, greaterThan(240)); // upsampled to 48 kHz

      adapters.dispose();
    });

    test('equal requested/contract rate leaves the fallback feed unchanged',
        () async {
      final adapters = Pcm16Adapters();
      await adapters.wire(
        inputStreamRate: browser48k,
        outputStreamRate: browser48k,
        inputEngineRate: browser48k,
        outputEngineRate: browser48k,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
      );

      adapters.outputBytes.add(Int16List(480).buffer.asUint8List());
      await Future<void>.delayed(Duration.zero);
      expect(engineOutSamples.length, 480); // passthrough

      adapters.dispose();
    });
  });
}

/// Minimal [Sink] that records every added chunk — stands in for the web
/// output worklet's PCM16 sink so the forward-untouched contract is observable.
class _CollectingSink implements Sink<Uint8List> {
  _CollectingSink(this._onAdd);

  final void Function(Uint8List) _onAdd;

  @override
  void add(Uint8List data) => _onAdd(data);

  @override
  void close() {}
}
