import 'dart:async';
import 'dart:io';

import 'audio_io_apple.dart';
import 'audio_io_stub.dart';
import 'audio_io_threading.dart';
import 'ffi/audio_io_ffi.dart';
import 'ffi/audio_io_isolate.dart';

class AudioIoNative extends AudioIoImpl {
  static const double _defaultFrameDuration = 0.003;

  AudioIoFFITransport? _transport;
  AudioIoThreading _threading = AudioIoThreading.mainIsolate;
  double? _requestedFrameDuration;

  @override
  bool get usePlatformImpl =>
      Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  @override
  Stream<List<double>>? get inputAudioStream => _transport?.inputAudioStream;

  @override
  StreamSink<List<double>>? get outputAudioStream =>
      _transport?.outputAudioStream;

  @override
  void configureThreading(AudioIoThreading threading) {
    _threading = threading;
  }

  @override
  Future<void> start() async {
    final wantIsolate = _threading == AudioIoThreading.audioIsolate;
    if (_transport != null &&
        (_transport is AudioIoFFIIsolateProxy) != wantIsolate) {
      await _transport!.stop();
      _transport = null;
    }
    _transport ??=
        wantIsolate ? AudioIoFFIIsolateProxy() : AudioIoFFI.instance;

    // Re-applied on every start so a requested duration survives a
    // threading-mode transport swap (a fresh transport starts from its own
    // default, not the duration applied to the discarded one).
    final requested = _requestedFrameDuration;
    if (requested != null) {
      await _transport!.requestFrameDuration(requested);
    }
    await _transport!.start();
  }

  @override
  Future<void> stop() async {
    await _transport?.stop();
  }

  @override
  Future<void> clearOutput() async {
    _transport?.clearOutput();
  }

  @override
  Map<String, dynamic> getFormat() {
    return _transport?.getFormat() ?? AudioIoFFICore.defaultFormat;
  }

  @override
  Future<void> requestFrameDuration(double duration) async {
    _requestedFrameDuration = duration;
    await _transport?.requestFrameDuration(duration);
  }

  @override
  Future<double> getFrameDuration() async {
    return await _transport?.getFrameDuration() ??
        _requestedFrameDuration ??
        _defaultFrameDuration;
  }
}

/// iOS/macOS use the AVAudioEngine backend (method-channel control plane +
/// FFI data plane, issue #27); the other `dart:io` platforms use the miniaudio
/// FFI backend.
AudioIoImpl createAudioIoImpl() =>
    (Platform.isIOS || Platform.isMacOS) ? AudioIoApple() : AudioIoNative();
