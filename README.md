# audio_io

A Flutter plugin for real-time audio streaming between iOS/macOS and Flutter/Dart. Provides low-latency audio processing, recording, and visualization with minimal code.

## Features

- Simple audio data streaming from platform to Flutter
- Input audio stream as `Stream<List<double>>` (frames/chunks)
- Output audio sink for playback
- Low-latency audio processing
- Format description for input/output
- Supports iOS and macOS platforms

## Platform Support

| Platform | Status |
|----------|--------|
| iOS      | ✅ Supported |
| macOS    | ✅ Supported |
| Android  | ❌ Not yet implemented |
| Linux    | ❌ Not yet implemented |
| Windows  | ❌ Not yet implemented |
| Web      | ❌ Not yet implemented |

## Getting Started

### Installation

Add `audio_io` to your `pubspec.yaml`:

```yaml
dependencies:
  audio_io: ^0.2.0
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

### Usage

```dart
import 'package:audio_io/audio_io.dart';

// Get the audio instance
final audioIo = AudioIo();

// Start audio processing
await audioIo.start();

// Listen to input audio stream
audioIo.inputAudioStream.listen((audioData) {
  // Process audio data (List<double>)
  print('Received ${audioData.length} samples');
});

// Send audio to output
audioIo.outputAudioStream.add(audioData);

// Stop audio processing
await audioIo.stop();
```

## Audio Format

- Sample Rate: 48kHz (adapts to device)
- Channels: Mono
- Data Type: Double precision floats (Float64)
- Internal Processing: Float32

## Requirements

- Dart SDK: >=3.0.0 <4.0.0
- Flutter: >=3.10.0
- iOS: 12.0 or higher
- macOS: 10.15 or higher

## License

See LICENSE file for details.