import 'dart:async';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/pcm16_adapters.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Pcm16Adapters lifecycle', () {
    // Regression for the single-subscription output controller defect: a
    // wire -> teardown -> wire restart re-listened the output byte controller
    // and threw `Bad state: Stream has already been listened to`. The adapter
    // lifecycle is owned by Pcm16Adapters (not the public AudioIo surface), so
    // it is exercised directly here with a stand-in engine input stream and
    // output sink, the same way the other src/ primitives are tested.

    late StreamController<List<double>> engineInput;
    late StreamController<List<double>> engineOutput;

    setUp(() {
      // Broadcast so the adapter can re-listen the engine input across wires.
      engineInput = StreamController<List<double>>.broadcast();
      engineOutput = StreamController<List<double>>.broadcast()
        ..stream.listen((_) {});
    });

    tearDown(() {
      engineInput.close();
      engineOutput.close();
    });

    Future<void> wire(Pcm16Adapters adapters, int streamRate) => adapters.wire(
          streamRate: streamRate,
          inputEngineRate: 48000,
          outputEngineRate: 48000,
          inputAudio: engineInput.stream,
          outputAudio: engineOutput.sink,
        );

    test('survives a wire -> teardown -> wire restart', () async {
      final adapters = Pcm16Adapters();
      await wire(adapters, AudioIoSampleRate.rate16000.hz);
      await adapters.teardown();
      // Threw here before the broadcast fix; must now re-wire cleanly.
      await wire(adapters, AudioIoSampleRate.rate16000.hz);
      adapters.dispose();
    });

    test('survives repeated restarts at a changed rate', () async {
      final adapters = Pcm16Adapters();
      await wire(adapters, AudioIoSampleRate.rate16000.hz);
      await adapters.teardown();
      await wire(adapters, AudioIoSampleRate.rate24000.hz);
      await adapters.teardown();
      await wire(adapters, AudioIoSampleRate.rate48000.hz);
      adapters.dispose();
    });

    test('directOutputBytes bypasses the Dart decode/resample path', () async {
      final adapters = Pcm16Adapters();
      final forwarded = <Uint8List>[];
      final engineSamples = <List<double>>[];
      engineOutput.stream.listen(engineSamples.add);

      await adapters.wire(
        streamRate: AudioIoSampleRate.rate16000.hz,
        inputEngineRate: 48000,
        outputEngineRate: 48000,
        inputAudio: engineInput.stream,
        outputAudio: engineOutput.sink,
        directOutputBytes: _CollectingSink(forwarded),
      );

      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      adapters.outputBytes.add(bytes);
      await Future<void>.delayed(Duration.zero);

      expect(forwarded, [bytes]);
      expect(engineSamples, isEmpty);
      adapters.dispose();
    });

    test('outputBytes is a reusable broadcast sink across restarts', () async {
      final adapters = Pcm16Adapters();
      // The same sink reference stays valid across a restart because the
      // controller is broadcast and persists (not closed on teardown).
      final sink = adapters.outputBytes;
      await wire(adapters, AudioIoSampleRate.rate16000.hz);
      sink.add(Uint8List.fromList([0, 0, 0, 0]));
      await adapters.teardown();
      await wire(adapters, AudioIoSampleRate.rate16000.hz);
      expect(() => sink.add(Uint8List.fromList([0, 0])), returnsNormally);
      adapters.dispose();
    });
  });

  group('AudioIo', () {
    test('clearOutput dispatch completes without a started engine', () async {
      // The host test runner has no platform plugin registered; a mock
      // handler stands in so the dispatch path itself is what's exercised.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.wearemobilefirst.audio_io'),
        (call) async => null,
      );

      final audio = AudioIo();
      await expectLater(audio.clearOutput(), completes);
      audio.dispose();
    });

    test('config carries the optional threading mode', () {
      const defaulted = AudioIoConfig();
      const isolated = AudioIoConfig(threading: AudioIoThreading.audioIsolate);

      expect(defaulted.threading, AudioIoThreading.mainIsolate);
      expect(isolated.threading, AudioIoThreading.audioIsolate);
    });
  });
}

class _CollectingSink implements Sink<Uint8List> {
  _CollectingSink(this.collected);

  final List<Uint8List> collected;

  @override
  void add(Uint8List data) => collected.add(data);

  @override
  void close() {}
}
