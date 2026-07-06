## 0.5.0

- Optional dedicated audio isolate: `AudioIoConfig.threading:
  AudioIoThreading.audioIsolate` runs device polling and native buffer
  copies on a spawned isolate on the FFI back ends (Android, Windows,
  Linux), so audio transport is immune to main-isolate jank. The default
  stays `AudioIoThreading.mainIsolate` and unsupported platforms fall back
  to it; the Stream/Sink API still surfaces on the main isolate.
- Web: PCM16 decode and resampling for `outputBytes` now happen inside the
  output AudioWorklet on the audio rendering thread, and chunks cross to it
  as transferable buffers instead of structured clones — the main-thread
  cost per output chunk drops to one copy plus a postMessage, fixing
  underruns under heavy UI load. Float64 output is likewise resampled in
  the worklet.
- Web: microphone capture moved off the deprecated main-thread
  ScriptProcessorNode onto an input AudioWorkletProcessor that resamples to
  the 48 kHz contract on the rendering thread and posts transferable
  chunks (ScriptProcessorNode remains as fallback, now reporting its true
  device rate via `getFormat`). Input delivery no longer boxes every
  sample into a growable `List<double>`.
- FFI transport: the input poll now drains everything available instead of
  capping at 480 frames per tick (a delayed tick previously turned into
  permanent input latency), polls at 5 ms, and both directions reuse
  persistent native buffers with bulk typed-data copies instead of
  per-sample pointer access and a malloc/free per call.
- Native (miniaudio): the ring buffers are now lock-free single-producer
  single-consumer (atomics + bulk memcpy) instead of mutex-guarded
  per-sample copies, removing a priority-inversion risk in the realtime
  callback, and the callback no longer heap-allocates conversion buffers.
- Fixed a latent frame-duration bug on the FFI back ends where a latency
  requested before the first `start()` was silently dropped.
- `pcm16BytesToFloat64` / `float64ToPcm16Bytes` use typed-array views on
  little-endian hosts instead of per-sample `ByteData` calls.
- Android: the plugin is now declared FFI-only (`ffiPlugin: true` without a
  `pluginClass`). The previous declaration referenced a Kotlin plugin class
  that does not exist, which newer Flutter versions reject as a deleted
  Android v1 embedding plugin. The plugin build also moved to
  `compileSdk 35` and no longer applies its own Kotlin plugin
  (Flutter built-in Kotlin compatibility).

## 0.4.1

- Swift Package Manager support for the iOS and macOS plugins, alongside the
  existing CocoaPods support (no consumer changes required — apps keep using
  CocoaPods until they opt into SwiftPM). Native sources moved to the Flutter
  Swift Package layout under `ios/audio_io/Sources/audio_io/` and
  `macos/audio_io/Sources/audio_io/`, with a `Package.swift` per platform. The
  podspecs now reference the new source location, so both build systems work.
- The iOS plugin is now pure Swift: the thin Objective-C registration shim
  (`AudioIoPlugin.h`/`.m`) was removed and the iOS `pluginClass` is now
  `SwiftAudioIoPlugin` (which already implemented `register(with:)`). No Dart
  API changes.

## 0.4.0

- PCM16 streaming and configurable sample rates: new `AudioIo.startWith`
  taking an `AudioIoConfig` (`AudioIoFormat.float64` / `pcm16`,
  `AudioIoSampleRate.rate16000` / `rate24000` / `rate48000`, latency
  preset). The engine keeps its fixed 48 kHz contract internally; the new
  byte streams are resampled to and from the requested rate, so callers can
  work in the rate their API expects (e.g. 16 kHz in / 24 kHz out for
  Gemini Live).
- Byte streams: `AudioIo.inputBytes` (Int16 little-endian PCM16 input
  `Stream<Uint8List>`) and `AudioIo.outputBytes` (PCM16 output
  `Sink<Uint8List>`), active after `startWith` with `AudioIoFormat.pcm16`.
  Both are broadcast streams, so the adapters survive a stop -> startWith
  restart (previously the single-subscription output controller threw
  `Bad state: Stream has already been listened to` on the second
  `startWith`).
- `AudioIo.clearOutput()`: discards audio queued for playback but not yet
  rendered, for immediate barge-in / interruption handling. Wired across
  the native (iOS/macOS/Android/desktop) and web back ends.
- `AudioIo.currentConfig`: the `AudioIoConfig` passed to the most recent
  `startWith`, or null after `start()` / `stop()`.

## 0.3.3

- macOS/iOS: the output source node is now pinned to the 48 kHz mono
  Float64 contract format instead of inheriting the INPUT device's sample
  rate. Previously, Bluetooth routes (44.1 kHz A2DP output, 16-24 kHz HFP
  microphone) made 48 kHz content play slow and pitched down while the
  ring buffer overflowed (periodic crackles); AVAudioEngine now converts
  to the hardware rate and always consumes 48,000 frames/s. `getFormat()`
  reports the real device rate under `output.deviceSampleRate`. The ring
  is sized from the contract rate on every path (it previously shrank
  after route changes), `requestFrameDuration` while running restarts the
  engine instead of swapping the ring under the live render thread, the
  iOS session preferred rate no longer drifts to the last input rate, the
  input buffer pool is sized after the device rate is known and guarded
  by `os_unfair_lock` instead of a render-thread `DispatchQueue.sync`,
  and the engine-reconfiguration observer is scoped to this plugin's
  engine.
- Web: concurrent `start()` calls now share one start attempt (the web
  fires a lifecycle resume on every window focus, which could race a
  widget-init start into two AudioContexts and a `StateError` on the
  second output listen); `stop()` waits for an in-flight start before
  tearing down. `getFormat()` reports which output path is active under
  `output.backend` (`audioWorklet` / `scriptProcessor` / `inactive`).
- Web: output now plays through an `AudioWorkletNode` when available. The
  worklet owns a ring buffer drained on the dedicated audio rendering
  thread, so main-thread jank (heavy frames, GC pauses) can no longer
  glitch playback. Pushed 48 kHz audio is resampled to the device rate on
  the push path before being posted to the worklet. Browsers without
  AudioWorklet fall back to the ScriptProcessor path below; microphone
  input continues to use a (lazy, input-only) ScriptProcessorNode.
- Web: replaced the growable-list output queue (O(n) `removeAt(0)` per
  sample inside the audio callback) with an O(1) `Float32List` ring buffer,
  and replaced per-sample JS interop with bulk `copyToChannel` /
  typed-array copies. Fixes crackling and dropouts under load.
- Web: pushed 48 kHz audio is now linearly resampled to the actual
  AudioContext device rate (often 44.1 kHz), fixing pitch and queue-drift
  on devices that do not run at 48 kHz. `getFormat()` reports the device
  rate under `output.deviceSampleRate`.
- Web: the microphone is only requested when `input` is listened to;
  output-only apps no longer trigger a permission prompt.
- Web: ScriptProcessor buffer size floor raised to 2048 frames for
  main-thread stability.
- Added public `requestFrameDuration(double seconds)` so clients can size
  the native output ring buffer; the latency presets now route through it.

## 0.0.1
Kiss release
Input from mic at fixed sample rate and buffer size, no output

## 0.0.2
Kiss MVP release

Input from mic at fixed sample rate and buffer size, output fixed at mono at the same sample rate as input.
Simple quick and dirty ringbuffer for output (needs optimisation)

## 0.0.3
Bugfix
Fix 32-64bit mismatch of data.

## 0.0.4
Improvement
Allow muliple listeners on audio input

## 0.0.5
Bugfix
Thread safety - memory leak fixed :)

## 0.0.6
Improvement
Main thread call for sink removed (attempt to reduce latency introduced in 0.0.5)

## 0.0.7
Rollback 0.0.6

## 0.0.8
Improvement
Handle audio session changes
Reset audio when entering foreground

## 0.0.9
Improvement
Handle audio interruptions
Using simpler binary message system to send data (2x cpu optimisation)
Replaced invoking method with binary message for output audio
Less format conversions when sending data in and out
Prep work for upcoming buffer and samplerate selection features

## 0.1.0
New Interface
Added inteface for getting format and buffer size selection (audio frame size)
Using serial queue for read and writes to buffer

## 0.1.1
Performance
Fixing Dart side audio format to double (everything is 64bit these days, 64bit is great for processing)
Optimised data conversion 

## 0.1.2
Bugfix
Fix bug which stopped audio when coming back from background

## 0.1.3
Bugfix
Fixed issue with route swapping from speaker to headphones

## 0.1.4
Bugfix
Better way to detect changes in audio format, removed old methods

## 0.1.5
Bugfix
Using detected input sample rate rather than fixed sample rate

## 0.1.6
Cleanup
Added null safety 

## 0.1.7
Performance improvement

## 0.1.8
Fix dangling pointer

## 0.1.9
Small performance improvement
Remove fonts from example
Bump SDK version

## 0.2.0
Major Update
- Added macOS platform support with full audio input/output capabilities
- Updated minimum SDK requirements: Dart >=3.4.0, Flutter >=3.22.0
- Fixed ring buffer infinite recursion bug in macOS implementation
- Added proper entitlements configuration for macOS microphone access
- Updated documentation with platform-specific setup instructions
- Improved cross-platform compatibility

## 0.3.0
Multi-Platform Release
- Added Android platform support using miniaudio C++ library via FFI
- Added Web platform support using Web Audio API
- Added Linux platform support using miniaudio via FFI
- Added Windows platform support using miniaudio via FFI
- Implemented configurable audio latency (Realtime/Balanced/Powersave modes)
- Added real-time volume meter visualization in example app
- Standardized data format across all platforms (Float64, 48kHz, mono)
- Fixed microphone permissions handling on Android
- Improved FFI implementation with proper memory management
- Added comprehensive .gitignore for C/C++ build artifacts
- Fixed all analyzer warnings and improved code quality
- Updated minimum SDK requirements: Dart >=3.0.0, Flutter >=3.10.0

Platform Support:
- iOS ✅ (Native Swift/AVAudioEngine)
- macOS ✅ (Native Swift/AVAudioEngine)  
- Android ✅ (FFI/miniaudio)
- Web ✅ (Web Audio API)
- Linux ✅ (FFI/miniaudio)
- Windows ✅ (FFI/miniaudio)

## 0.3.2
Bug Fix
- Fixed compile error in resetAudio() caused by start() signature change

## 0.3.1
Performance, Stability & Error Handling Update

Permission Handling:
- Added graceful error handling when microphone permission is not granted (iOS/macOS)
- Plugin now throws AudioIoException with clear message instead of crashing
- Added AudioIoException class with isPermissionDenied helper for easy error handling
- Permission errors clearly state that permission handling is the app's responsibility

Threading Fix:
- Fixed critical threading crash on macOS where platform channel messages were sent from audio thread
- Binary messages now dispatched to main thread before sending to Flutter (iOS/macOS)

API Additions:
- Added AudioIoException class for typed error handling
- AudioIoException.isPermissionDenied getter for checking permission errors
- AudioIoException includes code, message, and optional details

Critical Memory Leak Fixes:
- Implemented buffer pool for Data objects to eliminate real-time allocations in audio callbacks (iOS/macOS)
- Fixed catastrophic memory leak from DispatchQueue.main.async accumulation in audio callbacks (iOS/macOS)
- Fixed memory accumulation from queue.async in output message handler by switching to sync (iOS/macOS)
- Added autoreleasepool to audio callbacks and message handlers to ensure immediate memory release (iOS/macOS)
- Fixed retain cycle in plugin instance preventing deallocation (iOS/macOS)
- Fixed retain cycles in audio node callbacks by using weak self references (iOS/macOS)
- Fixed NotificationCenter observer leak by adding proper deinit cleanup (iOS/macOS)
- Fixed ByteData reference chain leak by copying audio data instead of creating views
- Fixed ring buffer index overflow that would cause eventual corruption
- Fixed StreamController memory leak in Dart output sink fallback
- Added proper cleanup of binary message handlers on stop
- Added buffer.clear() on stop to release memory immediately
- Optimized audio buffer conversion to reduce allocations per frame
- Made stream controllers synchronous to prevent event queue buildup
- Optimized Dart input processing to skip allocations when no listener present
- Eliminated Data array allocation in output handler by writing directly from buffer (iOS/macOS)

Performance Improvements:
- Optimized audio pipeline to use Float64 throughout iOS/macOS, eliminating unnecessary Float32→Float64 conversions
- Removed unnecessary thread dispatch from audio callbacks, eliminating unbounded queue growth
- Removed expensive DateTime operations from per-frame Dart message handler
- Reduced CPU overhead by eliminating Float32→Float64 conversion in audio processing
- Optimized buffer sizes based on latency mode (256-4096 samples)
- Improved thread synchronization for audio callbacks
- Optimized Dart output stream to avoid unnecessary Float64List allocations
- Eliminated per-frame List allocations in example app audio processing
- Minimized per-frame allocations in Dart message handler for better throughput

Bug Fixes:
- Fixed critical pipeline setup bug in iOS/macOS (_isPipelineSetup flag now properly set)
- Fixed audio format mismatch crash on iOS/macOS (AVAudioEngine Float32 compatibility)
- Fixed latency change handling on miniaudio platforms (now properly restarts with new buffer)
- Fixed Web platform getFrameDuration calculation before audio start
- Fixed example app pubspec.yaml formatting issues
- Added missing flutter_lints dependency to example app

Platform Improvements:
- Added clipping protection for miniaudio platforms (Linux/Windows/Android) to prevent audio distortion
- Implemented dynamic latency switching without restart on all platforms
- Fixed Web platform buffer size configuration based on latency settings
- Improved ring buffer size management with minimum size guarantee

Code Quality:
- Fixed analyzer warnings and applied dart fix recommendations
- Removed debug print statements from production code
- Disabled latency dropdown in example app when audio is running

Diagnostics:
- Added ring buffer overflow detection with logging (iOS/macOS)