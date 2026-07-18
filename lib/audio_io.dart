import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/audio_io_errors.dart';
import 'src/audio_io_exception.dart';
import 'src/audio_io_input_source.dart';
import 'src/audio_io_threading.dart';
import 'src/pcm16_adapters.dart';

// The base implementation type, used to type the (optionally injected)
// backend. All three conditional implementations extend this class.
import 'src/audio_io_stub.dart' show AudioIoImpl;

// Conditional imports for platform-specific implementations
import 'src/audio_io_stub.dart'
    if (dart.library.io) 'src/audio_io_native.dart'
    if (dart.library.js_interop) 'src/audio_io_web.dart' as impl;

export 'src/audio_io_exception.dart';
export 'src/audio_io_input_source.dart';
export 'src/audio_io_threading.dart';

// AudioIoException and its error codes live in
// `src/audio_io_exception.dart` (re-exported above) so platform
// implementations can raise typed errors without a circular import.

class _Constants {
  static const millisecPerSec = 1000;
}

enum AudioIoLatency {
  Realtime,
  Balanced,
  Powersave,
}

final Map<AudioIoLatency, double> _presetLatency = {
  AudioIoLatency.Realtime: 1.5 / 1000.0,
  AudioIoLatency.Balanced: 3.0 / 1000.0,
  AudioIoLatency.Powersave: 6.0 / 1000.0,
};

enum AudioIoQuality {
  Low,
  Medium,
  High,
  Highest,
}

/// Wire format for the byte streams ([AudioIo.inputBytes] /
/// [AudioIo.outputBytes]).
enum AudioIoFormat { float64, pcm16 }

/// Sample rate the byte streams operate at.
///
/// The audio engine runs at a fixed 48 kHz contract internally; the byte
/// streams are resampled to and from this rate, so callers can work in the
/// rate their API expects (e.g. 16 kHz in / 24 kHz out for Gemini Live).
enum AudioIoSampleRate {
  rate16000(16000),
  rate24000(24000),
  rate48000(48000);

  const AudioIoSampleRate(this.hz);

  final int hz;
}

/// Configuration for [AudioIo.startWith].
class AudioIoConfig {
  const AudioIoConfig({
    this.sampleRate = AudioIoSampleRate.rate48000,
    AudioIoSampleRate? inputSampleRate,
    AudioIoSampleRate? outputSampleRate,
    this.format = AudioIoFormat.float64,
    this.latency = AudioIoLatency.Balanced,
    this.threading = AudioIoThreading.mainIsolate,
    this.inputSource = AudioIoInputSource.microphone,
    this.outputBufferDuration,
  })  : inputSampleRate = inputSampleRate ?? sampleRate,
        outputSampleRate = outputSampleRate ?? sampleRate,
        // Debug-only descriptive guard. Complemented by the release-time
        // throw in [checkInvariants] (asserts are stripped in
        // release/profile builds); see that method for why the throw is
        // needed. A non-positive value cannot size an output ring.
        assert(
          outputBufferDuration == null || outputBufferDuration > 0,
          'outputBufferDuration must be greater than 0 seconds',
        );

  /// Shorthand rate applied to both directions. Sets [inputSampleRate] and
  /// [outputSampleRate] unless either is given explicitly.
  ///
  /// The byte streams are asymmetric-capable: pass [inputSampleRate] /
  /// [outputSampleRate] to run each direction at a different rate (e.g. mic
  /// 16 kHz in / speaker 24 kHz out, matching OpenAI Realtime and Gemini
  /// Live). Callers that only need one rate keep passing [sampleRate].
  final AudioIoSampleRate sampleRate;

  /// Rate the [AudioIo.inputBytes] stream is delivered at. Resolves to
  /// [sampleRate] when not given explicitly.
  final AudioIoSampleRate inputSampleRate;

  /// Rate the [AudioIo.outputBytes] sink expects. Resolves to [sampleRate]
  /// when not given explicitly.
  final AudioIoSampleRate outputSampleRate;

  /// Wire format for the byte streams.
  final AudioIoFormat format;

  /// Callback latency preset.
  final AudioIoLatency latency;

  /// Where the audio transport runs; see [AudioIoThreading]. Optional:
  /// defaults to the main isolate, which every platform supports.
  final AudioIoThreading threading;

  /// Which source the input stream captures from. Defaults to
  /// [AudioIoInputSource.microphone]. [AudioIoInputSource.systemAudio]
  /// captures the machine's audio mix (Windows via WASAPI loopback, macOS
  /// via Core Audio taps) and throws an [AudioIoException] with
  /// [AudioIoException.isSystemAudioUnsupported] on platforms/backends that
  /// cannot provide it.
  final AudioIoInputSource inputSource;

  /// Optional cap on how much audio the output ring may hold, in seconds of
  /// the 48 kHz playback contract.
  ///
  /// Sizes the playback ring independently of [latency] / the frame
  /// duration, so latency-sensitive callers can cap queued output low
  /// (barge-in) while burst producers (e.g. Gemini Live) can size it high
  /// enough that a multi-second response is not dropped. Each back end still
  /// enforces a small safety floor, so values below it are clamped up.
  ///
  /// When null (the default), each back end keeps its existing sizing
  /// (derived from the frame duration on Apple/web, a fixed default on the
  /// FFI back ends) — no behaviour change.
  final double? outputBufferDuration;

  /// Enforces every numeric field invariant in ALL build modes, throwing
  /// [ArgumentError] on a contract breach.
  ///
  /// The const-constructor `assert`s that carry the descriptive messages are
  /// stripped in release/profile builds, so an out-of-range value would
  /// otherwise reach the native audio engine — where it can size buffers from
  /// a garbage frame count and cause native crashes or undefined behaviour
  /// with no signal to the caller. [AudioIo.startWith] calls this before the
  /// config reaches the engine, mirroring the sample-rate-mismatch guard that
  /// throws in all build modes (PR #7).
  void checkInvariants() {
    checkOutputBufferDuration(outputBufferDuration);
  }

  /// Throws [ArgumentError] unless [seconds] is null or a positive, finite
  /// number of seconds. Enforced in all build modes (see [checkInvariants]).
  ///
  /// A non-positive duration cannot size a playback ring, and a non-finite
  /// one (NaN/infinity) slips past the native `seconds <= 0` guard and reaches
  /// `(size_t)(seconds * sampleRate)`, which is undefined behaviour.
  static void checkOutputBufferDuration(double? seconds) {
    if (seconds != null && (!seconds.isFinite || seconds <= 0)) {
      throw ArgumentError.value(
        seconds,
        'outputBufferDuration',
        'must be a positive, finite number of seconds',
      );
    }
  }
}

class AudioIo {
  AudioIoLatency frameSize = AudioIoLatency.Balanced;
  static AudioIo instance = AudioIo();

  AudioIo() : _impl = impl.createAudioIoImpl();

  /// Injects a specific backend, for tests that need to observe the
  /// [start] / [stop] / [startWith] control flow without a real platform
  /// engine (e.g. the input-source reset contract).
  @visibleForTesting
  AudioIo.withImpl(AudioIoImpl backend) : _impl = backend;

  // Platform-specific implementation. Every platform now routes through an
  // [AudioIoImpl] (web AudioWorklet, miniaudio FFI, or the Apple AVAudioEngine
  // backend), so `AudioIo` is a thin facade with no transport of its own.
  final AudioIoImpl _impl;

  static const int _contractSampleRate = 48000;

  AudioIoConfig? _config;
  final Pcm16Adapters _pcm16 = Pcm16Adapters();

  /// Configuration passed to the most recent [startWith], or null if the
  /// session was started with [start] or has been stopped.
  AudioIoConfig? get currentConfig => _config;

  /// PCM16 (Int16 little-endian) input stream at
  /// [AudioIoConfig.inputSampleRate].
  ///
  /// Active after [startWith] with [AudioIoFormat.pcm16]. Resampled from the
  /// engine's capture rate and encoded from the underlying [input] stream.
  Stream<Uint8List> get inputBytes => _pcm16.inputBytes;

  /// PCM16 (Int16 little-endian) output sink at
  /// [AudioIoConfig.outputSampleRate].
  ///
  /// Active after [startWith] with [AudioIoFormat.pcm16]. Decoded and
  /// resampled to the engine's 48 kHz contract before reaching [output].
  ///
  /// Broadcast so the adapter can re-listen across a stop -> startWith
  /// restart and a retained sink reference stays valid; a single-subscription
  /// controller threw `Bad state: Stream has already been listened to` on the
  /// second startWith.
  Sink<Uint8List> get outputBytes => _pcm16.outputBytes;


  static final _fallbackController = StreamController<List<double>>();

  Stream<List<double>> get input =>
      _impl.inputAudioStream ?? const Stream.empty();

  Sink<List<double>> get output =>
      _impl.outputAudioStream ?? _fallbackController.sink;

  Future<void> start() async {
    // A plain start() is the legacy microphone contract. startWith sets
    // _config before delegating here, so an unconfigured start means the
    // backend must be reset to the microphone: otherwise a prior
    // startWith(systemAudio) -> stop() leaves the web backend configured for
    // display capture and this start() would silently reopen the share
    // picker instead of the microphone.
    if (_config == null) {
      _impl.configureInputSource(AudioIoInputSource.microphone);
    }
    try {
      await _impl.start();
    } on InputSourceUnsupportedException catch (e) {
      // A capability limitation the native engine only discovers at device
      // init (e.g. WASAPI process-loopback needs Windows build 20348+) surfaces
      // as an InputSourceUnsupportedException; present it as the same typed
      // AudioIoException the up-front supportsInputSource check throws.
      throw AudioIoException(
        AudioIoErrorCodes.systemAudioUnsupported,
        e.message,
      );
    } on PlatformException catch (e) {
      throw AudioIoException(e.code, e.message ?? 'Unknown error', e.details);
    }
  }

  /// Starts the engine and, for [AudioIoFormat.pcm16], wires the [inputBytes]
  /// / [outputBytes] streams at [AudioIoConfig.inputSampleRate] /
  /// [AudioIoConfig.outputSampleRate].
  ///
  /// The engine runs at the fixed 48 kHz contract; the byte streams are
  /// resampled to and from the requested per-direction rates and converted
  /// between Float64 and Int16, so [AudioIoFormat.float64] callers keep using
  /// [input] / [output] unchanged.
  Future<void> startWith(AudioIoConfig config) async {
    // Enforce the config's numeric invariants in every build mode: the
    // const-constructor asserts are stripped in release/profile, so without
    // this an out-of-range value would reach the native engine unchecked.
    config.checkInvariants();
    if (!_impl.supportsInputSource(config.inputSource)) {
      throw AudioIoException(
        AudioIoErrorCodes.systemAudioUnsupported,
        'Input source ${config.inputSource.name} is not supported on this '
        'platform or audio backend.',
      );
    }
    // Assign _config transactionally: if any setup step throws, clear it so
    // currentConfig does not report a session that never started and a later
    // plain start() still resets to the microphone (start() only resets when
    // _config is null).
    _config = config;
    try {
      _impl.configureThreading(config.threading);
      _impl.configureInputSource(config.inputSource);
      await requestLatency(config.latency);
      final outputBufferDuration = config.outputBufferDuration;
      if (outputBufferDuration != null) {
        await requestOutputBufferDuration(outputBufferDuration);
      }
      await start();
      if (config.format == AudioIoFormat.pcm16) {
        await _wirePcm16Adapters(
          config.inputSampleRate.hz,
          config.outputSampleRate.hz,
        );
      }
    } catch (_) {
      _config = null;
      rethrow;
    }
  }

  Future<void> _wirePcm16Adapters(
    int inputStreamRate,
    int outputStreamRate,
  ) async {
    final format = await getFormat();
    final inputRate = _engineRate(format, 'input') ?? _contractSampleRate;
    final outputRate = _engineRate(format, 'output') ?? _contractSampleRate;
    await _pcm16.wire(
      inputStreamRate: inputStreamRate,
      outputStreamRate: outputStreamRate,
      inputEngineRate: inputRate,
      outputEngineRate: outputRate,
      inputAudio: input,
      outputAudio: output,
      directOutputBytes: _impl.pcm16OutputSink(outputStreamRate),
    );
  }

  int? _engineRate(Map<String, dynamic>? format, String direction) {
    final section = format?[direction];
    if (section is Map) {
      final rate = section['sampleRate'];
      if (rate is num) return rate.round();
    }
    return null;
  }

  Future<void> stop() async {
    await _pcm16.teardown();
    _config = null;
    await _impl.stop();
  }

  /// Discards audio queued for playback but not yet rendered.
  ///
  /// Use this to cut output immediately on a barge-in or when the remote peer
  /// signals the current response was interrupted, rather than waiting for the
  /// already-buffered audio to drain.
  Future<void> clearOutput() async {
    await _impl.clearOutput();
  }

  Future<Map<String, dynamic>?> getFormat() async {
    final dynamic value = _impl.getFormat();
    if (value is Map) {
      return value.map((key, dynamic v) => MapEntry(key.toString(), v));
    }
    return null;
  }

  Future<void> requestLatency(AudioIoLatency option) {
    return requestFrameDuration(_presetLatency[option]!);
  }

  /// Requests an explicit frame duration in seconds.
  ///
  /// Besides the callback quantum, native back ends size their internal
  /// output ring buffer from this value (duration * sampleRate * 4 frames),
  /// so clients that queue large amounts of audio ahead of time should
  /// request a duration big enough that the queue fits; pushed samples
  /// that exceed the ring are dropped. Must be called before [start] to
  /// take effect on platforms that size buffers at startup.
  Future<void> requestFrameDuration(double seconds) async {
    await _impl.requestFrameDuration(seconds);
  }

  /// Requests the output playback ring hold roughly [seconds] of audio at the
  /// 48 kHz playback contract, independent of the frame duration / latency.
  ///
  /// Lets latency-sensitive callers cap queued output low so a barge-in drops
  /// less stale audio, and burst producers size it high enough that a
  /// multi-second response is not dropped. Each back end enforces a small
  /// safety floor, so smaller values are clamped up. Must be called before
  /// [start] to take effect on platforms that size the ring at startup;
  /// [startWith] applies [AudioIoConfig.outputBufferDuration] automatically.
  Future<void> requestOutputBufferDuration(double seconds) async {
    await _impl.requestOutputBufferDuration(seconds);
  }

  Future<double> currentLatency() async {
    final latency = await _impl.getFrameDuration();
    return latency * _Constants.millisecPerSec;
  }

  void dispose() {
    _pcm16.dispose();
    _config = null;
    _impl.stop();
  }
}
