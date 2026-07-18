import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
    this.format = AudioIoFormat.float64,
    this.latency = AudioIoLatency.Balanced,
    this.threading = AudioIoThreading.mainIsolate,
    this.inputSource = AudioIoInputSource.microphone,
  });

  /// Rate the [AudioIo.inputBytes] / [AudioIo.outputBytes] streams use.
  final AudioIoSampleRate sampleRate;

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

  /// PCM16 (Int16 little-endian) input stream at [AudioIoConfig.sampleRate].
  ///
  /// Active after [startWith] with [AudioIoFormat.pcm16]. Resampled from the
  /// engine's capture rate and encoded from the underlying [input] stream.
  Stream<Uint8List> get inputBytes => _pcm16.inputBytes;

  /// PCM16 (Int16 little-endian) output sink at [AudioIoConfig.sampleRate].
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
    } on PlatformException catch (e) {
      throw AudioIoException(e.code, e.message ?? 'Unknown error', e.details);
    }
  }

  /// Starts the engine and, for [AudioIoFormat.pcm16], wires the
  /// [inputBytes] / [outputBytes] streams at [AudioIoConfig.sampleRate].
  ///
  /// The engine runs at the fixed 48 kHz contract; the byte streams are
  /// resampled to and from the requested rate and converted between
  /// Float64 and Int16, so [AudioIoFormat.float64] callers keep using
  /// [input] / [output] unchanged.
  Future<void> startWith(AudioIoConfig config) async {
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
      await start();
      if (config.format == AudioIoFormat.pcm16) {
        await _wirePcm16Adapters(config.sampleRate.hz);
      }
    } catch (_) {
      _config = null;
      rethrow;
    }
  }

  Future<void> _wirePcm16Adapters(int streamRate) async {
    final format = await getFormat();
    final inputRate = _engineRate(format, 'input') ?? _contractSampleRate;
    final outputRate = _engineRate(format, 'output') ?? _contractSampleRate;
    await _pcm16.wire(
      streamRate: streamRate,
      inputEngineRate: inputRate,
      outputEngineRate: outputRate,
      inputAudio: input,
      outputAudio: output,
      directOutputBytes: _impl.pcm16OutputSink(streamRate),
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
