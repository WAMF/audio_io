import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:audio_io/audio_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Mirrors the channel name the native macOS/iOS plugins register
  // (_Channels.methodChannelName in lib/audio_io.dart, which is private).
  const methodChannel = MethodChannel('com.wearemobilefirst.audio_io');
  final invokedMethods = <String>[];

  // clearOutput() only routes through the platform method channel on macOS/iOS.
  // On Linux/Windows/Android AudioIoNative.usePlatformImpl is true, so the call
  // (and start()/stop() below) goes straight to FFI, which would try to load the
  // native library and is not exercised under `flutter test`. The method-name
  // regression this test guards lives on the channel path, so the assertion runs
  // only where that path is active (this plugin's tests run on macOS).
  final channelPathActive = Platform.isMacOS || Platform.isIOS;

  setUpAll(() {
    // Installed before the per-test setUp so start()'s method-channel call does
    // not throw MissingPluginException on the channel path.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      invokedMethods.add(call.method);
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
  });

  setUp(() {
    AudioIo.instance.start();
  });

  tearDown(() {
    AudioIo.instance.stop();
  });

  test(
    'clearOutput() invokes the "clearOutput" platform method',
    () async {
      invokedMethods.clear();

      await AudioIo.instance.clearOutput();

      // Catches a method-name regression: renaming _Methods.clearOutput or the
      // invokeMethod argument in lib/audio_io.dart breaks this expectation.
      expect(invokedMethods, contains('clearOutput'));
    },
    skip: channelPathActive
        ? false
        : 'clearOutput() uses the FFI path (not the method channel) on this '
            'platform; the channel assertion only applies on macOS/iOS.',
  );
}
