import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../audio_io_errors.dart';
import '../audio_io_input_source.dart';
import 'audio_io_bindings.dart';

/// Common surface of the FFI transports so the platform layer can swap the
/// main-isolate and dedicated-isolate implementations behind one type.
abstract class AudioIoFFITransport {
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;

  Future<void> start();
  Future<void> stop();
  void clearOutput();
  Map<String, dynamic> getFormat();
  Future<void> requestFrameDuration(double duration);
  Future<void> requestOutputBufferDuration(double seconds);
  Future<double> getFrameDuration();

  /// Selects the capture source applied at the next [start]. Fixed at
  /// device-init time, so it must be set before [start].
  void setInputSource(AudioIoInputSource source);
}

/// Core FFI engine shared by the main-isolate and audio-isolate transports.
///
/// Owns the native handle plus reusable native buffers so the poll and write
/// hot paths run without per-call allocation, and drains the entire native
/// input ring every poll so a delayed tick recovers immediately instead of
/// accruing input latency (the previous fixed 480-frame cap drained at
/// exactly the production rate, so any backlog became permanent).
class AudioIoFFICore {
  AudioIoFFICore() : _bindings = AudioIoBindings();

  static const pollInterval = Duration(milliseconds: 5);
  static const _maxChunkFrames = 4800;

  /// Native `audio_io_start` return code for an input source that the current
  /// OS/backend cannot provide (see `audio_io_init_device` in the C layer).
  static const _startUnsupportedInputSource = -2;
  static const defaultFormat = <String, dynamic>{
    'input': {'type': 'double', 'channels': 1, 'sampleRate': 48000.0},
    'output': {'type': 'double', 'channels': 1, 'sampleRate': 48000.0},
  };

  final AudioIoBindings _bindings;
  Pointer<Void>? _handle;
  Timer? _inputTimer;
  bool _isRunning = false;
  double _requestedFrameDuration = 0.003;
  int _inputSource = 0;
  double? _requestedOutputBufferSeconds;

  Pointer<Double> _readBuffer = nullptr;
  int _readCapacity = 0;
  Pointer<Double> _writeBuffer = nullptr;
  int _writeCapacity = 0;

  void Function(Float64List frames)? _onInput;

  bool get isRunning => _isRunning;

  void start(void Function(Float64List frames) onInput) {
    if (_isRunning) return;

    final handle = _bindings.create();
    if (handle == nullptr) {
      throw Exception('Failed to create audio context');
    }

    _bindings.setFrameDuration(handle, _requestedFrameDuration);
    _bindings.setInputSource(handle, _inputSource);

    final outputBufferSeconds = _requestedOutputBufferSeconds;
    if (outputBufferSeconds != null) {
      _bindings.setOutputBufferSeconds(handle, outputBufferSeconds);
    }

    final startResult = _bindings.start(handle);
    if (startResult != 0) {
      _bindings.destroy(handle);
      if (startResult == _startUnsupportedInputSource) {
        throw const InputSourceUnsupportedException(
          'System audio capture is unavailable on this system. WASAPI '
          'process-excluded loopback requires Windows 11 or Windows Server '
          '2022 (build 20348) or newer.',
        );
      }
      throw Exception('Failed to start audio device');
    }

    _handle = handle;
    _onInput = onInput;
    _isRunning = true;
    _inputTimer = Timer.periodic(pollInterval, (_) => _poll());
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;

    _inputTimer?.cancel();
    _inputTimer = null;
    _onInput = null;

    final handle = _handle;
    if (handle != null) {
      _bindings.stop(handle);
      _bindings.destroy(handle);
      _handle = null;
    }

    _releaseBuffers();
  }

  void _poll() {
    final handle = _handle;
    final onInput = _onInput;
    if (!_isRunning || handle == null || onInput == null) return;

    var available = _bindings.getAvailableReadFrames(handle);
    while (available > 0) {
      final request = math.min(available, _maxChunkFrames);
      _ensureReadCapacity(request);
      final framesRead = _bindings.read(handle, _readBuffer, request);
      if (framesRead <= 0) break;
      onInput(Float64List.fromList(_readBuffer.asTypedList(framesRead)));
      available -= framesRead;
    }
  }

  void write(List<double> data) {
    final handle = _handle;
    if (!_isRunning || handle == null || data.isEmpty) return;

    _ensureWriteCapacity(data.length);
    _writeBuffer.asTypedList(data.length).setAll(0, data);
    _bindings.write(handle, _writeBuffer, data.length);
  }

  void clearOutput() {
    final handle = _handle;
    if (!_isRunning || handle == null) return;
    _bindings.clearOutput(handle);
  }

  Map<String, dynamic> getFormat() {
    final handle = _handle;
    if (handle == null) return defaultFormat;

    final sampleRate = _bindings.getSampleRate(handle).toDouble();
    final channels = _bindings.getChannels(handle);

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

  void setFrameDuration(double duration) {
    _requestedFrameDuration = duration;
    final handle = _handle;
    if (handle != null) {
      _bindings.setFrameDuration(handle, duration);
    }
  }

  /// Records the capture source (0 = microphone, 1 = system audio) to apply
  /// when the native device is created at the next [start]. Not changeable
  /// while running, since it fixes the device topology.
  void setInputSource(int source) {
    _inputSource = source;
  }

  /// Sizes the output ring to hold roughly [seconds] of audio. The native
  /// side rejects the change while running and reallocates the ring at the
  /// device rate, so the value is (re)applied in [start].
  void setOutputBufferSeconds(double seconds) {
    _requestedOutputBufferSeconds = seconds;
    final handle = _handle;
    if (handle != null && !_isRunning) {
      _bindings.setOutputBufferSeconds(handle, seconds);
    }
  }

  /// The device's actual frame duration when running, otherwise the
  /// requested one — matching the isolate transport, which reports the
  /// requested duration until its worker delivers the device value.
  double getFrameDuration() {
    final handle = _handle;
    if (handle != null) {
      return _bindings.getFrameDuration(handle);
    }
    return _requestedFrameDuration;
  }

  void _ensureReadCapacity(int frames) {
    if (_readCapacity >= frames) return;
    if (_readBuffer != nullptr) malloc.free(_readBuffer);
    _readBuffer = malloc<Double>(frames);
    _readCapacity = frames;
  }

  void _ensureWriteCapacity(int frames) {
    if (_writeCapacity >= frames) return;
    if (_writeBuffer != nullptr) malloc.free(_writeBuffer);
    _writeBuffer = malloc<Double>(frames);
    _writeCapacity = frames;
  }

  void _releaseBuffers() {
    if (_readBuffer != nullptr) {
      malloc.free(_readBuffer);
      _readBuffer = nullptr;
      _readCapacity = 0;
    }
    if (_writeBuffer != nullptr) {
      malloc.free(_writeBuffer);
      _writeBuffer = nullptr;
      _writeCapacity = 0;
    }
  }
}

/// Main-isolate FFI transport: the poll timer and buffer copies run on the
/// main isolate. Default mode; see [AudioIoFFIIsolateProxy] for the
/// dedicated-isolate alternative.
class AudioIoFFI implements AudioIoFFITransport {
  AudioIoFFI._();

  static AudioIoFFI? _instance;
  static AudioIoFFI get instance => _instance ??= AudioIoFFI._();

  final AudioIoFFICore _core = AudioIoFFICore();

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Future<void> start() async {
    if (_core.isRunning) return;

    final inputController = StreamController<List<double>>.broadcast();
    _core.start(inputController.add);
    _inputController = inputController;

    _outputController = StreamController<List<double>>();
    _outputController!.stream.listen(_core.write);
  }

  @override
  Future<void> stop() async {
    if (!_core.isRunning) return;
    _core.stop();
    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;
  }

  @override
  void clearOutput() => _core.clearOutput();

  @override
  Map<String, dynamic> getFormat() => _core.getFormat();

  @override
  Future<void> requestFrameDuration(double duration) async {
    _core.setFrameDuration(duration);
  }

  @override
  void setInputSource(AudioIoInputSource source) =>
      _core.setInputSource(source.index);

  @override
  Future<void> requestOutputBufferDuration(double seconds) async {
    _core.setOutputBufferSeconds(seconds);
  }

  @override
  Future<double> getFrameDuration() async => _core.getFrameDuration();
}
