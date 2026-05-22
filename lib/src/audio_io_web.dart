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
  static const _pcm16FormatValue = 1;
  static const _scriptProcessorBufferSize = 2048;

  AudioContext? _audioContext;
  ScriptProcessorNode? _scriptProcessor;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  StreamController<Uint8List>? _inputBytesController;
  StreamController<Uint8List>? _outputBytesController;
  List<double> _outputBuffer = [];
  bool _isRunning = false;
  int _format = 0;

  @override
  bool get usePlatformImpl => true;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Stream<Uint8List>? get inputBytesStream => _inputBytesController?.stream;

  @override
  StreamSink<Uint8List>? get outputBytesSink => _outputBytesController?.sink;

  @override
  Future<void> start({int sampleRate = 48000, int format = 0}) async {
    if (_isRunning) return;
    _format = format;

    try {
      _audioContext = AudioContext();

      if (_audioContext!.state == 'suspended') {
        await _audioContext!.resume().toDart;
      }

      _scriptProcessor = _audioContext!.createScriptProcessor(
        _scriptProcessorBufferSize,
        1,
        1,
      );

      _inputController = StreamController<List<double>>.broadcast();
      _outputController = StreamController<List<double>>();
      _inputBytesController = StreamController<Uint8List>.broadcast();
      _outputBytesController = StreamController<Uint8List>();

      if (_format == _pcm16FormatValue) {
        _outputBytesController!.stream.listen((bytes) {
          _outputBuffer.addAll(_pcm16LeToFloat32(bytes));
        });
      } else {
        _outputController!.stream.listen((data) {
          _outputBuffer.addAll(data);
        });
      }

      _scriptProcessor!.onaudioprocess = ((JSAny event) {
        final audioEvent = event as AudioProcessingEvent;
        final inputBuffer = audioEvent.inputBuffer;
        final outputBuffer = audioEvent.outputBuffer;

        final bufferLength = inputBuffer.length;

        final inputData = inputBuffer.getChannelData(0);
        final inputList = <double>[];
        for (int i = 0; i < bufferLength; i++) {
          final value = inputData.getProperty(i.toJS) as JSNumber?;
          inputList.add(value?.toDartDouble ?? 0.0);
        }

        if (_format == _pcm16FormatValue) {
          _inputBytesController?.add(_float32ListToPcm16Le(inputList));
        } else {
          _inputController?.add(inputList);
        }

        final outputData = outputBuffer.getChannelData(0);
        for (int i = 0; i < bufferLength; i++) {
          final value =
              _outputBuffer.isNotEmpty ? _outputBuffer.removeAt(0) : 0.0;
          outputData.setProperty(i.toJS, value.toJS);
        }
      }).toJS;

      _scriptProcessor!.connect(_audioContext!.destination);

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
    await _inputBytesController?.close();
    await _outputBytesController?.close();
    _inputController = null;
    _outputController = null;
    _inputBytesController = null;
    _outputBytesController = null;
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

Uint8List _float32ListToPcm16Le(List<double> samples) {
  final bytes = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    bytes.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return bytes.buffer.asUint8List();
}

List<double> _pcm16LeToFloat32(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final samples = List<double>.filled(bytes.length ~/ 2, 0.0);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32767.0;
  }
  return samples;
}

AudioIoImpl createAudioIoImpl() => AudioIoWeb();
