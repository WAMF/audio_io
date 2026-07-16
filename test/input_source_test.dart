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
    });
  });

  group('AudioIoConfig.inputSource', () {
    test('defaults to microphone', () {
      const config = AudioIoConfig();
      expect(config.inputSource, AudioIoInputSource.microphone);
    });

    test('is configurable', () {
      const config =
          AudioIoConfig(inputSource: AudioIoInputSource.systemAudio);
      expect(config.inputSource, AudioIoInputSource.systemAudio);
    });
  });

  group('AudioIoException.isSystemAudioUnsupported', () {
    test('true for the unsupported code, false otherwise', () {
      final unsupported =
          AudioIoException('SYSTEM_AUDIO_UNSUPPORTED', 'nope');
      expect(unsupported.isSystemAudioUnsupported, isTrue);
      expect(unsupported.isPermissionDenied, isFalse);

      final other = AudioIoException('MICROPHONE_PERMISSION_DENIED', 'nope');
      expect(other.isSystemAudioUnsupported, isFalse);
    });
  });

  group('AudioIoNative.supportsInputSource', () {
    final native = createAudioIoImpl();

    test('microphone is always supported', () {
      expect(native.supportsInputSource(AudioIoInputSource.microphone), isTrue);
    });

    test('system audio is supported only on Windows (FFI loopback leg)', () {
      expect(
        native.supportsInputSource(AudioIoInputSource.systemAudio),
        Platform.isWindows,
      );
    });

    test('configureInputSource does not throw', () {
      expect(
        () => native.configureInputSource(AudioIoInputSource.systemAudio),
        returnsNormally,
      );
    });
  });

  group('AudioIo.startWith', () {
    // On non-Windows FFI hosts, requesting system audio must surface a typed
    // AudioIoException before any native device work — never crash the engine.
    test('throws typed error for an unsupported source', () async {
      if (Platform.isWindows) {
        // Windows supports the source; the unsupported path can't be exercised
        // here (and a real start needs an audio endpoint).
        return;
      }
      await expectLater(
        AudioIo.instance.startWith(
          const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
        ),
        throwsA(
          isA<AudioIoException>()
              .having((e) => e.isSystemAudioUnsupported,
                  'isSystemAudioUnsupported', isTrue),
        ),
      );
    });
  });
}
