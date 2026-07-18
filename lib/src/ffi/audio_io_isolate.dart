import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../audio_io_errors.dart';
import '../audio_io_input_source.dart';
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
///
/// Every command is guarded: an unhandled throw would kill the isolate with
/// no error path back to the proxy, so failures are forwarded as
/// [_Protocol.error] events instead.
void _audioIsolateMain((SendPort ready, SendPort events) ports) {
  final (ready, events) = ports;
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  final core = AudioIoFFICore();

  commands.listen((dynamic message) {
    try {
      _handleCommand(core, events, message as List<dynamic>);
    } on InputSourceUnsupportedException catch (e) {
      // Preserve the typed-ness across the isolate boundary: the trailing flag
      // tells the proxy to rebuild an InputSourceUnsupportedException rather
      // than a generic Exception, so callers still see the typed error.
      events.send([_Protocol.error, e.message, true]);
    } on Object catch (e) {
      events.send([_Protocol.error, e.toString(), false]);
    }
  });
}

void _handleCommand(
    AudioIoFFICore core, SendPort events, List<dynamic> message) {
  final command = message[0] as String;
  switch (command) {
    case _Protocol.start:
      core.setFrameDuration(message[1] as double);
      core.setInputSource(message[2] as int);
      core.start((frames) => events.send([_Protocol.input, frames]));
      events.send([_Protocol.state, core.getFormat(), core.getFrameDuration()]);
    case _Protocol.write:
      core.write(message[1] as Float64List);
    case _Protocol.clearOutput:
      core.clearOutput();
    case _Protocol.setFrameDuration:
      core.setFrameDuration(message[1] as double);
      events.send([_Protocol.state, core.getFormat(), core.getFrameDuration()]);
    case _Protocol.stop:
      try {
        core.stop();
      } finally {
        events.send([_Protocol.stopped]);
      }
  }
}

/// Dedicated-isolate FFI transport: device polling and native buffer copies
/// run on a spawned audio isolate, immune to main-isolate jank. The
/// [Stream] / [Sink] surface stays on the caller's isolate; input chunks and
/// output writes cross the isolate boundary as [Float64List] messages.
class AudioIoFFIIsolateProxy implements AudioIoFFITransport {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  ReceivePort? _control;
  StreamSubscription<dynamic>? _eventsSubscription;
  StreamSubscription<dynamic>? _controlSubscription;

  StreamController<List<double>>? _inputController;
  StreamController<List<double>>? _outputController;

  Completer<void>? _startCompleter;
  Completer<void>? _stopCompleter;

  Map<String, dynamic> _format = AudioIoFFICore.defaultFormat;
  double _frameDuration = 0.003;
  double _requestedFrameDuration = 0.003;
  int _requestedInputSource = 0;
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

    // Crash signals arrive on their own port so they never mix with the
    // [_Protocol] message parsing; an intentional teardown cancels this
    // subscription before killing the isolate.
    final control = ReceivePort();
    _control = control;
    _controlSubscription = control.listen(_handleCrash);

    _isolate = await Isolate.spawn(
      _audioIsolateMain,
      (ready.sendPort, events.sendPort),
      onError: control.sendPort,
      onExit: control.sendPort,
      debugName: 'audio_io',
    );
    _commands = await ready.first as SendPort;
    ready.close();

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();
    _outputController!.stream.listen(_forwardWrite);

    final startCompleter = Completer<void>();
    _startCompleter = startCompleter;
    _commands!
        .send([_Protocol.start, _requestedFrameDuration, _requestedInputSource]);
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
  void setInputSource(AudioIoInputSource source) {
    _requestedInputSource = source.index;
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
        final unsupportedInputSource =
            message.length > 2 && message[2] == true;
        _reportError(unsupportedInputSource
            ? InputSourceUnsupportedException(message[1] as String)
            : Exception(message[1] as String));
      case _Protocol.stopped:
        _stopCompleter?.complete();
        _stopCompleter = null;
    }
  }

  /// Routes a worker failure to whoever can observe it: a pending start
  /// awaits the error directly; afterwards it surfaces on the input stream.
  void _reportError(Object error) {
    final startCompleter = _startCompleter;
    if (startCompleter != null) {
      _startCompleter = null;
      startCompleter.completeError(error);
      return;
    }
    _inputController?.addError(error);
  }

  /// Handles uncaught-error and unexpected-exit signals from the isolate
  /// itself. Anything arriving here means the worker is gone: fail pending
  /// waits, surface the error, and tear down.
  void _handleCrash(dynamic message) {
    final error = message is List && message.isNotEmpty && message[0] != null
        ? Exception('audio_io isolate error: ${message[0]}')
        : Exception('audio_io isolate exited unexpectedly');
    _isRunning = false;
    _reportError(error);
    _stopCompleter?.complete();
    _stopCompleter = null;
    unawaited(_teardown());
  }

  Future<void> _teardown() async {
    await _controlSubscription?.cancel();
    _controlSubscription = null;
    _control?.close();
    _control = null;
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
