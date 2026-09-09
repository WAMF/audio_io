import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_io_exception.dart';
import 'audio_io_input_source.dart';
import 'audio_io_stub.dart';
import 'audio_io_threading.dart';
import 'ffi/audio_io_apple_ffi.dart';
import 'ffi/audio_io_apple_isolate.dart';

/// iOS/macOS implementation: the AVAudioEngine control plane
/// (start/stop/permissions/latency/format) runs on the method channel — fine
/// on the root isolate — while the audio data plane moves across FFI rings, so
/// polling and buffer copies can run on a dedicated isolate. This is what lets
/// `AudioIoThreading.audioIsolate` work on Apple platforms, which the old
/// binary-messenger transport could not do (platform→Dart pushed messages only
/// deliver to the root isolate). See issue #27.
class AudioIoApple extends AudioIoImpl {
  static const String _methodChannelName = 'com.wearemobilefirst.audio_io';

  /// Event channel the macOS plugin pushes session failures on, as
  /// `PlatformException` error events. The iOS plugin has no handler for it,
  /// so it is only subscribed on macOS.
  static const String _sessionEventChannelName =
      'com.wearemobilefirst.audio_io/session';

  /// Key of the input source in the `start` call's argument map. The value is
  /// the [AudioIoInputSource] name; the macOS plugin selects its capture
  /// graph from it and the iOS plugin ignores it (microphone only).
  static const String inputSourceArgument = 'inputSource';
  static const double _defaultFrameDuration = 0.003;
  static const Map<String, dynamic> _defaultFormat = <String, dynamic>{
    'input': {'type': 'double', 'channels': 1, 'sampleRate': 48000.0},
    'output': {'type': 'double', 'channels': 1, 'sampleRate': 48000.0},
  };

  final MethodChannel _methods = const MethodChannel(_methodChannelName);
  final EventChannel _sessionEvents =
      const EventChannel(_sessionEventChannelName);

  AudioIoAppleTransport? _transport;
  AudioIoThreading _threading = AudioIoThreading.mainIsolate;
  AudioIoInputSource _inputSource = AudioIoInputSource.microphone;
  double? _requestedFrameDuration;
  Map<String, dynamic> _format = _defaultFormat;

  @override
  bool get usePlatformImpl => true;

  @override
  Stream<List<double>>? get inputAudioStream => _transport?.inputAudioStream;

  @override
  StreamSink<List<double>>? get outputAudioStream =>
      _transport?.outputAudioStream;

  @override
  Stream<AudioIoException> get sessionErrors {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return const Stream.empty();
    }
    return _sessionEvents.receiveBroadcastStream().transform(
      StreamTransformer<dynamic, AudioIoException>.fromHandlers(
        handleData: (_, __) {},
        handleError: (error, stackTrace, sink) {
          if (error is PlatformException) {
            sink.add(
              AudioIoException(
                error.code,
                error.message ?? 'Unknown error',
                error.details,
              ),
            );
          } else {
            sink.addError(error, stackTrace);
          }
        },
      ),
    );
  }

  @override
  void configureThreading(AudioIoThreading threading) {
    _threading = threading;
  }

  @override
  void configureInputSource(AudioIoInputSource source) {
    _inputSource = source;
  }

  @override
  bool supportsInputSource(AudioIoInputSource source) {
    // System audio rides on Core Audio process taps (macOS 14.2+, issue #32);
    // iOS has no equivalent. A macOS host older than 14.2 is only detectable
    // natively, so the plugin reports it from `start` as the same typed
    // SYSTEM_AUDIO_UNSUPPORTED error.
    return !source.includesSystemAudio || Platform.isMacOS;
  }

  @override
  Future<void> start() async {
    // Control plane: start the AVAudioEngine (permission check, session,
    // pipeline, ring allocation). A permission failure surfaces as a
    // PlatformException, which `AudioIo.start` maps to `AudioIoException`.
    await _methods.invokeMethod<void>(
      'start',
      <String, dynamic>{inputSourceArgument: _inputSource.name},
    );

    // The native engine and microphone capture are now live. If any of the
    // remaining setup throws — `getFormat` failing, or (the PR's top risk) the
    // FFI transport's `lookupFunction` throwing because a release linker
    // stripped an `@_cdecl` symbol — the error must not escape with the engine
    // still running. Tear down whatever partial transport exists and stop the
    // native engine before rethrowing, so a failed start leaves nothing live.
    try {
      // Cache the true engine rates so the synchronous `getFormat()` (used when
      // wiring the PCM16 adapters right after start) reports them as before.
      final format = await _methods.invokeMethod<dynamic>('getFormat');
      if (format is Map) {
        _format = format.map((key, dynamic v) => MapEntry(key.toString(), v));
      }

      // Data plane: start the FFI poll/write transport on the configured
      // isolate. Only started once the engine — and therefore the rings — is
      // live, so the first poll never races ring allocation.
      final wantIsolate = _threading == AudioIoThreading.audioIsolate;
      if (_transport != null &&
          (_transport is AudioIoAppleIsolateProxy) != wantIsolate) {
        await _transport!.stop();
        _transport = null;
      }
      _transport ??= wantIsolate
          ? AudioIoAppleIsolateProxy()
          : AudioIoAppleMainTransport();
      await _transport!.start();
    } catch (_) {
      // Best-effort rollback; swallow teardown errors so the original failure
      // is the one that propagates.
      try {
        await _transport?.stop();
      } catch (_) {}
      _transport = null;
      try {
        await _methods.invokeMethod<void>('stop');
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    // Stop the data plane first so no poll reads the ring after the engine
    // tears it down.
    await _transport?.stop();
    await _methods.invokeMethod<void>('stop');
  }

  @override
  Future<void> clearOutput() async {
    // Cleared over FFI so a barge-in drops queued playback with no method-
    // channel round trip. Falls back to the method channel if the data plane
    // has not been started yet.
    final transport = _transport;
    if (transport != null) {
      transport.clearOutput();
    } else {
      await _methods.invokeMethod<void>('clearOutput');
    }
  }

  @override
  Map<String, dynamic> getFormat() => _format;

  @override
  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    await _methods.invokeMethod<void>('requestFrameDuration', duration);
  }

  @override
  Future<void> requestOutputBufferDuration(double seconds) async {
    await _methods.invokeMethod<void>('requestOutputBufferDuration', seconds);
  }

  @override
  Future<double> getFrameDuration() async {
    final value = await _methods.invokeMethod<dynamic>('getFrameDuration');
    if (value is num) return value.toDouble();
    return _requestedFrameDuration ?? _defaultFrameDuration;
  }
}
