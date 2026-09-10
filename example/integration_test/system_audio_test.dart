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
/// itself. Then, in the same session, this process plays a tone through the
/// output stream and the captured level must stay silent — proof that the
/// own-process exclusion holds. The first case is the positive control for
/// the second: a session that captures nothing at all fails the first case
/// instead of passing the second.
///
/// macOS: the capture needs the System Audio Recording grant. TCC attributes
/// an app the `flutter` tool launches to the terminal that runs the tool, so
/// either grant that terminal *System Audio Recording Only* in System
/// Settings > Privacy & Security, or launch the built example app once from
/// Finder / `open` and click Allow. A missing grant captures silence, which
/// fails the positive control with the reason below.
class _Levels {
  static const listenFor = Duration(seconds: 4);
  static const audibleRms = 0.005;
  static const ownToneDuration = 3.0;
  static const ownToneHz = 440.0;
  static const ownToneAmplitude = 0.8;
  static const contractRate = 48000;
}

class _Capture {
  _Capture(this.frames, this.peakRms);

  final int frames;
  final double peakRms;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<_Capture> captureWhile(Future<void> Function() stimulus) async {
    var frames = 0;
    var peak = 0.0;
    final subscription = AudioIo.instance.input.listen((frame) {
      frames++;
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
    return _Capture(frames, peak);
  }

  Future<Process> speakFromAnotherProcess() async {
    if (Platform.isMacOS) {
      // Detached so the phrase plays out while we keep sampling.
      return Process.start('say', [
        '-r',
        '160',
        'testing system audio capture one two three four five',
      ]);
    }
    return Process.start('powershell', [
      '-Command',
      'Add-Type -AssemblyName System.Speech; '
          '(New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("testing system audio capture one two three four five")',
    ]);
  }

  /// A loud tone played by this process through the output stream. The
  /// session is started with an output buffer that holds the whole tone, so
  /// the single `output.add` is not truncated to the default 2048-sample
  /// ring.
  Future<void> playOwnTone() async {
    const rate = _Levels.contractRate;
    final tone = List<double>.generate(
      (rate * _Levels.ownToneDuration).toInt(),
      (i) => _Levels.ownToneAmplitude *
          math.sin(2 * math.pi * _Levels.ownToneHz * i / rate),
    );
    AudioIo.instance.output.add(tone);
  }

  testWidgets(
      'a system-audio session hears another process and not its own output',
      (tester) async {
    await AudioIo.instance.startWith(
      const AudioIoConfig(
        inputSource: AudioIoInputSource.systemAudio,
        outputBufferDuration: _Levels.ownToneDuration,
      ),
    );
    addTearDown(AudioIo.instance.stop);

    final format = await AudioIo.instance.getFormat();
    final inputRate = (format?['input'] as Map?)?['sampleRate'];
    expect(inputRate, isA<num>().having((r) => r > 0, 'positive', isTrue));

    // Positive control: the capture is alive and hears another process.
    Process? speaker;
    final control = await captureWhile(() async {
      speaker = await speakFromAnotherProcess();
    });
    expect(
      control.frames,
      greaterThan(0),
      reason: 'no frames were delivered at all — nothing drives the capture',
    );
    expect(
      control.peakRms,
      greaterThan(_Levels.audibleRms),
      reason: 'captured level stayed at ${control.peakRms} — the System '
          'Audio Recording grant is missing for this process or for the '
          'terminal that launched it (see the file comment)',
    );
    await speaker?.exitCode;

    // Same session: this process plays, and must not hear itself.
    final own = await captureWhile(playOwnTone);
    expect(own.frames, greaterThan(0));
    expect(
      own.peakRms,
      lessThan(_Levels.audibleRms),
      reason: 'the host process must be excluded from the capture '
          '(peak ${own.peakRms})',
    );
  });
}
