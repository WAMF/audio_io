import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'audio_io_apple_ffi.dart';

class _Protocol {
  static const start = 'start';
  static const started = 'started';
  static const stop = 'stop';
  static const stopped = 'stopped';
  static const write = 'write';
  static const clearOutput = 'clearOutput';
  static const input = 'input';
  static const error = 'error';
}

/// Entry point of the dedicated audio isolate. Runs an [AudioIoAppleCore]
/// (the FFI exports resolve a process-wide singleton, so they work from any
/// isolate) and speaks the [_Protocol] messages.
///
/// Every command is guarded: an unhandled throw — most likely
/// `AudioIoAppleBindings` failing to resolve a symbol — would kill the isolate
/// with no error path back to the proxy, so failures are forwarded as
/// [_Protocol.error] events instead.
void _appleAudioIsolateMain((SendPort ready, SendPort events) ports) {
  final (ready, events) = ports;
  final commands = ReceivePort();
  ready.send(commands.sendPort);

  AudioIoAppleCore? core;

  commands.listen((dynamic message) {
    final list = message as List<dynamic>;
    try {
      switch (list[0] as String) {
        case _Protocol.start:
          core ??= AudioIoAppleCore();
          core!.start((frames) => events.send([_Protocol.input, frames]));
          events.send([_Protocol.started]);
        case _Protocol.write:
          core?.write(list[1] as Float64List);
        case _Protocol.clearOutput:
          core?.clearOutput();
        case _Protocol.stop:
          try {
            core?.stop();
          } finally {
            events.send([_Protocol.stopped]);
          }
      }
    } on Object catch (e) {
      events.send([_Protocol.error, e.toString()]);
    }
  });
}

/// Dedicated-isolate Apple data-plane transport: the input poll and native
/// buffer copies run on a spawned audio isolate, immune to main-isolate jank.
/// The [Stream] / [Sink] surface stays on the caller's isolate; input chunks
/// and output writes cross the isolate boundary as typed-data messages.
///
/// Mirrors `AudioIoFFIIsolateProxy`, minus the format/frame-duration state sync
/// — on Apple those are control-plane concerns owned by the method channel, so
/// the worker only moves samples.
class AudioIoAppleIsolateProxy implements AudioIoAppleTransport {
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
      _appleAudioIsolateMain,
      (ready.sendPort, events.sendPort),
      onError: control.sendPort,
      onExit: control.sendPort,
      debugName: 'audio_io_apple',
    );
    _commands = await ready.first as SendPort;
    ready.close();

    _inputController = StreamController<List<double>>.broadcast();
    _outputController = StreamController<List<double>>();
    _outputController!.stream.listen(_forwardWrite);

    final startCompleter = Completer<void>();
    _startCompleter = startCompleter;
    _commands!.send([_Protocol.start]);
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

  void _forwardWrite(List<double> data) {
    if (!_isRunning) return;
    final frames = data is Float64List ? data : Float64List.fromList(data);
    _commands?.send([_Protocol.write, frames]);
  }

  void _handleEvent(dynamic message) {
    final event = (message as List<dynamic>)[0] as String;
    switch (event) {
      case _Protocol.input:
        _inputController?.add(message[1] as Float32List);
      case _Protocol.started:
        _startCompleter?.complete();
        _startCompleter = null;
      case _Protocol.error:
        _reportError(Exception(message[1] as String));
      case _Protocol.stopped:
        _stopCompleter?.complete();
        _stopCompleter = null;
    }
  }

  /// Routes a worker failure to whoever can observe it: a pending start awaits
  /// the error directly; afterwards it surfaces on the input stream.
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
        ? Exception('audio_io apple isolate error: ${message[0]}')
        : Exception('audio_io apple isolate exited unexpectedly');
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
