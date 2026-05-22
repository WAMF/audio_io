import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/audio_io_stub.dart'
    if (dart.library.io) 'src/audio_io_native.dart'
    if (dart.library.js_interop) 'src/audio_io_web.dart' as impl;

class _Methods {
  static const start = 'start';
  static const stop = 'stop';
  static const requestFrameDuration = 'requestFrameDuration';
  static const getFrameDuration = 'getFrameDuration';
  static const getFormat = 'getFormat';
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

/// Audio format for streaming data.
enum AudioIoFormat {
  /// Float64 samples in [-1.0, 1.0]. Default, backward compatible.
  float64(0),

  /// Signed 16-bit PCM little-endian. For real-time AI APIs.
  pcm16(1);

  const AudioIoFormat(this.value);

  /// Native format identifier.
  final int value;
}

/// Supported sample rates.
enum AudioIoSampleRate {
  /// 16 kHz — speech AI APIs (Gemini Live, Whisper).
  rate16000(16000),

  /// 24 kHz — OpenAI Realtime API.
  rate24000(24000),

  /// 48 kHz — full quality, default.
  rate48000(48000);

  const AudioIoSampleRate(this.hz);

  /// Sample rate in Hz.
  final int hz;
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

/// Configuration for [AudioIo.startWith].
class AudioIoConfig {
  /// Target sample rate.
  final AudioIoSampleRate sampleRate;

  /// Audio data format.
  final AudioIoFormat format;

  /// Latency preset.
  final AudioIoLatency latency;

  /// Frame chunk duration in milliseconds. Null uses the platform default.
  /// When set, input stream emits chunks of approximately this duration.
  /// Valid range: 20–100 ms.
  final int? frameDurationMs;

  const AudioIoConfig({
    this.sampleRate = AudioIoSampleRate.rate48000,
    this.format = AudioIoFormat.float64,
    this.latency = AudioIoLatency.Balanced,
    this.frameDurationMs,
  }) : assert(
          frameDurationMs == null ||
              (frameDurationMs >= 20 && frameDurationMs <= 100),
          'frameDurationMs must be between 20 and 100 milliseconds',
        );
}

class AudioIo {
  MethodChannel _methods = const MethodChannel(_Channels.methodChannelName);
  StreamSubscription<List<double>>? _outputSubscription;
  StreamSubscription? _inputSubscription;
  AudioIoLatency frameSize = AudioIoLatency.Balanced;
  static AudioIo instance = AudioIo();

  final _impl = impl.createAudioIoImpl();

  StreamController<List<double>> _outputController =
      StreamController<List<double>>.broadcast();
  StreamController<List<double>> _inputController =
      StreamController<List<double>>.broadcast();
  final StreamController<Uint8List> _inputBytesController =
      StreamController<Uint8List>.broadcast();
  final StreamController<Uint8List> _outputBytesController =
      StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _outputBytesSubscription;

  AudioIoConfig? _config;

  /// Current configuration. Null before [startWith] is called.
  AudioIoConfig? get currentConfig => _config;

  /// Float64 input stream. Active when format is [AudioIoFormat.float64].
  Stream<List<double>> get input {
    if (_impl.usePlatformImpl) {
      return _impl.inputAudioStream ?? const Stream.empty();
    }
    return _inputController.stream;
  }

  /// Float64 output sink. Active when format is [AudioIoFormat.float64].
  Sink<List<double>> get output {
    if (_impl.usePlatformImpl) {
      return _impl.outputAudioStream ?? StreamController<List<double>>().sink;
    }
    return _outputController.sink;
  }

  /// PCM16 input stream. Active when format is [AudioIoFormat.pcm16].
  /// Each [Uint8List] contains signed 16-bit little-endian PCM samples.
  Stream<Uint8List> get inputBytes {
    if (_impl.usePlatformImpl) {
      return _impl.inputBytesStream ?? const Stream.empty();
    }
    return _inputBytesController.stream;
  }

  /// PCM16 output sink. Active when format is [AudioIoFormat.pcm16].
  /// Write signed 16-bit little-endian PCM bytes.
  Sink<Uint8List> get outputBytes {
    if (_impl.usePlatformImpl) {
      return _impl.outputBytesSink ?? StreamController<Uint8List>().sink;
    }
    return _outputBytesController.sink;
  }

  /// Start with default settings (48 kHz, Float64, Balanced latency).
  Future<void> start() async {
    if (_impl.usePlatformImpl) {
      await _impl.start();
      return;
    }

    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
    _outputBytesSubscription?.cancel();
    _outputSubscription = _outputController.stream.listen((output) {
      final outData = ByteData.view(Float64List.fromList(output).buffer);
      ServicesBinding.instance.defaultBinaryMessenger
          .send(_Channels.audioOutput, outData);
    });
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _Channels.audioInput,
      (ByteData? message) {
        if (message != null) {
          final audioFrame = message.buffer.asFloat64List(message.offsetInBytes,
              message.lengthInBytes ~/ _Constants.bytesPerSample);
          _inputController.sink.add(audioFrame);
        }
        return null;
      },
    );
    return _methods.invokeMethod(_Methods.start);
  }

  /// Start with explicit configuration.
  Future<void> startWith(AudioIoConfig config) async {
    _config = config;

    if (_impl.usePlatformImpl) {
      if (config.frameDurationMs != null) {
        await _impl.requestFrameDuration(config.frameDurationMs! / 1000.0);
      } else {
        await _impl.requestFrameDuration(_presetLatency[config.latency]!);
      }
      await _impl.start(
        sampleRate: config.sampleRate.hz,
        format: config.format.value,
      );
      return;
    }

    // iOS/macOS method channel path
    final frameDuration = config.frameDurationMs != null
        ? config.frameDurationMs! / 1000.0
        : _presetLatency[config.latency]!;
    await _methods.invokeMethod(_Methods.requestFrameDuration, frameDuration);

    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
    _outputBytesSubscription?.cancel();

    if (config.format == AudioIoFormat.pcm16) {
      _outputBytesSubscription =
          _outputBytesController.stream.listen((bytes) {
        final data = ByteData.sublistView(bytes);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_Channels.audioOutput, data);
      });
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _Channels.audioInput,
        (ByteData? message) {
          if (message != null) {
            final bytes = message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            );
            _inputBytesController.sink.add(bytes);
          }
          return null;
        },
      );
    } else {
      _outputSubscription = _outputController.stream.listen((output) {
        final outData = ByteData.view(Float64List.fromList(output).buffer);
        ServicesBinding.instance.defaultBinaryMessenger
            .send(_Channels.audioOutput, outData);
      });
      ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
        _Channels.audioInput,
        (ByteData? message) {
          if (message != null) {
            final audioFrame = message.buffer.asFloat64List(
                message.offsetInBytes,
                message.lengthInBytes ~/ _Constants.bytesPerSample);
            _inputController.sink.add(audioFrame);
          }
          return null;
        },
      );
    }

    return _methods.invokeMethod(_Methods.start, {
      'sampleRate': config.sampleRate.hz,
      'format': config.format.value,
    });
  }

  Future<void> stop() async {
    if (_impl.usePlatformImpl) {
      await _impl.stop();
      return;
    }
    await _outputSubscription?.cancel();
    await _inputSubscription?.cancel();
    await _outputBytesSubscription?.cancel();
    await _methods.invokeMethod(_Methods.stop);
  }

  Future<Map<String, dynamic>?> getFormat() async {
    if (_impl.usePlatformImpl) {
      return _impl.getFormat();
    }
    final value = await _methods.invokeMethod(_Methods.getFormat);
    if (value != null && value is Map<String, dynamic>) {
      return value;
    }
    return null;
  }

  Future<void> requestLatency(AudioIoLatency option) async {
    if (_impl.usePlatformImpl) {
      await _impl.requestFrameDuration(_presetLatency[option]!);
      return;
    }
    return _methods.invokeMethod(
        _Methods.requestFrameDuration, _presetLatency[option]);
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
    if (_impl.usePlatformImpl) {
      _impl.stop();
      return;
    }
    unawaited(_outputSubscription?.cancel());
    unawaited(_inputSubscription?.cancel());
    unawaited(_outputBytesSubscription?.cancel());
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
    _inputBytesController.close();
    _outputBytesController.close();
  }
}
