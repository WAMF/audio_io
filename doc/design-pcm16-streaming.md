# Design: PCM16 Streaming, Configurable Sample Rates & Frame Chunking

**Issue:** #6 — Support PCM16 streaming (16kHz/24kHz) + low-latency chunked duplex audio for real-time AI  
**Status:** Shipped in 0.4.0 (historical design document)

> **Where the implementation diverged:** conversion and resampling did NOT
> land on the native side as proposed below. The shipped design does both in
> Dart adapters (`lib/src/pcm16_adapters.dart`, `pcm16_codec.dart`,
> `push_resampler.dart`) over the engine's fixed 48 kHz Float64 contract; on
> web since 0.5.0 they run inside the output AudioWorklet on the audio
> rendering thread. The native FFI backend gained a PCM16 mode
> (`audio_io_create_with_config`) that the Dart layer does not currently use.
> Native-side conversion for iOS/macOS is revisited in issue #27.

---

## Summary

Add configurable sample rates (16/24/48 kHz), PCM16 (Int16) format support, and predictable frame chunking to enable real-time AI voice streaming (Gemini Live, OpenAI Realtime, etc). Zero breaking changes — all new API alongside existing Float64 streams.

## Key Design Decision

**Format conversion and resampling happen on the native side.** Each platform converts and resamples in its audio callback — tight C/Swift loops operating on raw buffers, not Dart garbage-collected lists. This gives us:

- **Minimal latency** — data arrives at Dart already in the requested format, no extra processing step
- **4x bandwidth reduction** — PCM16 (2 bytes/sample) over the binary channel instead of Float64 (8 bytes/sample)
- **No GC pressure** — no intermediate Float64 lists created and discarded every frame in Dart
- **Hardware-native formats** — miniaudio supports `ma_format_s16` natively, AVAudioEngine supports Int16 PCM formats natively

Web is the exception — Web Audio API only supports Float32, so Dart-side conversion is used there.

---

## Proposed API

### New Types

```dart
enum AudioIoFormat {
  float64,  // Default, backward compatible
  pcm16,    // Signed 16-bit PCM little-endian
}

enum AudioIoSampleRate {
  rate16000(16000),  // Speech AI APIs (Gemini Live, Whisper)
  rate24000(24000),  // OpenAI Realtime API
  rate48000(48000);  // Full quality, default

  const AudioIoSampleRate(this.hz);
  final int hz;
}

class AudioIoConfig {
  final AudioIoSampleRate sampleRate;
  final AudioIoFormat format;
  final AudioIoLatency latency;
  final int? frameDurationMs;  // 20-100ms, null = platform default

  const AudioIoConfig({
    this.sampleRate = AudioIoSampleRate.rate48000,
    this.format = AudioIoFormat.float64,
    this.latency = AudioIoLatency.Balanced,
    this.frameDurationMs,
  });
}
```

### Updated AudioIo Class

```dart
class AudioIo {
  // EXISTING — unchanged
  Stream<List<double>> get input;
  Sink<List<double>> get output;
  Future<void> start();

  // NEW
  Stream<Uint8List> get inputBytes;   // PCM16 LE when format=pcm16
  Sink<Uint8List> get outputBytes;    // PCM16 LE when format=pcm16
  Future<void> startWith(AudioIoConfig config);
  AudioIoConfig? get currentConfig;
}
```

When `format: pcm16`, `inputBytes` emits data and `input` is silent (and vice versa). This keeps types honest and avoids ambiguity.

---

## Native Conversion Pipeline

### Input (Recording)

```text
Mic → Hardware ADC → [Native Resample to target rate] → [Native Convert to target format] → Binary Channel → Dart Stream
```

- **Float64 mode (default):** Same as today. Float32 capture → Float64 conversion → send to Dart.
- **PCM16 mode:** Float32 capture → resample to target rate → convert to Int16 LE → send raw bytes to Dart.

### Output (Playback)

```text
Dart Sink → Binary Channel → [Native Convert from target format] → [Native Resample to hardware rate] → DAC → Speakers
```

- **Float64 mode (default):** Same as today. Float64 from Dart → Float32 → ring buffer → speaker.
- **PCM16 mode:** Int16 LE bytes from Dart → Float32 → resample to hardware rate → ring buffer → speaker.

---

## Platform Implementation

### iOS (`SwiftAudioIoPlugin.swift`)

**Configuration changes:**
- Accept `sampleRate` and `format` in `start` method channel arguments as `Map`
- Replace hardcoded `preferedSampleRate = 48000.0` with value from config
- Pass to `AVAudioSession.setPreferredSampleRate()` (already called, just with new value)

**Conversion in audio callbacks:**
- Input sink node: Currently does `Float32 → Float64`. Add branch:
  - If PCM16: `Float32 → Int16` (clamp, scale by 32767, pack LE)
  - If hardware rate != target rate: use `AVAudioConverter` to resample before format conversion
- Output source node: Currently reads `Float64 → Float32`. Add branch:
  - If PCM16: `Int16 → Float32` (unpack LE, scale by 1/32767)
  - If hardware rate != target rate: resample after format conversion

**AVAudioConverter for resampling:**
iOS/macOS have `AVAudioConverter` built in — handles arbitrary rate conversion with high quality. Use it when `AVAudioSession.sampleRate` doesn't match the requested rate.

**Binary channel changes:**
- Input channel: send raw `Data` (Int16 LE bytes when PCM16, Float64 when float64)
- Output channel: receive raw `Data` in the configured format
- Dart side reads `message.buffer.asInt16List()` or `asFloat64List()` based on config

**Frame chunking:**
- New `_frameChunkSize` computed from `frameDurationMs * sampleRate / 1000`
- Accumulator buffer collects samples from audio callbacks
- Sends to Dart only when accumulator reaches `_frameChunkSize`

### macOS (`AudioIoPlugin.swift`)

Same as iOS. No `AVAudioSession`, but `AVAudioConverter` is available for resampling. Hardware rate read from `AVAudioEngine.inputNode.inputFormat(forBus:).sampleRate`.

### C++/miniaudio (`audio_io_miniaudio.cpp`) — Android, Linux, Windows

**Configuration changes:**
- Replace `const int SAMPLE_RATE = 48000` with `AudioContext` member
- Add `int format` member to `AudioContext` (0 = float64, 1 = pcm16)
- New function: `audio_io_create_with_config(double frameDuration, int sampleRate, int format)`
- In `ma_device_config`: set `config.sampleRate` from context, keep `config.playback.format = ma_format_f32` (miniaudio handles internal resampling)

**Conversion in data_callback:**
- Input callback currently does: `Float32 → Double → DoubleRingBuffer`
  - PCM16 mode: `Float32 → Int16 → Int16RingBuffer` (new ring buffer type)
  - Clamp and scale in the callback loop: `int16_t sample = (int16_t)(fminf(fmaxf(floatInput[i], -1.0f), 1.0f) * 32767.0f)`
- Output callback currently does: `DoubleRingBuffer → Double → Float32`
  - PCM16 mode: `Int16RingBuffer → Int16 → Float32`

**New ring buffer for Int16:**
- Add `Int16RingBuffer` alongside existing `DoubleRingBuffer` (same structure, `int16_t` instead of `double`)
- Or template it: `RingBuffer<T>` with `T = double` or `T = int16_t`

**New FFI functions:**
```c
void* audio_io_create_with_config(double frameDuration, int sampleRate, int format);
int audio_io_read_pcm16(void* context, int16_t* buffer, int maxFrames);
int audio_io_write_pcm16(void* context, const int16_t* buffer, int frames);
```

**miniaudio resampling:**
miniaudio has a built-in resampler. When `config.sampleRate = 16000` and the hardware runs at 48000, miniaudio handles the conversion automatically in its device layer. This is the cleanest approach — we don't need to write our own resampler.

**FFI Dart wrapper (`audio_io_ffi.dart`) changes:**
- `start()` calls `createWithConfig(frameDuration, sampleRate, format)`
- PCM16 mode: polling timer reads via `audio_io_read_pcm16` into `Int16List` → convert to `Uint8List` (zero-copy via `.buffer.asUint8List()`)
- Scale `framesPerPoll` with sample rate: 160 frames at 16kHz, 240 at 24kHz, 480 at 48kHz

### Web (`audio_io_web.dart`)

Web Audio API only supports Float32. Conversion to PCM16 happens in Dart.

- `AudioContext.sampleRate` is fixed by browser (usually 48kHz or 44.1kHz)
- When PCM16 requested: capture Float32 from ScriptProcessor → convert to Int16 LE in Dart
- When sample rate != browser rate: resample in Dart using simple linear interpolation (acceptable for speech)
- New file `lib/src/audio_converter.dart` provides web-only conversion utilities:
  - `float32ToPcm16Le(Float32List) → Uint8List`
  - `pcm16LeToFloat32(Uint8List) → Float32List`
  - `resample(Float32List, fromRate, toRate) → Float32List`

### Binary Protocol Changes

**iOS/macOS binary messenger:**
- `start` method channel call gains `Map` argument: `{"sampleRate": 16000, "format": "pcm16", "frameDurationMs": 20}`
- Input channel: raw bytes in the configured format (Int16 LE or Float64)
- Output channel: raw bytes in the configured format
- Dart side uses `config.format` to decode: `asInt16List()` vs `asFloat64List()`

**FFI protocol (Android/Linux/Windows):**
- New C functions for PCM16 read/write (separate from Float64 read/write)
- Dart allocates `Int16` native pointers for PCM16 mode, `Double` for Float64 mode

---

## Implementation Phases

### Phase 1: C++/miniaudio Native PCM16 + Sample Rate
- Add `AudioContext` config members (sampleRate, format)
- `audio_io_create_with_config`, `audio_io_read_pcm16`, `audio_io_write_pcm16`
- `Int16RingBuffer`
- Int16 conversion in `data_callback`
- Update FFI bindings and Dart wrapper
- **Test:** Android or Linux device at 16kHz PCM16

### Phase 2: iOS/macOS Native PCM16 + Sample Rate
- Accept config in `start` method channel
- Add format branching in sink/source node callbacks
- `AVAudioConverter` for resampling when hardware rate differs
- Frame chunk accumulator
- **Test:** iOS device at 16kHz PCM16

### Phase 3: Dart API Layer
- Add `AudioIoConfig`, `AudioIoFormat`, `AudioIoSampleRate` types
- Add `startWith()`, `inputBytes`/`outputBytes` to `AudioIo`
- Wire format-aware decoding of binary channel data
- Maintain backward compatibility of `start()`/`input`/`output`

### Phase 4: Web Conversion Layer
- `lib/src/audio_converter.dart` with Dart-side PCM16/resample for Web only
- Integration with `audio_io_web.dart`

### Phase 5: Frame Chunking (all platforms)
- Native-side chunk accumulators (iOS/macOS/C++)
- Dart-side chunk accumulator (Web)
- Configurable via `frameDurationMs`

### Phase 6: Example App & Documentation
- Gemini Live / real-time AI example
- Document duplex + PCM16 workflow
- Document actual vs requested sample rate (`getFormat()`)

---

## Compatibility

**Zero breaking changes.** All additions are purely additive.

| Existing API | Status |
|---|---|
| `start()` | Unchanged — defaults to 48kHz, Float64, Balanced |
| `input` / `output` | Unchanged — still `List<double>` |
| `requestLatency()` | Unchanged |

**Version bump:** 0.3.0 → 0.4.0 (minor, no breaking changes)

---

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Hardware can't run at 16kHz | miniaudio resamples internally; AVAudioConverter on iOS/macOS. `getFormat()` reports actual rate |
| Frame chunking adds latency | Expected — up to `frameDurationMs` added. Documented as explicit tradeoff |
| Web AudioContext rate not controllable | Dart-side resampler for Web only (acceptable — Web is inherently higher latency) |
| Two code paths per platform (Float64 vs PCM16) | Branch in existing callbacks, not separate pipelines. Keep conversion inline and simple |
| Int16 clipping on loud signals | Clamp to [-1.0, 1.0] before scaling. Standard practice |

## Open Questions

1. **Should `AudioIoSampleRate` be an enum or int?** Enum for now (self-documenting, prevents invalid rates). Easy to add values later.
2. **PCM16 endianness?** Always little-endian (matches AI API expectations). Explicit in docs.
3. **ScriptProcessorNode deprecation on Web?** Pre-existing tech debt — track separately.
4. **Ring buffer templating in C++?** Template `RingBuffer<T>` vs separate `Int16RingBuffer`. Template is cleaner but adds compile complexity for a Flutter plugin.
