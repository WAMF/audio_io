import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  StreamController<List<double>> _outputController =
      StreamController<List<double>>.broadcast();
  StreamController<List<double>> _inputController =
      StreamController<List<double>>.broadcast();

  Stream<List<double>> get input {
    return _inputController.stream;
  }

  Sink<List<double>> get output {
    return _outputController.sink;
  }

  Future<void> start() async {
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
    await _methods.invokeMethod(_Methods.stop);
  }

  Future<Map<String, dynamic>?> getFormat() async {
    final value = await _methods.invokeMethod(_Methods.getFormat);
    if (value != null && value is Map<String, dynamic>) {
      return value;
    }
    return null;
  }

  Future<void> requestLatency(AudioIoLatency option) async {
    return _methods.invokeMethod(
        _Methods.requestFrameDuration, _presetLatency[option]);
  }

  Future<double> currentLatency() async {
    return _methods.invokeMethod(_Methods.getFrameDuration).then((latency) {
      return (latency as double) * _Constants.millisecPerSec;
    });
  }

  void dispose() {
    _outputController.sink.close();
    _outputController.close();
    _inputController.sink.close();
    _inputController.close();
  }
}
