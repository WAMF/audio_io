import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

@JS('AudioIoWasm')
external JSObject get audioIoWasm;

@JS()
@staticInterop
class AudioIoModule {}

extension AudioIoModuleExtension on AudioIoModule {
  external JSFunction get _audio_io_create;
  external JSFunction get _audio_io_destroy;
  external JSFunction get _audio_io_start;
  external JSFunction get _audio_io_stop;
  external JSFunction get _audio_io_read;
  external JSFunction get _audio_io_write;
  external JSFunction get _audio_io_get_sample_rate;
  external JSFunction get _audio_io_get_channels;
  external JSFunction get _audio_io_get_available_read_frames;
  external JSFunction get _audio_io_get_available_write_space;
  external JSFunction get ccall;
  external JSFunction get cwrap;
  external JSAny get HEAPF64;
  external JSFunction get _malloc;
  external JSFunction get _free;
}

class AudioIoWeb {
  static AudioIoWeb? _instance;
  static AudioIoWeb get instance => _instance ??= AudioIoWeb._();

  AudioIoModule? _module;
  JSNumber? _handle;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  Timer? _inputTimer;
  bool _isRunning = false;
  bool _isInitialized = false;

  AudioIoWeb._();

  Stream<List<double>>? get inputAudioStream => _inputController?.stream;
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  Future<void> _initializeModule() async {
    if (_isInitialized) return;

    // Load the WebAssembly module
    final script =
        web.document.createElement('script') as web.HTMLScriptElement;
    script.src = 'packages/audio_io/web/build/audio_io.js';

    final completer = Completer<void>();
    script.onload = ((web.Event e) {
      _module = audioIoWasm as AudioIoModule;
      _isInitialized = true;
      completer.complete();
    }).toJS;

    script.onerror = ((web.Event e) {
      completer.completeError('Failed to load WebAssembly module');
    }).toJS;

    web.document.head!.appendChild(script);
    await completer.future;
  }

  Future<void> start() async {
    if (_isRunning) return;

    await _initializeModule();
    if (_module == null) {
      throw Exception('WebAssembly module not initialized');
    }

    // Create audio context
    final createFunc = _module!.cwrap.callAsFunction(
      'audio_io_create'.toJS,
      'number'.toJS,
      [].toJS,
    ) as JSFunction;

    _handle = createFunc.callAsFunction() as JSNumber;

    if (_handle == null || _handle!.toDartInt == 0) {
      throw Exception('Failed to create audio context');
    }

    // Start audio device
    final startFunc = _module!.cwrap.callAsFunction(
      'audio_io_start'.toJS,
      'number'.toJS,
      ['number'].toJS,
    ) as JSFunction;

    final result = startFunc.callAsFunction(_handle) as JSNumber;

    if (result.toDartInt != 0) {
      _destroyContext();
      throw Exception('Failed to start audio device');
    }

    _isRunning = true;
    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();

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
    _inputController = null;
    _outputController = null;

    if (_handle != null && _module != null) {
      final stopFunc = _module!.cwrap.callAsFunction(
        'audio_io_stop'.toJS,
        'number'.toJS,
        ['number'].toJS,
      ) as JSFunction;

      stopFunc.callAsFunction(_handle);
      _destroyContext();
    }
  }

  void _destroyContext() {
    if (_handle != null && _module != null) {
      final destroyFunc = _module!.cwrap.callAsFunction(
        'audio_io_destroy'.toJS,
        null.toJS,
        ['number'].toJS,
      ) as JSFunction;

      destroyFunc.callAsFunction(_handle);
      _handle = null;
    }
  }

  void _startInputPolling() {
    const pollInterval = Duration(milliseconds: 10);
    const framesPerPoll = 480;

    _inputTimer = Timer.periodic(pollInterval, (_) {
      if (!_isRunning || _handle == null || _module == null) return;

      final getAvailableFunc = _module!.cwrap.callAsFunction(
        'audio_io_get_available_read_frames'.toJS,
        'number'.toJS,
        ['number'].toJS,
      ) as JSFunction;

      final availableFrames =
          (getAvailableFunc.callAsFunction(_handle) as JSNumber).toDartInt;

      if (availableFrames > 0) {
        final framesToRead =
            availableFrames > framesPerPoll ? framesPerPoll : availableFrames;

        // Allocate buffer in WASM memory
        final mallocFunc = _module!._malloc;
        final bufferPtr =
            (mallocFunc.callAsFunction((framesToRead * 8).toJS) as JSNumber)
                .toDartInt;

        try {
          // Read audio data
          final readFunc = _module!.cwrap.callAsFunction(
            'audio_io_read'.toJS,
            'number'.toJS,
            ['number', 'number', 'number'].toJS,
          ) as JSFunction;

          final framesRead = (readFunc.callAsFunction(
            _handle,
            bufferPtr.toJS,
            framesToRead.toJS,
          ) as JSNumber)
              .toDartInt;

          if (framesRead > 0) {
            // Copy data from WASM heap to Dart
            final heap = _module!.HEAPF64 as JSFloat64Array;
            final startIdx = bufferPtr ~/ 8;
            final data = List<double>.generate(
              framesRead,
              (i) => heap[startIdx + i].toDartDouble,
            );

            _inputController?.add(data);
          }
        } finally {
          // Free WASM memory
          final freeFunc = _module!._free;
          freeFunc.callAsFunction(bufferPtr.toJS);
        }
      }
    });
  }

  void _writeAudio(List<double> data) {
    if (!_isRunning || _handle == null || _module == null) return;

    // Allocate buffer in WASM memory
    final mallocFunc = _module!._malloc;
    final bufferPtr =
        (mallocFunc.callAsFunction((data.length * 8).toJS) as JSNumber)
            .toDartInt;

    try {
      // Copy data to WASM heap
      final heap = _module!.HEAPF64 as JSFloat64Array;
      final startIdx = bufferPtr ~/ 8;
      for (int i = 0; i < data.length; i++) {
        heap[startIdx + i] = data[i].toJS;
      }

      // Write audio data
      final writeFunc = _module!.cwrap.callAsFunction(
        'audio_io_write'.toJS,
        'number'.toJS,
        ['number', 'number', 'number'].toJS,
      ) as JSFunction;

      writeFunc.callAsFunction(
        _handle,
        bufferPtr.toJS,
        data.length.toJS,
      );
    } finally {
      // Free WASM memory
      final freeFunc = _module!._free;
      freeFunc.callAsFunction(bufferPtr.toJS);
    }
  }

  Map<String, dynamic> getFormat() {
    if (_handle == null || _module == null) {
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

    final getSampleRateFunc = _module!.cwrap.callAsFunction(
      'audio_io_get_sample_rate'.toJS,
      'number'.toJS,
      ['number'].toJS,
    ) as JSFunction;

    final getChannelsFunc = _module!.cwrap.callAsFunction(
      'audio_io_get_channels'.toJS,
      'number'.toJS,
      ['number'].toJS,
    ) as JSFunction;

    final sampleRate =
        (getSampleRateFunc.callAsFunction(_handle) as JSNumber).toDartDouble;
    final channels =
        (getChannelsFunc.callAsFunction(_handle) as JSNumber).toDartInt;

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

  Future<void> requestFrameDuration(double duration) async {}

  Future<double> getFrameDuration() async {
    return 0.01;
  }
}
