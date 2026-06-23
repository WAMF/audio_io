# Gemini Live example

Real-time, two-way voice conversation with the Gemini Live API, built on
`audio_io`'s PCM16 streaming. Captures microphone audio as PCM16 @ 16 kHz,
streams it to Gemini over a WebSocket, and plays the model's 24 kHz reply back
through the speaker with mic suppression while the model is talking.

## Running

This example tracks only its Dart source and the platform files that carry the
microphone-permission setup (Info.plist usage strings, macOS entitlements, and
the `AppDelegate`s that request mic access on launch). Generate the remaining
platform scaffolding with:

```bash
cd example_gemini_live
flutter create --platforms=ios,macos .
flutter pub get
flutter run -d macos   # or: flutter run -d <your-ios-device-id>
```

`flutter create` fills in the build files (Xcode project, Podfile, …) without
overwriting the committed `Info.plist` / `AppDelegate` / entitlements, so the
mic-permission wiring is preserved.

Then paste a [Gemini API key](https://aistudio.google.com/apikey) into the app,
tap connect, allow microphone access, and start talking.

## How it works

- **Capture** — `AudioIo.startWith(AudioIoConfig(sampleRate: rate16000,
  format: pcm16))` exposes `inputBytes` as PCM16 @ 16 kHz, sent to Gemini as
  `realtimeInput.audio`.
- **Playback** — model audio (PCM16 @ 24 kHz) is resampled to 16 kHz and fed to
  `outputBytes` through a small **real-time burst buffer**: Gemini streams a
  whole turn faster than real time, so the audio is queued and drained at the
  real-time byte rate to avoid overrunning the engine's output ring buffer
  (which would drop samples and sound choppy).
- **Turn-taking** — the mic is suppressed while the model is speaking and
  reopened on `turnComplete` / `interrupted`, with a watchdog that recovers if
  an end-of-turn signal is dropped.

## Microphone permission

The native `AppDelegate` requests microphone access on launch
(`AVAudioApplication.requestRecordPermission` on iOS,
`AVCaptureDevice.requestAccess` on macOS); `permission_handler` is used as a
secondary nudge where available. `audio_io` itself only checks the
authorization status and throws if it has not been granted — it does not
request, by design — so the app must request it before `start()`.

Required platform setup (already committed here):

- iOS & macOS `Info.plist`: `NSMicrophoneUsageDescription`.
- macOS entitlements: `com.apple.security.device.audio-input` and
  `com.apple.security.network.client` (the latter for the Gemini WebSocket).
