import 'dart:async';
import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal backend: every engine method is a no-op that records whether it was
/// reached, so a test can assert that an invalid config is rejected *before*
/// the engine is touched.
class _StubImpl extends AudioIoImpl {
  int startCount = 0;

  @override
  bool get usePlatformImpl => true;
  @override
  Stream<List<double>>? get inputAudioStream => const Stream.empty();
  @override
  StreamSink<List<double>>? get outputAudioStream => null;

  @override
  bool supportsInputSource(AudioIoInputSource source) => true;

  @override
  Future<void> start() async {
    startCount++;
  }

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

  // The release-time throw. Exercised through the static helper so it runs
  // with release semantics — i.e. without depending on the const-constructor
  // asserts, which are stripped in release/profile builds. This is the guard
  // that actually protects the native engine in production; #9 requires it to
  // fire for out-of-range values in all build modes.
  group('AudioIoConfig.checkOutputBufferDuration (release-time throw)', () {
    test('throws for a negative duration', () {
      expect(
        () => AudioIoConfig.checkOutputBufferDuration(-1),
        throwsArgumentError,
      );
    });

    test('throws for a zero duration', () {
      expect(
        () => AudioIoConfig.checkOutputBufferDuration(0),
        throwsArgumentError,
      );
    });

    test('throws for NaN (slips past the native seconds <= 0 guard)', () {
      expect(
        () => AudioIoConfig.checkOutputBufferDuration(double.nan),
        throwsArgumentError,
      );
    });

    test('throws for infinity', () {
      expect(
        () => AudioIoConfig.checkOutputBufferDuration(double.infinity),
        throwsArgumentError,
      );
    });

    test('accepts null (default: back ends keep their own sizing)', () {
      expect(() => AudioIoConfig.checkOutputBufferDuration(null),
          returnsNormally);
    });

    test('accepts a positive, finite duration', () {
      expect(() => AudioIoConfig.checkOutputBufferDuration(0.5),
          returnsNormally);
      expect(
          () => AudioIoConfig.checkOutputBufferDuration(30), returnsNormally);
    });
  });

  group('AudioIoConfig.checkInvariants', () {
    test('passes for a valid config', () {
      expect(const AudioIoConfig(outputBufferDuration: 0.5).checkInvariants,
          returnsNormally);
      expect(const AudioIoConfig().checkInvariants, returnsNormally);
    });

    // infinity survives the const-constructor assert (`infinity > 0` is true),
    // so it is the value that proves the runtime throw catches a breach the
    // debug assert cannot.
    test('throws for a non-finite duration the assert cannot catch', () {
      const config = AudioIoConfig(outputBufferDuration: double.infinity);
      expect(config.checkInvariants, throwsArgumentError);
    });
  });

  // Debug-only descriptive guard. Kept alongside the throw so debug builds
  // retain the assertion message (#9 step 3). Asserts are enabled under
  // `flutter test`, so constructing an out-of-range config trips here.
  group('AudioIoConfig const-constructor assert (debug builds)', () {
    test('rejects a negative duration', () {
      expect(() => AudioIoConfig(outputBufferDuration: -1),
          throwsA(isA<AssertionError>()));
    });

    test('rejects a zero duration', () {
      expect(() => AudioIoConfig(outputBufferDuration: 0),
          throwsA(isA<AssertionError>()));
    });
  });

  group('AudioIo.startWith enforces the config invariants', () {
    test('throws and does not start the engine on an invalid duration',
        () async {
      final backend = _StubImpl();
      final audio = AudioIo.withImpl(backend);

      // infinity reaches startWith (it passes the const assert); the
      // release-time guard must reject it before the engine is touched.
      await expectLater(
        audio.startWith(
          const AudioIoConfig(outputBufferDuration: double.infinity),
        ),
        throwsArgumentError,
      );
      expect(backend.startCount, 0);
      expect(audio.currentConfig, isNull);
    });

    test('starts normally for a valid duration', () async {
      final backend = _StubImpl();
      final audio = AudioIo.withImpl(backend);

      await audio.startWith(const AudioIoConfig(outputBufferDuration: 0.5));
      expect(backend.startCount, 1);
      expect(audio.currentConfig?.outputBufferDuration, 0.5);
    });
  });
}
