import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'src/ffi/audio_io_ffi.dart';

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

class AudioIo {
  MethodChannel _methods = const MethodChannel(_Channels.methodChannelName);
  StreamSubscription<List<double>>? _outputSubscription;
  StreamSubscription? _inputSubscription;
  AudioIoLatency frameSize = AudioIoLatency.Balanced;
  static AudioIo instance = AudioIo();

  // FFI instance for Android/Windows/Linux
  AudioIoFFI? _ffi;
  bool get _useFFI =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  StreamController<List<double>> _outputController =
      StreamController<List<double>>.broadcast();
  StreamController<List<double>> _inputController =
      StreamController<List<double>>.broadcast();

  Stream<List<double>> get input {
    if (_useFFI) {
      return _ffi?.inputAudioStream ?? const Stream.empty();
    }
    return _inputController.stream;
  }

  Sink<List<double>> get output {
    if (_useFFI) {
      return _ffi?.outputAudioStream ?? StreamController<List<double>>().sink;
    }
    return _outputController.sink;
  }

  Future<void> start() async {
    if (_useFFI) {
      _ffi = AudioIoFFI.instance;
      await _ffi!.start();
      return;
    }

    // Original method channel implementation for iOS/macOS
    _outputSubscription?.cancel();
    _inputSubscription?.cancel();
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

  Future<void> stop() async {
    if (_useFFI) {
      await _ffi?.stop();
      return;
    }
    await _methods.invokeMethod(_Methods.stop);
  }

  Future<Map<String, dynamic>?> getFormat() async {
    if (_useFFI) {
      return _ffi?.getFormat();
    }
    final value = await _methods.invokeMethod(_Methods.getFormat);
    if (value != null && value is Map<String, dynamic>) {
      return value;
    }
    return null;
  }

  Future<void> requestLatency(AudioIoLatency option) async {
    if (_useFFI) {
      await _ffi?.requestFrameDuration(_presetLatency[option]!);
      return;
    }
    return _methods.invokeMethod(
        _Methods.requestFrameDuration, _presetLatency[option]);
  }

  Future<double> currentLatency() async {
    if (_useFFI) {
      final latency = await _ffi?.getFrameDuration() ?? 0.01;
      return latency * _Constants.millisecPerSec;
    }
    return _methods.invokeMethod(_Methods.getFrameDuration).then((latency) {
      return (latency as double) * _Constants.millisecPerSec;
    });
  }

  void dispose() {
    if (_useFFI) {
      _ffi?.stop();
      return;
    }
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
  }
}
