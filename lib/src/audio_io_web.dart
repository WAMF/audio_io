import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_io_stub.dart';
import 'output_ring.dart';

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
  external void copyToChannel(JSFloat32Array source, int channelNumber);
  external int get length;
}

/// Web implementation backed by a ScriptProcessorNode.
///
/// Output samples are queued in an O(1) [OutputRing] and copied to the
/// audio callback in bulk (no per-sample JS interop). Clients always push
/// 48 kHz data; when the AudioContext runs at a different device rate the
/// ring drain linearly resamples, so the contract and the real-time
/// consumption rate (48,000 frames per second) hold on every device.
///
/// The microphone is only requested once [inputAudioStream] is listened
/// to: output-only users never trigger a permission prompt.
class AudioIoWeb implements AudioIoImpl {
  static const double _contractSampleRate = 48000;

  // ScriptProcessorNode runs on the main thread; small buffers glitch as
  // soon as the page does any real work.
  static const int _minBufferSize = 2048;
  static const int _minRingFrames = 16384;
  static const double _ringDurationMultiplier = 4;

  AudioContext? _audioContext;
  ScriptProcessorNode? _scriptProcessor;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  OutputRing _ring = OutputRing(_minRingFrames);
  Float32List _scratch = Float32List(0);
  bool _isRunning = false;
  bool _inputRequested = false;
  double _requestedFrameDuration = 0.003; // Default 3ms (Balanced)
  int _bufferSize = _minBufferSize;

  @override
  bool get usePlatformImpl => true;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  // ScriptProcessorNode requires a power of two between 256 and 16384;
  // anything below 2048 glitches on the main thread.
  int _calculateBufferSize(double sampleRate) {
    final targetSamples = (_requestedFrameDuration * sampleRate).round();

    const validSizes = [2048, 4096, 8192, 16384];

    for (final size in validSizes) {
      if (size >= targetSamples) {
        return size;
      }
    }

    return 16384;
  }

  int _calculateRingFrames() {
    final requested =
        (_requestedFrameDuration * _contractSampleRate * _ringDurationMultiplier)
            .round();
    return requested > _minRingFrames ? requested : _minRingFrames;
  }

  @override
  Future<void> start() async {
    if (_isRunning) return;

    try {
      _audioContext = AudioContext();

      // Resume context if suspended (required for Chrome)
      if (_audioContext!.state == 'suspended') {
        await _audioContext!.resume().toDart;
      }

      final sampleRate = _audioContext!.sampleRate;
      _bufferSize = _calculateBufferSize(sampleRate);
      _ring = OutputRing(_calculateRingFrames());
      _scratch = Float32List(_bufferSize);

      // Buffer size, 1 input channel, 1 output channel
      _scriptProcessor =
          _audioContext!.createScriptProcessor(_bufferSize, 1, 1);

      // Request the microphone lazily so output-only users never see a
      // permission prompt.
      _inputController = StreamController<List<double>>.broadcast(
        onListen: _connectInputIfNeeded,
      );

      _outputController = StreamController<List<double>>();
      _outputController!.stream.listen(_ring.write);

      final resampleRatio = _contractSampleRate / sampleRate;

      _scriptProcessor!.onaudioprocess = ((JSAny event) {
        final audioEvent = event as AudioProcessingEvent;
        final outputBuffer = audioEvent.outputBuffer;
        final frames = outputBuffer.length;

        if (_scratch.length < frames) {
          _scratch = Float32List(frames);
        }

        _ring.readResampled(_scratch, frames, resampleRatio);
        outputBuffer.copyToChannel(_scratch.toJS, 0);

        final input = _inputController;
        if (_inputRequested && input != null && input.hasListener) {
          final inputData = audioEvent.inputBuffer.getChannelData(0).toDart;
          input.add(List<double>.from(inputData));
        }
      }).toJS;

      // Connect to speakers
      _scriptProcessor!.connect(_audioContext!.destination);

      _isRunning = true;

      if (_inputController!.hasListener) {
        await _connectInputIfNeeded();
      }
    } catch (e) {
      throw Exception('Failed to start audio: $e');
    }
  }

  Future<void> _connectInputIfNeeded() async {
    if (_inputRequested || !_isRunning) return;
    _inputRequested = true;

    final mediaStream = await _getUserMedia();
    final context = _audioContext;
    final processor = _scriptProcessor;
    if (mediaStream != null && context != null && processor != null) {
      context.createMediaStreamSource(mediaStream).connect(processor);
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
      // Failed to get user media
      return null;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    _isRunning = false;
    _inputRequested = false;
    _scriptProcessor?.disconnect();
    _scriptProcessor = null;
    await _audioContext?.close().toDart;
    _audioContext = null;
    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;
    _ring.clear();
  }

  @override
  Map<String, dynamic> getFormat() {
    final deviceSampleRate = _audioContext?.sampleRate ?? _contractSampleRate;
    return {
      'input': {
        'type': 'double',
        'channels': 1,
        'sampleRate': _contractSampleRate,
      },
      'output': {
        'type': 'double',
        'channels': 1,
        'sampleRate': _contractSampleRate,
        'deviceSampleRate': deviceSampleRate,
      },
    };
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;

    // If already running, restart with new buffer size
    if (_isRunning) {
      await stop();
      await start();
    }
  }

  @override
  Future<double> getFrameDuration() async {
    final sampleRate = _audioContext?.sampleRate ?? _contractSampleRate;
    // If not running, calculate what the buffer size would be
    final actualBufferSize =
        _isRunning ? _bufferSize : _calculateBufferSize(sampleRate);

    return actualBufferSize / sampleRate;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoWeb();
