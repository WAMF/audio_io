import 'dart:typed_data';

import 'package:audio_io/audio_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PCM16 adapter lifecycle', () {
    // Regression for the single-subscription output controller defect: a
    // startWith -> stop() -> startWith restart re-listened the output byte
    // controller and threw `Bad state: Stream has already been listened to`.
    // The native engine cannot be started in a unit test, but the byte
    // adapters and stop()'s teardown are no-ops on the (uninitialised) native
    // handle, so the wire/teardown/re-wire path can be exercised directly.

    test('survives a wire -> teardown -> wire restart', () async {
      final audio = AudioIo();
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate16000.hz);
      await audio.stop();
      // Threw here before the fix; must now re-wire cleanly.
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate16000.hz);
      audio.dispose();
    });

    test('survives repeated restarts at a changed rate', () async {
      final audio = AudioIo();
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate16000.hz);
      await audio.stop();
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate24000.hz);
      await audio.stop();
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate48000.hz);
      audio.dispose();
    });

    test('outputBytes is a reusable broadcast sink across restarts', () async {
      final audio = AudioIo();
      // The same sink reference stays valid across a restart because the
      // controller is broadcast and persists (not closed on teardown).
      final sink = audio.outputBytes;
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate16000.hz);
      sink.add(Uint8List.fromList([0, 0, 0, 0]));
      await audio.stop();
      await audio.wirePcm16AdaptersForTest(AudioIoSampleRate.rate16000.hz);
      expect(() => sink.add(Uint8List.fromList([0, 0])), returnsNormally);
      audio.dispose();
    });

    test('clearOutput dispatch completes without a started engine', () async {
      final audio = AudioIo();
      await expectLater(audio.clearOutput(), completes);
      audio.dispose();
    });
  });
}
