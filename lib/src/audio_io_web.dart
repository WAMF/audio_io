import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_io_stub.dart';
import 'output_ring.dart';
import 'push_resampler.dart';

@JS('AudioContext')
@staticInterop
class AudioContext {
  external factory AudioContext();
}

extension AudioContextExt on AudioContext {
  external AudioWorkletJs get audioWorklet;
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

@JS()
@staticInterop
class AudioWorkletJs {}

extension AudioWorkletJsExt on AudioWorkletJs {
  external JSPromise addModule(String moduleURL);
}

@JS('AudioWorkletNode')
@staticInterop
class AudioWorkletNodeJs {
  external factory AudioWorkletNodeJs(AudioContext context, String name);
}

extension AudioWorkletNodeJsExt on AudioWorkletNodeJs {
  external MessagePortJs get port;
  external void connect(AudioDestinationNode destination);
  external void disconnect();
}

@JS()
@staticInterop
class MessagePortJs {}

extension MessagePortJsExt on MessagePortJs {
  external void postMessage(JSAny? message);
}

extension AudioBufferExt on AudioBuffer {
  external JSFloat32Array getChannelData(int channel);
  external void copyToChannel(JSFloat32Array source, int channelNumber);
  external int get length;
}

/// JavaScript for the output AudioWorkletProcessor: a simple
/// single-producer single-consumer ring drained on the audio rendering
/// thread, immune to main-thread jank.
const String _workletSource = '''
class AudioIoOutput extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = 65536;
    this.mask = this.capacity - 1;
    this.buf = new Float32Array(this.capacity);
    this.head = 0;
    this.tail = 0;
    this.port.onmessage = (e) => {
      const d = e.data;
      const free = this.capacity - (this.head - this.tail);
      const n = Math.min(d.length, free);
      for (let i = 0; i < n; i++) {
        this.buf[(this.head + i) & this.mask] = d[i];
      }
      this.head += n;
    };
  }
  process(inputs, outputs) {
    const out = outputs[0][0];
    const avail = this.head - this.tail;
    const n = Math.min(out.length, avail);
    for (let i = 0; i < n; i++) {
      out[i] = this.buf[(this.tail + i) & this.mask];
    }
    for (let i = n; i < out.length; i++) {
      out[i] = 0;
    }
    this.tail += n;
    return true;
  }
}
registerProcessor('audio-io-output', AudioIoOutput);
''';

/// Web implementation.
///
/// Output goes through an [AudioWorkletNode] when available: the worklet
/// owns a ring buffer drained on the dedicated audio rendering thread, so
/// main-thread jank cannot glitch playback. Browsers without worklet
/// support fall back to a ScriptProcessorNode fed from an O(1)
/// [OutputRing] with bulk copies.
///
/// Clients always push 48 kHz data; when the AudioContext runs at a
/// different device rate the push path linearly resamples, so the
/// contract and the real-time consumption rate (48,000 frames per second)
/// hold on every device.
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

  // AudioWorklet renders in fixed quanta of 128 frames.
  static const int _workletQuantumFrames = 128;
  static const String _workletProcessorName = 'audio-io-output';

  AudioContext? _audioContext;
  AudioWorkletNodeJs? _workletNode;
  String? _workletUrl;
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

      // Request the microphone lazily so output-only users never see a
      // permission prompt.
      _inputController = StreamController<List<double>>.broadcast(
        onListen: _connectInputIfNeeded,
      );
      _outputController = StreamController<List<double>>();

      final workletStarted = await _tryStartWorkletOutput(sampleRate);
      if (!workletStarted) {
        _startScriptProcessorOutput(sampleRate);
      }

      _isRunning = true;

      if (_inputController!.hasListener) {
        await _connectInputIfNeeded();
      }
    } catch (e) {
      throw Exception('Failed to start audio: $e');
    }
  }

  /// Loads the worklet module from a Blob URL and wires the output stream
  /// to its message port. Returns false (after cleaning up) on browsers
  /// without AudioWorklet support so the caller can fall back.
  Future<bool> _tryStartWorkletOutput(double sampleRate) async {
    try {
      final blob = web.Blob(
        [_workletSource.toJS].toJS,
        web.BlobPropertyBag(type: 'application/javascript'),
      );
      final url = web.URL.createObjectURL(blob);
      _workletUrl = url;
      await _audioContext!.audioWorklet.addModule(url).toDart;

      final node = AudioWorkletNodeJs(_audioContext!, _workletProcessorName)
        ..connect(_audioContext!.destination);
      _workletNode = node;

      final resampler =
          PushResampler(_contractSampleRate.toInt(), sampleRate.round());
      _outputController!.stream.listen((data) {
        final converted = resampler.process(data);
        if (converted.isNotEmpty) {
          node.port.postMessage(converted.toJS);
        }
      });
      return true;
    } catch (e) {
      _releaseWorklet();
      return false;
    }
  }

  void _startScriptProcessorOutput(double sampleRate) {
    _ring = OutputRing(_calculateRingFrames());
    _scratch = Float32List(_bufferSize);
    _outputController!.stream.listen(_ring.write);

    final resampleRatio = _contractSampleRate / sampleRate;

    // Buffer size, 1 input channel, 1 output channel
    final processor = _audioContext!.createScriptProcessor(_bufferSize, 1, 1);
    processor.onaudioprocess = ((JSAny event) {
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
    processor.connect(_audioContext!.destination);
    _scriptProcessor = processor;
  }

  void _releaseWorklet() {
    _workletNode?.disconnect();
    _workletNode = null;
    final url = _workletUrl;
    if (url != null) {
      web.URL.revokeObjectURL(url);
      _workletUrl = null;
    }
  }

  Future<void> _connectInputIfNeeded() async {
    if (_inputRequested || !_isRunning) return;
    _inputRequested = true;

    final mediaStream = await _getUserMedia();
    final context = _audioContext;
    if (mediaStream == null || context == null) return;

    final processor = _scriptProcessor ?? _createInputProcessor(context);
    context.createMediaStreamSource(mediaStream).connect(processor);
  }

  /// Input-only ScriptProcessorNode used when output runs in the worklet.
  /// It must be connected to the destination to fire, but it never writes
  /// to its output buffer, so it contributes only silence.
  ScriptProcessorNode _createInputProcessor(AudioContext context) {
    final processor = context.createScriptProcessor(_bufferSize, 1, 1);
    processor.onaudioprocess = ((JSAny event) {
      final audioEvent = event as AudioProcessingEvent;
      final input = _inputController;
      if (input != null && input.hasListener) {
        final inputData = audioEvent.inputBuffer.getChannelData(0).toDart;
        input.add(List<double>.from(inputData));
      }
    }).toJS;
    processor.connect(context.destination);
    _scriptProcessor = processor;
    return processor;
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
    _releaseWorklet();
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
    if (_workletNode != null) {
      return _workletQuantumFrames / sampleRate;
    }
    // If not running, calculate what the buffer size would be
    final actualBufferSize =
        _isRunning ? _bufferSize : _calculateBufferSize(sampleRate);

    return actualBufferSize / sampleRate;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoWeb();
