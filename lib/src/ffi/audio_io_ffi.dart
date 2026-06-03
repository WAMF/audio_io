import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'audio_io_bindings.dart';

const int _formatFloat64 = 0;
const int _formatPcm16 = 1;

class AudioIoFFI {
  static AudioIoFFI? _instance;
  static AudioIoFFI get instance => _instance ??= AudioIoFFI._();

  late final AudioIoBindings _bindings;
  Pointer<Void>? _handle;

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  StreamController<Uint8List>? _inputBytesController;
  StreamController<Uint8List>? _outputBytesController;

  Timer? _inputTimer;

  bool _isRunning = false;
  double _requestedFrameDuration = 0.003;
  int _requestedSampleRate = 48000;
  int _requestedFormat = _formatFloat64;

  AudioIoFFI._() {
    _bindings = AudioIoBindings();
  }

  Stream<List<double>>? get inputAudioStream => _inputController?.stream;
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;
  Stream<Uint8List>? get inputBytesStream => _inputBytesController?.stream;
  StreamSink<Uint8List>? get outputBytesSink => _outputBytesController?.sink;

  bool get isPcm16 => _requestedFormat == _formatPcm16;

  Future<void> start({int sampleRate = 48000, int format = 0}) async {
    if (_isRunning) {
      // Re-starting with the same config is a harmless no-op, but silently
      // ignoring a *reconfigure* (e.g. pcm16 -> float64, or a new sample
      // rate) would leave the caller listening on the wrong stream with no
      // signal. Fail loudly instead.
      if (sampleRate != _requestedSampleRate || format != _requestedFormat) {
        throw StateError(
          'audio_io is already started; call stop() before reconfiguring '
          '(requested sampleRate=$sampleRate, format=$format; '
          'current sampleRate=$_requestedSampleRate, '
          'format=$_requestedFormat)',
        );
      }
      return;
    }

    _requestedSampleRate = sampleRate;
    _requestedFormat = format;

    _handle = _bindings.createWithConfig(
      _requestedFrameDuration,
      sampleRate,
      format,
    );
    if (_handle == nullptr) {
      throw Exception('Failed to create audio context');
    }

    final result = _bindings.start(_handle!);
    if (result != 0) {
      _bindings.destroy(_handle!);
      _handle = null;
      throw Exception('Failed to start audio device');
    }

    _isRunning = true;

    if (format == _formatPcm16) {
      _inputBytesController = StreamController<Uint8List>.broadcast();
      _outputBytesController = StreamController<Uint8List>();
      _outputBytesController!.stream.listen(_writePcm16Audio);
    } else {
      _inputController = StreamController<List<double>>.broadcast();
      _outputController = StreamController<List<double>>();
      _outputController!.stream.listen(_writeAudio);
    }

    _startInputPolling();
  }

  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _inputTimer?.cancel();
    _inputTimer = null;

    await _inputController?.close();
    await _outputController?.close();
    await _inputBytesController?.close();
    await _outputBytesController?.close();
    _inputController = null;
    _outputController = null;
    _inputBytesController = null;
    _outputBytesController = null;

    if (_handle != null) {
      _bindings.stop(_handle!);
      _bindings.destroy(_handle!);
      _handle = null;
    }
  }

  void _startInputPolling() {
    const pollInterval = Duration(milliseconds: 10);
    final framesPerPoll = (_requestedSampleRate * 0.01).toInt();

    _inputTimer = Timer.periodic(pollInterval, (_) {
      if (!_isRunning || _handle == null) return;

      final availableFrames = _bindings.getAvailableReadFrames(_handle!);
      if (availableFrames <= 0) return;

      final framesToRead =
          availableFrames > framesPerPoll ? framesPerPoll : availableFrames;

      if (isPcm16) {
        _pollPcm16Input(framesToRead);
      } else {
        _pollFloat64Input(framesToRead);
      }
    });
  }

  void _pollFloat64Input(int framesToRead) {
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

  void _pollPcm16Input(int framesToRead) {
    final buffer = malloc<Int16>(framesToRead);
    try {
      final framesRead = _bindings.readPcm16(_handle!, buffer, framesToRead);
      if (framesRead > 0) {
        final int16List = buffer.asTypedList(framesRead);
        final bytes = Uint8List.fromList(
          int16List.buffer.asUint8List(
            int16List.offsetInBytes,
            framesRead * 2,
          ),
        );
        _inputBytesController?.add(bytes);
      }
    } finally {
      malloc.free(buffer);
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

  void _writePcm16Audio(Uint8List data) {
    if (!_isRunning || _handle == null) return;

    final frameCount = data.length ~/ 2;
    if (frameCount <= 0) return;

    final buffer = malloc<Int16>(frameCount);
    try {
      final int16View = data.buffer.asInt16List(data.offsetInBytes, frameCount);
      for (int i = 0; i < frameCount; i++) {
        buffer[i] = int16View[i];
      }
      _bindings.writePcm16(_handle!, buffer, frameCount);
    } finally {
      malloc.free(buffer);
    }
  }

  Map<String, dynamic> getFormat() {
    final sampleRate = _handle != null
        ? _bindings.getSampleRate(_handle!).toDouble()
        : _requestedSampleRate.toDouble();
    final channels =
        _handle != null ? _bindings.getChannels(_handle!) : 1;
    final type = isPcm16 ? 'pcm16' : 'double';

    return {
      'input': {
        'type': type,
        'channels': channels,
        'sampleRate': sampleRate,
      },
      'output': {
        'type': type,
        'channels': channels,
        'sampleRate': sampleRate,
      },
    };
  }

  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    if (_handle != null && _isRunning) {
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
