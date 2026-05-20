import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_io_stub.dart';

@JS('window')
external JSObject get window;

@JS('AudioContext')
@staticInterop
class AudioContext {
  external factory AudioContext();
}

extension AudioContextExt on AudioContext {
  external double get sampleRate;
  external String get state;
  external JSPromise resume();
  external JSPromise close();
  external ScriptProcessorNode createScriptProcessor(
      int bufferSize, int inputChannels, int outputChannels);
  external AudioDestinationNode get destination;
  external MediaStreamAudioSourceNode createMediaStreamSource(
      web.MediaStream stream);
}

@JS()
@staticInterop
class AudioDestinationNode {}

@JS()
@staticInterop
class MediaStreamAudioSourceNode {}

extension MediaStreamAudioSourceNodeExt on MediaStreamAudioSourceNode {
  external void connect(ScriptProcessorNode node);
}

@JS()
@staticInterop
class ScriptProcessorNode {}

extension ScriptProcessorNodeExt on ScriptProcessorNode {
  external set onaudioprocess(JSFunction? handler);
  external void connect(AudioDestinationNode destination);
  external void disconnect();
}

@JS()
@staticInterop
class AudioProcessingEvent {}

extension AudioProcessingEventExt on AudioProcessingEvent {
  external AudioBuffer get inputBuffer;
  external AudioBuffer get outputBuffer;
}

@JS()
@staticInterop
class AudioBuffer {}

extension AudioBufferExt on AudioBuffer {
  external JSFloat32Array getChannelData(int channel);
  external int get length;
}

class AudioIoWeb implements AudioIoImpl {
  AudioContext? _audioContext;
  ScriptProcessorNode? _scriptProcessor;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  List<double> _outputBuffer = [];
  bool _isRunning = false;

  @override
  bool get usePlatformImpl => true;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Stream<Uint8List>? get inputBytesStream => null;

  @override
  StreamSink<Uint8List>? get outputBytesSink => null;

  @override
  Future<void> start({int sampleRate = 48000, int format = 0}) async {
    if (_isRunning) return;

    try {
      // Create audio context
      _audioContext = AudioContext();

      // Resume context if suspended (required for Chrome)
      if (_audioContext!.state == 'suspended') {
        await _audioContext!.resume().toDart;
      }

      // Create script processor for audio processing
      // Buffer size of 2048, 1 input channel, 1 output channel
      _scriptProcessor = _audioContext!.createScriptProcessor(2048, 1, 1);

      _inputController = StreamController<List<double>>.broadcast();
      _outputController = StreamController<List<double>>();

      // Listen for output data
      _outputController!.stream.listen((data) {
        _outputBuffer.addAll(data);
      });

      // Set up audio processing callback
      _scriptProcessor!.onaudioprocess = ((JSAny event) {
        final audioEvent = event as AudioProcessingEvent;
        final inputBuffer = audioEvent.inputBuffer;
        final outputBuffer = audioEvent.outputBuffer;

        final bufferLength = inputBuffer.length;

        // Get input data
        final inputData = inputBuffer.getChannelData(0);

        // Convert Float32Array to Dart List
        final inputList = <double>[];
        for (int i = 0; i < bufferLength; i++) {
          final value = inputData.getProperty(i.toJS) as JSNumber?;
          inputList.add(value?.toDartDouble ?? 0.0);
        }

        // Send input to stream
        _inputController?.add(inputList);

        // Get output data
        final outputData = outputBuffer.getChannelData(0);

        // Fill output buffer
        for (int i = 0; i < bufferLength; i++) {
          final value =
              _outputBuffer.isNotEmpty ? _outputBuffer.removeAt(0) : 0.0;
          outputData.setProperty(i.toJS, value.toJS);
        }
      }).toJS;

      // Connect to speakers
      _scriptProcessor!.connect(_audioContext!.destination);

      // Request microphone access
      final mediaStream = await _getUserMedia();
      if (mediaStream != null) {
        final source = _audioContext!.createMediaStreamSource(mediaStream);
        source.connect(_scriptProcessor!);
      }

      _isRunning = true;
    } catch (e) {
      throw Exception('Failed to start audio: $e');
    }
  }

  Future<web.MediaStream?> _getUserMedia() async {
    try {
      final constraints = web.MediaStreamConstraints(
        audio: true.toJS,
      );

      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      return stream;
    } catch (e) {
      print('Failed to get user media: $e');
      return null;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;

    _scriptProcessor?.disconnect();
    _scriptProcessor = null;

    await _audioContext?.close().toDart;
    _audioContext = null;

    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;
    _outputBuffer.clear();
  }

  @override
  Map<String, dynamic> getFormat() {
    final sampleRate = _audioContext?.sampleRate ?? 48000.0;

    return {
      'input': {
        'type': 'double',
        'channels': 1,
        'sampleRate': sampleRate,
      },
      'output': {
        'type': 'double',
        'channels': 1,
        'sampleRate': sampleRate,
      },
    };
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    // Web Audio API uses fixed buffer sizes
  }

  @override
  Future<double> getFrameDuration() async {
    // 2048 samples at 48kHz = ~42.67ms
    final sampleRate = _audioContext?.sampleRate ?? 48000.0;
    return 2048 / sampleRate;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoWeb();
