import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/pcm16_adapters.dart';

// Conditional imports for platform-specific implementations
import 'src/audio_io_stub.dart'
    if (dart.library.io) 'src/audio_io_native.dart'
    if (dart.library.js_interop) 'src/audio_io_web.dart' as impl;

class _Methods {
  static const start = 'start';
  static const stop = 'stop';
  static const clearOutput = 'clearOutput';
  static const requestFrameDuration = 'requestFrameDuration';
  static const getFrameDuration = 'getFrameDuration';
  static const getFormat = 'getFormat';
}

class _ErrorCodes {
  static const microphonePermissionDenied = 'MICROPHONE_PERMISSION_DENIED';
}

class AudioIoException implements Exception {
  AudioIoException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final dynamic details;

  bool get isPermissionDenied => code == _ErrorCodes.microphonePermissionDenied;

  @override
  String toString() => 'AudioIoException($code): $message';
}

class _Channels {
  static const methodChannelName = 'com.wearemobilefirst.audio_io';
  static const audioInput = 'com.wearemobilefirst.audio_io.inputAudio';
  static const audioOutput = 'com.wearemobilefirst.audio_io.outputAudio';
}

class _Constants {
  static const bytesPerSample = 8;
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
  });

  /// Rate the [AudioIo.inputBytes] / [AudioIo.outputBytes] streams use.
  final AudioIoSampleRate sampleRate;

  /// Wire format for the byte streams.
  final AudioIoFormat format;

  /// Callback latency preset.
  final AudioIoLatency latency;
}

class AudioIo {
  MethodChannel _methods = const MethodChannel(_Channels.methodChannelName);
  StreamSubscription<List<double>>? _outputSubscription;
  StreamSubscription? _inputSubscription;
  AudioIoLatency frameSize = AudioIoLatency.Balanced;
  static AudioIo instance = AudioIo();

  // Platform-specific implementation
  final _impl = impl.createAudioIoImpl();

  StreamController<List<double>> _outputController =
      StreamController<List<double>>.broadcast(sync: true);
  StreamController<List<double>> _inputController =
      StreamController<List<double>>.broadcast(sync: true);

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


  Stream<List<double>> get input {
    if (_impl.usePlatformImpl) {
      return _impl.inputAudioStream ?? const Stream.empty();
    }
    return _inputController.stream;
  }

  static final _fallbackController = StreamController<List<double>>();

  Sink<List<double>> get output {
    if (_impl.usePlatformImpl) {
      return _impl.outputAudioStream ?? _fallbackController.sink;
    }
    return _outputController.sink;
  }

  Future<void> start() async {
    if (_impl.usePlatformImpl) {
      await _impl.start();
      return;
    }

    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
    _outputSubscription = _outputController.stream.listen((output) {
      final buffer =
          output is Float64List ? output : Float64List.fromList(output);
      final outData = ByteData.view(buffer.buffer);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_Channels.audioOutput, outData);
    });
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _Channels.audioInput,
      (ByteData? message) {
        if (message != null && _inputController.hasListener) {
          final view = message.buffer.asFloat64List(message.offsetInBytes,
              message.lengthInBytes ~/ _Constants.bytesPerSample);
          final copy = Float64List.fromList(view);
          _inputController.sink.add(copy);
        }
        return null;
      },
    );
    try {
      await _methods.invokeMethod(_Methods.start);
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
    _config = config;
    await requestLatency(config.latency);
    await start();
    if (config.format == AudioIoFormat.pcm16) {
      await _wirePcm16Adapters(config.sampleRate.hz);
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
    if (_impl.usePlatformImpl) {
      await _impl.stop();
      return;
    }
    _outputSubscription?.cancel();
    _outputSubscription = null;
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_Channels.audioInput, null);
    await _methods.invokeMethod(_Methods.stop);
  }

  /// Discards audio queued for playback but not yet rendered.
  ///
  /// Use this to cut output immediately on a barge-in or when the remote peer
  /// signals the current response was interrupted, rather than waiting for the
  /// already-buffered audio to drain.
  Future<void> clearOutput() async {
    if (_impl.usePlatformImpl) {
      await _impl.clearOutput();
      return;
    }
    await _methods.invokeMethod(_Methods.clearOutput);
  }

  Future<Map<String, dynamic>?> getFormat() async {
    final dynamic value = _impl.usePlatformImpl
        ? _impl.getFormat()
        : await _methods.invokeMethod(_Methods.getFormat);
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
    if (_impl.usePlatformImpl) {
      await _impl.requestFrameDuration(seconds);
      return;
    }
    return _methods.invokeMethod(_Methods.requestFrameDuration, seconds);
  }

  Future<double> currentLatency() async {
    if (_impl.usePlatformImpl) {
      final latency = await _impl.getFrameDuration();
      return latency * _Constants.millisecPerSec;
    }
    return _methods.invokeMethod(_Methods.getFrameDuration).then((latency) {
      return (latency as double) * _Constants.millisecPerSec;
    });
  }

  void dispose() {
    _pcm16.dispose();
    _config = null;
    if (_impl.usePlatformImpl) {
      _impl.stop();
      return;
    }
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
  }
}
