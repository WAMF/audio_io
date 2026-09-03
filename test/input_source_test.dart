import 'dart:io';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioIoInputSource enum', () {
    // The native FFI backend keys its device topology off the enum index
    // (INPUT_SOURCE_MICROPHONE = 0, INPUT_SOURCE_SYSTEM_AUDIO = 1). Pin the
    // ordering so a reordering of the enum can't silently swap the source.
    test('index values match the native contract', () {
      expect(AudioIoInputSource.microphone.index, 0);
      expect(AudioIoInputSource.systemAudio.index, 1);
      expect(AudioIoInputSource.microphoneAndSystemAudio.index, 2);
    });

    test('composition helpers describe each source', () {
      expect(AudioIoInputSource.microphone.includesMicrophone, isTrue);
      expect(AudioIoInputSource.microphone.includesSystemAudio, isFalse);
      expect(AudioIoInputSource.systemAudio.includesMicrophone, isFalse);
      expect(AudioIoInputSource.systemAudio.includesSystemAudio, isTrue);
      expect(
        AudioIoInputSource.microphoneAndSystemAudio.includesMicrophone,
        isTrue,
      );
      expect(
        AudioIoInputSource.microphoneAndSystemAudio.includesSystemAudio,
        isTrue,
      );
    });
  });

  group('AudioIoConfig.inputSource', () {
    test('defaults to microphone', () {
      const config = AudioIoConfig();
      expect(config.inputSource, AudioIoInputSource.microphone);
    });

    test('is configurable', () {
      const config = AudioIoConfig(inputSource: AudioIoInputSource.systemAudio);
      expect(config.inputSource, AudioIoInputSource.systemAudio);
    });
  });

  group('AudioIoException system-audio codes', () {
    test('isSystemAudioUnsupported is true only for the unsupported code', () {
      final unsupported = AudioIoException('SYSTEM_AUDIO_UNSUPPORTED', 'nope');
      expect(unsupported.isSystemAudioUnsupported, isTrue);
      expect(unsupported.isSystemAudioCaptureFailed, isFalse);
      expect(unsupported.isPermissionDenied, isFalse);

      final other = AudioIoException('MICROPHONE_PERMISSION_DENIED', 'nope');
      expect(other.isSystemAudioUnsupported, isFalse);
    });

    test('isSystemAudioCaptureFailed is true only for the capture code', () {
      final failed = AudioIoException('SYSTEM_AUDIO_CAPTURE_FAILED', 'tap');
      expect(failed.isSystemAudioCaptureFailed, isTrue);
      expect(failed.isSystemAudioUnsupported, isFalse);
    });
  });

  group('platform backend supportsInputSource', () {
    // `createAudioIoImpl` picks the Apple backend on macOS hosts and the FFI
    // backend elsewhere, so this pins the per-platform matrix as a whole.
    final backend = createAudioIoImpl();

    test('microphone is always supported', () {
      expect(
          backend.supportsInputSource(AudioIoInputSource.microphone), isTrue);
    });

    test('system audio is supported on Windows (WASAPI) and macOS (taps)', () {
      expect(
        backend.supportsInputSource(AudioIoInputSource.systemAudio),
        Platform.isWindows || Platform.isMacOS,
      );
    });

    test('microphone + system audio is macOS-only', () {
      expect(
        backend.supportsInputSource(
          AudioIoInputSource.microphoneAndSystemAudio,
        ),
        Platform.isMacOS,
      );
    });

    test('configureInputSource does not throw', () {
      expect(
        () => backend.configureInputSource(AudioIoInputSource.systemAudio),
        returnsNormally,
      );
    });
  });

  group('miniaudio FFI backend supportsInputSource', () {
    // Constructed directly so the FFI leg's matrix is pinned on every host,
    // including macOS where createAudioIoImpl would pick the Apple backend.
    final native = AudioIoNative();

    test('system audio is Windows-only on the FFI leg', () {
      expect(
        native.supportsInputSource(AudioIoInputSource.systemAudio),
        Platform.isWindows,
      );
    });

    test('microphone + system audio is never supported on the FFI leg', () {
      expect(
        native.supportsInputSource(
          AudioIoInputSource.microphoneAndSystemAudio,
        ),
        isFalse,
      );
    });
  });

  group('AudioIo.startWith', () {
    // Requesting a source the backend cannot provide must surface a typed
    // AudioIoException before any native device work — never crash the
    // engine.
    test('throws typed error for an unsupported source on the FFI backend',
        () async {
      final audio = AudioIo.withImpl(AudioIoNative());
      await expectLater(
        audio.startWith(
          const AudioIoConfig(
            inputSource: AudioIoInputSource.microphoneAndSystemAudio,
          ),
        ),
        throwsA(
          isA<AudioIoException>().having((e) => e.isSystemAudioUnsupported,
              'isSystemAudioUnsupported', isTrue),
        ),
      );
    });

    test('throws typed error for system audio where the platform lacks it',
        () async {
      if (Platform.isWindows || Platform.isMacOS) {
        // These hosts support the source; the unsupported path can't be
        // exercised here (and a real start needs an audio endpoint).
        return;
      }
      await expectLater(
        AudioIo.instance.startWith(
          const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
        ),
        throwsA(
          isA<AudioIoException>().having((e) => e.isSystemAudioUnsupported,
              'isSystemAudioUnsupported', isTrue),
        ),
      );
    });
  });
}
