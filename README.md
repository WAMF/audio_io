# audio_io

A Flutter plugin for cross-platform real-time audio streaming. Provides low-latency audio input/output with simple Stream-based API for audio processing, recording, and visualization.

## Live demo

Try the PCM16 streaming + Gemini Live example in your browser:
**[wamf.github.io/audio_io](https://wamf.github.io/audio_io/)** — paste your own
[Gemini API key](https://aistudio.google.com/apikey), allow the microphone, and talk.

## Features

- Real-time audio streaming from microphone to Flutter
- Audio output/playback through speakers
- Cross-platform support (iOS, macOS, Android, Web, Linux, Windows)
- Simple Stream-based API
- PCM16 byte streams at 16/24/48 kHz for realtime voice APIs (e.g. Gemini Live)
- Configurable audio latency modes
- Optional dedicated audio isolate on FFI platforms
- Consistent data format across all platforms (Float64, 48kHz, mono)
- Low-latency audio processing
- Volume level monitoring

## Platform Support

| Platform | Status | Implementation |
|----------|--------|---------------|
| iOS      | ✅ Supported | Native (AVAudioEngine) |
| macOS    | ✅ Supported | Native (AVAudioEngine) |
| Android  | ✅ Supported | FFI (miniaudio) |
| Web      | ✅ Supported | Web Audio API |
| Linux    | ✅ Supported | FFI (miniaudio) |
| Windows  | ✅ Supported | FFI (miniaudio) |

## Getting Started

### Installation

Add `audio_io` to your `pubspec.yaml`:

```yaml
dependencies:
  audio_io: ^0.5.0
```

### iOS Setup

Add microphone usage description to your `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

### macOS Setup

1. Add microphone usage description to your `macos/Runner/Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone for audio processing.</string>
```

2. Enable audio input in your entitlements files:
   - `macos/Runner/DebugProfile.entitlements`
   - `macos/Runner/Release.entitlements`

```xml
<key>com.apple.security.device.audio-input</key>
<true/>
```

### Android Setup

Add microphone permission to your `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

Request the microphone permission at runtime (for example with the
`permission_handler` package) before calling `start()`. If permission has
not been granted, `start()` throws an `AudioIoException` whose
`isPermissionDenied` is true.

### Usage

```dart
import 'package:audio_io/audio_io.dart';

// Get the audio instance
final audioIo = AudioIo.instance;

// Configure latency (optional)
await audioIo.requestLatency(AudioIoLatency.Balanced);

// Start audio processing
await audioIo.start();

// Listen to input audio stream
audioIo.input.listen((audioData) {
  // Process audio data (List<double>)
  print('Received ${audioData.length} samples');
  
  // Calculate volume level (RMS)
  final sum = audioData.fold<double>(
    0.0, (sum, sample) => sum + sample * sample);
  final rms = sqrt(sum / audioData.length);
});

// Send audio to output (echo example)
audioIo.input.listen((data) {
  audioIo.output.add(data);
});

// Stop audio processing
await audioIo.stop();
```

### Latency Configuration

The plugin supports three latency modes:

```dart
enum AudioIoLatency {
  Realtime,  // Lowest latency (~1.5ms buffer)
  Balanced,  // Balanced latency/CPU (~3ms buffer)
  Powersave, // Lower CPU usage (~6ms buffer)
}

// Set before starting audio
await audioIo.requestLatency(AudioIoLatency.Realtime);
```

### PCM16 byte streams (realtime voice APIs)

Realtime voice APIs typically speak little-endian PCM16 at specific sample
rates (Gemini Live expects 16 kHz in / 24 kHz out). `startWith` configures
byte streams in the rate and format the API expects, while the engine keeps
its internal 48 kHz contract — resampling and conversion are handled for
you, on the audio rendering thread where the platform supports it:

```dart
final audioIo = AudioIo.instance;

await audioIo.startWith(const AudioIoConfig(
  format: AudioIoFormat.pcm16,
  sampleRate: AudioIoSampleRate.rate16000,
));

// Microphone as PCM16 bytes at 16 kHz
audioIo.inputBytes.listen(api.sendAudio);

// Play PCM16 bytes (decode + resample handled internally)
api.audioResponses.listen(audioIo.outputBytes.add);

// Barge-in: discard audio queued for playback but not yet rendered
await audioIo.clearOutput();
```

See `example_gemini_live` for a complete voice conversation app, or try it
in the browser at [wamf.github.io/audio_io](https://wamf.github.io/audio_io/).

### Threading (optional dedicated audio isolate)

By default the audio transport runs on the main isolate, which suits most
apps and every platform. On the FFI back ends (Android, Windows, Linux) you
can opt into a dedicated audio isolate so device polling and native buffer
copies are unaffected by main-isolate jank (heavy widget builds, GC):

```dart
await audioIo.startWith(const AudioIoConfig(
  threading: AudioIoThreading.audioIsolate,
));
```

Platforms without dedicated-isolate support (iOS, macOS, web) silently fall
back to main-isolate operation. The `input` / `output` streams still surface
on the main isolate in both modes, so listener callbacks run there; move
heavy DSP out of the listener if it competes with UI work.

## Audio Format

All platforms use a consistent audio format:

- **Sample Rate**: 48kHz (may adapt to device capabilities)
- **Channels**: Mono (1 channel)
- **Data Type**: Double precision floats (Float64/double)
- **Stream Format**: Chunks of audio samples as `List<double>`
- **Internal Processing**: Platform-specific (Float32 on native platforms)

## Requirements

- Dart SDK: >=3.0.0 <4.0.0
- Flutter: >=3.10.0
- iOS: 13.0 or higher
- macOS: 10.15 or higher

## License

See LICENSE file for details.