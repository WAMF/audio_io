import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../audio_io_stub.dart' show AudioBufferStatus;
import 'audio_io_bindings.dart';

class _FFIConstants {
  static const bufferLowWaterMark = 0.25;
  static const defaultBufferCapacity = 4096;
}

class AudioIoFFI {
  static AudioIoFFI? _instance;
  static AudioIoFFI get instance => _instance ??= AudioIoFFI._();

  late final AudioIoBindings _bindings;
  Pointer<Void>? _handle;

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  StreamController<AudioBufferStatus>? _bufferStatusController;

  Timer? _inputTimer;

  bool _isRunning = false;
  int _bufferCapacity = _FFIConstants.defaultBufferCapacity;
  double _requestedFrameDuration = 0.003;

  AudioIoFFI._() {
    _bindings = AudioIoBindings();
  }

  Stream<List<double>>? get inputAudioStream => _inputController?.stream;
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;
  Stream<AudioBufferStatus>? get bufferStatusStream =>
      _bufferStatusController?.stream;

  Future<void> start() async {
    if (_isRunning) return;

    _handle = _bindings.create();
    if (_handle == nullptr) {
      throw Exception('Failed to create audio context');
    }

    // Set the frame duration before starting
    _bindings.setFrameDuration(_handle!, _requestedFrameDuration);

    final result = _bindings.start(_handle!);
    if (result != 0) {
      _bindings.destroy(_handle!);
      _handle = null;
      throw Exception('Failed to start audio device');
    }

    _isRunning = true;

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();
    _bufferStatusController = StreamController<AudioBufferStatus>.broadcast();

    _outputController!.stream.listen((data) {
      _writeAudio(data);
    });

    _startInputPolling();
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _inputTimer?.cancel();
    _inputTimer = null;

    await _inputController?.close();
    await _outputController?.close();
    await _bufferStatusController?.close();
    _inputController = null;
    _outputController = null;
    _bufferStatusController = null;

    if (_handle != null) {
      _bindings.stop(_handle!);
      _bindings.destroy(_handle!);
      _handle = null;
    }
  }

  void _startInputPolling() {
    const pollInterval = Duration(milliseconds: 10);
    const framesPerPoll = 480;

    _inputTimer = Timer.periodic(pollInterval, (_) {
      if (!_isRunning || _handle == null) return;

      final availableFrames = _bindings.getAvailableReadFrames(_handle!);
      if (availableFrames > 0) {
        final framesToRead =
            availableFrames > framesPerPoll ? framesPerPoll : availableFrames;
        final buffer = malloc<Double>(framesToRead);

        try {
          final framesRead = _bindings.read(_handle!, buffer, framesToRead);
          if (framesRead > 0) {
            final data = List<double>.generate(
              framesRead,
              (i) => buffer[i],
            );
            _inputController?.add(data);
          }
        } finally {
          malloc.free(buffer);
        }
      }

      _checkBufferStatus();
    });
  }

  void _checkBufferStatus() {
    if (_handle == null || _bufferStatusController == null) return;

    final availableWriteSpace = _bindings.getAvailableWriteSpace(_handle!);
    final availableForReading = _bufferCapacity - availableWriteSpace;
    final fillRatio = availableForReading / _bufferCapacity;
    final lowWaterMark = _FFIConstants.bufferLowWaterMark;

    if (fillRatio < lowWaterMark) {
      _bufferStatusController?.add(AudioBufferStatus(
        availableFrames: availableForReading,
        capacityFrames: _bufferCapacity,
      ));
    }
  }

  void _writeAudio(List<double> data) {
    if (!_isRunning || _handle == null) return;

    final buffer = malloc<Double>(data.length);
    try {
      for (int i = 0; i < data.length; i++) {
        buffer[i] = data[i];
      }

      _bindings.write(_handle!, buffer, data.length);
    } finally {
      malloc.free(buffer);
    }
  }

  Map<String, dynamic> getFormat() {
    if (_handle == null) {
      return {
        'input': {
          'type': 'double',
          'channels': 1,
          'sampleRate': 48000.0,
        },
        'output': {
          'type': 'double',
          'channels': 1,
          'sampleRate': 48000.0,
        },
      };
    }

    final sampleRate = _bindings.getSampleRate(_handle!).toDouble();
    final channels = _bindings.getChannels(_handle!);

    return {
      'input': {
        'type': 'double',
        'channels': channels,
        'sampleRate': sampleRate,
      },
      'output': {
        'type': 'double',
        'channels': channels,
        'sampleRate': sampleRate,
      },
    };
  }

  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    if (_handle != null) {
      _bindings.setFrameDuration(_handle!, duration);
    }
  }

  Future<double> getFrameDuration() async {
    if (_handle != null) {
      return _bindings.getFrameDuration(_handle!);
    }
    return 0.01;
  }
}
