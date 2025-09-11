# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`audio_io` is a Flutter plugin providing real-time audio streaming between iOS/macOS and Flutter/Dart. It enables low-latency audio processing, recording, and visualization with minimal code.

## Commands

### Development Setup
```bash
flutter pub get
cd example && flutter pub get
cd ios && pod install
```

### Code Quality
```bash
dart analyze
dart fix --apply
```

### Testing
```bash
flutter test test/audio_io_test.dart  # Plugin tests (minimal)
cd example && flutter test            # Example app tests
```

### Running Example
```bash
cd example
flutter run  # iOS: requires device or simulator
flutter run -d macos  # macOS: runs on Mac
```

### Building Plugins
```bash
# iOS
cd example/ios
pod install
open Runner.xcworkspace  # Opens in Xcode

# macOS
cd example/macos
pod install
open Runner.xcworkspace  # Opens in Xcode
```

## Architecture

### Plugin Structure
- **lib/audio_io.dart**: Main Dart API with singleton `AudioIo` class
  - Exposes input/output audio streams as `Stream<List<double>>`
  - Handles platform channel communication
  - Binary messaging for efficient audio transfer

- **ios/Classes/SwiftAudioIoPlugin.swift**: iOS implementation
  - AVAudioEngine-based audio pipeline
  - Custom ring buffer for audio buffering
  - Audio session management and interruption handling
  - Float32 internal processing, Float64 I/O

- **macos/Classes/AudioIoPlugin.swift**: macOS implementation
  - AVAudioEngine-based audio pipeline (similar to iOS)
  - Custom ring buffer for audio buffering
  - Simplified audio handling for desktop environment
  - Float32 internal processing, Float64 I/O

### Audio Pipeline
1. **Input**: Microphone → AVAudioEngine → Float32 → Float64 → Flutter Stream
2. **Output**: Flutter Stream (Float64) → Ring Buffer → AVAudioSourceNode → Speakers
3. **Format**: 48kHz mono (adapts to device), double-precision floats

### Key Implementation Details
- Thread-safe ring buffer (2048 samples) for audio buffering
- Separate method channels for control and binary channels for audio data
- Automatic audio session configuration based on latency mode
- Handles route changes and interruptions gracefully

## Development Guidelines

### Adding Features
- Support both iOS and macOS platforms
- Follow existing Swift patterns in SwiftAudioIoPlugin.swift (iOS) and AudioIoPlugin.swift (macOS)
- Use proper error handling and audio session management (iOS-specific)
- Test with different latency modes on iOS (Realtime, Balanced, Powersave)
- Ensure macOS entitlements are properly configured for audio input

### Code Style
- Swift: Follow existing formatting in iOS plugin
- Dart: Use `dart fix` and resolve all analyzer warnings
- Avoid inline comments unless explaining complex audio processing

### Testing Audio Features
- Test on real iOS devices for accurate latency measurements
- Test on macOS for desktop audio behavior
- Verify audio continues through interruptions on iOS (phone calls, etc.)
- Check memory usage with Instruments for long-running sessions
- Verify microphone permissions are properly requested on both platforms

## Common Tasks

### Modifying Audio Format
- Update `audioFormat` in SwiftAudioIoPlugin.swift:153
- Ensure ring buffer size matches expected frame counts
- Update Dart side if changing from mono/48kHz

### Adding Android Support
- Create android/src/main/kotlin implementation
- Use Android AudioTrack/AudioRecord or Oboe library
- Match the Dart API interface exactly
- Consider using same ring buffer approach for consistency

### Debugging Audio Issues
- Check audio session category/mode in iOS Console
- Monitor ring buffer fill levels for underruns
- Use AVAudioEngine tap points for debugging
- Enable audio interruption logging in SwiftAudioIoPlugin