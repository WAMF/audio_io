import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/audio_io_stub.dart' show AudioBufferStatus;
export 'src/audio_io_stub.dart' show AudioBufferStatus;

// Conditional imports for platform-specific implementations
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
  static const bufferStatus = 'com.wearemobilefirst.audio_io.bufferStatus';
}

class _Constants {
  static const bytesPerSample = 8;
  static const bytesPerInt32 = 4;
  static const millisecPerSec = 1000;
  static const bufferStatusFieldCount = 2;
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

const Map<AudioIoLatency, double> audioIoFrameSizeSeconds = {
  AudioIoLatency.Realtime: 0.05,
  AudioIoLatency.Balanced: 0.1,
  AudioIoLatency.Powersave: 0.25,
};

enum AudioBufferStrategy {
  lowLatency,
  balanced,
}

const Map<AudioBufferStrategy, double> audioBufferStrategyThreshold = {
  AudioBufferStrategy.lowLatency: 0.5,
  AudioBufferStrategy.balanced: 0.75,
};

enum AudioIoQuality {
  Low,
  Medium,
  High,
  Highest,
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
  StreamController<AudioBufferStatus> _bufferStatusController =
      StreamController<AudioBufferStatus>.broadcast(sync: true);


  Stream<List<double>> get input {
    if (_impl.usePlatformImpl) {
      return _impl.inputAudioStream ?? const Stream.empty();
    }
    return _inputController.stream;
  }

  static final _fallbackController = StreamController<List<double>>();

  Stream<AudioBufferStatus> get bufferStatus {
    if (_impl.usePlatformImpl) {
      return _impl.bufferStatusStream ?? const Stream.empty();
    }
    return _bufferStatusController.stream;
  }

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
    ServicesBinding.instance.defaultBinaryMessenger.setMessageHandler(
      _Channels.bufferStatus,
      (ByteData? message) {
        if (message != null && _bufferStatusController.hasListener) {
          final expectedBytes =
              _Constants.bufferStatusFieldCount * _Constants.bytesPerInt32;
          if (message.lengthInBytes >= expectedBytes) {
            final available = message.getInt32(0, Endian.little);
            final capacity =
                message.getInt32(_Constants.bytesPerInt32, Endian.little);
            _bufferStatusController.sink.add(AudioBufferStatus(
              availableFrames: available,
              capacityFrames: capacity,
            ));
          }
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

  Future<void> stop() async {
    if (_impl.usePlatformImpl) {
      await _impl.stop();
      return;
    }
    _outputSubscription?.cancel();
    _outputSubscription = null;
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_Channels.audioInput, null);
    ServicesBinding.instance.defaultBinaryMessenger
        .setMessageHandler(_Channels.bufferStatus, null);
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
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
  }
}
