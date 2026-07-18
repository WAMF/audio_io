import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'audio_io_exception.dart';
import 'audio_io_input_source.dart';
import 'audio_io_stub.dart';
import 'output_ring.dart';

/// `MediaDevices.getDisplayMedia` is not declared in `package:web` 0.5.x, so
/// we bind it locally. It prompts the browser's screen/tab/window share
/// picker (must be called from a user gesture) and resolves to a
/// [web.MediaStream]. On Chromium the stream carries an audio track with the
/// captured tab/system audio; Firefox and Safari resolve a video-only stream.
extension MediaDevicesDisplayMediaExt on web.MediaDevices {
  external JSPromise<web.MediaStream> getDisplayMedia([JSObject options]);
}

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
  @JS('connect')
  external void connectWorklet(AudioWorkletNodeJs node);
  external void disconnect();
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
  external factory AudioWorkletNodeJs(AudioContext context, String name,
      [JSAny? options]);
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
  @JS('postMessage')
  external void postMessageWithTransfer(
      JSAny? message, JSArray<JSObject> transfer);
  external set onmessage(JSFunction? handler);
}

extension AudioBufferExt on AudioBuffer {
  external JSFloat32Array getChannelData(int channel);
  external void copyToChannel(JSFloat32Array source, int channelNumber);
  external int get length;
}

/// JavaScript for the AudioWorkletProcessors.
///
/// Output: a single-producer single-consumer ring drained on the audio
/// rendering thread. Chunks arrive as transferable buffers already in wire
/// format (Float32 or PCM16 Int16) at a declared source rate; decoding and
/// linear resampling to the context rate happen HERE, on the rendering
/// thread, so the main thread's only per-chunk cost is a postMessage. The
/// resampler mirrors the Dart PushResampler phase arithmetic.
///
/// Input: captures at the context rate, resamples to the 48 kHz contract,
/// and posts transferable fixed-size chunks back to the main thread.
const String _workletSource = '''
class AudioIoOutput extends AudioWorkletProcessor {
  constructor() {
    super();
    this.capacity = 65536;
    this.mask = this.capacity - 1;
    this.buf = new Float32Array(this.capacity);
    this.head = 0;
    this.tail = 0;
    this.prev = 0;
    this.phase = sampleRate;
    this.port.onmessage = (e) => {
      const d = e.data;
      if (d === 'clear') {
        this.head = 0;
        this.tail = 0;
        this.prev = 0;
        this.phase = sampleRate;
        return;
      }
      const pcm16 = d.fmt === 'pcm16';
      const samples = pcm16
        ? new Int16Array(d.buf, d.off, d.len)
        : new Float32Array(d.buf, d.off, d.len);
      this.push(samples, pcm16 ? 1 / 32767 : 1, d.rate);
    };
  }
  writeSample(v) {
    if (this.head - this.tail < this.capacity) {
      this.buf[this.head & this.mask] = v;
      this.head++;
    }
  }
  push(samples, scale, srcRate) {
    const dstRate = sampleRate;
    if (srcRate === dstRate) {
      for (let i = 0; i < samples.length; i++) {
        this.writeSample(samples[i] * scale);
      }
      return;
    }
    let prev = this.prev;
    let phase = this.phase;
    for (let i = 0; i < samples.length; i++) {
      const s = samples[i] * scale;
      while (phase < dstRate) {
        this.writeSample(prev + (s - prev) * (phase / dstRate));
        phase += srcRate;
      }
      phase -= dstRate;
      prev = s;
    }
    this.prev = prev;
    this.phase = phase;
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

class AudioIoInput extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const opts = (options && options.processorOptions) || {};
    this.targetRate = opts.targetRate || 48000;
    this.chunkFrames = opts.chunkFrames || 1024;
    this.chunk = new Float32Array(this.chunkFrames);
    this.fill = 0;
    this.prev = 0;
    this.phase = this.targetRate;
  }
  emit(v) {
    this.chunk[this.fill++] = v;
    if (this.fill === this.chunkFrames) {
      this.port.postMessage(this.chunk, [this.chunk.buffer]);
      this.chunk = new Float32Array(this.chunkFrames);
      this.fill = 0;
    }
  }
  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (!channel) return true;
    const srcRate = sampleRate;
    const dstRate = this.targetRate;
    if (srcRate === dstRate) {
      for (let i = 0; i < channel.length; i++) {
        this.emit(channel[i]);
      }
      return true;
    }
    let prev = this.prev;
    let phase = this.phase;
    for (let i = 0; i < channel.length; i++) {
      const s = channel[i];
      while (phase < dstRate) {
        this.emit(prev + (s - prev) * (phase / dstRate));
        phase += srcRate;
      }
      phase -= dstRate;
      prev = s;
    }
    this.prev = prev;
    this.phase = phase;
    return true;
  }
}

registerProcessor('audio-io-output', AudioIoOutput);
registerProcessor('audio-io-input', AudioIoInput);
''';

class _MessageFields {
  static const format = 'fmt';
  static const buffer = 'buf';
  static const byteOffset = 'off';
  static const length = 'len';
  static const rate = 'rate';
}

class _Formats {
  static const float32 = 'f32';
  static const pcm16 = 'pcm16';
}

/// Posts [buffer] to a worklet port as a transferable, so crossing to the
/// audio rendering thread is a hand-off rather than a structured clone.
/// The buffer must be freshly allocated by the caller: transfer detaches it.
void _postSamples(MessagePortJs port, String format, ByteBuffer buffer,
    int byteOffset, int length, int rate) {
  final jsBuffer = buffer.toJS;
  final message = JSObject()
    ..[_MessageFields.format] = format.toJS
    ..[_MessageFields.buffer] = jsBuffer
    ..[_MessageFields.byteOffset] = byteOffset.toJS
    ..[_MessageFields.length] = length.toJS
    ..[_MessageFields.rate] = rate.toJS;
  port.postMessageWithTransfer(message, <JSObject>[jsBuffer].toJS);
}

/// PCM16 sink that feeds the output worklet directly: decode and resampling
/// happen on the audio rendering thread, so pushing a chunk costs the main
/// thread one copy and one postMessage.
class _WorkletPcm16Sink implements Sink<Uint8List> {
  _WorkletPcm16Sink(this._port, this._sourceRate);

  final MessagePortJs _port;
  final int _sourceRate;

  static const _bytesPerSample = 2;

  @override
  void add(Uint8List data) {
    if (data.isEmpty) return;
    // Copied so the transferred (detached) buffer is never one the caller
    // still holds, and so the Int16Array view starts 2-byte aligned.
    final owned = Uint8List.fromList(data);
    _postSamples(_port, _Formats.pcm16, owned.buffer, 0,
        owned.length ~/ _bytesPerSample, _sourceRate);
  }

  @override
  void close() {}
}

/// Web implementation.
///
/// Output goes through an [AudioWorkletNode] when available: the worklet
/// owns a ring buffer drained on the dedicated audio rendering thread, and
/// also performs PCM16 decoding and resampling there, so main-thread jank
/// cannot glitch playback and the main-thread cost per chunk is one
/// transferable postMessage. Browsers without worklet support fall back to
/// a ScriptProcessorNode fed from an O(1) [OutputRing] with bulk copies.
///
/// Input likewise prefers an AudioWorkletProcessor that resamples to the
/// 48 kHz contract on the rendering thread and posts transferable chunks;
/// the ScriptProcessorNode fallback delivers at the context rate (reported
/// honestly by [getFormat]).
///
/// The microphone is only requested once [inputAudioStream] is listened
/// to: output-only users never trigger a permission prompt.
class AudioIoWeb extends AudioIoImpl {
  static const double _contractSampleRate = 48000;

  // ScriptProcessorNode runs on the main thread; small buffers glitch as
  // soon as the page does any real work.
  static const int _minBufferSize = 2048;
  static const int _minRingFrames = 16384;
  static const double _ringDurationMultiplier = 4;

  // AudioWorklet renders in fixed quanta of 128 frames.
  static const int _workletQuantumFrames = 128;
  static const String _outputProcessorName = 'audio-io-output';
  static const String _inputProcessorName = 'audio-io-input';
  static const int _minInputChunkFrames = 128;
  static const int _maxInputChunkFrames = 4096;

  AudioContext? _audioContext;
  Future<void>? _startInFlight;
  AudioWorkletNodeJs? _workletNode;
  AudioWorkletNodeJs? _inputWorkletNode;
  String? _workletUrl;
  bool _workletModuleLoaded = false;
  ScriptProcessorNode? _scriptProcessor;
  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;
  OutputRing _ring = OutputRing(_minRingFrames);
  Float32List _scratch = Float32List(0);
  bool _isRunning = false;
  bool _inputRequested = false;
  double _requestedFrameDuration = 0.003; // Default 3ms (Balanced)
  int _bufferSize = _minBufferSize;
  AudioIoInputSource _inputSource = AudioIoInputSource.microphone;
  MediaStreamAudioSourceNode? _inputSourceNode;
  web.MediaStream? _inputMediaStream;

  @override
  bool get usePlatformImpl => true;

  @override
  void configureInputSource(AudioIoInputSource source) {
    _inputSource = source;
  }

  @override
  bool supportsInputSource(AudioIoInputSource source) {
    // Both the microphone (getUserMedia) and system/tab audio
    // (getDisplayMedia) are reachable in the browser. getDisplayMedia only
    // yields an audio track on Chromium, but that can't be detected until
    // the user has answered the share picker, so the "no audio track"
    // failure surfaces at start time as an [AudioIoException] with
    // [AudioIoException.isSystemAudioUnsupported] rather than here.
    return true;
  }

  @override
  Stream<List<double>>? get inputAudioStream => _ensureInputController().stream;

  /// The input stream must exist *before* [start], so a listener that
  /// subscribes before `startWith` attaches to the real controller rather than
  /// a throwaway `Stream.empty()` and still receives the getDisplayMedia picker
  /// error (delivered via [_connectInputIfNeeded]'s `addError`). Created lazily
  /// and reused across a start; broadcast so a listen-before-start and a
  /// listen-after-start both work and multiple listeners are allowed.
  StreamController<List<double>> _ensureInputController() {
    return _inputController ??= StreamController<List<double>>.broadcast(
      onListen: _connectInputIfNeeded,
    );
  }

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Sink<Uint8List>? pcm16OutputSink(int sourceRate) {
    final node = _workletNode;
    if (node == null) return null;
    return _WorkletPcm16Sink(node.port, sourceRate);
  }

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
    final requested = (_requestedFrameDuration *
            _contractSampleRate *
            _ringDurationMultiplier)
        .round();
    return requested > _minRingFrames ? requested : _minRingFrames;
  }

  int _calculateInputChunkFrames() {
    final requested = (_requestedFrameDuration * _contractSampleRate).round();
    return requested.clamp(_minInputChunkFrames, _maxInputChunkFrames);
  }

  /// Concurrent calls share one start attempt: the web fires a lifecycle
  /// resume on every window focus, which raced widget-init starts into
  /// two AudioContexts (and a StateError on the second output listen).
  @override
  Future<void> start() {
    if (_isRunning) return Future.value();
    return _startInFlight ??=
        _startOnce().whenComplete(() => _startInFlight = null);
  }

  Future<void> _startOnce() async {
    if (_isRunning) return;

    try {
      _audioContext = AudioContext();

      // Resume context if suspended (required for Chrome)
      if (_audioContext!.state == 'suspended') {
        await _audioContext!.resume().toDart;
      }

      final sampleRate = _audioContext!.sampleRate;
      _bufferSize = _calculateBufferSize(sampleRate);

      // Reuse the controller a pre-start listener may already hold so its
      // subscription stays attached across start (and receives input/errors);
      // create it here if nothing has listened yet. The microphone is still
      // requested lazily via onListen, so output-only users see no prompt.
      _ensureInputController();
      _outputController = StreamController<List<double>>();

      final workletStarted = await _tryStartWorkletOutput();
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
  Future<bool> _tryStartWorkletOutput() async {
    try {
      final blob = web.Blob(
        [_workletSource.toJS].toJS,
        web.BlobPropertyBag(type: 'application/javascript'),
      );
      final url = web.URL.createObjectURL(blob);
      _workletUrl = url;
      await _audioContext!.audioWorklet.addModule(url).toDart;
      _workletModuleLoaded = true;

      final node = AudioWorkletNodeJs(_audioContext!, _outputProcessorName)
        ..connect(_audioContext!.destination);
      _workletNode = node;

      _outputController!.stream.listen((data) {
        if (data.isEmpty) return;
        final converted = Float32List.fromList(data);
        _postSamples(node.port, _Formats.float32, converted.buffer, 0,
            converted.length, _contractSampleRate.toInt());
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
        _addInputCopy(input, audioEvent.inputBuffer);
      }
    }).toJS;

    // Connect to speakers
    processor.connect(_audioContext!.destination);
    _scriptProcessor = processor;
  }

  /// Copies one capture buffer into the input stream. The copy is required
  /// (the browser reuses the AudioBuffer) but stays typed end to end:
  /// Float32List implements List<double>, so no per-sample boxing occurs.
  void _addInputCopy(
      StreamController<List<double>> controller, AudioBuffer inputBuffer) {
    final view = inputBuffer.getChannelData(0).toDart;
    controller.add(Float32List.fromList(view));
  }

  void _releaseWorklet() {
    _workletNode?.disconnect();
    _workletNode = null;
    _inputWorkletNode?.disconnect();
    _inputWorkletNode = null;
    _workletModuleLoaded = false;
    final url = _workletUrl;
    if (url != null) {
      web.URL.revokeObjectURL(url);
      _workletUrl = null;
    }
  }

  Future<void> _connectInputIfNeeded() async {
    if (_inputRequested || !_isRunning) return;
    _inputRequested = true;

    final web.MediaStream? mediaStream;
    try {
      mediaStream = _inputSource == AudioIoInputSource.systemAudio
          ? await _acquireSystemAudioStream()
          : await _getUserMedia();
    } on AudioIoException catch (e) {
      // Surface the typed failure through the input stream's error channel so
      // listeners see it regardless of whether they subscribed before or
      // after start(); allow another attempt on a later restart.
      _inputRequested = false;
      _inputController?.addError(e);
      return;
    }

    final context = _audioContext;
    if (mediaStream == null || context == null) return;
    _inputMediaStream = mediaStream;

    final source = context.createMediaStreamSource(mediaStream);
    _inputSourceNode = source;
    if (_workletModuleLoaded) {
      source.connectWorklet(_createInputWorkletNode(context));
      return;
    }
    source.connect(_scriptProcessor ?? _createInputProcessor(context));
  }

  /// Captures system / tab audio via `getDisplayMedia`. The picker is a
  /// user-driven share dialog, so `start()` (already user-gesture-adjacent)
  /// triggers it. The video track is required for the picker but immediately
  /// stopped; only the audio track feeds the graph.
  ///
  /// Throws an [AudioIoException] with
  /// [AudioIoException.isSystemAudioUnsupported] when the browser returns no
  /// audio track (Firefox / Safari implement `getDisplayMedia` but never
  /// deliver audio) or when the picker call itself fails / is dismissed.
  Future<web.MediaStream> _acquireSystemAudioStream() async {
    final web.MediaStream stream;
    try {
      // suppressLocalAudioPlayback defaults to false, so a shared tab keeps
      // playing out of the speakers — the right UX for a listening demo.
      // systemAudio: 'include' asks for full-system audio when the user
      // shares an entire screen (Chromium honours it; others ignore it).
      final options = JSObject()
        ..['audio'] = true.toJS
        ..['video'] = true.toJS
        ..['systemAudio'] = 'include'.toJS;
      stream = await web.window.navigator.mediaDevices
          .getDisplayMedia(options)
          .toDart;
    } catch (e) {
      throw AudioIoException(
        AudioIoErrorCodes.systemAudioUnsupported,
        'System-audio capture via getDisplayMedia failed or was dismissed: $e',
      );
    }

    final videoTracks = stream.getVideoTracks().toDart;
    for (final track in videoTracks) {
      track.stop();
    }

    final audioTracks = stream.getAudioTracks().toDart;
    if (audioTracks.isEmpty) {
      throw AudioIoException(
        AudioIoErrorCodes.systemAudioUnsupported,
        'This browser returned a screen-capture stream with no audio track. '
        'System/tab audio capture is only supported on Chromium browsers '
        '(Chrome/Edge); Firefox and Safari do not deliver audio.',
      );
    }

    // "Stop sharing" (browser UI) ends the track; surface it downstream.
    audioTracks.first.onended = ((web.Event _) {
      _handleInputTrackEnded();
    }).toJS;

    return stream;
  }

  /// The user stopped the screen/tab share from the browser UI. Tear down the
  /// input node and complete the input stream so listeners see the end of
  /// capture; output (e.g. TTS playback) keeps running.
  void _handleInputTrackEnded() {
    _inputSourceNode?.disconnect();
    _inputSourceNode = null;
    _stopInputMediaStream();
    _inputRequested = false;
    final controller = _inputController;
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
      _inputController = null;
    }
  }

  void _stopInputMediaStream() {
    final stream = _inputMediaStream;
    if (stream == null) return;
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
    _inputMediaStream = null;
  }

  /// Input AudioWorkletNode: resamples to the 48 kHz contract on the audio
  /// rendering thread and posts transferable chunks, so the main-thread
  /// cost per chunk is adopting an already-transferred Float32List.
  AudioWorkletNodeJs _createInputWorkletNode(AudioContext context) {
    final processorOptions = JSObject()
      ..['targetRate'] = _contractSampleRate.toInt().toJS
      ..['chunkFrames'] = _calculateInputChunkFrames().toJS;
    final options = JSObject()..['processorOptions'] = processorOptions;

    final node = AudioWorkletNodeJs(context, _inputProcessorName, options)
      ..connect(context.destination);
    node.port.onmessage = ((web.MessageEvent event) {
      final controller = _inputController;
      if (controller == null || !controller.hasListener) return;
      controller.add((event.data! as JSFloat32Array).toDart);
    }).toJS;
    _inputWorkletNode = node;
    return node;
  }

  /// Input-only ScriptProcessorNode used when the worklet module failed to
  /// load. It must be connected to the destination to fire, but it never
  /// writes to its output buffer, so it contributes only silence.
  ScriptProcessorNode _createInputProcessor(AudioContext context) {
    final processor = context.createScriptProcessor(_bufferSize, 1, 1);
    processor.onaudioprocess = ((JSAny event) {
      final audioEvent = event as AudioProcessingEvent;
      final input = _inputController;
      if (input != null && input.hasListener) {
        _addInputCopy(input, audioEvent.inputBuffer);
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
  Future<void> clearOutput() async {
    _ring.clear();
    _workletNode?.port.postMessage('clear'.toJS);
  }

  @override
  Future<void> stop() async {
    final inFlight = _startInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } on Exception {
        // The start attempt failed; nothing is running to stop.
      }
    }
    if (!_isRunning) return;

    _isRunning = false;
    _inputRequested = false;
    _inputSourceNode?.disconnect();
    _inputSourceNode = null;
    _stopInputMediaStream();
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
    final inputSampleRate =
        _workletModuleLoaded ? _contractSampleRate : deviceSampleRate;
    return {
      'input': {
        'type': 'double',
        'channels': 1,
        'sampleRate': inputSampleRate,
        'backend': _workletModuleLoaded ? 'audioWorklet' : 'scriptProcessor',
      },
      'output': {
        'type': 'double',
        'channels': 1,
        'sampleRate': _contractSampleRate,
        'deviceSampleRate': deviceSampleRate,
        'backend': _workletNode != null
            ? 'audioWorklet'
            : _scriptProcessor != null
                ? 'scriptProcessor'
                : 'inactive',
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
