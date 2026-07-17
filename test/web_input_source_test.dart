import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal concrete [AudioIoImpl] used to exercise the base-class defaults
/// that the web backend overrides. The engine methods are stubbed; only the
/// input-source contract is under test here.
class _BaseImpl extends AudioIoImpl {
  @override
  bool get usePlatformImpl => true;
  @override
  Stream<List<double>>? get inputAudioStream => null;
  @override
  StreamSink<List<double>>? get outputAudioStream => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> clearOutput() async {}
  @override
  Map<String, dynamic> getFormat() => const {};
  @override
  Future<void> requestFrameDuration(double duration) async {}
  @override
  Future<void> requestOutputBufferDuration(double seconds) async {}
  @override
  Future<double> getFrameDuration() async => 0;
  @override
  Sink<Uint8List>? pcm16OutputSink(int sourceRate) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioIoErrorCodes', () {
    // These strings are the cross-platform contract (Dart, Swift, and the
    // web backend all compare against them); pin them so a rename can't
    // silently break isSystemAudioUnsupported / isPermissionDenied checks.
    test('carry the stable wire values', () {
      expect(AudioIoErrorCodes.microphonePermissionDenied,
          'MICROPHONE_PERMISSION_DENIED');
      expect(AudioIoErrorCodes.systemAudioUnsupported,
          'SYSTEM_AUDIO_UNSUPPORTED');
    });
  });

  group('AudioIoException typed-error mapping', () {
    test('systemAudioUnsupported code maps to isSystemAudioUnsupported', () {
      final e = AudioIoException(
        AudioIoErrorCodes.systemAudioUnsupported,
        'no audio track',
      );
      expect(e.isSystemAudioUnsupported, isTrue);
      expect(e.isPermissionDenied, isFalse);
    });

    test('permission-denied code maps to isPermissionDenied only', () {
      final e = AudioIoException(
        AudioIoErrorCodes.microphonePermissionDenied,
        'denied',
      );
      expect(e.isPermissionDenied, isTrue);
      expect(e.isSystemAudioUnsupported, isFalse);
    });
  });

  group('AudioIoImpl input-source defaults', () {
    final impl = _BaseImpl();

    test('microphone is supported by default', () {
      expect(impl.supportsInputSource(AudioIoInputSource.microphone), isTrue);
    });

    test('systemAudio is unsupported unless a backend opts in', () {
      // The web backend overrides this to advertise getDisplayMedia support;
      // the base contract is microphone-only so unaware backends fail closed.
      expect(impl.supportsInputSource(AudioIoInputSource.systemAudio), isFalse);
    });

    test('configureInputSource is a harmless no-op on the base', () {
      expect(
        () => impl.configureInputSource(AudioIoInputSource.systemAudio),
        returnsNormally,
      );
    });
  });
}
