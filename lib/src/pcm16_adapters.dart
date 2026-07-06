import 'dart:async';
import 'dart:typed_data';

import 'pcm16_codec.dart';
import 'push_resampler.dart';

/// Owns the PCM16 (Int16 little-endian) byte <-> Float64 adapter lifecycle
/// that bridges the `AudioIo` byte streams to the engine's Float64 contract.
///
/// Lives here (package-internal) rather than inline on `AudioIo` so the
/// wire -> teardown -> wire restart invariant can be exercised directly by
/// tests — the same way the other `src/` primitives are tested — without
/// adding a test-only member to the public `AudioIo` API.
class Pcm16Adapters {
  StreamController<Uint8List>? _inputBytesController;
  StreamController<Uint8List>? _outputBytesController;
  StreamSubscription<List<double>>? _inputBytesSubscription;
  StreamSubscription<Uint8List>? _outputBytesSubscription;
  PushResampler? _inputResampler;
  PushResampler? _outputResampler;

  /// PCM16 input stream, resampled and encoded from the engine's capture rate.
  Stream<Uint8List> get inputBytes =>
      (_inputBytesController ??= StreamController<Uint8List>.broadcast())
          .stream;

  /// PCM16 output sink, decoded and resampled to the engine's contract rate.
  ///
  /// Broadcast (like [inputBytes]) so the adapter can re-listen across a
  /// teardown -> wire restart; a single-subscription controller threw
  /// `Bad state: Stream has already been listened to` on the second wire
  /// because [teardown] cancels the subscription but keeps the controller,
  /// and a retained sink reference would have been invalidated.
  Sink<Uint8List> get outputBytes =>
      (_outputBytesController ??= StreamController<Uint8List>.broadcast()).sink;

  /// Wires the byte adapters around the engine's [inputAudio] / [outputAudio]
  /// Float64 streams. [streamRate] is the rate callers see on the byte
  /// streams; [inputEngineRate] / [outputEngineRate] are the engine's actual
  /// capture/render rates. Re-callable: cancels any prior subscriptions first.
  ///
  /// When [directOutputBytes] is provided (a back end that decodes and
  /// resamples PCM16 natively, like the web AudioWorklet), output bytes are
  /// forwarded to it untouched and the Dart-side decode/resample is skipped.
  Future<void> wire({
    required int streamRate,
    required int inputEngineRate,
    required int outputEngineRate,
    required Stream<List<double>> inputAudio,
    required Sink<List<double>> outputAudio,
    Sink<Uint8List>? directOutputBytes,
  }) async {
    _outputResampler = PushResampler(streamRate, outputEngineRate);
    _inputResampler = PushResampler(inputEngineRate, streamRate);

    final outputBytesController =
        _outputBytesController ??= StreamController<Uint8List>.broadcast();
    await _outputBytesSubscription?.cancel();
    _outputBytesSubscription = directOutputBytes != null
        ? outputBytesController.stream.listen(directOutputBytes.add)
        : outputBytesController.stream.listen((bytes) {
            final samples = pcm16BytesToFloat64(bytes);
            outputAudio.add(_outputResampler!.process(samples));
          });

    final inputBytesController =
        _inputBytesController ??= StreamController<Uint8List>.broadcast();
    await _inputBytesSubscription?.cancel();
    _inputBytesSubscription = inputAudio.listen((frame) {
      if (!inputBytesController.hasListener) return;
      inputBytesController.add(
        float64ToPcm16Bytes(_inputResampler!.process(frame)),
      );
    });
  }

  /// Cancels the active subscriptions and resamplers but keeps the byte
  /// controllers, so a subsequent [wire] can re-listen and retained
  /// [inputBytes] / [outputBytes] references stay valid across a restart.
  Future<void> teardown() async {
    await _inputBytesSubscription?.cancel();
    await _outputBytesSubscription?.cancel();
    _inputBytesSubscription = null;
    _outputBytesSubscription = null;
    _inputResampler = null;
    _outputResampler = null;
  }

  /// Tears down and closes the byte controllers. Use on final disposal.
  void dispose() {
    unawaited(_inputBytesSubscription?.cancel());
    unawaited(_outputBytesSubscription?.cancel());
    _inputBytesSubscription = null;
    _outputBytesSubscription = null;
    _inputResampler = null;
    _outputResampler = null;
    _inputBytesController?.close();
    _outputBytesController?.close();
    _inputBytesController = null;
    _outputBytesController = null;
  }
}
