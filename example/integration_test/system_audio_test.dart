import 'dart:io';
import 'dart:math' as math;

import 'package:audio_io/audio_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Real-engine check of the desktop system-audio input source.
///
/// Run on a desktop host: `flutter test integration_test -d macos` (or
/// `-d windows`). Another process (`say` on macOS) speaks while a
/// system-audio session listens, and the captured level must rise — proof
/// that the tap/loopback delivers audio that this process did not play
/// itself. On macOS the first run triggers the System Audio Recording
/// permission prompt; a denied grant captures silence, so grant it and run
/// again.
class _Levels {
  static const listenFor = Duration(seconds: 4);
  static const audibleRms = 0.005;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<double> peakRmsWhile(Future<void> Function() stimulus) async {
    var peak = 0.0;
    final subscription = AudioIo.instance.input.listen((frame) {
      if (frame.isEmpty) return;
      var sum = 0.0;
      for (final sample in frame) {
        sum += sample * sample;
      }
      peak = math.max(peak, math.sqrt(sum / frame.length));
    });
    await stimulus();
    await Future<void>.delayed(_Levels.listenFor);
    await subscription.cancel();
    return peak;
  }

  Future<void> speakFromAnotherProcess() async {
    if (Platform.isMacOS) {
      // Detached so the phrase plays out while we keep sampling.
      await Process.start('say', [
        '-r',
        '160',
        'testing system audio capture one two three four five'
      ]);
    } else if (Platform.isWindows) {
      await Process.start('powershell', [
        '-Command',
        'Add-Type -AssemblyName System.Speech; '
            '(New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("testing system audio capture one two three four five")',
      ]);
    }
  }

  testWidgets('a system-audio session hears audio another process plays',
      (tester) async {
    await AudioIo.instance.startWith(
      const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
    );
    addTearDown(AudioIo.instance.stop);

    final format = await AudioIo.instance.getFormat();
    final inputRate = (format?['input'] as Map?)?['sampleRate'];
    expect(inputRate, isA<num>().having((r) => r > 0, 'positive', isTrue));

    final peak = await peakRmsWhile(speakFromAnotherProcess);
    expect(
      peak,
      greaterThan(_Levels.audibleRms),
      reason: 'captured level stayed at $peak — if the System Audio '
          'Recording permission was just denied, grant it and re-run',
    );
  });

  testWidgets('a system-audio session does not hear its own output',
      (tester) async {
    await AudioIo.instance.startWith(
      const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
    );
    addTearDown(AudioIo.instance.stop);

    // A loud 440 Hz tone played by this process through the output stream.
    Future<void> playOwnTone() async {
      const seconds = 3;
      const rate = 48000;
      final tone = List<double>.generate(
        rate * seconds,
        (i) => 0.8 * math.sin(2 * math.pi * 440 * i / rate),
      );
      AudioIo.instance.output.add(tone);
    }

    final peak = await peakRmsWhile(playOwnTone);
    expect(
      peak,
      lessThan(_Levels.audibleRms),
      reason: 'the host process must be excluded from the capture (peak $peak)',
    );
  });
}
