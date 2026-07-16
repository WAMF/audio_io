# Gemini Live example

Real-time, two-way voice conversation with the Gemini Live API, built on
`audio_io`'s PCM16 streaming. Captures microphone audio as PCM16 @ 16 kHz,
streams it to Gemini over a WebSocket, and plays the model's 24 kHz reply back
through the speaker with mic suppression while the model is talking.

## Running

This example tracks only its Dart source and the platform files that carry the
microphone-permission setup (Info.plist usage strings, macOS entitlements, the
`AppDelegate`s that request mic access on launch, and the Android manifest
permissions). Generate the remaining platform scaffolding with:

```bash
cd example_gemini_live
flutter create --platforms=ios,macos,android,web .
flutter pub get
flutter run -d macos   # or -d <ios/android device id>, or -d chrome
```

`flutter create` fills in the build files (Xcode project, Podfile, Gradle, …)
without overwriting the committed `Info.plist` / `AppDelegate` / entitlements /
`AndroidManifest.xml`, so the mic-permission wiring is preserved. Runs on iOS,
macOS, Android, and the web.

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

## Limitations

This example is deliberately **half-duplex**: while the model is speaking the
mic is fully muted, so you cannot interrupt Gemini by voice ("barge-in"). The
mute exists to stop the model hearing its own playback and talking over itself.
`audio_io` only provides acoustic echo cancellation on iOS (voice-processing
I/O); on macOS, Android, Web, Windows, and Linux there is no cross-platform AEC,
so an always-open mic would feed the model's audio straight back into the
WebSocket. Full-duplex barge-in was therefore left out of the example rather
than shipped as behaviour that only works correctly on one platform.

A fuller integration that wanted barge-in would keep streaming mic audio during
playback and rely on Gemini's own VAD `interrupted` signal to stop playback (the
example already handles `interrupted` by flushing the queue and reopening the
mic), and/or gate the mic on a local VAD/energy threshold instead of muting
outright — both only safe once echo cancellation is available on the target
platform.

The mute is **self-healing**: if a turn's audio stops arriving without a
`turnComplete` / `interrupted` signal (a dropped socket message, say), a
watchdog timer resumes the mic shortly after the estimated playback end, so it
never sticks muted for the rest of the session.

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
- Android `AndroidManifest.xml`: `RECORD_AUDIO` and `INTERNET`. The Android
  `audio_io` backend requests the runtime mic permission when audio starts.
