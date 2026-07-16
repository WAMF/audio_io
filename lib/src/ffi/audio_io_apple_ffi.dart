import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// FFI data plane for the iOS/macOS AVAudioEngine backend (issue #27).
///
/// Only the audio *data* plane crosses FFI: the poll loop drains the native
/// input ring and pushes samples into the output ring. Engine lifecycle
/// (start/stop/permissions/latency/format) stays on the method channel — see
/// `AudioIoApple`. Because the exports resolve the live plugin through a
/// process-wide singleton (not the Flutter registrar), the poll and write
/// hot paths work from any isolate, which is what unlocks
/// `AudioIoThreading.audioIsolate` on Apple platforms.

/// Common surface of the Apple data-plane transports so `AudioIoApple` can
/// swap the main-isolate and dedicated-isolate implementations behind one
/// type. Narrower than `AudioIoFFITransport`: the control-plane methods
/// (format, frame duration) do not belong to the data plane on Apple.
abstract class AudioIoAppleTransport {
  Stream<List<double>>? get inputAudioStream;
  StreamSink<List<double>>? get outputAudioStream;

  Future<void> start();
  Future<void> stop();
  void clearOutput();
}

/// Binds the `@_cdecl` exports from the Swift plugin, resolved via
/// `DynamicLibrary.process()` (the symbols are linked into the app image, not
/// a standalone shared library). Constructing this throws if the symbols are
/// missing — surfaced to the caller on the main isolate, or forwarded as an
/// error event from the audio isolate.
class AudioIoAppleBindings {
  AudioIoAppleBindings() {
    final lib = DynamicLibrary.process();
    inputAvailable = lib.lookupFunction<Int32 Function(), int Function()>(
        'audio_io_apple_input_available');
    inputRead = lib.lookupFunction<Int32 Function(Pointer<Float>, Int32),
        int Function(Pointer<Float>, int)>('audio_io_apple_input_read');
    outputWrite = lib.lookupFunction<Int32 Function(Pointer<Double>, Int32),
        int Function(Pointer<Double>, int)>('audio_io_apple_output_write');
    outputClear = lib.lookupFunction<Void Function(), void Function()>(
        'audio_io_apple_output_clear');
  }

  late final int Function() inputAvailable;
  late final int Function(Pointer<Float>, int) inputRead;
  late final int Function(Pointer<Double>, int) outputWrite;
  late final void Function() outputClear;
}

/// Poll/write engine shared by the main-isolate and audio-isolate transports.
///
/// Mirrors `AudioIoFFICore`'s hot-path discipline — reusable native buffers so
/// poll and write never allocate per call, and a drain-all input poll so a
/// delayed tick recovers immediately instead of accruing latency. Unlike
/// `AudioIoFFICore` it does not own a device handle: the AVAudioEngine is
/// started out of band on the method channel, and this core only moves samples
/// across the already-live rings. Input is read as Float32 (the engine's
/// native format) and surfaced as `Float32List`, which implements
/// `List<double>` — so the public API is unchanged while the busiest path
/// stays Float32 end to end.
class AudioIoAppleCore {
  AudioIoAppleCore() : _bindings = AudioIoAppleBindings();

  static const pollInterval = Duration(milliseconds: 5);
  static const _maxChunkFrames = 4800;

  final AudioIoAppleBindings _bindings;
  Timer? _inputTimer;
  bool _isRunning = false;

  Pointer<Float> _readBuffer = nullptr;
  int _readCapacity = 0;
  Pointer<Double> _writeBuffer = nullptr;
  int _writeCapacity = 0;

  void Function(Float32List frames)? _onInput;

  bool get isRunning => _isRunning;

  void start(void Function(Float32List frames) onInput) {
    if (_isRunning) return;
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
    _releaseBuffers();
  }

  void _poll() {
    final onInput = _onInput;
    if (!_isRunning || onInput == null) return;

    var available = _bindings.inputAvailable();
    while (available > 0) {
      final request = math.min(available, _maxChunkFrames);
      _ensureReadCapacity(request);
      final framesRead = _bindings.inputRead(_readBuffer, request);
      if (framesRead <= 0) break;
      onInput(Float32List.fromList(_readBuffer.asTypedList(framesRead)));
      available -= framesRead;
    }
  }

  void write(List<double> data) {
    if (!_isRunning || data.isEmpty) return;
    _ensureWriteCapacity(data.length);
    _writeBuffer.asTypedList(data.length).setAll(0, data);
    _bindings.outputWrite(_writeBuffer, data.length);
  }

  void clearOutput() {
    if (!_isRunning) return;
    _bindings.outputClear();
  }

  void _ensureReadCapacity(int frames) {
    if (_readCapacity >= frames) return;
    if (_readBuffer != nullptr) malloc.free(_readBuffer);
    _readBuffer = malloc<Float>(frames);
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

/// Main-isolate Apple data-plane transport: the poll timer and buffer copies
/// run on the main isolate. Default mode; see `AudioIoAppleIsolateProxy` for
/// the dedicated-isolate alternative.
class AudioIoAppleMainTransport implements AudioIoAppleTransport {
  final AudioIoAppleCore _core = AudioIoAppleCore();

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
}
