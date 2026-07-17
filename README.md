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
- System-audio (loopback) capture on Windows — record what the machine is playing
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
apps and every platform. On the FFI back ends (Android, Windows, Linux) and
on iOS/macOS you can opt into a dedicated audio isolate so device polling and
native buffer copies are unaffected by main-isolate jank (heavy widget
builds, GC):

```dart
await audioIo.startWith(const AudioIoConfig(
  threading: AudioIoThreading.audioIsolate,
));
```

iOS and macOS reach the AVAudioEngine ring buffers over FFI (the engine
lifecycle stays on the method channel), so the data plane can run on the
audio isolate just like the FFI back ends. Web silently falls back to
main-isolate operation. The `input` / `output` streams still surface on the
main isolate in every mode, so listener callbacks run there; move heavy DSP
out of the listener if it competes with UI work.

### System / tab audio input (web)

Set `inputSource` to capture the machine's audio mix instead of the
microphone. On the web this is backed by
[`getDisplayMedia`](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getDisplayMedia):
`startWith` triggers the browser's share picker (it must run from a user
gesture — a button tap is fine), and the audio track from the chosen tab or
screen is piped into the same 48 kHz mono graph the microphone uses. The
video track is required by the picker but is stopped immediately.

```dart
await audioIo.startWith(const AudioIoConfig(
  inputSource: AudioIoInputSource.systemAudio,
));
```

Platform reality — read before relying on it:

- **Chromium only.** Chrome and Edge deliver an audio track; Firefox and
  Safari implement `getDisplayMedia` but return **no** audio track. On those
  browsers the input stream emits an `AudioIoException` with
  `isSystemAudioUnsupported == true` — listen to the stream's `onError` (or
  catch it) rather than assuming audio will arrive.
- **Tab audio** works on every Chromium desktop platform when the user shares
  a tab — the right UX for browser-hosted meetings ("share the Meet tab").
- **Full system audio** (sharing the whole screen) works on Windows and
  ChromeOS always, and on macOS only since Chrome 141 on macOS 14.2+.
- The captured tab keeps playing out of the speakers by default, so a
  listening app does not silence the source it is capturing.
- When the user clicks **Stop sharing** in the browser UI, the capture track
  ends and the `input` stream completes (`onDone`); output/playback keeps
  running.

On desktop `AudioIoInputSource.systemAudio` is backed by WASAPI loopback
(Windows) and Core Audio process taps (macOS); it throws the same
`isSystemAudioUnsupported` error on platforms/back ends that cannot provide
it. See the `example/` app for a share-a-tab listening demo.

### System audio capture (loopback)

By default the input stream captures the microphone. Set
`inputSource: AudioIoInputSource.systemAudio` to instead capture the machine's
audio mix — what is currently playing out of the speakers (meetings, media,
other apps). The captured frames arrive on the same `input` / `inputBytes`
stream, downmixed to mono and resampled to the configured rate, so consumers
are unchanged.

```dart
await audioIo.startWith(const AudioIoConfig(
  inputSource: AudioIoInputSource.systemAudio,
));
```

| Platform | System audio | Mechanism |
|----------|--------------|-----------|
| Windows  | ✅ Supported (build 20348+) | WASAPI loopback (`ma_device_type_loopback`) |
| macOS    | ✅ Supported | Core Audio process taps (macOS 14.2+) |
| Linux    | ⛔ Not yet | PulseAudio/PipeWire monitor sources — planned |
| Android / iOS / Web | ⛔ Not supported | — |

**Own-process exclusion.** On Windows the host process is excluded from the
loopback capture (`wasapi.loopbackProcessID` + `loopbackProcessExclude`), so an
app that plays TTS through the output stream while capturing system audio does
**not** hear itself. The output stream keeps working in this mode: because a
WASAPI loopback device is capture-only, a separate playback device is opened
alongside it.

**Windows minimum: build 20348 (Windows 11 / Windows Server 2022).**
Process-excluded loopback uses the WASAPI `VAD\Process_Loopback` activation
path, which only exists from build 20348. On older Windows (e.g. Windows 10
19045) the native device fails to initialise; rather than silently dropping the
own-process exclusion and re-capturing the app's own output, `startWith` throws
the same `AudioIoException` with `isSystemAudioUnsupported == true` as the
unsupported platforms below, so the microphone-fallback pattern covers this case
too.

**No permission prompt** is required for loopback capture on Windows.

**Unsupported platforms** throw an `AudioIoException` with
`isSystemAudioUnsupported == true` from `startWith` rather than crashing the
engine, so callers can fall back to the microphone:

```dart
try {
  await audioIo.startWith(
    const AudioIoConfig(inputSource: AudioIoInputSource.systemAudio),
  );
} on AudioIoException catch (e) {
  if (e.isSystemAudioUnsupported) {
    await audioIo.startWith(const AudioIoConfig()); // microphone fallback
  } else {
    rethrow;
  }
}
```

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