import 'package:audio_io/src/audio_io_apple.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudioIoApple.start rollback', () {
    const channel = MethodChannel('com.wearemobilefirst.audio_io');
    final calls = <String>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
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

    test(
        'a failing FFI transport binding stops the native engine and rethrows',
        () async {
      // The host test runner has no audio_io @_cdecl symbols linked into the
      // process, so constructing the FFI data-plane transport throws at
      // lookupFunction — the exact release-linker-stripped-symbol failure this
      // rollback guards. start() has already completed the native `start`
      // (engine + mic live), so it must invoke the native `stop` and rethrow
      // rather than leaving the engine running.
      final apple = AudioIoApple();

      await expectLater(apple.start(), throwsA(isA<Object>()));

      expect(calls, contains('start'));
      expect(
        calls,
        contains('stop'),
        reason: 'the native engine must be stopped when post-start setup fails',
      );
    });
  });
}
