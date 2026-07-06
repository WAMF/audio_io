import 'dart:async';
import 'dart:io';

import 'audio_io_stub.dart';
import 'audio_io_threading.dart';
import 'ffi/audio_io_ffi.dart';
import 'ffi/audio_io_isolate.dart';

class AudioIoNative extends AudioIoImpl {
  AudioIoFFITransport? _transport;
  AudioIoThreading _threading = AudioIoThreading.mainIsolate;
  double? _pendingFrameDuration;

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

    final pending = _pendingFrameDuration;
    if (pending != null) {
      await _transport!.requestFrameDuration(pending);
      _pendingFrameDuration = null;
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
    final transport = _transport;
    if (transport != null) {
      await transport.requestFrameDuration(duration);
      return;
    }
    _pendingFrameDuration = duration;
  }

  @override
  Future<double> getFrameDuration() async {
    return await _transport?.getFrameDuration() ?? 0.01;
  }
}

AudioIoImpl createAudioIoImpl() => AudioIoNative();
