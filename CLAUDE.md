# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`audio_io` is a Flutter plugin providing real-time audio streaming on iOS, macOS, Android, Web, Linux, and Windows. It enables low-latency audio processing, recording, and visualization with minimal code, including PCM16 byte streams at 16/24/48 kHz for realtime voice APIs (e.g. Gemini Live).

## Commands

### Development Setup
```bash
flutter pub get
cd example && flutter pub get
cd ios && pod install   # iOS example only; macOS example uses Swift Package Manager
```

### Code Quality
```bash
dart analyze
dart fix --apply
```

### Testing
```bash
flutter test          # Plugin unit tests (ring, resampler, codec, adapters)
cd example && flutter test
```

### Running Examples
```bash
cd example
flutter run              # iOS: requires device or simulator
flutter run -d macos
flutter run -d chrome    # Web (AudioWorklet pipeline)

cd example_gemini_live   # Realtime voice conversation demo (needs Gemini API key)
flutter run -d chrome
```

## Architecture

### Plugin Structure
- **lib/audio_io.dart**: Public API — singleton `AudioIo`, `AudioIoConfig`
  (`startWith`), Float64 `input`/`output` streams, PCM16 `inputBytes`/`outputBytes`,
  `clearOutput`, latency and threading options. iOS/macOS transport (binary
  platform channels) also lives here.
- **lib/src/**: Internals
  - `audio_io_stub.dart` / `audio_io_native.dart` / `audio_io_web.dart`: the
    conditional `AudioIoImpl` implementations
  - `ffi/audio_io_ffi.dart`: FFI transport for Android/Windows/Linux —
    `AudioIoFFICore` (handle, drain-all polling, persistent native buffers)
    behind the `AudioIoFFITransport` interface
  - `ffi/audio_io_isolate.dart`: opt-in dedicated audio isolate transport
    (`AudioIoThreading.audioIsolate`), with worker guards and crash handling
  - `pcm16_adapters.dart` / `pcm16_codec.dart` / `push_resampler.dart` /
    `output_ring.dart`: PCM16 byte-stream adapters and DSP primitives
- **ios/audio_io/Sources/audio_io/** and **macos/audio_io/Sources/audio_io/**:
  Swift sources in the Flutter Swift Package layout (dual SwiftPM + CocoaPods;
  the podspecs point at the same sources). AVAudioEngine pipeline;
  `AudioOutputRing.swift` is shared between the platforms. iOS uses
  voice-processing I/O for echo cancellation.
- **src/audio_io_miniaudio.cpp**: miniaudio backend for Android/Windows/Linux.
  Lock-free SPSC ring buffers (atomics + bulk memcpy), preallocated scratch —
  the realtime callback must never lock or allocate.
- **android/**, **linux/**, **windows/**: FFI-only build glue (CMake/Gradle),
  no platform plugin classes.

### Audio Pipeline
1. **iOS/macOS**: Mic → AVAudioEngine sink → Float64 over binary channel →
   Dart stream; output stream → binary channel → `AudioOutputRing` →
   AVAudioSourceNode (pinned to the 48 kHz mono Float64 contract).
2. **FFI platforms**: miniaudio duplex callback ↔ lock-free rings ↔ Dart
   poll/write via FFI (5 ms drain-all poll), optionally on a dedicated isolate.
3. **Web**: AudioWorklet output ring drained on the audio rendering thread;
   PCM16 decode and resampling happen inside the worklet, fed by transferable
   buffers. Input worklet resamples to 48 kHz and posts transferable chunks.
4. **Format**: engine contract is 48 kHz mono Float64 (`Stream<List<double>>`);
   PCM16 byte streams resample to/from the configured rate.

### Key Implementation Details
- Realtime threads never lock against Dart or allocate: `os_unfair_lock`
  short bulk copies on Apple platforms, atomics + memcpy in C++
- `clearOutput` is deferred to the ring consumer and only discards samples
  queued before the request (barge-in must not clip the next response)
- iOS `start()` requires microphone permission already granted; it throws
  `MICROPHONE_PERMISSION_DENIED` (`AudioIoException.isPermissionDenied`)
- Output ring sizes derive from the requested frame duration; oversized
  pushes are dropped, so long-buffering clients should request a duration
  that fits their queue

## Development Guidelines

### Adding Features
- Support all six platforms, or degrade gracefully (see
  `AudioIoThreading.audioIsolate`, which falls back to main-isolate mode
  where unsupported)
- Keep the realtime paths allocation-free and lock-free; do format work on
  the audio rendering thread (worklet/native callback) rather than the main
  thread where the platform allows
- Test with different latency modes (Realtime, Balanced, Powersave)
- Ensure macOS entitlements are configured for audio input

### Code Style
- Swift: follow existing formatting in the plugin sources
- Dart: run `dart fix --apply` and resolve all analyzer warnings
- Avoid inline comments unless explaining complex audio processing

### Testing Audio Features
- Test on real iOS devices for accurate latency measurements
- Web: verify with a busy UI — the worklet pipeline exists to survive
  main-thread jank; test both the worklet and ScriptProcessor fallback paths
- Verify audio continues through interruptions on iOS (phone calls, etc.)
- Check memory usage with Instruments for long-running sessions
- The JS in the web worklet mirrors `PushResampler`'s arithmetic but is not
  covered by `flutter test` — verify audibly via the example when touching it

## Common Tasks

### Modifying Audio Format
- iOS/macOS: contract format constants in `_Constants`
  (ios/audio_io/Sources/audio_io/SwiftAudioIoPlugin.swift and
  macos/audio_io/Sources/audio_io/AudioIoPlugin.swift)
- FFI platforms: `audio_io_create_with_config` in src/audio_io_miniaudio.cpp
### Debugging Audio Issues
- Check audio session category/mode in iOS Console
- Monitor ring buffer fill levels for underruns (`OutputRing.droppedFrames`
  on web fallback; `getFormat()` reports the active backend)
- Use AVAudioEngine tap points for debugging on Apple platforms
- iOS/macOS platform-channel transport (escaping the root isolate) is tracked in issue `#27`
