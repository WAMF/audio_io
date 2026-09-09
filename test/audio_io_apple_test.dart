import 'dart:io';

import 'package:audio_io/audio_io.dart';
import 'package:audio_io/src/audio_io_apple.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.wearemobilefirst.audio_io');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getFormat') {
        return <String, dynamic>{
          'input': {'sampleRate': 48000.0},
          'output': {'sampleRate': 48000.0},
        };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  List<String> methods() => calls.map((c) => c.method).toList();

  group('AudioIoApple.start rollback', () {
    test('a failing FFI transport binding stops the native engine and rethrows',
        () async {
      // The host test runner has no audio_io @_cdecl symbols linked into the
      // process, so constructing the FFI data-plane transport throws at
      // lookupFunction — the exact release-linker-stripped-symbol failure this
      // rollback guards. start() has already completed the native `start`
      // (engine + mic live), so it must invoke the native `stop` and rethrow
      // rather than leaving the engine running.
      final apple = AudioIoApple();

      await expectLater(apple.start(), throwsA(isA<Object>()));

      expect(methods(), contains('start'));
      expect(
        methods(),
        contains('stop'),
        reason: 'the native engine must be stopped when post-start setup fails',
      );
    });
  });

  group('AudioIoApple input source', () {
    // The native `start` call carries the configured source by name so the
    // macOS plugin can build the matching capture graph (microphone, Core
    // Audio tap, or both). The FFI transport still throws on the host after
    // the channel call, which is fine: the argument has been recorded.
    Future<Map<Object?, Object?>?> startArguments(
        AudioIoInputSource source) async {
      final apple = AudioIoApple()..configureInputSource(source);
      await expectLater(apple.start(), throwsA(isA<Object>()));
      final start = calls.firstWhere((c) => c.method == 'start');
      return start.arguments as Map<Object?, Object?>?;
    }

    test('defaults to the microphone', () async {
      final args = await startArguments(AudioIoInputSource.microphone);
      expect(args, {'inputSource': 'microphone'});
    });

    test('passes systemAudio to the native start', () async {
      final args = await startArguments(AudioIoInputSource.systemAudio);
      expect(args, {'inputSource': 'systemAudio'});
    });

    test('passes microphoneAndSystemAudio to the native start', () async {
      final args =
          await startArguments(AudioIoInputSource.microphoneAndSystemAudio);
      expect(args, {'inputSource': 'microphoneAndSystemAudio'});
    });

    test('advertises system audio on macOS only', () {
      final apple = AudioIoApple();
      expect(
        apple.supportsInputSource(AudioIoInputSource.microphone),
        isTrue,
      );
      expect(
        apple.supportsInputSource(AudioIoInputSource.systemAudio),
        Platform.isMacOS,
      );
      expect(
        apple.supportsInputSource(
          AudioIoInputSource.microphoneAndSystemAudio,
        ),
        Platform.isMacOS,
      );
    });
  });

  group('AudioIo error mapping', () {
    test('a native SYSTEM_AUDIO_UNSUPPORTED start maps to the typed error',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          throw PlatformException(
            code: 'SYSTEM_AUDIO_UNSUPPORTED',
            message: 'macOS 14.2 or newer is required',
          );
        }
        return null;
      });
      final apple = AudioIoApple()
        ..configureInputSource(AudioIoInputSource.systemAudio);
      final audio = AudioIo.withImpl(apple);

      await expectLater(
        audio.start(),
        throwsA(
          isA<AudioIoException>()
              .having((e) => e.isSystemAudioUnsupported,
                  'isSystemAudioUnsupported', isTrue)
              .having((e) => e.message, 'message', contains('14.2')),
        ),
      );
    });

    test('a native SYSTEM_AUDIO_CAPTURE_FAILED start maps to the typed error',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') {
          throw PlatformException(
            code: 'SYSTEM_AUDIO_CAPTURE_FAILED',
            message:
                'AudioHardwareCreateProcessTap failed (OSStatus 1852797029)',
          );
        }
        return null;
      });
      final audio = AudioIo.withImpl(AudioIoApple());

      await expectLater(
        audio.start(),
        throwsA(
          isA<AudioIoException>().having(
            (e) => e.isSystemAudioCaptureFailed,
            'isSystemAudioCaptureFailed',
            isTrue,
          ),
        ),
      );
    });
  });

  group('AudioIo session errors', () {
    const sessionChannel = EventChannel('com.wearemobilefirst.audio_io/session');

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(sessionChannel, null);
    });

    test('a failed macOS rebuild arrives as a typed AudioIoException',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(
        sessionChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) {
            events.error(
              code: 'SYSTEM_AUDIO_CAPTURE_FAILED',
              message:
                  'AudioHardwareCreateAggregateDevice failed (OSStatus -50)',
            );
          },
        ),
      );
      final audio = AudioIo.withImpl(AudioIoApple());

      final error = await audio.sessionErrors.first;

      expect(error.isSystemAudioCaptureFailed, isTrue);
      expect(error.message, contains('AudioHardwareCreateAggregateDevice'));
    });

    test('is silent on iOS, which has no session event channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final audio = AudioIo.withImpl(AudioIoApple());

      expect(await audio.sessionErrors.isEmpty, isTrue);
    });
  });
}
