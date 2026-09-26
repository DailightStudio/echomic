# echomic

Low-latency karaoke microphone app: phone mic -> real-time gain + echo -> phone speaker. iOS (AVAudioEngine) and Android (Oboe/AAudio LowLatency).

## Build

```bash
flutter pub get

# Android (minSdk 23, builds the native Oboe engine via CMake)
flutter run -d android

# iOS (plugins come in via Swift Package Manager; no CocoaPods)
flutter run -d ios
```

> Use earbuds/headphones to avoid acoustic feedback (mic -> speaker -> mic) when testing.

## Architecture

- `lib/` — Flutter UI shell + `MethodChannel` wrapper (`com.dailightstudio.echomic/audio`).
- `android/app/src/main/cpp/` — Oboe AAudio engine (Float, LowLatency, Exclusive) with a circular-buffer echo.
- `ios/Runner/` — `AVAudioEngine` + `AVAudioSession` (playAndRecord, 5 ms IO buffer) with the same circular-buffer echo.

### Echo algorithm (shared design)

```
delayed   = circularBuffer.read(delaySamples)
out       = in * gain + delayed * feedback
circularBuffer.write(out)
```

## Release

Android (Play): `flutter build appbundle --release` → `build/app/outputs/bundle/release/app-release.aab`.
Signing reads `android/key.properties` (gitignored) pointing at the upload keystore kept outside the repo;
without it the release build falls back to the debug key and Play rejects it. targetSdk follows
`flutter.targetSdkVersion` (Play requires 36 from 2026-08-31).

iOS (App Store): no Mac needed — `.github/workflows/build.yml` on a GitHub macOS runner.
Actions → Build → Run workflow: `ios_signed` = signed IPA artifact, `ios_upload` = send to
App Store Connect (the app record must exist; the ASC API cannot create apps).
Team `HB85X53L9D`, bundle `com.dailightstudio.echomic`, secrets `ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_P8`.
