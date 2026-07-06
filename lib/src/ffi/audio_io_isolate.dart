import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'audio_io_ffi.dart';

class _Protocol {
  static const start = 'start';
  static const stop = 'stop';
  static const stopped = 'stopped';
  static const write = 'write';
  static const clearOutput = 'clearOutput';
  static const setFrameDuration = 'setFrameDuration';
  static const input = 'input';
  static const error = 'error';

  /// Worker -> proxy state sync carrying (format, frameDuration); emitted
  /// after a successful start and after a frame-duration change.
  static const state = 'state';
}

/// Entry point of the dedicated audio isolate: runs an [AudioIoFFICore]
/// (FFI is usable from any isolate) and speaks the [_Protocol] messages.
void _audioIsolateMain((SendPort ready, SendPort events) ports) {
  final (ready, events) = ports;
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  final core = AudioIoFFICore();

  commands.listen((dynamic message) {
    final command = (message as List<dynamic>)[0] as String;
    switch (command) {
      case _Protocol.start:
        core.setFrameDuration(message[1] as double);
        try {
          core.start((frames) => events.send([_Protocol.input, frames]));
          events.send([
            _Protocol.state,
            core.getFormat(),
            core.getFrameDuration(),
          ]);
        } on Exception catch (e) {
          events.send([_Protocol.error, e.toString()]);
        }
      case _Protocol.write:
        core.write(message[1] as Float64List);
      case _Protocol.clearOutput:
        core.clearOutput();
      case _Protocol.setFrameDuration:
        core.setFrameDuration(message[1] as double);
        events
            .send([_Protocol.state, core.getFormat(), core.getFrameDuration()]);
      case _Protocol.stop:
        core.stop();
        events.send([_Protocol.stopped]);
    }
  });
}

/// Dedicated-isolate FFI transport: device polling and native buffer copies
/// run on a spawned audio isolate, immune to main-isolate jank. The
/// [Stream] / [Sink] surface stays on the caller's isolate; input chunks and
/// output writes cross the isolate boundary as [Float64List] messages.
class AudioIoFFIIsolateProxy implements AudioIoFFITransport {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  StreamSubscription<dynamic>? _eventsSubscription;

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;

  Completer<void>? _startCompleter;
  Completer<void>? _stopCompleter;

  Map<String, dynamic> _format = AudioIoFFICore.defaultFormat;
  double _frameDuration = 0.003;
  double _requestedFrameDuration = 0.003;
  bool _isRunning = false;

  @override
  Stream<List<double>>? get inputAudioStream => _inputController?.stream;

  @override
  StreamSink<List<double>>? get outputAudioStream => _outputController?.sink;

  @override
  Future<void> start() async {
    if (_isRunning) return;

    final ready = ReceivePort();
    final events = ReceivePort();
    _events = events;
    _eventsSubscription = events.listen(_handleEvent);

    _isolate = await Isolate.spawn(
      _audioIsolateMain,
      (ready.sendPort, events.sendPort),
      debugName: 'audio_io',
    );
    _commands = await ready.first as SendPort;
    ready.close();

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();
    _outputController!.stream.listen(_forwardWrite);

    final startCompleter = Completer<void>();
    _startCompleter = startCompleter;
    _commands!.send([_Protocol.start, _requestedFrameDuration]);
    try {
      await startCompleter.future;
      _isRunning = true;
    } on Exception {
      await _teardown();
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;
    _isRunning = false;

    final stopCompleter = Completer<void>();
    _stopCompleter = stopCompleter;
    _commands?.send([_Protocol.stop]);
    await stopCompleter.future
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    await _teardown();
  }

  @override
  void clearOutput() => _commands?.send([_Protocol.clearOutput]);

  @override
  Map<String, dynamic> getFormat() => _format;

  @override
  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    if (_isRunning) {
      _commands?.send([_Protocol.setFrameDuration, duration]);
    }
  }

  @override
  Future<double> getFrameDuration() async => _frameDuration;

  void _forwardWrite(List<double> data) {
    if (!_isRunning) return;
    final frames = data is Float64List ? data : Float64List.fromList(data);
    _commands?.send([_Protocol.write, frames]);
  }

  void _handleEvent(dynamic message) {
    final event = (message as List<dynamic>)[0] as String;
    switch (event) {
      case _Protocol.input:
        _inputController?.add(message[1] as Float64List);
      case _Protocol.state:
        _format = (message[1] as Map).cast<String, dynamic>();
        _frameDuration = message[2] as double;
        _startCompleter?.complete();
        _startCompleter = null;
      case _Protocol.error:
        _startCompleter?.completeError(Exception(message[1] as String));
        _startCompleter = null;
      case _Protocol.stopped:
        _stopCompleter?.complete();
        _stopCompleter = null;
    }
  }

  Future<void> _teardown() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;
    _events?.close();
    _events = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    await _inputController?.close();
    await _outputController?.close();
    _inputController = null;
    _outputController = null;
  }
}
